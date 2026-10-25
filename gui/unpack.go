package main

// Unpacking a firmware file into the folder the Detect and UDFPS tabs read.
//
// Both tabs take "the folder that holds the unpacked ROM" and run a shell probe
// over it, because the probe is also the command line tool. The usual way to
// get that folder is a handful of commands that differ per platform — lpunpack
// for super.img, 7z or a Samsung-aware script for an AP, simg2img for the sparse
// ones — and on Windows there is no way to read EROFS at all. So the window does
// the unpacking itself, in Go, with no download and no package manager, and
// hands the probes a folder that looks exactly like a dump a user made by hand.
//
// What is extracted is deliberately not the whole ROM: the probes read
// build.prop files, the overlay APKs, framework-res.apk and the etc/*.rc|*.xml
// files that name a fingerprint sensor. Copying those (a few MB) out of a 9 GB
// super.img takes seconds and leaves the 9 GB where it is. The rules that pick
// them live in keepFirmwareFile, and the alternative — extract 7 GB so that a
// `find` can read eight files — is why this is worth explaining.

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"
)

// fileSystem is a read-only partition. Both readers implement it, so the
// extraction rules do not care whether the ROM was built with ext4 or EROFS.
type fileSystem interface {
	Kind() string
	Walk(fn func(rel string, size int64, isDir bool) error) error
	ReadPath(rel string) ([]byte, error)
}

func orRoot(p string) string {
	if p == "" {
		return "the root folder"
	}
	return p
}

// openFileSystem sniffs the filesystem of one partition image.
func openFileSystem(img image) (fileSystem, error) {
	var magic [4]byte
	if _, err := img.ReadAt(magic[:], erofsSuperOffset); err == nil {
		if le32(magic[:]) == erofsMagic {
			return newEROFSImage(img)
		}
	}
	var fs [2]byte
	if _, err := img.ReadAt(fs[:], 1024+0x38); err == nil {
		if le16(fs[:]) == ext4Magic {
			return newExt4Image(img)
		}
	}
	return nil, errors.New("neither ext4 nor EROFS")
}

// ---------------------------------------------------------------------------
// Sources: a folder, a super image, a Samsung AP
// ---------------------------------------------------------------------------

// unpackedPart is one filesystem found in the source, and where its bytes live.
type unpackedPart struct {
	Name  string
	Image image
}

// source is what the user pointed at, opened far enough to know its partitions.
type source struct {
	Label string
	Kind  string // "folder", "super", "ap", "image", "tree"
	Parts []unpackedPart
	extra []func() error // closers
	tmp   []string       // temp files made while opening (none today)
}

func (s *source) Close() {
	for _, f := range s.extra {
		_ = f()
	}
	for _, p := range s.tmp {
		_ = os.Remove(p)
	}
}

var errAlreadyUnpacked = errors.New("already an unpacked tree")

// classify resolves a file or folder into a list of partitions. The folder case
// is the friendly one: a fastboot ROM is a folder with images/super.img in it,
// a Samsung AP is a folder with AP_*.tar.md5 in it, and a tree a user already
// unpacked is a folder with system/build.prop — all three are just "the path".
func classify(p string) (*source, error) {
	abs, err := filepath.Abs(strings.TrimSpace(p))
	if err != nil {
		return nil, err
	}
	info, err := os.Stat(abs)
	if err != nil {
		return nil, errors.New("nothing at " + abs)
	}
	if info.IsDir() {
		return classifyDir(abs)
	}
	return classifyFile(abs)
}

