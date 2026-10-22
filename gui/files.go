package main

// ---------------------------------------------------------------------------
// The src/ workspace
// ---------------------------------------------------------------------------
// Everything the build reads lives under src/: the overlay resources, the
// module scripts, the optional vendor HAL tree and the on-device WebUI. Until
// now the app could only run build.sh; a HAL binary, a VINTF fragment or a
// SELinux rule had to be dropped in with Explorer or `cp`, which is exactly the
// step that made the CLI mandatory.
//
// This file is the other half: a small, allow-listed file manager over src/.
// The rules it follows are the ones the rest of the app follows too.
//
//   - Every path from the UI is relative to src/ and is re-validated here
//     (safeRel): no absolute paths, no `..`, no drive letters, no separators
//     that Windows would read differently. The endpoint surface stays an
//     allow-list, not "write this path".
//   - "Disable" is a move into src/.disabled/, which mirrors the tree. The file
//     stays on disk and in the clone (so it survives an update and can be
//     re-enabled with one click), but it leaves every directory the build
//     reads, which is why nothing in stuff/scripts has to know about it.
//     A rename would not work: aapt2 rejects res/values/foo.xml.off outright
//     ("file name cannot contain '.' other than for specifying the extension"),
//     so a disabled resource has to leave res/ rather than change its name.
//   - Two file kinds are understood rather than merely stored: a
//     sepolicy.rule and a VINTF manifest are checked on read, on save and on
//     request, so a rule that the module cannot apply, or a manifest that
//     declares the wrong HAL format, is reported in the window instead of on
//     the phone after a flash.
// ---------------------------------------------------------------------------

import (
	"bytes"
	"encoding/json"
	"encoding/xml"
	"errors"
	"fmt"
	"io"
	"mime"
	"net/http"
	"os"
	"path"
	"path/filepath"
	"strings"
	"unicode/utf8"
)

const (
	// disabledDir sits inside src/ so a disabled file travels with the clone.
	disabledDir = ".disabled"

	// Limits. The editable ones are generous for text and small enough that a
	// mistake (opening a 400 MB .so in a textarea) fails fast.
	maxFilesListed = 5000
	maxTextBytes   = 4 << 20   // what the editor will open and save
	maxUploadBody  = 512 << 20 // one multipart upload
	maxUploadPart  = 256 << 20 // one file inside it
)

var (
	errNoClone = errors.New("no clone selected")
	errNoSrc   = errors.New("this clone has no src/ folder")
)

// ---------------------------------------------------------------------------
// Paths
// ---------------------------------------------------------------------------
func (a *App) srcDir() (string, error) {
	root := a.Root()
	if !isClone(root) {
		return "", errNoClone
	}
	src := filepath.Join(root, "src")
	if !dirExists(src) {
		return "", errNoSrc
	}
	return src, nil
}

// safeRel normalises a path the UI sent and refuses anything that could leave
// src/. The empty string means src/ itself, which is only useful as an upload
// or creation target.
func safeRel(p string) (string, error) {
	p = strings.TrimSpace(strings.ReplaceAll(p, `\`, "/"))
	if p == "" {
		return "", nil
	}
	if strings.ContainsRune(p, 0) {
		return "", errors.New("that path contains a null byte")
	}
	if strings.HasPrefix(p, "/") || path.IsAbs(p) {
		return "", errors.New("paths are relative to src/")
	}
	if len(p) >= 2 && p[1] == ':' {
		return "", errors.New("paths are relative to src/")
	}
	clean := path.Clean(p)
	if clean == "." {
		return "", nil
	}
	if clean == ".." || strings.HasPrefix(clean, "../") {
		return "", errors.New("that path points outside src/")
	}
	for _, seg := range strings.Split(clean, "/") {
		if seg == "" || seg == "." || seg == ".." {
			return "", errors.New("that path is not a plain relative path")
		}
		if seg == disabledDir {
			return "", fmt.Errorf("src/%s is managed by the Disable button", disabledDir)
		}
		if strings.ContainsAny(seg, `:*?"<>|`) {
			return "", fmt.Errorf("%q cannot be used in a file name", seg)
		}
	}
	return clean, nil
}

// storedPath maps a virtual path to where it actually lives: inside src/, or
// inside src/.disabled/ when the file is disabled.
func storedPath(src, rel string, disabled bool) string {
	full := filepath.Join(src, filepath.FromSlash(rel))
	if disabled {
		return filepath.Join(src, disabledDir, filepath.FromSlash(rel))
	}
	return full
}

