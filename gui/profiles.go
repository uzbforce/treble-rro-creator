package main

import (
	"context"
	"errors"
	"net/http"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

// ---------------------------------------------------------------------------
// Profiles
// ---------------------------------------------------------------------------
// config.env holds one device. A profile is a named copy of it, so building for
// a second phone does not mean keeping config.env.a90 next to config.env.zephyr
// and remembering which is which.
//
// All the work happens in stuff/scripts/profiles.sh, which the terminal menu
// calls too: this file only turns its tab separated listing into JSON and its
// verbs into a request. Switching a profile rewrites config.env, so the page
// refreshes its config after an action rather than patching one field.

// profilesScript is run through bash, like addons.sh: the clone is the source of
// truth for what a profile is.
const profilesScript = "stuff/scripts/profiles.sh"

// Profile is one saved setup, as the modal lists it.
type Profile struct {
	ID     string `json:"id"`
	Name   string `json:"name"`
	Device string `json:"device"`
	Active bool   `json:"active"`
}

// profilesRun runs the helper with a short timeout: every verb is a copy or a
// rename, and none of them touch the phone.
func (a *App) profilesRun(args ...string) ([]byte, error) {
	root := a.Root()
	if !isClone(root) {
		return nil, errors.New("no clone selected")
	}
	script := filepath.Join(root, filepath.FromSlash(profilesScript))
	if !fileExists(script) {
		return nil, errors.New("stuff/scripts/profiles.sh is missing — update the clone")
	}
	bash := a.Bash()
	if !fileExists(bash) {
		return nil, errors.New("bash was not found — pick it with the Path chip")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, bash, append([]string{script}, args...)...)
	setProcAttr(cmd)
	cmd.Dir = root
	var stderr strings.Builder
	cmd.Stderr = &stderr
	out, err := cmd.Output()
	if err != nil {
		msg := strings.TrimSpace(stderr.String())
		if msg == "" {
			msg = err.Error()
		}
		return nil, errors.New(msg)
	}
	return out, nil
}

// Profiles is the list the modal shows. A checkout with no profiles gets its
// first one made for it (the helper does that), so the list is never empty.
func (a *App) Profiles() ([]Profile, error) {
	out, err := a.profilesRun("list")
	if err != nil {
		return nil, err
	}
	list := []Profile{}
	for _, line := range strings.Split(string(out), "\n") {
		line = strings.TrimRight(line, "\r")
		if strings.TrimSpace(line) == "" {
			continue
		}
		f := strings.Split(line, "\t")
		if len(f) < 4 {
			continue
		}
		p := Profile{ID: f[0], Name: f[2], Device: f[3], Active: f[1] == "1"}
		if p.Name == "" {
			p.Name = "Profile " + strings.TrimPrefix(p.ID, "p")
		}
		if p.Device == "" {
			p.Device = "no device set"
		}
		list = append(list, p)
	}
	return list, nil
}

// handleProfiles serves the list. It is a GET so the modal can open on the
// current state without an action first.
func (a *App) handleProfiles(w http.ResponseWriter, r *http.Request) {
	list, err := a.Profiles()
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"profiles": list, "active": activeID(list)})
}

func activeID(list []Profile) string {
	for _, p := range list {
		if p.Active {
			return p.ID
		}
	}
	return ""
}

// handleProfilesAction is one request for all four verbs. The id is checked
// against the shape the helper accepts before it is passed on, so a path can
// never reach the helper's rm -rf.
func (a *App) handleProfilesAction(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Action string `json:"action"`
		ID     string `json:"id"`
		Name   string `json:"name"`
	}
	if !decode(w, r, &body) {
		return
	}
	// A build reads config.env as it goes, and switching replaces that file under
	// it, so the module would be named for one device and filled from another.
	// Waiting costs nothing; the dialog says so and the button stays where it is.
	if a.runner != nil && a.runner.Snapshot().Running {
		switch body.Action {
		case "new", "switch", "delete":
			writeError(w, http.StatusConflict, "a build is running \u2014 change profiles after it finishes")
			return
		}
	}

	var args []string
	switch body.Action {
	case "new":
		args = []string{"new", body.Name}
	case "switch":
		args = []string{"switch", body.ID}
	case "rename":
		args = []string{"rename", body.ID, body.Name}
	case "delete":
		args = []string{"delete", body.ID}
	case "save":
		args = []string{"save"}
	default:
		writeError(w, http.StatusBadRequest, "unknown profile action: "+body.Action)
		return
	}
	// The helper's own message is not passed on: the page reloads the list and
	// says what happened in the row it changed.
	if _, err := a.profilesRun(args...); err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	list, err := a.Profiles()
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	// The config tab keeps its own copy of config.env; a switch makes that copy
	// wrong, so the fresh text rides back with the list.
	text := readConfig(a.Root())
	config, _ := parseConfig(text)
	writeJSON(w, http.StatusOK, map[string]any{
		"profiles":   list,
		"active":     activeID(list),
		"configText": text,
		"config":     config,
	})
}