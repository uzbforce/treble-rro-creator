package main

// Tests for the unpacker. The format-level parts (a tar index, an LZ4 frame) are
// built in memory; the part that needs a real Android image is skipped unless
// TREBLE_TEST_FIRMWARE points at a super.img or a ROM folder, because no CI
// machine has a 7 GB ROM checked in.

import (
	"archive/tar"
	"bytes"
	"encoding/binary"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func writeTestTar(t *testing.T, path string, files map[string][]byte) {
	t.Helper()
	f, err := os.Create(path)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	tw := tar.NewWriter(f)
	// Map iteration order is random on purpose: the reader must not depend on it.
	for name, body := range files {
		h := &tar.Header{Name: name, Mode: 0o644, Size: int64(len(body)), Typeflag: tar.TypeReg}
		if err := tw.WriteHeader(h); err != nil {
			t.Fatal(err)
		}
		if _, err := tw.Write(body); err != nil {
			t.Fatal(err)
		}
	}
	if err := tw.Close(); err != nil {
		t.Fatal(err)
	}
}

func TestScanTarFindsBodies(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "AP_TEST.tar.md5")
	body := []byte("not really an image, but the index does not care")
	writeTestTar(t, path, map[string][]byte{
		"boot.img":                      []byte("boot"),
		"super.img":                     body,
		"vendor.img":                    []byte("vendor"),
		"META-INF/com/android/metadata": []byte("x"),
	})

	f, err := os.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	st, _ := f.Stat()
	entries, err := scanTar(f, st.Size())
	if err != nil {
		t.Fatal(err)
	}
	got := map[string]int64{}
	for _, e := range entries {
		got[e.name] = e.size
		// Every body must actually be where the index says it is.
		raw := make([]byte, e.size)
		if e.size > 0 {
			if _, err := f.ReadAt(raw, e.off); err != nil {
				t.Fatalf("%s: read at %d: %v", e.name, e.off, err)
			}
		}
		if e.name == "super.img" && string(raw) != string(body) {
			t.Fatalf("super.img body is not where the index points")
		}
	}
	if len(got) != 4 {
		t.Fatalf("want 4 entries, got %d: %v", len(got), got)
	}
	if got["super.img"] != int64(len(body)) {
		t.Fatalf("super.img size: want %d, got %d", len(body), got["super.img"])
	}
}

// writeLZ4Frame writes a legal LZ4 frame made of stored blocks. A real Samsung
// AP uses compressed blocks, but the frame parser and the block index are the
// same code either way, and a stored block is what a test can produce without
// an LZ4 compressor.
func writeLZ4Frame(t *testing.T, path string, data []byte) {
	t.Helper()
	f, err := os.Create(path)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()

	var out []byte
	magic := make([]byte, 4)
	binary.LittleEndian.PutUint32(magic, lz4FrameMagic)
	out = append(out, magic...)
	out = append(out, 0x60, 0x40, 0x00) // independent blocks, 64 KB max, dummy checksum
	for len(data) > 0 {
		n := len(data)
		if n > 64<<10 {
			n = 64 << 10
		}
		var bh [4]byte
		binary.LittleEndian.PutUint32(bh[:], uint32(n)|0x80000000)
		out = append(out, bh[:]...)
		out = append(out, data[:n]...)
		data = data[n:]
	}
	out = append(out, 0, 0, 0, 0) // end mark
	if _, err := f.Write(out); err != nil {
		t.Fatal(err)
	}
}

// carve writes one partition of a super image to its own file, which is what a
// Samsung AP holds (system.img, vendor.img, … as separate entries).
func carve(t *testing.T, part unpackedPart, path string) {
	t.Helper()
	f, err := os.Create(path)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	buf := make([]byte, 1<<20)
	var off int64
	for off < part.Image.Size() {
		n := int64(len(buf))
		if off+n > part.Image.Size() {
			n = part.Image.Size() - off
		}
		got, err := part.Image.ReadAt(buf[:n], off)
		if err != nil && got == 0 {
			t.Fatalf("carve %s at %d: %v", part.Name, off, err)
		}
		if _, err := f.Write(buf[:got]); err != nil {
			t.Fatal(err)
		}
		off += int64(got)
	}
}

