package main

import (
	"bytes"
	"encoding/json"
	"io"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// testClone builds the two things a workspace handler needs: a folder that
// looks like a clone, and src/ inside it.
func testClone(t *testing.T) (root, src string) {
	t.Helper()
	root = t.TempDir()
	if err := os.WriteFile(filepath.Join(root, "build.sh"), []byte("#!/bin/sh\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(root, "stuff", "scripts"), 0o755); err != nil {
		t.Fatal(err)
	}
	src = filepath.Join(root, "src")
	if err := os.MkdirAll(src, 0o755); err != nil {
		t.Fatal(err)
	}
	return root, src
}

func writeTestFile(t *testing.T, path, content string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}

func call(t *testing.T, h http.HandlerFunc, method, target string, body any) *httptest.ResponseRecorder {
	t.Helper()
	var reader io.Reader
	if body != nil {
		data, err := json.Marshal(body)
		if err != nil {
			t.Fatal(err)
		}
		reader = bytes.NewReader(data)
	}
	request := httptest.NewRequest(method, target, reader)
	recorder := httptest.NewRecorder()
	h(recorder, request)
	return recorder
}

func decodeBody(t *testing.T, rec *httptest.ResponseRecorder, dst any) {
	t.Helper()
	if err := json.Unmarshal(rec.Body.Bytes(), dst); err != nil {
		t.Fatalf("response is not JSON (%d): %s", rec.Code, rec.Body.String())
	}
}

// ---------------------------------------------------------------------------
// Paths
// ---------------------------------------------------------------------------
func TestSafeRel(t *testing.T) {
	ok := map[string]string{
		"":                            "",
		"module/sepolicy.rule":        "module/sepolicy.rule",
		`vendor\bin\hw\hal`:           "vendor/bin/hw/hal",
		"vendor/bin/../bin/hw/hal":    "vendor/bin/hw/hal",
		"vendor/etc/vintf/manifest/x": "vendor/etc/vintf/manifest/x",
	}
	for input, want := range ok {
		got, err := safeRel(input)
		if err != nil {
			t.Fatalf("%q was rejected: %v", input, err)
		}
		if got != want {
			t.Fatalf("%q became %q, want %q", input, got, want)
		}
	}

	for _, input := range []string{
		"../config.env",
		"src/../../config.env",
		"/etc/passwd",
		`C:\Windows\system32`,
		"C:/Windows",
		"..",
		"vendor/.disabled/foo",
		"vendor/foo:bar",
		"vendor/foo\x00bar",
	} {
		if _, err := safeRel(input); err == nil {
			t.Fatalf("%q should have been rejected", input)
		}
	}
}

// ---------------------------------------------------------------------------
// Listing and disabling
// ---------------------------------------------------------------------------
func TestListFilesMarksDisabledFiles(t *testing.T) {
	_, src := testClone(t)
	writeTestFile(t, filepath.Join(src, "module", "sepolicy.rule"), "allow a b:file read;\n")
	writeTestFile(t, filepath.Join(src, "vendor", "bin", "hw", "hal"), "ELF")
	writeTestFile(t, filepath.Join(src, disabledDir, "vendor", "etc", "vintf", "manifest", "fp.xml"), "<manifest/>")

	state := listFiles(src)
	byPath := map[string]FileEntry{}
	for _, e := range state.Entries {
		key := e.Path
		if e.Disabled {
			key = "off:" + key
		}
		byPath[key] = e
	}

	if e, found := byPath["module/sepolicy.rule"]; !found || !e.Text || e.Disabled {
		t.Fatalf("sepolicy.rule: got %+v", e)
	}
	if e, found := byPath["vendor/bin/hw/hal"]; !found || e.Text || e.Disabled {
		t.Fatalf("binary vendor file: got %+v", e)
	}
	if e, found := byPath["off:vendor/etc/vintf/manifest/fp.xml"]; !found || !e.Disabled || !e.Text {
		t.Fatalf("disabled manifest: got %+v", e)
	}
	// The disabled root must not appear as a folder of its own.
	for _, e := range state.Entries {
		if e.Path == disabledDir {
			t.Fatalf("src/.disabled was listed as a normal folder: %+v", e)
		}
	}
}

func TestToggleMovesBetweenSrcAndDisabled(t *testing.T) {
	root, src := testClone(t)
	app := &App{root: root}
	hal := filepath.Join(src, "vendor", "bin", "hw", "hal")
	writeTestFile(t, hal, "ELF")

	rec := call(t, app.handleFileToggle, "POST", "/api/files/toggle",
		map[string]any{"path": "vendor/bin/hw/hal", "disabled": false})
	if rec.Code != http.StatusOK {
		t.Fatalf("disable failed: %d %s", rec.Code, rec.Body.String())
	}
	var res struct {
		Path     string `json:"path"`
		Disabled bool   `json:"disabled"`
	}
	decodeBody(t, rec, &res)
	if !res.Disabled || res.Path != "vendor/bin/hw/hal" {
		t.Fatalf("unexpected toggle response: %+v", res)
	}
	if _, err := os.Stat(hal); !os.IsNotExist(err) {
		t.Fatal("the file is still in src/ after disabling it")
	}
	moved := filepath.Join(src, disabledDir, "vendor", "bin", "hw", "hal")
	if data, err := os.ReadFile(moved); err != nil || string(data) != "ELF" {
		t.Fatalf("disabled copy: %q %v", data, err)
	}

	rec = call(t, app.handleFileToggle, "POST", "/api/files/toggle",
		map[string]any{"path": "vendor/bin/hw/hal", "disabled": true})
	if rec.Code != http.StatusOK {
		t.Fatalf("enable failed: %d %s", rec.Code, rec.Body.String())
	}
	if data, err := os.ReadFile(hal); err != nil || string(data) != "ELF" {
		t.Fatalf("restored file: %q %v", data, err)
	}
}

func TestToggleRefusesToOverwrite(t *testing.T) {
	root, src := testClone(t)
	app := &App{root: root}
	writeTestFile(t, filepath.Join(src, "module", "service.sh"), "on")
	writeTestFile(t, filepath.Join(src, disabledDir, "module", "service.sh"), "off")

	rec := call(t, app.handleFileToggle, "POST", "/api/files/toggle",
		map[string]any{"path": "module/service.sh", "disabled": true})
	if rec.Code != http.StatusConflict {
		t.Fatalf("expected a conflict, got %d %s", rec.Code, rec.Body.String())
	}
}

func TestFileHandlersRejectEscapes(t *testing.T) {
	root, src := testClone(t)
	app := &App{root: root}
	writeTestFile(t, filepath.Join(root, "config.env"), "DEVICE_CODENAME=x\n")

	if rec := call(t, app.handleFileRead, "GET", "/api/files/read?path=../config.env", nil); rec.Code != http.StatusBadRequest {
		t.Fatalf("reading outside src/ returned %d", rec.Code)
	}
	if rec := call(t, app.handleFileWrite, "POST", "/api/files/write",
		map[string]any{"path": "../config.env", "text": "pwned"}); rec.Code != http.StatusBadRequest {
		t.Fatalf("writing outside src/ returned %d", rec.Code)
	}
	if rec := call(t, app.handleFileDelete, "POST", "/api/files/delete",
		map[string]any{"path": "", "disabled": false}); rec.Code != http.StatusBadRequest {
		t.Fatalf("deleting src/ itself returned %d", rec.Code)
	}
	if data, _ := os.ReadFile(filepath.Join(src, "module", "sepolicy.rule")); len(data) != 0 {
		t.Fatal("a rejected write touched the tree")
	}
}

func TestMkdirAndDeleteFolder(t *testing.T) {
	root, src := testClone(t)
	app := &App{root: root}
	folder := filepath.Join(src, "vendor", "bin", "hw")

	rec := call(t, app.handleFileMkdir, "POST", "/api/files/mkdir", map[string]any{"path": "vendor/bin/hw"})
	if rec.Code != http.StatusOK {
		t.Fatalf("mkdir failed: %d %s", rec.Code, rec.Body.String())
	}
	if !dirExists(folder) {
		t.Fatal("the folder was not created")
	}

	rec = call(t, app.handleFileMkdir, "POST", "/api/files/mkdir", map[string]any{"path": "vendor/bin/hw"})
	if rec.Code != http.StatusConflict {
		t.Fatalf("creating it twice should conflict, got %d %s", rec.Code, rec.Body.String())
	}

	writeTestFile(t, filepath.Join(folder, "hal"), "ELF")
	rec = call(t, app.handleFileDelete, "POST", "/api/files/delete",
		map[string]any{"path": "vendor/bin/hw", "disabled": false})
	if rec.Code != http.StatusOK {
		t.Fatalf("delete failed: %d %s", rec.Code, rec.Body.String())
	}
	if dirExists(folder) {
		t.Fatal("the folder is still there after delete")
	}
}

func TestReadWriteRoundTrip(t *testing.T) {
	root, src := testClone(t)
	app := &App{root: root}

	rec := call(t, app.handleFileWrite, "POST", "/api/files/write", map[string]any{
		"path": "module/sepolicy.rule",
		"text": "allow hal_fingerprint_default vendor_file:file { read open };\n",
	})
	if rec.Code != http.StatusOK {
		t.Fatalf("write failed: %d %s", rec.Code, rec.Body.String())
	}
	var wrote struct {
		Check *FileCheck `json:"check"`
	}
	decodeBody(t, rec, &wrote)
	if wrote.Check == nil || wrote.Check.Kind != "sepolicy" || wrote.Check.Summary != "1 allow rule" {
		t.Fatalf("write did not return the rule check: %+v", wrote.Check)
	}

	rec = call(t, app.handleFileRead, "GET", "/api/files/read?path=module/sepolicy.rule", nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("read failed: %d %s", rec.Code, rec.Body.String())
	}
	var content FileContent
	decodeBody(t, rec, &content)
	if !strings.Contains(content.Text, "allow hal_fingerprint_default") || content.Binary {
		t.Fatalf("unexpected content: %+v", content)
	}
	if content.Check == nil || len(content.Check.Errors) != 0 {
		t.Fatalf("a valid rule should have no errors: %+v", content.Check)
	}

	// A binary file is listed but not handed to the editor as text.
	writeTestFile(t, filepath.Join(src, "vendor", "lib64", "libfoo.so"), "\x00ELF")
	rec = call(t, app.handleFileRead, "GET", "/api/files/read?path=vendor/lib64/libfoo.so", nil)
	decodeBody(t, rec, &content)
	if !content.Binary || content.Text != "" {
		t.Fatalf("a .so should read as binary: %+v", content)
	}
}

// ---------------------------------------------------------------------------
// Uploads
// ---------------------------------------------------------------------------
func TestUploadKeepsRelativePaths(t *testing.T) {
	root, src := testClone(t)
	app := &App{root: root}
	if err := os.MkdirAll(filepath.Join(src, "vendor", "bin", "hw"), 0o755); err != nil {
		t.Fatal(err)
	}

	var body bytes.Buffer
	form := multipart.NewWriter(&body)
	if err := form.WriteField("paths", `["lib64/libfoo.so","etc/init/hal.rc"]`); err != nil {
		t.Fatal(err)
	}
	// Browsers strip directories from a multipart filename; the server has to
	// use the paths field for the shape and the part only for the bytes.
	for i, content := range []string{"\x7fELF one", "service hal /vendor/bin/hw/hal"} {
		part, err := form.CreateFormFile("files", "part"+string(rune('a'+i))+".bin")
		if err != nil {
			t.Fatal(err)
		}
		if _, err := io.WriteString(part, content); err != nil {
			t.Fatal(err)
		}
	}
	if err := form.Close(); err != nil {
		t.Fatal(err)
	}

	request := httptest.NewRequest("POST", "/api/files/upload?dir=vendor", &body)
	request.Header.Set("Content-Type", form.FormDataContentType())
	recorder := httptest.NewRecorder()
	app.handleFileUpload(recorder, request)
	if recorder.Code != http.StatusOK {
		t.Fatalf("upload failed: %d %s", recorder.Code, recorder.Body.String())
	}
	var res struct {
		Written []string `json:"written"`
		Skipped []string `json:"skipped"`
	}
	decodeBody(t, recorder, &res)
	if len(res.Skipped) != 0 || len(res.Written) != 2 {
		t.Fatalf("unexpected upload result: %+v", res)
	}

	if data, err := os.ReadFile(filepath.Join(src, "vendor", "lib64", "libfoo.so")); err != nil || string(data) != "\x7fELF one" {
		t.Fatalf("lib64 upload: %q %v", data, err)
	}
	if data, err := os.ReadFile(filepath.Join(src, "vendor", "etc", "init", "hal.rc")); err != nil || !strings.Contains(string(data), "service hal") {
		t.Fatalf("init upload: %q %v", data, err)
	}
}

func TestUploadRejectsTraversal(t *testing.T) {
	root, src := testClone(t)
	app := &App{root: root}
	if err := os.MkdirAll(filepath.Join(src, "vendor"), 0o755); err != nil {
		t.Fatal(err)
	}

	var body bytes.Buffer
	form := multipart.NewWriter(&body)
	if err := form.WriteField("paths", `["../escaped.bin"]`); err != nil {
		t.Fatal(err)
	}
	part, err := form.CreateFormFile("files", "escaped.bin")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := io.WriteString(part, "nope"); err != nil {
		t.Fatal(err)
	}
	if err := form.Close(); err != nil {
		t.Fatal(err)
	}

	request := httptest.NewRequest("POST", "/api/files/upload?dir=vendor", &body)
	request.Header.Set("Content-Type", form.FormDataContentType())
	recorder := httptest.NewRecorder()
	app.handleFileUpload(recorder, request)
	if recorder.Code != http.StatusOK {
		t.Fatalf("upload failed: %d %s", recorder.Code, recorder.Body.String())
	}
	var res struct {
		Written []string `json:"written"`
		Skipped []string `json:"skipped"`
	}
	decodeBody(t, recorder, &res)
	if len(res.Written) != 0 || len(res.Skipped) != 1 {
		t.Fatalf("traversal was not skipped: %+v", res)
	}
	if _, err := os.Stat(filepath.Join(src, "escaped.bin")); !os.IsNotExist(err) {
		t.Fatal("a traversal upload escaped src/vendor")
	}
}

// ---------------------------------------------------------------------------
// The two checkers
// ---------------------------------------------------------------------------
func TestCheckSepolicy(t *testing.T) {
	good := checkSepolicy(`# rules
allow hal_fingerprint_default vendor_file:file { read open map };
allow hal_vibrator_default sysfs:file rw_file_perms;
`)
	if len(good.Errors) != 0 || good.Rules != 2 {
		t.Fatalf("a valid file should check clean: %+v", good)
	}

	broken := checkSepolicy("allow a b:file read\n  allow c d:file write;\nallow <hal_type> e:file read;\n")
	if len(broken.Errors) != 1 {
		t.Fatalf("the missing ; should be the only error: %+v", broken.Errors)
	}
	joined := strings.Join(broken.Warnings, "\n")
	if !strings.Contains(joined, "first column") {
		t.Fatalf("an indented rule should warn: %v", broken.Warnings)
	}
	if !strings.Contains(joined, "<placeholder>") {
		t.Fatalf("a placeholder should warn: %v", broken.Warnings)
	}

	empty := checkSepolicy("# only comments\n")
	if empty.Rules != 0 || len(empty.Warnings) == 0 || !strings.Contains(empty.Warnings[0], "no allow rules") {
		t.Fatalf("an empty file should say the build will skip it: %+v", empty)
	}
}

func TestCheckVintfManifest(t *testing.T) {
	aidl := `<?xml version="1.0"?>
<manifest version="1.0" type="device">
  <hal format="aidl">
    <name>android.hardware.biometrics.fingerprint</name>
    <version>2</version>
    <interface><name>IFingerprint</name><instance>default</instance></interface>
  </hal>
</manifest>`
	check := checkVintfManifest(aidl)
	if len(check.Errors) != 0 || len(check.Warnings) != 0 {
		t.Fatalf("a correct AIDL manifest should check clean: %+v", check)
	}
	if len(check.HALs) != 1 || check.HALs[0].Interface != "IFingerprint" || check.HALs[0].Instance != "default" {
		t.Fatalf("the HAL was not read: %+v", check.HALs)
	}
	if check.Summary != "1 AIDL HAL" {
		t.Fatalf("summary: %q", check.Summary)
	}

	hidl := `<manifest version="1.0" type="device">
  <hal format="hidl">
    <name>android.hardware.vibrator</name>
    <transport>hwbinder</transport>
    <version>2.3</version>
    <fqname>@2.3::IVibrator/default</fqname>
  </hal>
</manifest>`
	check = checkVintfManifest(hidl)
	if len(check.Errors) != 0 || len(check.Warnings) != 0 {
		t.Fatalf("a correct HIDL manifest should check clean: %+v", check)
	}

	// HIDL syntax on an AIDL HAL is the mistake this check exists for.
	mixed := `<manifest version="1.0" type="device">
  <hal format="aidl">
    <name>android.hardware.vibrator</name>
    <version>2.3</version>
    <fqname>@2.3::IVibrator/default</fqname>
  </hal>
</manifest>`
	check = checkVintfManifest(mixed)
	joined := strings.Join(check.Warnings, "\n")
	if !strings.Contains(joined, "major version only") || !strings.Contains(joined, "<fqname> is HIDL syntax") {
		t.Fatalf("AIDL/HIDL mix was not reported: %v", check.Warnings)
	}

	check = checkVintfManifest("<manifest><hal>")
	if len(check.Errors) == 0 {
		t.Fatal("broken XML should be an error")
	}
}

func TestCheckForPicksTheRightChecker(t *testing.T) {
	if checkFor("module/sepolicy.rule", "allow a b:file read;") == nil {
		t.Fatal("sepolicy.rule was not recognised")
	}
	if checkFor("vendor/etc/vintf/manifest/fp.xml", "<manifest/>") == nil {
		t.Fatal("a VINTF fragment was not recognised")
	}
	if checkFor("framework/res/values/config.xml", "<resources/>") != nil {
		t.Fatal("an ordinary resource XML should not be treated as a manifest")
	}
}