func classifyDir(dir string) (*source, error) {
	name := filepath.Base(dir)

	// A tree that is already unpacked: the probes can read it as it is. This is
	// checked first so re-scanning an unpacked folder never re-walks it. It also
	// covers the app's own output, where the partitions are folders with an
	// _a/_b suffix (system_a/system/build.prop).
	if looksUnpacked(dir) {
		return nil, errAlreadyUnpacked
	}

	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil, err
	}
	var tars, supers, payloads []string
	for _, e := range entries {
		if e.IsDir() {
			continue
		}
		lower := strings.ToLower(e.Name())
		switch {
		case strings.HasSuffix(lower, ".tar.md5"), strings.HasSuffix(lower, ".tar"):
			tars = append(tars, filepath.Join(dir, e.Name()))
		case strings.HasPrefix(lower, "super.img"):
			supers = append(supers, filepath.Join(dir, e.Name()))
		case lower == "payload.bin":
			payloads = append(payloads, filepath.Join(dir, e.Name()))
		}
	}
	sort.Strings(tars)
	sort.Strings(supers)

	// images/ is where Redmi, Poco and most fastboot ROMs put super.img.
	if len(supers) == 0 && len(tars) == 0 {
		if sub := filepath.Join(dir, "images"); dirExists(sub) {
			if s, err := classifyDir(sub); err == nil {
				s.Label = dir
				return s, nil
			}
		}
	}
	switch {
	case len(supers) > 0:
		return classifyFile(supers[0])
	case len(tars) > 0:
		return classifyFile(tars[0])
	case len(payloads) > 0:
		return nil, errors.New("payload.bin is a Google OTA format. Extract the images with payload_dumper, or point at the fastboot ROM's super.img (super.img is in the images/ folder of a Redmi/Poco ROM)")
	}
	return nil, fmt.Errorf("no super.img, AP tar or unpacked system/ under %s — point at the ROM folder, its super.img, or a Samsung AP file", name)
}

func classifyFile(file string) (*source, error) {
	f, err := os.Open(file)
	if err != nil {
		return nil, err
	}
	ok := false
	defer func() {
		if !ok {
			f.Close()
		}
	}()

	st, err := f.Stat()
	if err != nil {
		return nil, err
	}
	raw := &rawImage{f: f, n: st.Size()}

	// A tar first: Samsung AP files carry a ustar header at 257.
	var tb [263]byte
	if _, err := raw.ReadAt(tb[:], 0); err == nil && string(tb[257:262]) == "ustar" {
		ok = true
		src, err := openSamsungTar(file, raw)
		if err != nil {
			raw.Close()
			return nil, err
		}
		return src, nil
	}

	img, kind, err := openContainer(raw)
	if err != nil {
		raw.Close()
		return nil, err
	}
	ok = true
	src := &source{Label: file, Kind: kind, extra: []func() error{f.Close}}
	if err := addPartitions(src, img, file); err != nil {
		src.Close()
		return nil, err
	}
	return src, nil
}

// isFileSystemImage reports whether an image starts with a filesystem this can
// read, without keeping anything it allocates.
func isFileSystemImage(img image) bool {
	fs, err := openFileSystem(img)
	if err != nil {
		return false
	}
	if c, ok := fs.(interface{ Close() error }); ok {
		_ = c.Close()
	}
	return true
}

// openContainer unwraps sparse and LZ4 until it finds something it recognises:
// a super image, or a single filesystem.
func openContainer(img image) (image, string, error) {
	for depth := 0; depth < 4; depth++ {
		var magic [4]byte
		if _, err := img.ReadAt(magic[:], 0); err != nil && err != io.EOF {
			return nil, "", err
		}
		switch {
		case le32(magic[:]) == sparseMagic:
			sp, err := newSparseImage(img)
			if err != nil {
				return nil, "", err
			}
			img = sp
		case le32(magic[:]) == lz4FrameMagic || le32(magic[:]) == lz4LegacyMagic:
			z, err := newLZ4Image(img)
			if err != nil {
				return nil, "", err
			}
			img = z
		default:
			// super images start with the LP geometry at 4096.
			var geo [4]byte
			if _, err := img.ReadAt(geo[:], lpReservedBytes); err == nil && le32(geo[:]) == lpGeometryMagic {
				return img, "super", nil
			}
			return img, "image", nil
		}
	}
	return nil, "", errors.New("the file is nested more deeply than a firmware image ever is")
}

func addPartitions(src *source, img image, label string) error {
	kind := src.Kind
	if kind == "super" || kind == "" {
		sup, err := newSuperImage(img)
		if err != nil {
			return err
		}
		for _, p := range sup.Partitions() {
			part, err := sup.Open(p.Name)
			if err != nil {
				continue
			}
			src.Parts = append(src.Parts, unpackedPart{Name: p.Name, Image: part})
		}
		if len(src.Parts) == 0 {
			return errors.New("the super image has no partitions in it")
		}
		src.Kind = "super"
		src.Label = label
		return nil
	}

	// A bare partition image (system.img, product.img): name it from the file,
	// which is also how a user's unpacked folder names it.
	if !isFileSystemImage(img) {
		return fmt.Errorf("%s is not an ext4 or EROFS image — point at super.img or a partition image", filepath.Base(label))
	}
	name := strings.TrimSuffix(filepath.Base(label), filepath.Ext(label))
	name = strings.TrimSuffix(name, ".img")
	src.Parts = append(src.Parts, unpackedPart{Name: sanitizeName(name), Image: img})
	return nil
}

