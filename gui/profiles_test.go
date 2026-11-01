package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// profileApp is a throwaway clone with the real helper in it. Profiles are a
// shell feature — the app only parses what stuff/scripts/profiles.sh prints —
// so copying the script is the honest fixture: a stub would pin nothing.
func profileApp(t *testing.T) *App {
	t.Helper()
	bash, err := exec.LookPath("bash")
	if err != nil {
		t.Skip("bash is not available")
	}
	src := filepath.Join("..", "stuff", "scripts")
	for _, name := range []string{"profiles.sh", "config-edit.sh"} {
		if !fileExists(filepath.Join(src, name)) {
			t.Skipf("%s not found next to the package", name)
		}
	}

	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, "stuff", "scripts"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "build.sh"), []byte("#!/bin/sh\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"profiles.sh", "config-edit.sh"} {
		data, err := os.ReadFile(filepath.Join(src, name))
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(root, "stuff", "scripts", name), data, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	cfg := "# ── Device ──\nDEVICE_MANUFACTURER=Xiaomi\nDEVICE_MODEL=Test\nDEVICE_CODENAME=zephyr\n"
	if err := os.WriteFile(filepath.Join(root, "config.env"), []byte(cfg), 0o644); err != nil {
		t.Fatal(err)
	}
	return &App{root: root, bash: bash}
}

func profileCall(t *testing.T, app *App, method, body string) map[string]any {
	t.Helper()
	var rec *httptest.ResponseRecorder
	if method == http.MethodGet {
		rec = httptest.NewRecorder()
		app.handleProfiles(rec, httptest.NewRequest(method, "/api/profiles", nil))
	} else {
		rec = httptest.NewRecorder()
		req := httptest.NewRequest(method, "/api/profiles/act", strings.NewReader(body))
		req.Header.Set("Content-Type", "application/json")
		app.handleProfilesAction(rec, req)
	}
	if rec.Code != http.StatusOK {
		t.Fatalf("%s: status %d, body %s", method, rec.Code, rec.Body.String())
	}
	var out map[string]any
	if err := json.Unmarshal(rec.Body.Bytes(), &out); err != nil {
		t.Fatalf("%s: %v (%s)", method, err, rec.Body.String())
	}
	return out
}

// profilesOf turns the JSON list back into the struct, which is also what the
// page does with it.
func profilesOf(t *testing.T, out map[string]any) []Profile {
	t.Helper()
	raw, err := json.Marshal(out["profiles"])
	if err != nil {
		t.Fatal(err)
	}
	var list []Profile
	if err := json.Unmarshal(raw, &list); err != nil {
		t.Fatal(err)
	}
	return list
}

// TestProfilesLifecycle walks the four verbs through the handlers. The parts
// worth pinning are the ones the page depends on: the first profile is made for
// a checkout that has none, the active flag moves with a switch, and the config
// text comes back with the list so the config tab cannot go stale.
func TestProfilesLifecycle(t *testing.T) {
	app := profileApp(t)

	out := profileCall(t, app, http.MethodGet, "")
	list := profilesOf(t, out)
	if len(list) != 1 {
		t.Fatalf("first look: %d profiles, want 1 (%v)", len(list), list)
	}
	if list[0].ID != "p1" || !list[0].Active || list[0].Name != "Profile #1" {
		t.Fatalf("first look: %+v, want p1/Profile #1/active", list[0])
	}
	if list[0].Device != "Xiaomi Test (zephyr)" {
		t.Fatalf("device line = %q", list[0].Device)
	}

	// A new profile is a copy of config.env, and becomes the one in use.
	out = profileCall(t, app, http.MethodPost, `{"action":"new","name":"Second phone"}`)
	list = profilesOf(t, out)
	if len(list) != 2 {
		t.Fatalf("after new: %d profiles, want 2", len(list))
	}
	active := out["active"]
	if active != "p2" {
		t.Fatalf("after new: active = %v, want p2", active)
	}
	if txt, _ := out["configText"].(string); !strings.Contains(txt, "DEVICE_CODENAME=zephyr") {
		t.Fatalf("configText did not ride back with the list: %q", txt)
	}

	// Rename, then switch back: the marker and both names have to hold.
	profileCall(t, app, http.MethodPost, `{"action":"rename","id":"p1","name":"Zephyr"}`)
	out = profileCall(t, app, http.MethodPost, `{"action":"switch","id":"p1"}`)
	list = profilesOf(t, out)
	if out["active"] != "p1" {
		t.Fatalf("after switch: active = %v, want p1", out["active"])
	}
	names := map[string]string{}
	for _, p := range list {
		names[p.ID] = p.Name
	}
	if names["p1"] != "Zephyr" || names["p2"] != "Second phone" {
		t.Fatalf("names after rename/switch = %v", names)
	}

	// Delete the one not in use; deleting the one in use must be refused rather
	// than leaving config.env belonging to nothing.
	profileCall(t, app, http.MethodPost, `{"action":"delete","id":"p2"}`)
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/api/profiles/act",
		strings.NewReader(`{"action":"delete","id":"p1"}`))
	app.handleProfilesAction(rec, req)
	if rec.Code == http.StatusOK {
		t.Fatal("deleting the profile in use was allowed")
	}

	list = profilesOf(t, profileCall(t, app, http.MethodGet, ""))
	if len(list) != 1 || list[0].ID != "p1" || !list[0].Active {
		t.Fatalf("after delete: %+v", list)
	}
}