// within reports whether target is base or below it.
func within(base, target string) bool {
	rel, err := filepath.Rel(base, target)
	if err != nil {
		return false
	}
	return rel == "." || (rel != ".." && !strings.HasPrefix(rel, ".."+string(filepath.Separator)))
}

// ---------------------------------------------------------------------------
// Listing
// ---------------------------------------------------------------------------
type FileEntry struct {
	Path     string `json:"path"`
	Name     string `json:"name"`
	Dir      bool   `json:"dir"`
	Size     int64  `json:"size"`
	Mod      int64  `json:"mod"`
	Text     bool   `json:"text"`
	Disabled bool   `json:"disabled"`
}

type FilesState struct {
	Root    string      `json:"root"`
	Entries []FileEntry `json:"entries"`
	// MaxSize is what one uploaded file may be; the UI shows it in the toolbar
	// hint instead of failing silently on a big .so.
	MaxSize int64 `json:"maxSize"`
}

// textExtensions is what the editor opens. Everything else is listed, uploaded
// and deleted like any other file but shown as binary.
var textExtensions = map[string]bool{
	".xml": true, ".rc": true, ".prop": true, ".sh": true, ".md": true,
	".json": true, ".txt": true, ".conf": true, ".cfg": true, ".rule": true,
	".te": true, ".aidl": true, ".hidl": true, ".mk": true, ".env": true,
	".ini": true, ".yaml": true, ".yml": true, ".js": true, ".css": true,
	".html": true, ".c": true, ".h": true, ".py": true,
}

func isTextName(name string) bool {
	return textExtensions[strings.ToLower(filepath.Ext(name))]
}

// listFiles walks src/ and src/.disabled/ and returns one flat list. The UI
// builds the tree from it, which keeps this side free of presentation and makes
// "the file is disabled" a property of an entry rather than of a second tree.
func listFiles(src string) FilesState {
	st := FilesState{Root: src, MaxSize: maxUploadPart, Entries: []FileEntry{}}

	var walk func(base, prefix string, disabled bool, depth int)
	walk = func(base, prefix string, disabled bool, depth int) {
		if len(st.Entries) >= maxFilesListed || depth > 12 {
			return
		}
		entries, err := os.ReadDir(base)
		if err != nil {
			return
		}
		for _, e := range entries {
			name := e.Name()
			if name == ".git" || name == "node_modules" {
				continue
			}
			// .disabled is a real folder in the tree; it is walked separately
			// and never shown as a folder of its own.
			if !disabled && prefix == "" && name == disabledDir {
				continue
			}
			rel := name
			if prefix != "" {
				rel = prefix + "/" + name
			}
			info, err := e.Info()
			if err != nil {
				continue
			}
			// A symlink would let a listing escape src/; skip it instead of
			// following it.
			if info.Mode()&os.ModeSymlink != 0 {
				continue
			}
			if e.IsDir() {
				st.Entries = append(st.Entries, FileEntry{
					Path: rel, Name: name, Dir: true,
					Mod: info.ModTime().Unix(), Disabled: disabled,
				})
				walk(filepath.Join(base, name), rel, disabled, depth+1)
				continue
			}
			if !info.Mode().IsRegular() {
				continue
			}
			st.Entries = append(st.Entries, FileEntry{
				Path: rel, Name: name,
				Size: info.Size(), Mod: info.ModTime().Unix(),
				Text: isTextName(name), Disabled: disabled,
			})
		}
	}

	walk(src, "", false, 0)
	if dirExists(filepath.Join(src, disabledDir)) {
		walk(filepath.Join(src, disabledDir), "", true, 0)
	}
	return st
}

// ---------------------------------------------------------------------------
// Reading and writing
// ---------------------------------------------------------------------------
type FileContent struct {
	Path     string     `json:"path"`
	Text     string     `json:"text"`
	Binary   bool       `json:"binary"`
	TooBig   bool       `json:"tooBig,omitempty"`
	Size     int64      `json:"size"`
	Disabled bool       `json:"disabled"`
	Check    *FileCheck `json:"check,omitempty"`
}