// TestSamsungAP builds an AP out of a partition from the real firmware: the tar
// holds a plain .img and an .img.lz4, and both have to come back as a readable
// filesystem.
func TestSamsungAP(t *testing.T) {
	fw := strings.TrimSpace(os.Getenv("TREBLE_TEST_FIRMWARE"))
	if fw == "" {
		t.Skip("set TREBLE_TEST_FIRMWARE to a super.img or ROM folder to run this")
	}
	src, err := classify(fw)
	if err != nil {
		t.Fatalf("%s: %v", fw, err)
	}
	defer src.Close()

	// The smallest partition keeps the test quick and still exercises tar,
	// LZ4 and the filesystem reader.
	var pick unpackedPart
	for _, p := range src.Parts {
		if pick.Image == nil || p.Image.Size() < pick.Image.Size() {
			pick = p
		}
	}
	if pick.Image == nil {
		t.Fatal("no partitions in that firmware")
	}

	dir := t.TempDir()
	raw := filepath.Join(dir, "system.img")
	carve(t, pick, raw)
	body, err := os.ReadFile(raw)
	if err != nil {
		t.Fatal(err)
	}
	lz4 := filepath.Join(dir, "vendor.img.lz4")
	writeLZ4Frame(t, lz4, body)

	ap := filepath.Join(dir, "AP_TEST.tar.md5")
	writeTestTar(t, ap, map[string][]byte{
		"boot.img":       []byte("boot"),
		"system.img":     body,
		"vendor.img.lz4": nil,
	})
	// The map above cannot express "read this file's bytes", so put the frame in
	// as a second pass: rewrite the tar with both bodies in one place.
	frame, err := os.ReadFile(lz4)
	if err != nil {
		t.Fatal(err)
	}
	writeTestTar(t, ap, map[string][]byte{
		"boot.img":       []byte("boot"),
		"system.img":     body,
		"vendor.img.lz4": frame,
	})

	asrc, err := classify(ap)
	if err != nil {
		t.Fatalf("classify AP: %v", err)
	}
	defer asrc.Close()
	if len(asrc.Parts) != 2 {
		t.Fatalf("want 2 filesystems in the AP, got %d: %+v", len(asrc.Parts), asrc.Parts)
	}
	for _, p := range asrc.Parts {
		fsys, err := openFileSystem(p.Image)
		if err != nil {
			t.Fatalf("%s: %v", p.Name, err)
		}
		if fsys.Kind() != "erofs" && fsys.Kind() != "ext4" {
			t.Fatalf("%s: unexpected filesystem %s", p.Name, fsys.Kind())
		}
		// The carved partition is byte-identical to the original, so the same
		// files must be readable through the tar.
		var want string
		var wantSize int64
		_ = fsys.Walk(func(rel string, size int64, isDir bool) error {
			if !isDir && want == "" && keepFirmwareFile(rel) {
				want, wantSize = rel, size
			}
			return nil
		})
		if want == "" {
			continue // this partition holds none of the files the probes read
		}
		data, err := fsys.ReadPath(want)
		if err != nil {
			t.Fatalf("%s: %s: %v", p.Name, want, err)
		}
		if int64(len(data)) != wantSize {
			t.Fatalf("%s: %s came back as %d bytes, want %d", p.Name, want, len(data), wantSize)
		}
	}
}

