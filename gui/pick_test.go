package main

// Tests for the file chooser endpoint. The dialog itself cannot be driven from
// a test — it is modal and waits for a person — so the handler is tested with a
// stub in place of the platform call, and the path arithmetic around it is
// covered directly.

import (
	"errors"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestPickHandlerAnswersWithThePath(t *testing.T) {
	dir := t.TempDir()
	img := filepath.Join(dir, "super.img")
	if err := os.WriteFile(img, []byte("not really an image"), 0o644); err != nil {
		t.Fatal(err)
	}

	app := &App{}
	var asked pickAsk
	app.picker = func(ask pickAsk) (string, error) {
		asked = ask
		return img, nil
	}

	// The field already held the file, so the dialog has to open at its folder.
	rec := call(t, app.handlePick, "POST", "/api/pick", map[string]any{"kind": "file", "start": img})
	if rec.Code != http.StatusOK {
		t.Fatalf("want 200, got %d: %s", rec.Code, rec.Body.String())
	}
	var body struct {
		Path string `json:"path"`
	}
	decodeBody(t, rec, &body)
	if body.Path != img {
		t.Fatalf("path: want %q, got %q", img, body.Path)
	}
	if asked.Kind != pickFile {
		t.Fatalf("kind: want file, got %q", asked.Kind)
	}
	if asked.Start != dir {
		t.Fatalf("start: want the file's folder %q, got %q", dir, asked.Start)
	}
}

func TestPickHandlerFolder(t *testing.T) {
	dir := t.TempDir()
	app := &App{}
	var asked pickAsk
	app.picker = func(ask pickAsk) (string, error) {
		asked = ask
		return dir, nil
	}

	rec := call(t, app.handlePick, "POST", "/api/pick", map[string]any{"kind": "folder", "start": dir})
	if rec.Code != http.StatusOK {
		t.Fatalf("want 200, got %d: %s", rec.Code, rec.Body.String())
	}
	if asked.Kind != pickFolder || asked.Start != dir {
		t.Fatalf("folder ask lost: %+v", asked)
	}
}

// Closing the dialog is not an error: the page keeps what was typed.
func TestPickHandlerCancel(t *testing.T) {
	app := &App{}
	app.picker = func(pickAsk) (string, error) { return "", nil }

	rec := call(t, app.handlePick, "POST", "/api/pick", map[string]any{"kind": "file"})
	if rec.Code != http.StatusOK {
		t.Fatalf("want 200, got %d: %s", rec.Code, rec.Body.String())
	}
	var body struct {
		Path string `json:"path"`
	}
	decodeBody(t, rec, &body)
	if body.Path != "" {
		t.Fatalf("a cancelled dialog must answer with an empty path, got %q", body.Path)
	}
}

// A machine with no dialog (Termux, a bare X session) has to say so instead of
// hanging or answering with a path it made up.
func TestPickHandlerReportsADialogFailure(t *testing.T) {
	app := &App{}
	app.picker = func(pickAsk) (string, error) {
		return "", errors.New("no file chooser was found (install zenity or kdialog), or type the path instead")
	}

	rec := call(t, app.handlePick, "POST", "/api/pick", map[string]any{"kind": "file"})
	if rec.Code != http.StatusInternalServerError {
		t.Fatalf("want 500, got %d: %s", rec.Code, rec.Body.String())
	}
	var body struct {
		Error string `json:"error"`
	}
	decodeBody(t, rec, &body)
	if !strings.Contains(body.Error, "type the path instead") {
		t.Fatalf("the error was not passed through: %q", body.Error)
	}
}

func TestPickHandlerRejectsAnUnknownKind(t *testing.T) {
	app := &App{}
	rec := call(t, app.handlePick, "POST", "/api/pick", map[string]any{"kind": "everything"})
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("want 400, got %d: %s", rec.Code, rec.Body.String())
	}
}

func TestStartDir(t *testing.T) {
	dir := t.TempDir()
	file := filepath.Join(dir, "AP_something.tar.md5")
	if err := os.WriteFile(file, []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	cases := []struct{ in, want string }{
		{"", ""},
		{"   ", ""},
		{dir, dir},
		{file, dir},
		{filepath.Join(dir, "missing.img"), dir},
		{filepath.Join(dir, "gone", "missing.img"), ""},
	}
	for _, c := range cases {
		if got := startDir(c.in); got != c.want {
			t.Fatalf("startDir(%q): want %q, got %q", c.in, c.want, got)
		}
	}
}

func TestPickRouteIsServed(t *testing.T) {
	root, _ := testClone(t)
	app := testAppWithBash(t, root)
	app.picker = func(pickAsk) (string, error) { return filepath.Join(root, "super.img"), nil }

	ln, url, srv, err := app.serve(0)
	if err != nil {
		t.Fatalf("serve: %v", err)
	}
	go srv.Serve(ln)
	defer srv.Close()

	res, err := http.Post(url+"api/pick", "application/json", strings.NewReader(`{"kind":"file"}`))
	if err != nil {
		t.Fatalf("post: %v", err)
	}
	defer res.Body.Close()
	if res.StatusCode != http.StatusOK {
		t.Fatalf("route returned %d", res.StatusCode)
	}
}