func readSrcFile(src, rel string, disabled bool) (FileContent, error) {
	full := storedPath(src, rel, disabled)
	info, err := os.Stat(full)
	if err != nil {
		return FileContent{}, err
	}
	if info.IsDir() {
		return FileContent{}, errors.New("that is a folder")
	}

	out := FileContent{Path: rel, Size: info.Size(), Disabled: disabled}
	if info.Size() > maxTextBytes {
		out.Binary = true
		out.TooBig = true
		return out, nil
	}

	f, err := os.Open(full)
	if err != nil {
		return FileContent{}, err
	}
	defer f.Close()
	data, err := io.ReadAll(io.LimitReader(f, maxTextBytes+1))
	if err != nil {
		return FileContent{}, err
	}
	if len(data) > maxTextBytes {
		out.Binary = true
		out.TooBig = true
		return out, nil
	}
	if bytes.IndexByte(data, 0) >= 0 || !utf8.Valid(data) {
		out.Binary = true
		return out, nil
	}
	out.Text = string(data)
	out.Check = checkFor(rel, out.Text)
	return out, nil
}

func writeSrcFile(src, rel string, disabled bool, text string) error {
	full := storedPath(src, rel, disabled)
	if st, err := os.Stat(full); err == nil && st.IsDir() {
		return errors.New("there is a folder with that name")
	}
	if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
		return err
	}
	return os.WriteFile(full, []byte(text), 0o644)
}

// ---------------------------------------------------------------------------
// The two files the app understands
// ---------------------------------------------------------------------------
type FileCheck struct {
	Kind     string   `json:"kind"`
	Summary  string   `json:"summary"`
	Rules    int      `json:"rules,omitempty"`
	Errors   []string `json:"errors"`
	Warnings []string `json:"warnings"`
	// HALs is filled in for a VINTF manifest, so the window can show what the
	// framework will be told about.
	HALs []VintfHal `json:"hals,omitempty"`
}

type VintfHal struct {
	Name      string `json:"name"`
	Format    string `json:"format"`
	Version   string `json:"version"`
	Interface string `json:"interface"`
	Instance  string `json:"instance"`
}

// checkFor picks the checker by path: the module's SELinux rules, and any VINTF
// fragment under src/vendor/etc/vintf/manifest/.
func checkFor(rel, text string) *FileCheck {
	base := path.Base(rel)
	switch {
	case base == "sepolicy.rule":
		c := checkSepolicy(text)
		return &c
	case strings.HasSuffix(base, ".xml") && strings.Contains("/"+rel, "/etc/vintf/manifest/"):
		c := checkVintfManifest(text)
		return &c
	}
	return nil
}

// policyStatements is what the module's sepolicy patcher (Magisk/KernelSU/
// APatch, all of them magiskpolicy) understands. A line starting with anything
// else is reported as a warning, not an error: the list is deliberately
// conservative, and a false alarm on an exotic statement is better than a
// silent one on a typo.
var policyStatements = map[string]bool{
	"allow": true, "allowxperm": true, "auditallow": true, "auditallowxperm": true,
	"dontaudit": true, "dontauditxperm": true, "neverallow": true, "neverallowxperm": true,
	"type": true, "typeattribute": true, "attributetype": true, "typealias": true,
	"typebounds": true, "typepermissive": true, "permissive": true, "expandattribute": true,
	"type_transition": true, "type_change": true, "type_member": true,
	"genfscon": true, "bool": true, "define": true, "if": true, "else": true,
}

// checkSepolicy reports what build.sh and the patcher will make of these rules.
// The build only ships the file when a line starts with `allow`, so a file full
// of commented examples is not a mistake — but it is worth saying out loud.
func checkSepolicy(text string) FileCheck {
	check := FileCheck{Kind: "sepolicy", Errors: []string{}, Warnings: []string{}}
	crlf := strings.Contains(text, "\r\n")
	lines := strings.Split(strings.ReplaceAll(text, "\r\n", "\n"), "\n")
	allows := 0

	for i, raw := range lines {
		line := strings.TrimSpace(raw)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		where := fmt.Sprintf("line %d", i+1)
		if !strings.HasSuffix(line, ";") {
			check.Errors = append(check.Errors, where+": every rule has to end with ';'")
		}
		if strings.HasSuffix(line, "\\") {
			check.Warnings = append(check.Warnings, where+": a rule cannot be continued on the next line")
		}
		if strings.TrimLeft(raw, " \t") != raw {
			check.Warnings = append(check.Warnings, where+": build.sh only counts rules that start in the first column")
		}
		fields := strings.Fields(line)
		stmt := fields[0]
		if !policyStatements[stmt] {
			check.Warnings = append(check.Warnings, fmt.Sprintf("%s: %q is not a statement the module can apply", where, stmt))
		}
		if strings.ContainsAny(line, "<>") {
			check.Warnings = append(check.Warnings, where+": a <placeholder> is still in the rule")
		}
		if strings.Count(line, "{") != strings.Count(line, "}") {
			check.Warnings = append(check.Warnings, where+": unbalanced { } in the permission list")
		}
		if stmt == "allow" || stmt == "allowxperm" {
			allows++
		}
	}

	if crlf {
		check.Warnings = append(check.Warnings, "the file has Windows line endings — harmless, but the patcher reads it more predictably with Unix ones")
	}
	if allows == 0 {
		check.Warnings = append(check.Warnings, "no allow rules yet — build.sh leaves sepolicy.rule out of the module when there is nothing to apply")
	}
	check.Rules = allows
	check.Summary = fmt.Sprintf("%d allow rule%s", allows, plural(allows))
	return check
}

