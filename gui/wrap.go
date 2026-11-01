package main

// Wrapping overlay APKs a user already has into a flashable test module.
//
// The work is stuff/scripts/wrap.sh, run in the Build console like every other
// command: aapt2 failures, a wrong APK and the zip itself all show up in the
// log the page already streams, so this file only checks the request and hands
// it over. The paths come from the dialog in pick.go or a typed field, never
// from the request being trusted to point somewhere harmless — the script only
// reads them, and it writes nothing outside out/wrap/.

import (
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

// wrapNameRE is the module id rule the three root managers share. A bad id is a
// module the phone silently refuses to install, so it is caught here as well as
// in the script.
var wrapNameRE = regexp.MustCompile(`^[A-Za-z][A-Za-z0-9._-]+$`)

func (a *App) handleWrap(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Overlay  string `json:"overlay"`
		SystemUI string `json:"systemui"`
		Name     string `json:"name"`
	}
	if !decode(w, r, &body) {
		return
	}
	overlay := strings.TrimSpace(body.Overlay)
	systemui := strings.TrimSpace(body.SystemUI)
	name := strings.TrimSpace(body.Name)

	if !isClone(a.Root()) {
		writeError(w, http.StatusBadRequest, "no clone selected")
		return
	}
	if overlay == "" {
		writeError(w, http.StatusBadRequest, "choose the overlay APK first")
		return
	}
	for _, one := range []struct {
		path  string
		label string
	}{
		{overlay, "overlay"},
		{systemui, "SystemUI"},
	} {
		if one.path == "" {
			continue
		}
		if !strings.EqualFold(filepath.Ext(one.path), ".apk") {
			writeError(w, http.StatusBadRequest, one.label+" has to be an .apk: "+one.path)
			return
		}
		st, err := os.Stat(one.path)
		if err != nil {
			writeError(w, http.StatusBadRequest, one.label+" APK not found: "+one.path)
			return
		}
		if !st.Mode().IsRegular() {
			writeError(w, http.StatusBadRequest, one.label+" is not a file: "+one.path)
			return
		}
		if st.Size() == 0 {
			writeError(w, http.StatusBadRequest, one.label+" APK is empty: "+one.path)
			return
		}
	}
	if systemui != "" && sameFile(overlay, systemui) {
		writeError(w, http.StatusBadRequest, "the same APK was given as both overlay and SystemUI")
		return
	}
	if name != "" && !wrapNameRE.MatchString(name) {
		writeError(w, http.StatusBadRequest,
			"the module id has to start with a letter — letters, digits, dots, dashes and underscores only")
		return
	}

	args := []string{"--noprofile", "--norc", "./build.sh", "wrap", "--overlay", overlay}
	if systemui != "" {
		args = append(args, "--systemui", systemui)
	}
	if name != "" {
		args = append(args, "--name", name)
	}
	// -y: no terminal behind this request, so nothing may stop for an answer.
	args = append(args, "-y")

	if err := a.runner.StartEnv(a.Root(), a.Bash(), args, "build.sh wrap", false, nil, nil); err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	writeJSON(w, http.StatusAccepted, a.runner.Snapshot())
}

// sameFile compares two APK paths. The file being asked about always exists by
// now, so a stat is enough; symlinks and a relative path pointing at the same
// file both come out equal.
func sameFile(a, b string) bool {
	sa, errA := os.Stat(a)
	sb, errB := os.Stat(b)
	if errA != nil || errB != nil {
		return filepath.Clean(a) == filepath.Clean(b)
	}
	return os.SameFile(sa, sb)
}