// ---------------------------------------------------------------------------
// Samsung AP (a tar of .img.lz4 files)
// ---------------------------------------------------------------------------

type tarEntry struct {
	name string
	off  int64
	size int64
}

// scanTar indexes a tar without reading its contents: the entries are found by
// walking the 512-byte headers, and each body is then a window that can be read
// in any order. That is what lets a 9 GB super.img.lz4 be opened without being
// copied to a temp file first.
func scanTar(f *os.File, size int64) ([]tarEntry, error) {
	var out []tarEntry
	var hdr [512]byte
	off := int64(0)
	for off+512 <= size {
		if _, err := f.ReadAt(hdr[:], off); err != nil {
			return out, nil
		}
		empty := true
		for _, b := range hdr {
			if b != 0 {
				empty = false
				break
			}
		}
		if empty {
			return out, nil // end-of-archive marker
		}
		name := strings.TrimRight(string(hdr[0:100]), "\x00")
		if prefix := strings.TrimRight(string(hdr[345:500]), "\x00"); prefix != "" {
			name = prefix + "/" + name
		}
		sizeField := strings.TrimRight(string(hdr[124:136]), "\x00 ")
		n, err := strconv.ParseInt(strings.TrimSpace(sizeField), 8, 64)
		if err != nil || n < 0 {
			return nil, fmt.Errorf("%s: the tar entry %q has no readable size", filepath.Base(f.Name()), name)
		}
		typ := hdr[156]
		body := off + 512
		if typ == '0' || typ == 0 || typ == '7' {
			out = append(out, tarEntry{name: name, off: body, size: n})
		}
		off = body + (n+511)/512*512
	}
	return out, nil
}

func openSamsungTar(file string, raw *rawImage) (*source, error) {
	entries, err := scanTar(raw.f, raw.n)
	if err != nil {
		return nil, err
	}
	if len(entries) == 0 {
		return nil, errors.New("the tar holds no files")
	}

	src := &source{Label: file, Kind: "ap", extra: []func() error{raw.Close}}
	var wanted []tarEntry
	for _, e := range entries {
		base := strings.ToLower(path.Base(e.name))
		if !strings.HasSuffix(base, ".img") && !strings.HasSuffix(base, ".img.lz4") {
			continue // boot, vbmeta, param, userdata… are not filesystems we read
		}
		wanted = append(wanted, e)
	}
	if len(wanted) == 0 {
		return nil, errors.New("this AP has no .img or .img.lz4 entries — is it really a Samsung AP?")
	}

	// super.img first: it is the one that holds the partitions that matter.
	sort.SliceStable(wanted, func(i, j int) bool {
		return strings.HasPrefix(strings.ToLower(path.Base(wanted[i].name)), "super")
	})

	for _, e := range wanted {
		base := path.Base(e.name)
		win := section(raw, e.off, e.size)
		img, _, err := openContainer(win)
		if err != nil {
			continue
		}
		if strings.HasPrefix(strings.ToLower(base), "super") {
			if err := addPartitions(src, img, file); err != nil {
				continue
			}
			continue
		}
		// boot, dtbo, vbmeta… are .img files too, and none of them is a
		// filesystem; a partition the probes cannot read is not worth a folder.
		if !isFileSystemImage(img) {
			continue
		}
		name := strings.TrimSuffix(strings.TrimSuffix(base, ".lz4"), ".img")
		part := unpackedPart{Name: sanitizeName(name), Image: img}
		src.Parts = append(src.Parts, part)
	}
	if len(src.Parts) == 0 {
		return nil, errors.New("none of the images in this AP could be read")
	}
	return src, nil
}

// ---------------------------------------------------------------------------
// Extraction
// ---------------------------------------------------------------------------

// FirmwarePartition is what the page shows for one partition.
type FirmwarePartition struct {
	Name    string `json:"name"`
	FS      string `json:"fs"`
	SizeMB  int64  `json:"sizeMb"`
	Scanned int    `json:"scanned"`
	Kept    int    `json:"kept"`
	Bytes   int64  `json:"bytes"`
	Note    string `json:"note,omitempty"`
}