// profileActFail sends one action and expects it to be refused, returning the
// status and the message the dialog will show.
func profileActFail(t *testing.T, app *App, body string) (int, string) {
	t.Helper()
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/api/profiles/act", strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	app.handleProfilesAction(rec, req)
	return rec.Code, rec.Body.String()
}

// TestProfilesRejectsDuplicateNames pins the list staying readable: two rows
// called the same thing cannot be told apart in the menu or the dialog, so a
// second "Pixel 8" is refused, whatever case and spacing it arrives in. A
// rename to the name the profile already has is not a duplicate.
func TestProfilesRejectsDuplicateNames(t *testing.T) {
	app := profileApp(t)

	code, body := profileActFail(t, app, `{"action":"new","name":"profile #1"}`)
	if code != http.StatusBadRequest || !strings.Contains(body, "already taken") {
		t.Fatalf("duplicate new: %d %s", code, body)
	}
	profileCall(t, app, http.MethodPost, `{"action":"new","name":"Pixel 8"}`)

	code, body = profileActFail(t, app, `{"action":"rename","id":"p1","name":"PIXEL   8"}`)
	if code != http.StatusBadRequest || !strings.Contains(body, "already taken") {
		t.Fatalf("duplicate rename: %d %s", code, body)
	}

	// Its own name, same bytes as before, has to be allowed: the dialog commits
	// on blur, which fires even when nothing was typed.
	profileCall(t, app, http.MethodPost, `{"action":"rename","id":"p2","name":"Pixel 8"}`)
	list := profilesOf(t, profileCall(t, app, http.MethodGet, ""))
	if len(list) != 2 {
		t.Fatalf("after refusals: %d profiles, want 2", len(list))
	}
}

// TestProfilesRefusesWhileBuildRuns covers the one change that would corrupt a
// run in progress: a switch rewrites config.env, and the build reads it as it
// goes, so the module would be named for one device and filled from another.
func TestProfilesRefusesWhileBuildRuns(t *testing.T) {
	app := profileApp(t)
	profileCall(t, app, http.MethodPost, `{"action":"new","name":"Second"}`)

	runner := NewRunner()
	runner.mu.Lock()
	runner.running = true
	runner.mu.Unlock()
	app.runner = runner

	for _, body := range []string{
		`{"action":"new","name":"Third"}`,
		`{"action":"switch","id":"p1"}`,
		`{"action":"delete","id":"p1"}`,
	} {
		code, msg := profileActFail(t, app, body)
		if code != http.StatusConflict || !strings.Contains(msg, "build is running") {
			t.Fatalf("%s: %d %s", body, code, msg)
		}
	}

	// Reading the list is still fine; only the writes wait.
	if list := profilesOf(t, profileCall(t, app, http.MethodGet, "")); len(list) != 2 {
		t.Fatalf("list while running: %d profiles, want 2", len(list))
	}
}

// TestProfilesDamagedFolderLeavesConfigAlone: a profile whose config.env went
// missing must not be switched to. Copying it would empty config.env, which is
// the file the build reads.
func TestProfilesDamagedFolderLeavesConfigAlone(t *testing.T) {
	app := profileApp(t)
	profileCall(t, app, http.MethodPost, `{"action":"new","name":"Second"}`)
	before := readConfig(app.Root())

	if err := os.Remove(filepath.Join(app.Root(), "stuff", "profiles", "p2", "config.env")); err != nil {
		t.Fatal(err)
	}
	code, msg := profileActFail(t, app, `{"action":"switch","id":"p2"}`)
	if code != http.StatusBadRequest || !strings.Contains(msg, "no config.env") {
		t.Fatalf("switch to damaged: %d %s", code, msg)
	}
	if after := readConfig(app.Root()); after != before {
		t.Fatalf("config.env changed:\n%s", after)
	}
}

// TestProfilesLostMarkerIsNotGuessed: with the marker gone and config.env no
// longer matching any saved copy, no profile is reported active. Guessing one
// would let the next switch save this file into a profile it does not belong
// to, overwriting that device's answers.
func TestProfilesLostMarkerIsNotGuessed(t *testing.T) {
	app := profileApp(t)
	profileCall(t, app, http.MethodPost, `{"action":"new","name":"Second"}`)

	if err := os.Remove(filepath.Join(app.Root(), "stuff", "profiles", "active")); err != nil {
		t.Fatal(err)
	}
	cfg := filepath.Join(app.Root(), "config.env")
	data, err := os.ReadFile(cfg)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(cfg, append(data, []byte("DEVICE_CODENAME=edited\n")...), 0o644); err != nil {
		t.Fatal(err)
	}

	out := profileCall(t, app, http.MethodGet, "")
	if out["active"] != "" {
		t.Fatalf("active = %v, want empty when the marker is lost", out["active"])
	}
	for _, p := range profilesOf(t, out) {
		if p.Active {
			t.Fatalf("%s was adopted without evidence", p.ID)
		}
	}
}

// TestProfilesRejectsUnknownAction keeps the handler from passing a verb it does
// not know to the helper, whose own fallback is an error message and exit 2.
func TestProfilesRejectsUnknownAction(t *testing.T) {
	app := profileApp(t)
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/api/profiles/act",
		strings.NewReader(`{"action":"rm -rf /","id":"p1"}`))
	app.handleProfilesAction(rec, req)
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, want 400", rec.Code)
	}
	if !strings.Contains(rec.Body.String(), "unknown profile action") {
		t.Fatalf("body = %s", rec.Body.String())
	}
}