// buildExt4Fixture makes a small 64-bit ext4 image with e2fsprogs, which is how
// a real system.img is made. It reports false where mkfs.ext4/debugfs are not
// installed, so the test skips instead of failing a Windows machine.
func buildExt4Fixture(t *testing.T) (string, bool) {
	t.Helper()
	if _, err := exec.LookPath("mkfs.ext4"); err != nil {
		return "", false
	}
	if _, err := exec.LookPath("debugfs"); err != nil {
		return "", false
	}
	dir := t.TempDir()
	img := filepath.Join(dir, "system.img")
	if out, err := exec.Command("mkfs.ext4", "-q", "-b", "4096", "-O", "64bit,metadata_csum,extent", img).CombinedOutput(); err != nil {
		t.Logf("mkfs.ext4: %v: %s", err, out)
		return "", false
	}
	prop := filepath.Join(dir, "build.prop")
	body := "ro.product.vendor.device=zephyr\nro.sf.lcd_density=450\n"
	if err := os.WriteFile(prop, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	for _, cmd := range []string{
		"mkdir /system",
		"write " + prop + " /system/build.prop",
	} {
		if out, err := exec.Command("debugfs", "-w", "-R", cmd, img).CombinedOutput(); err != nil {
			t.Logf("debugfs %s: %v: %s", cmd, err, out)
			return "", false
		}
	}
	return img, true
}

// TestExt4Image reads a real mkfs.ext4 image. The 64-bit flag matters: with it
// the group descriptors are 64 bytes and an address is split across two halves,
// which is the shape every current Android image has.
func TestExt4Image(t *testing.T) {
	img := strings.TrimSpace(os.Getenv("TREBLE_TEST_EXT4"))
	if img == "" {
		if made, ok := buildExt4Fixture(t); ok {
			img = made
		}
	}
	if img == "" {
		t.Skip("set TREBLE_TEST_EXT4 to an ext4 image, or install e2fsprogs to build one")
	}
	f, err := os.Open(img)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	st, err := f.Stat()
	if err != nil {
		t.Fatal(err)
	}
	fsys, err := openFileSystem(&rawImage{f: f, n: st.Size()})
	if err != nil {
		t.Fatal(err)
	}
	if fsys.Kind() != "ext4" {
		t.Fatalf("want ext4, got %s", fsys.Kind())
	}
	data, err := fsys.ReadPath("system/build.prop")
	if err != nil {
		t.Fatalf("ReadPath: %v", err)
	}
	trimmed := strings.TrimSpace(string(data))
	if !strings.Contains(trimmed, "ro.product.vendor.device=zephyr") {
		t.Fatalf("build.prop came back as %q", trimmed)
	}
}

// buildSuperFixture writes a super.img by hand: geometry at 4096 (twice, as
// liblp writes it), two metadata slots, and partition data at sector-aligned
// offsets. No tool on a CI machine can produce one — lpmake is part of the
// Android build tree — and the LP format is simple enough that a synthetic
// image tests the reader rather than a skipped test testing nothing.
//
// The layout is what lpmake emits: system spread over two extents, vendor in
// one, and a disabled userdata that must not show up at all.
func buildSuperFixture(t *testing.T, path string) map[string][]byte {
	t.Helper()
	const (
		metaMax     = 4096
		slots       = 2
		headerSize  = 128
		partSize    = 52
		extentSize  = 24
		sectorBytes = 512
	)

	geo := make([]byte, lpGeometrySize)
	binary.LittleEndian.PutUint32(geo[0:], lpGeometryMagic)
	binary.LittleEndian.PutUint32(geo[4:], 52)
	binary.LittleEndian.PutUint32(geo[40:], metaMax)
	binary.LittleEndian.PutUint32(geo[44:], slots)
	binary.LittleEndian.PutUint32(geo[48:], 4096)

	// name, attributes, first extent, number of extents
	parts := []struct {
		name  string
		attrs uint32
		first uint32
		num   uint32
	}{
		{"system", 0, 0, 2},
		{"vendor", 0, 2, 1},
		{"userdata", 0x2, 3, 1}, // LP_PARTITION_ATTR_DISABLED
	}
	// numSectors, targetType, target sector
	exts := []struct {
		sectors uint64
		typ     uint32
		at      uint64
	}{
		{2, 0, 64},
		{1, 0, 200},
		{1, 0, 300},
		{1, 0, 400},
	}

	tables := make([]byte, len(parts)*partSize+len(exts)*extentSize)
	for i, p := range parts {
		b := tables[i*partSize:]
		copy(b[:36], p.name)
		binary.LittleEndian.PutUint32(b[36:], p.attrs)
		binary.LittleEndian.PutUint32(b[40:], p.first)
		binary.LittleEndian.PutUint32(b[44:], p.num)
		binary.LittleEndian.PutUint32(b[48:], 0) // the default group
	}
	extBase := len(parts) * partSize
	for i, e := range exts {
		b := tables[extBase+i*extentSize:]
		binary.LittleEndian.PutUint64(b[0:], e.sectors)
		binary.LittleEndian.PutUint32(b[8:], e.typ)
		binary.LittleEndian.PutUint64(b[12:], e.at)
	}

	head := make([]byte, metaMax)
	binary.LittleEndian.PutUint32(head[0:], lpMetadataMagic)
	binary.LittleEndian.PutUint16(head[4:], 10) // major
	binary.LittleEndian.PutUint16(head[6:], 2)  // minor
	binary.LittleEndian.PutUint32(head[8:], headerSize)
	binary.LittleEndian.PutUint32(head[44:], uint32(len(tables)))
	// offset, entries, entry size — the four table descriptors, in order.
	binary.LittleEndian.PutUint32(head[80:], 0)
	binary.LittleEndian.PutUint32(head[84:], uint32(len(parts)))
	binary.LittleEndian.PutUint32(head[88:], partSize)
	binary.LittleEndian.PutUint32(head[92:], uint32(extBase))
	binary.LittleEndian.PutUint32(head[96:], uint32(len(exts)))
	binary.LittleEndian.PutUint32(head[100:], extentSize)
	binary.LittleEndian.PutUint32(head[104:], 0)
	binary.LittleEndian.PutUint32(head[108:], 0)
	binary.LittleEndian.PutUint32(head[112:], 0)
	copy(head[headerSize:], tables)

	// The data area starts after both metadata slots.
	img := make([]byte, 256<<10)
	copy(img[lpReservedBytes:], geo)
	copy(img[lpReservedBytes+lpGeometrySize:], geo)
	copy(img[lpReservedBytes+lpGeometrySize*2:], head)

	want := map[string][]byte{}
	fill := func(name string, at, sectors uint64, b byte) {
		body := bytes.Repeat([]byte{b}, int(sectors)*sectorBytes)
		copy(img[int(at)*sectorBytes:], body)
		want[name] = append(want[name], body...)
	}
	fill("system", 64, 2, 0x11)
	fill("system", 200, 1, 0x22)
	fill("vendor", 300, 1, 0x33)
	fill("userdata", 400, 1, 0x44)

	if err := os.WriteFile(path, img, 0o644); err != nil {
		t.Fatal(err)
	}
	return want
}

// TestSuperImage covers the container every modern ROM ships in: the metadata
// is parsed, extents are stitched into one partition, and the classifications
// the unpacker makes from a path agree with the reader.
func TestSuperImage(t *testing.T) {
	path := filepath.Join(t.TempDir(), "super.img")
	want := buildSuperFixture(t, path)

	f, err := os.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	st, err := f.Stat()
	if err != nil {
		t.Fatal(err)
	}
	sup, err := newSuperImage(&rawImage{f: f, n: st.Size()})
	if err != nil {
		t.Fatalf("newSuperImage: %v", err)
	}

	var names []string
	for _, p := range sup.Partitions() {
		names = append(names, p.Name)
	}
	if strings.Join(names, ",") != "system,vendor" {
		t.Fatalf("partitions: want system,vendor got %v (the disabled one must not appear)", names)
	}

	for _, name := range names {
		part, err := sup.Open(name)
		if err != nil {
			t.Fatalf("Open(%s): %v", name, err)
		}
		if part.Size() != int64(len(want[name])) {
			t.Fatalf("%s size: want %d, got %d", name, len(want[name]), part.Size())
		}
		got := make([]byte, part.Size())
		if _, err := part.ReadAt(got, 0); err != nil {
			t.Fatalf("read %s: %v", name, err)
		}
		if !bytes.Equal(got, want[name]) {
			i := 0
			for i < len(got) && i < len(want[name]) && got[i] == want[name][i] {
				i++
			}
			t.Fatalf("%s diverges at byte %d of %d: want %#x, got %#x", name, i, len(got), want[name][i], got[i])
		}
	}

	// A read that starts in the first extent and ends in the second, which is
	// the one read a naive implementation gets wrong.
	part, err := sup.Open("system")
	if err != nil {
		t.Fatal(err)
	}
	span := make([]byte, 48)
	if _, err := part.ReadAt(span, 1000); err != nil {
		t.Fatalf("read across the extent boundary: %v", err)
	}
	for i, b := range span {
		wantByte := byte(0x11)
		if i >= 24 {
			wantByte = 0x22
		}
		if b != wantByte {
			t.Fatalf("byte %d of a spanning read: want %#x, got %#x", i, wantByte, b)
		}
	}
	if _, err := part.ReadAt(make([]byte, 8), part.Size()); err != io.EOF {
		t.Fatalf("read past the end: want EOF, got %v", err)
	}
	if _, err := sup.Open("nope"); err == nil {
		t.Fatal("a partition that is not there must be an error")
	}

	// The path the page sends: a bare super.img has to classify as a super
	// image and hand back the same partitions the reader sees.
	src, err := classify(path)
	if err != nil {
		t.Fatalf("classify: %v", err)
	}
	defer src.Close()
	if src.Kind != "super" {
		t.Fatalf("kind: want super, got %q", src.Kind)
	}
	if len(src.Parts) != 2 {
		t.Fatalf("want 2 partitions from classify, got %d", len(src.Parts))
	}
	for _, p := range src.Parts {
		payload := make([]byte, p.Image.Size())
		if _, err := p.Image.ReadAt(payload, 0); err != nil {
			t.Fatalf("%s through classify: %v", p.Name, err)
		}
		if !bytes.Equal(payload, want[p.Name]) {
			t.Fatalf("%s through classify has the wrong bytes", p.Name)
		}
	}

	// Damaged geometry has to say so, not panic or read garbage.
	broken := filepath.Join(t.TempDir(), "broken.img")
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	binary.LittleEndian.PutUint32(raw[lpReservedBytes+44:], 0) // metadata slots
	if err := os.WriteFile(broken, raw, 0o644); err != nil {
		t.Fatal(err)
	}
	bf, err := os.Open(broken)
	if err != nil {
		t.Fatal(err)
	}
	defer bf.Close()
	if _, err := newSuperImage(&rawImage{f: bf, n: int64(len(raw))}); err == nil || !strings.Contains(err.Error(), "not credible") {
		t.Fatalf("broken geometry: want a refusal, got %v", err)
	}
}

// TestUnpackRealFirmware runs the whole extraction against a real ROM: every
// file the scan keeps has to come back, and the tree has to be shaped the way
// the probe scripts expect to find it.
func TestUnpackRealFirmware(t *testing.T) {
	fw := strings.TrimSpace(os.Getenv("TREBLE_TEST_FIRMWARE"))
	if fw == "" {
		t.Skip("set TREBLE_TEST_FIRMWARE to a super.img or ROM folder to run this")
	}
	res, err := unpackFirmware(fw)
	if err != nil {
		t.Fatalf("unpack: %v", err)
	}
	if res.Kept == 0 || len(res.Parts) == 0 {
		t.Fatalf("nothing came out: %+v", res)
	}
	for _, p := range res.Parts {
		if p.FS == "?" {
			continue
		}
		if _, err := os.Stat(filepath.Join(res.Dir, p.Name)); err != nil {
			t.Fatalf("%s: partition folder missing: %v", p.Name, err)
		}
	}
	// build.prop is the file every scan starts from, in at least one partition.
	var props []string
	_ = filepath.WalkDir(res.Dir, func(path string, d os.DirEntry, err error) error {
		if err == nil && !d.IsDir() && d.Name() == "build.prop" {
			props = append(props, path)
		}
		return nil
	})
	if len(props) == 0 {
		t.Fatalf("no build.prop under %s after unpacking %d files", res.Dir, res.Kept)
	}
	t.Logf("%s: %d files, %s, %d build.prop, %d ms", res.Kind, res.Kept, humanBytes(res.Bytes), len(props), res.ElapsedMS)
}

// TestAapt2UsableRejectsAStaleBinary covers the case a plain file check gets
// wrong: a Linux aapt2 left in stuff/tools by a WSL run on a Windows machine
// exists but cannot be executed, so it has to count as missing.
func TestAapt2UsableRejectsAStaleBinary(t *testing.T) {
	root := t.TempDir()
	tools := filepath.Join(root, "stuff", "tools")
	if err := os.MkdirAll(tools, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(tools, "aapt2"), []byte("not an executable\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	app := &App{root: root}
	if app.aapt2Path() == "" {
		t.Fatal("the file exists, so aapt2Path should find it")
	}
	if app.aapt2Usable() {
		t.Fatal("a file that cannot run must not be reported as usable")
	}
}

func TestPrepareFirmwareRejectsMissing(t *testing.T) {
	if _, err := prepareFirmware(filepath.Join(t.TempDir(), "nope")); err == nil {
		t.Fatal("a missing path was accepted")
	}
	if _, err := prepareFirmware(""); err == nil {
		t.Fatal("an empty path was accepted")
	}
}

func TestPrepareFirmwareReadsATree(t *testing.T) {
	dir := t.TempDir()
	if err := os.MkdirAll(filepath.Join(dir, "system"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "system", "build.prop"), []byte("ro.product.device=zephyr\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	src, err := prepareFirmware(dir)
	if err != nil {
		t.Fatal(err)
	}
	if src.Unpacked || src.Dir != dir {
		t.Fatalf("a tree should be read as it is: %+v", src)
	}
	if src.Log == "" {
		t.Fatal("no log line for a tree")
	}
}