func plural(n int) string {
	if n == 1 {
		return ""
	}
	return "s"
}

// vintfManifest is the part of the schema this app needs: enough to say whether
// the framework will find the HAL, and in which format.
type vintfManifest struct {
	XMLName xml.Name   `xml:"manifest"`
	Version string     `xml:"version,attr"`
	Type    string     `xml:"type,attr"`
	Hals    []vintfHal `xml:"hal"`
}

type vintfHal struct {
	Format    string       `xml:"format,attr"`
	Name      string       `xml:"name"`
	Version   string       `xml:"version"`
	Transport string       `xml:"transport"`
	Fqnames   []string     `xml:"fqname"`
	Interface []vintfIface `xml:"interface"`
}

type vintfIface struct {
	Name     string `xml:"name"`
	Instance string `xml:"instance"`
}

// checkVintfManifest catches the mistakes that cost a boot loop: the wrong
// format for the HAL that was extracted (AIDL on an A16 GSI, HIDL on anything
// older), HIDL versioning on an AIDL entry, and a manifest that declares
// nothing at all.
func checkVintfManifest(text string) FileCheck {
	check := FileCheck{Kind: "vintf", Errors: []string{}, Warnings: []string{}}

	var doc vintfManifest
	if err := xml.Unmarshal([]byte(text), &doc); err != nil {
		check.Errors = append(check.Errors, "the XML does not parse: "+err.Error())
		check.Summary = "could not be read"
		return check
	}
	if doc.XMLName.Local != "manifest" {
		check.Errors = append(check.Errors, fmt.Sprintf("the root element is <%s>, not <manifest>", doc.XMLName.Local))
	}
	if doc.Type == "" {
		check.Warnings = append(check.Warnings, `no type="device" on <manifest> — VINTF expects the manifest to say what it describes`)
	}
	if len(doc.Hals) == 0 {
		check.Warnings = append(check.Warnings, "no <hal> entries — this fragment tells the framework nothing")
	}

	aidl, hidl := 0, 0
	for i, h := range doc.Hals {
		label := h.Name
		if label == "" {
			label = fmt.Sprintf("hal %d", i+1)
			check.Errors = append(check.Errors, fmt.Sprintf("%s: <name> is missing", label))
		}
		format := h.Format
		if format == "" {
			format = "hidl"
			check.Warnings = append(check.Warnings, label+": no format attribute — VINTF assumes hidl")
		}

		switch format {
		case "aidl":
			aidl++
			if strings.Contains(h.Version, ".") {
				check.Warnings = append(check.Warnings, label+": AIDL uses the major version only (2, not 2.3)")
			}
			if len(h.Fqnames) > 0 {
				check.Warnings = append(check.Warnings, label+": <fqname> is HIDL syntax and is ignored for an aidl HAL")
			}
			if h.Transport != "" {
				check.Warnings = append(check.Warnings, label+": <transport> is HIDL syntax and is ignored for an aidl HAL")
			}
			if len(h.Interface) == 0 {
				check.Warnings = append(check.Warnings, label+": no <interface> — the framework cannot bind the service")
			}
		case "hidl":
			hidl++
			if len(h.Fqnames) == 0 {
				check.Warnings = append(check.Warnings, label+": a HIDL HAL needs <fqname> (@2.3::IFoo/default)")
			}
			for _, fq := range h.Fqnames {
				if !strings.HasPrefix(fq, "@") {
					check.Warnings = append(check.Warnings, label+": <fqname>"+fq+"</fqname> is missing the @version prefix")
				}
			}
			if h.Transport == "" {
				check.Warnings = append(check.Warnings, label+": no <transport> (hwbinder is the usual one)")
			}
		default:
			check.Errors = append(check.Errors, fmt.Sprintf("%s: format=%q is neither aidl nor hidl", label, format))
		}

		for _, iface := range h.Interface {
			if iface.Name == "" {
				check.Warnings = append(check.Warnings, label+": an <interface> has no <name>")
			}
			if iface.Instance == "" {
				check.Warnings = append(check.Warnings, label+": an <interface> has no <instance> (usually default)")
			}
		}

		entry := VintfHal{Name: h.Name, Format: format, Version: h.Version}
		if len(h.Interface) > 0 {
			entry.Interface = h.Interface[0].Name
			entry.Instance = h.Interface[0].Instance
		}
		if len(h.Fqnames) > 0 && entry.Interface == "" {
			entry.Interface = h.Fqnames[0]
		}
		check.HALs = append(check.HALs, entry)
	}

	switch {
	case len(doc.Hals) == 0:
		check.Summary = "no HALs declared"
	case aidl > 0 && hidl > 0:
		check.Summary = fmt.Sprintf("%d HALs — %d aidl, %d hidl", len(doc.Hals), aidl, hidl)
	case aidl > 0:
		check.Summary = fmt.Sprintf("%d AIDL HAL%s", aidl, plural(aidl))
	default:
		check.Summary = fmt.Sprintf("%d HIDL HAL%s", hidl, plural(hidl))
	}
	return check
}