// FirmwareUnpack is the answer to "unpack this file": where the readable copy
// is and what was found in it.
type FirmwareUnpack struct {
	Source    string              `json:"source"`
	Kind      string              `json:"kind"`
	Dir       string              `json:"dir"`
	Cached    bool                `json:"cached"`
	Parts     []FirmwarePartition `json:"partitions"`
	Kept      int                 `json:"kept"`
	Bytes     int64               `json:"bytes"`
	ElapsedMS int64               `json:"elapsedMs"`
	Notes     []string            `json:"notes"`
	Warnings  []string            `json:"warnings"`
}

const firmwareCacheJSON = ".unpack.json"

// keepFirmwareFile is the extraction rule. It mirrors what
// stuff/scripts/device-probe.sh and udfps-probe.sh actually open:
//
//   - build.prop and any *.prop       -> the model, codename and panel properties
//   - */overlay/*.apk                 -> the OEM's own display overlays
//   - */framework/framework-res.apk   -> the AOSP defaults an overlay overrides
//   - */etc/**/*.rc and *.xml         -> fingerprint/sensor config named in them
//
// Everything else in a system partition is 99% of the bytes and none of the
// answers.
func keepFirmwareFile(rel string) bool {
	base := path.Base(rel)
	dir := path.Dir(rel)
	switch {
	case base == "build.prop", strings.HasSuffix(base, ".prop"):
		return true
	case base == "framework-res.apk":
		return true
	case strings.HasSuffix(base, ".apk") && strings.Contains("/"+dir+"/", "/overlay/"):
		return true
	case strings.Contains("/"+dir+"/", "/etc/") && (strings.HasSuffix(base, ".rc") || strings.HasSuffix(base, ".xml")):
		return true
	}
	return false
}

const maxKeptFile = 64 << 20

// unpackFirmware copies the files the probes read out of a firmware file and
// returns the folder to point them at.
func unpackFirmware(input string) (*FirmwareUnpack, error) {
	return unpackFirmwareTo(input, "")
}

// unpackFirmwareTo is unpackFirmware with a destination, which the command line
// uses to keep the extracted tree where the user asked for it.
func unpackFirmwareTo(input, dest string) (*FirmwareUnpack, error) {
	started := time.Now()
	abs, err := filepath.Abs(strings.TrimSpace(input))
	if err != nil {
		return nil, err
	}
	src, err := classify(abs)
	if err == errAlreadyUnpacked {
		return &FirmwareUnpack{
			Source: abs, Kind: "tree", Dir: abs, Cached: true,
			Parts: []FirmwarePartition{}, Notes: []string{"this folder is already unpacked — the scan reads it as it is"},
			Warnings: []string{},
		}, nil
	}
	if err != nil {
		return nil, err
	}
	defer src.Close()

	out := strings.TrimSpace(dest)
	if out == "" {
		out = firmwareOutDir(abs)
	} else if absOut, absErr := filepath.Abs(out); absErr == nil {
		out = absOut
	}
	res := &FirmwareUnpack{Source: abs, Kind: src.Kind, Dir: out, Notes: []string{}, Warnings: []string{}}

	key := firmwareCacheKey(abs)
	if cached, ok := readUnpackCache(out, key); ok {
		cached.Cached = true
		cached.ElapsedMS = time.Since(started).Milliseconds()
		return cached, nil
	}

	// A fresh extraction, so a half-written folder from an earlier run cannot
	// leak into this one.
	if err := os.RemoveAll(out); err != nil {
		return nil, fmt.Errorf("cannot clear %s: %w", out, err)
	}
	if err := os.MkdirAll(out, 0o755); err != nil {
		return nil, err
	}

	for _, part := range src.Parts {
		info := FirmwarePartition{Name: part.Name}
		fs, err := openFileSystem(part.Image)
		if err != nil {
			info.FS = "?"
			// The folder still has to exist so the probe's find does not fail.
			_ = os.MkdirAll(filepath.Join(out, part.Name), 0o755)
			info.Note = "not a filesystem this can read: " + err.Error()
			res.Parts = append(res.Parts, info)
			res.Warnings = append(res.Warnings, fmt.Sprintf("%s: %v", part.Name, err))
			continue
		}
		info.FS = fs.Kind()
		info.SizeMB = part.Image.Size() >> 20
		kept, bytes, scanned, skipped, err := extractPartition(fs, filepath.Join(out, part.Name))
		info.Kept, info.Bytes, info.Scanned = kept, bytes, scanned
		if err != nil {
			info.Note = err.Error()
			res.Warnings = append(res.Warnings, part.Name+": "+err.Error())
		} else if len(skipped) > 0 {
			// A file the reader cannot decode is a gap in the scan, not a
			// reason to fail the unpack; naming a few says which gap.
			info.Note = fmt.Sprintf("%d files could not be read (%s)", len(skipped), skipped[0])
			res.Warnings = append(res.Warnings, part.Name+": "+info.Note)
		}
		res.Kept += kept
		res.Bytes += bytes
		res.Parts = append(res.Parts, info)
	}

	if res.Kept == 0 {
		return res, errors.New("nothing readable came out of this firmware — none of its partitions held a file the scan uses")
	}

	res.ElapsedMS = time.Since(started).Milliseconds()
	writeUnpackCache(out, key, res)
	return res, nil
}

