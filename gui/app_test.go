package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestBuildArgs pins the argv the app hands to bash. The last element being -y
// is the important one: the child has no terminal, so a prompt would hang the
// run instead of taking a default.
func TestBuildArgs(t *testing.T) {
	cases := []struct {
		name    string
		verb    string
		flags   []string
		want    []string
		wantErr bool
	}{
		{
			name: "build",
			verb: "build",
			want: []string{"--noprofile", "--norc", "./build.sh", "build", "-y"},
		},
		{
			name:  "build with vendor hals",
			verb:  "build",
			flags: []string{"--with-vendor-hals"},
			want:  []string{"--noprofile", "--norc", "./build.sh", "build", "--with-vendor-hals", "-y"},
		},
		{
			name: "dry run",
			verb: "dryrun",
			want: []string{"--noprofile", "--norc", "./build.sh", "--dry-run", "-y"},
		},
		{
			name:  "clean all",
			verb:  "clean",
			flags: []string{"--all"},
			want:  []string{"--noprofile", "--norc", "./build.sh", "clean", "--all", "-y"},
		},
		{name: "unknown verb", verb: "install", wantErr: true},
		{name: "flag from another verb", verb: "build", flags: []string{"--all"}, wantErr: true},
		{name: "unknown flag", verb: "build", flags: []string{"--rm-rf"}, wantErr: true},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got, err := buildArgs(tc.verb, tc.flags)
			if tc.wantErr {
				if err == nil {
					t.Fatalf("expected an error, got %v", got)
				}
				return
			}
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if strings.Join(got, " ") != strings.Join(tc.want, " ") {
				t.Fatalf("got  %q\nwant %q", got, tc.want)
			}
		})
	}
}

// TestVerbsExistInBuildSh is a drift guard: the table is the only place the GUI
// learns build.sh's commands, so a renamed verb here would silently produce
// "Unknown option" at run time instead of at build time.
func TestVerbsExistInBuildSh(t *testing.T) {
	src, err := os.ReadFile(filepath.Join("..", "build.sh"))
	if err != nil {
		t.Skip("build.sh not found; running outside the clone")
	}
	text := string(src)
	for _, v := range verbTable {
		if !strings.Contains(text, v.Arg) {
			t.Errorf("verb %q: %q does not appear in build.sh", v.Name, v.Arg)
		}
	}
}

func TestIsCloneAndChooseClone(t *testing.T) {
	root := t.TempDir()
	if isClone(root) {
		t.Fatal("an empty folder looked like a clone")
	}
	if err := os.WriteFile(filepath.Join(root, "build.sh"), []byte("#!/bin/sh\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if isClone(root) {
		t.Fatal("build.sh alone should not be enough")
	}
	if err := os.MkdirAll(filepath.Join(root, "scripts"), 0o755); err != nil {
		t.Fatal(err)
	}
	if !isClone(root) {
		t.Fatal("build.sh + scripts/ should be a clone")
	}
	if got := chooseClone(root, ""); got != root {
		t.Fatalf("chooseClone(explicit) = %q, want %q", got, root)
	}
	if got := chooseClone("", root); got != root {
		t.Fatalf("chooseClone(saved) = %q, want %q", got, root)
	}
}

// TestWalkUpForClone covers the layouts the app has to survive: a build in
// gui/bin/, a release unpacked into the clone, and a shell started somewhere
// unrelated. It also pins the depth limit, so a runaway walk cannot end up
// claiming an unrelated parent project as "the clone".
func TestWalkUpForClone(t *testing.T) {
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, "build.sh"), []byte("#!/bin/sh\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(root, "scripts"), 0o755); err != nil {
		t.Fatal(err)
	}

	threeDown := filepath.Join(root, "gui", "bin", "x64")
	if err := os.MkdirAll(threeDown, 0o755); err != nil {
		t.Fatal(err)
	}
	if got := walkUpForClone(threeDown); got != root {
		t.Fatalf("three levels down: got %q, want %q", got, root)
	}
	if got := walkUpForClone(root); got != root {
		t.Fatalf("clone root: got %q, want %q", got, root)
	}

	beyond := filepath.Join(root, "a", "b", "c", "d", "e")
	if err := os.MkdirAll(beyond, 0o755); err != nil {
		t.Fatal(err)
	}
	if got := walkUpForClone(beyond); got != "" {
		t.Fatalf("five levels down should stop at the limit, got %q", got)
	}
}

func TestSettingsRoundTrip(t *testing.T) {
	path := filepath.Join(t.TempDir(), "gui.json")
	want := Settings{Clone: `C:\clone`, Bash: `C:\Program Files\Git\bin\bash.exe`}
	if err := saveSettings(path, want); err != nil {
		t.Fatal(err)
	}
	if got := loadSettings(path); got != want {
		t.Fatalf("got %+v, want %+v", got, want)
	}

	// A corrupted file must not stop the app from starting.
	if err := os.WriteFile(path, []byte("{not json"), 0o644); err != nil {
		t.Fatal(err)
	}
	if got := loadSettings(path); got != (Settings{}) {
		t.Fatalf("corrupt settings returned %+v", got)
	}
}

func TestReadDocStaysInsideDocs(t *testing.T) {
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, "docs"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "docs", "gui.md"), []byte("# GUI\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := readDoc(root, "gui.md"); err != nil {
		t.Fatalf("reading a real doc failed: %v", err)
	}
	for _, bad := range []string{"../build.sh", "..\\build.sh", "secrets.md", ""} {
		if _, err := readDoc(root, bad); err == nil {
			t.Fatalf("readDoc(%q) should have failed", bad)
		}
	}
}

// TestRunEndpointRejectsUnknownVerb checks the server-side allow-list, not just
// the buttons: a crafted POST must not reach build.sh.
func TestRunEndpointRejectsUnknownVerb(t *testing.T) {
	app := &App{runner: NewRunner()}
	body, _ := json.Marshal(map[string]any{"verb": "rm-rf", "flags": []string{}})
	req := httptest.NewRequest(http.MethodPost, "/api/run", strings.NewReader(string(body)))
	rec := httptest.NewRecorder()

	app.guard("POST", app.handleRun).ServeHTTP(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, want 400", rec.Code)
	}
}

func TestGuardRejectsCrossSite(t *testing.T) {
	app := &App{runner: NewRunner()}
	req := httptest.NewRequest(http.MethodGet, "/api/state", nil)
	req.Header.Set("Sec-Fetch-Site", "cross-site")
	rec := httptest.NewRecorder()

	app.guard("GET", app.handleState).ServeHTTP(rec, req)

	if rec.Code != http.StatusForbidden {
		t.Fatalf("status = %d, want 403", rec.Code)
	}
}