// ---------------------------------------------------------------------------
// Handlers
// ---------------------------------------------------------------------------
func (a *App) handleFiles(w http.ResponseWriter, r *http.Request) {
	src, err := a.srcDir()
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, listFiles(src))
}

func (a *App) handleFileRead(w http.ResponseWriter, r *http.Request) {
	src, err := a.srcDir()
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	rel, err := safeRel(r.URL.Query().Get("path"))
	if err != nil || rel == "" {
		writeError(w, http.StatusBadRequest, "pick a file first")
		return
	}
	disabled := r.URL.Query().Get("disabled") == "1"

	content, err := readSrcFile(src, rel, disabled)
	if err != nil {
		writeError(w, http.StatusNotFound, fmt.Sprintf("%s could not be read: %v", rel, err))
		return
	}
	writeJSON(w, http.StatusOK, content)
}

func (a *App) handleFileWrite(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Path     string `json:"path"`
		Text     string `json:"text"`
		Disabled bool   `json:"disabled"`
	}
	if !decodeLimit(w, r, &body, 8<<20) {
		return
	}
	src, err := a.srcDir()
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	rel, err := safeRel(body.Path)
	if err != nil || rel == "" {
		writeError(w, http.StatusBadRequest, "that is not a path inside src/")
		return
	}
	if len(body.Text) > maxTextBytes {
		writeError(w, http.StatusRequestEntityTooLarge, fmt.Sprintf("%s is limited to %d MiB in the editor", rel, maxTextBytes>>20))
		return
	}
	if err := writeSrcFile(src, rel, body.Disabled, body.Text); err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"path":  rel,
		"check": checkFor(rel, body.Text),
	})
}

// handleFileCheck validates text that has not been saved yet, so the window can
// report a broken rule while it is being typed.
func (a *App) handleFileCheck(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Path string `json:"path"`
		Text string `json:"text"`
	}
	if !decodeLimit(w, r, &body, 8<<20) {
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"check": checkFor(body.Path, body.Text)})
}

func (a *App) handleFileMkdir(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Path string `json:"path"`
	}
	if !decode(w, r, &body) {
		return
	}
	src, err := a.srcDir()
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	rel, err := safeRel(body.Path)
	if err != nil || rel == "" {
		writeError(w, http.StatusBadRequest, "that is not a path inside src/")
		return
	}
	full := storedPath(src, rel, false)
	if _, err := os.Lstat(full); err == nil {
		writeError(w, http.StatusConflict, rel+" already exists")
		return
	}
	if err := os.MkdirAll(full, 0o755); err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"path": rel})
}

func (a *App) handleFileDelete(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Path     string `json:"path"`
		Disabled bool   `json:"disabled"`
	}
	if !decode(w, r, &body) {
		return
	}
	src, err := a.srcDir()
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	rel, err := safeRel(body.Path)
	if err != nil || rel == "" {
		writeError(w, http.StatusBadRequest, "pick a file first")
		return
	}
	full := storedPath(src, rel, body.Disabled)
	info, err := os.Lstat(full)
	if err != nil {
		writeError(w, http.StatusNotFound, rel+" is not there any more")
		return
	}
	if err := os.RemoveAll(full); err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"removed": rel, "dir": info.IsDir()})
}