// extractPartition walks one partition and copies the kept files, returning how
// many it wrote and how large they are, plus the names of the few it could not
// decode so the caller can say so instead of quietly missing a build.prop.
func extractPartition(fs fileSystem, dest string) (kept int, bytes int64, scanned int, skipped []string, err error) {
	var paths []string
	err = fs.Walk(func(rel string, size int64, isDir bool) error {
		scanned++
		if isDir || !keepFirmwareFile(rel) || size > maxKeptFile {
			return nil
		}
		paths = append(paths, rel)
		return nil
	})
	if err != nil {
		return 0, 0, scanned, nil, err
	}

	for _, rel := range paths {
		data, err := fs.ReadPath(rel)
		if err != nil {
			// A file this reader cannot decode: skip it, keep the rest, but
			// remember it. Only the first few are named in the report.
			if len(skipped) < 5 {
				skipped = append(skipped, rel)
			}
			continue
		}
		dst := filepath.Join(dest, filepath.FromSlash(rel))
		if !strings.HasPrefix(dst, dest+string(filepath.Separator)) {
			continue // never write outside the partition folder
		}
		if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
			return kept, bytes, scanned, skipped, err
		}
		if err := os.WriteFile(dst, data, 0o644); err != nil {
			return kept, bytes, scanned, skipped, err
		}
		kept++
		bytes += int64(len(data))
	}
	if kept == 0 {
		// The folder still has to exist: the probe's `find` over it must not
		// fail just because a partition holds nothing it needs.
		if err := os.MkdirAll(dest, 0o755); err != nil {
			return 0, 0, scanned, skipped, err
		}
	}
	return kept, bytes, scanned, skipped, nil
}

// firmwareOutDir is where the extracted copy lives. Temp is the right place: it
// is a cache of files that are in the firmware anyway, and a user who wants to
// keep it can copy the folder the page prints.
func firmwareOutDir(file string) string {
	base := strings.TrimSuffix(filepath.Base(file), filepath.Ext(file))
	base = sanitizeName(strings.TrimSuffix(base, ".tar"))
	if base == "" {
		base = "firmware"
	}
	return filepath.Join(os.TempDir(), "treble-rro-firmware", base)
}

// firmwareCacheKey identifies the source well enough that editing or replacing
// the firmware file invalidates the cache.
func firmwareCacheKey(file string) string {
	info, err := os.Stat(file)
	if err != nil {
		return file
	}
	return fmt.Sprintf("%s|%d|%d|%d", file, info.Size(), info.ModTime().UnixNano(), unpackCacheVersion)
}

// unpackCacheVersion is bumped whenever the extraction rules change, so an
// older cache is rebuilt instead of silently missing a file the new rules want.
const unpackCacheVersion = 2

func readUnpackCache(dir, key string) (*FirmwareUnpack, bool) {
	raw, err := os.ReadFile(filepath.Join(dir, firmwareCacheJSON))
	if err != nil {
		return nil, false
	}
	var cached struct {
		Key  string          `json:"key"`
		Data *FirmwareUnpack `json:"data"`
	}
	if err := json.Unmarshal(raw, &cached); err != nil || cached.Key != key || cached.Data == nil {
		return nil, false
	}
	if _, err := os.Stat(filepath.Join(dir, "system")); err != nil {
		if _, err := os.Stat(dir); err != nil {
			return nil, false
		}
	}
	return cached.Data, true
}

func writeUnpackCache(dir, key string, res *FirmwareUnpack) {
	raw, err := json.MarshalIndent(struct {
		Key  string          `json:"key"`
		Data *FirmwareUnpack `json:"data"`
	}{key, res}, "", "  ")
	if err != nil {
		return
	}
	_ = os.WriteFile(filepath.Join(dir, firmwareCacheJSON), raw, 0o644)
}

// ---------------------------------------------------------------------------
// What the page is told
// ---------------------------------------------------------------------------

// FirmwareSource is the answer to "what was that path": the folder a probe can
// read, and what had to be done to get it. A path can be a tree the user
// unpacked themselves, a ROM folder, a bare super.img or a Samsung AP, and the
// page should say which one it was rather than pretend they are the same.
type FirmwareSource struct {
	Dir      string              `json:"dir"`
	Unpacked bool                `json:"unpacked"`
	Kind     string              `json:"kind,omitempty"`
	Source   string              `json:"source,omitempty"`
	Cached   bool                `json:"cached,omitempty"`
	Kept     int                 `json:"kept,omitempty"`
	Bytes    int64               `json:"bytes,omitempty"`
	Parts    []FirmwarePartition `json:"partitions,omitempty"`
	Notes    []string            `json:"notes,omitempty"`
	Warnings []string            `json:"warnings,omitempty"`
	Log      string              `json:"log,omitempty"`
}

// prepareFirmware accepts anything reasonable the user may point at — a tree
// they unpacked, a fastboot ROM folder, a bare super.img, a Samsung AP — and
// returns the folder the probe scripts can read.
func prepareFirmware(input string) (*FirmwareSource, error) {
	input = strings.TrimSpace(input)
	if input == "" {
		return nil, errors.New("point it at a super.img, a Samsung AP file, or a folder with a ROM in it")
	}
	abs, err := filepath.Abs(input)
	if err != nil {
		return nil, err
	}
	info, err := os.Stat(abs)
	if err != nil {
		return nil, errors.New("nothing at " + input)
	}
	if info.IsDir() && looksUnpacked(abs) {
		return &FirmwareSource{
			Dir: abs, Kind: "tree", Source: abs,
			Log: "reading " + abs + " as it is (already unpacked)",
		}, nil
	}

	res, err := unpackFirmware(abs)
	if err != nil {
		return nil, err
	}
	src := &FirmwareSource{
		Dir: res.Dir, Unpacked: true, Kind: res.Kind, Source: res.Source,
		Cached: res.Cached, Kept: res.Kept, Bytes: res.Bytes, Parts: res.Parts,
		Notes: res.Notes, Warnings: res.Warnings,
	}
	var b strings.Builder
	fmt.Fprintf(&b, "unpacked %s (%s) to %s\n", filepath.Base(res.Source), res.Kind, res.Dir)
	for _, p := range res.Parts {
		if p.FS == "?" {
			fmt.Fprintf(&b, "  %-16s %s\n", p.Name, p.Note)
			continue
		}
		fmt.Fprintf(&b, "  %-16s %-6s %5d MB  %d files\n", p.Name, p.FS, p.SizeMB, p.Kept)
	}
	when := time.Duration(res.ElapsedMS) * time.Millisecond
	if res.Cached {
		fmt.Fprintf(&b, "%s in %d files, from the cache (%s)\n", humanBytes(res.Bytes), res.Kept, when)
	} else {
		fmt.Fprintf(&b, "%s in %d files, read in %s\n", humanBytes(res.Bytes), res.Kept, when)
	}
	src.Log = strings.TrimRight(b.String(), "\n")
	return src, nil
}

// fwLog is the unpacking part of a probe's log, empty when the path was already
// a tree and nothing was extracted.
func fwLog(fw *FirmwareSource) string {
	if fw == nil {
		return ""
	}
	return fw.Log
}