// handleFileToggle moves a file (or a whole folder) between src/ and
// src/.disabled/. The request says what the file is now, so a stale page cannot
// move a file the wrong way.
func (a *App) handleFileToggle(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Path     string `json:"path"`
		Disabled bool   `json:"disabled"`
	}
	if !decode(w, r, &body) {
		return
	}
	src, err := a.srcDir()
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	rel, err := safeRel(body.Path)
	if err != nil || rel == "" {
		writeError(w, http.StatusBadRequest, "pick a file first")
		return
	}

	from := storedPath(src, rel, body.Disabled)
	to := storedPath(src, rel, !body.Disabled)
	if _, err := os.Lstat(from); err != nil {
		writeError(w, http.StatusNotFound, rel+" is not there any more — reload the list")
		return
	}
	if _, err := os.Lstat(to); err == nil {
		writeError(w, http.StatusConflict, rel+" already exists in the other place — open it there and move it back")
		return
	}
	if err := os.MkdirAll(filepath.Dir(to), 0o755); err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	if err := os.Rename(from, to); err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"path": rel, "disabled": !body.Disabled})
}

// handleFileUpload copies files picked in the window (or dropped on the tree)
// into the selected folder. The browser strips directories from a multipart
// filename, so the client sends the relative paths as one JSON field in the
// same order as the files; the filename is only a fallback.
func (a *App) handleFileUpload(w http.ResponseWriter, r *http.Request) {
	src, err := a.srcDir()
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	dirRel, err := safeRel(r.URL.Query().Get("dir"))
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	base := storedPath(src, dirRel, false)
	if st, err := os.Stat(base); err != nil || !st.IsDir() {
		writeError(w, http.StatusBadRequest, "that folder does not exist — reload the list")
		return
	}

	r.Body = http.MaxBytesReader(w, r.Body, maxUploadBody)
	mr, err := r.MultipartReader()
	if err != nil {
		writeError(w, http.StatusBadRequest, "expected a file upload: "+err.Error())
		return
	}

	var (
		paths   []string
		written []string
		skipped []string
		seen    int
	)
	for {
		part, err := mr.NextPart()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			writeError(w, http.StatusBadRequest, "could not read the upload: "+err.Error())
			return
		}

		if part.FormName() == "paths" {
			data, _ := io.ReadAll(io.LimitReader(part, 1<<20))
			part.Close()
			_ = json.Unmarshal(data, &paths)
			continue
		}

		want := ""
		if seen < len(paths) {
			want = paths[seen]
		}
		seen++
		if want == "" {
			want = mimeFilename(part.Header.Get("Content-Disposition"))
		}
		if want == "" {
			want = part.FileName()
		}

		rel, err := safeRel(want)
		if err != nil || rel == "" {
			skipped = append(skipped, fmt.Sprintf("%s: not a usable file name", want))
			part.Close()
			continue
		}
		dst := filepath.Join(src, filepath.FromSlash(path.Join(dirRel, rel)))
		if !within(base, dst) {
			skipped = append(skipped, rel+": outside the selected folder")
			part.Close()
			continue
		}
		if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
			skipped = append(skipped, rel+": "+err.Error())
			part.Close()
			continue
		}
		f, err := os.Create(dst)
		if err != nil {
			skipped = append(skipped, rel+": "+err.Error())
			part.Close()
			continue
		}
		n, copyErr := io.Copy(f, io.LimitReader(part, maxUploadPart+1))
		f.Close()
		part.Close()
		switch {
		case copyErr != nil:
			os.Remove(dst)
			skipped = append(skipped, rel+": "+copyErr.Error())
		case n > maxUploadPart:
			os.Remove(dst)
			skipped = append(skipped, fmt.Sprintf("%s: larger than %d MiB", rel, maxUploadPart>>20))
		default:
			written = append(written, path.Join(dirRel, rel))
		}
	}

	if written == nil {
		written = []string{}
	}
	if skipped == nil {
		skipped = []string{}
	}
	writeJSON(w, http.StatusOK, map[string]any{"written": written, "skipped": skipped})
}

// mimeFilename is kept next to the upload handler because it is the one place
// the raw header matters: mime.ParseMediaType keeps a relative path in
// filename=, which Go's Part.FileName() would reduce to a base name.
func mimeFilename(header string) string {
	if header == "" {
		return ""
	}
	_, params, err := mime.ParseMediaType(header)
	if err != nil {
		return ""
	}
	return params["filename"]
}