// ensureProbeTools installs the one external tool a firmware scan uses.
//
// The unpacking itself is Go and needs nothing installed, on any platform. The
// scans do need aapt2 to read the overlay APKs and framework-res.apk, and that
// is the same aapt2 a build uses — so a missing one is installed by the same
// setup run, which picks apt, pacman, pkg (Termux) or a download per platform.
func (a *App) ensureProbeTools(mode string) (string, error) {
	if mode != "firmware" || a.aapt2Usable() {
		return "", nil
	}
	bash := a.Bash()
	if bash == "" {
		return "", errors.New("aapt2 is missing and there is no bash to install it with")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Minute)
	defer cancel()
	cmd := exec.CommandContext(ctx, bash, "--noprofile", "--norc", "./build.sh", "setup", "-y")
	cmd.Dir = a.Root()
	cmd.Env = append(os.Environ(), "TERM=dumb")
	out, err := cmd.CombinedOutput()
	log := strings.TrimSpace(string(out))
	if ctx.Err() == context.DeadlineExceeded {
		return log, errors.New("installing aapt2 took longer than 10 minutes and was stopped")
	}
	if err != nil {
		return log, fmt.Errorf("aapt2 is missing and installing it failed: %v", err)
	}
	if !a.aapt2Usable() {
		return log, errors.New("aapt2 was installed but cannot be run on this machine")
	}
	return log, nil
}

// aapt2Usable asks aapt2 to print its version. A copy from the wrong platform
// (a Linux aapt2 left in stuff/tools by a WSL run) exists but cannot execute,
// and that is exactly the case a plain file check misses.
func (a *App) aapt2Usable() bool {
	path := a.aapt2Path()
	if path == "" {
		return false
	}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	return exec.CommandContext(ctx, path, "version").Run() == nil
}

// looksUnpacked reports whether a folder is already a tree the probes read,
// which is the one case where nothing has to be extracted.
//
// The probe scripts find their files by name at any depth, so the question is
// whether any child looks like a partition root: system/build.prop for a dump,
// system_a/system/build.prop for this app's own output, vendor_a/build.prop,
// product_a/overlay for the part of a partition that has no build.prop.
func looksUnpacked(dir string) bool {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return false
	}
	for _, e := range entries {
		if !e.IsDir() {
			continue
		}
		sub := filepath.Join(dir, e.Name())
		for _, rel := range []string{"build.prop", "system/build.prop", "etc/build.prop", "prop.default"} {
			if fileExists(filepath.Join(sub, filepath.FromSlash(rel))) {
				return true
			}
		}
		if dirExists(filepath.Join(sub, "overlay")) {
			return true
		}
	}
	return false
}

// ---------------------------------------------------------------------------
// Command line
// ---------------------------------------------------------------------------

// unpackCLI is `gui -unpack PATH`: the same extraction the Detect tab runs, for
// a terminal or a script. It prints the folder to point a probe at, so the
// documented command line and the window cannot disagree.
func unpackCLI(input, dest string, asJSON bool) int {
	res, err := unpackFirmwareTo(input, dest)
	if err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		if res != nil {
			for _, w := range res.Warnings {
				fmt.Fprintln(os.Stderr, "  warning:", w)
			}
		}
		return 1
	}
	if asJSON {
		raw, _ := json.MarshalIndent(res, "", "  ")
		fmt.Println(string(raw))
		return 0
	}

	fmt.Printf("%s — %s\n", res.Source, res.Kind)
	fmt.Printf("unpacked to %s\n", res.Dir)
	for _, p := range res.Parts {
		if p.FS == "?" {
			fmt.Printf("  %-16s %s\n", p.Name, p.Note)
			continue
		}
		fmt.Printf("  %-16s %-6s %5d MB  %d files kept\n", p.Name, p.FS, p.SizeMB, p.Kept)
	}
	fmt.Printf("\n%s in %d files, read in %s\n", humanBytes(res.Bytes), res.Kept, time.Duration(res.ElapsedMS)*time.Millisecond)
	for _, n := range res.Notes {
		fmt.Println("note:", n)
	}
	for _, w := range res.Warnings {
		fmt.Println("warning:", w)
	}
	fmt.Printf("\nscan it with: bash stuff/scripts/device-probe.sh --firmware %q\n", res.Dir)
	return 0
}

// ---------------------------------------------------------------------------
// Byte helpers shared by the readers
// ---------------------------------------------------------------------------

func le16(b []byte) uint16 { return uint16(b[0]) | uint16(b[1])<<8 }
func le32(b []byte) uint32 {
	return uint32(b[0]) | uint32(b[1])<<8 | uint32(b[2])<<16 | uint32(b[3])<<24
}
