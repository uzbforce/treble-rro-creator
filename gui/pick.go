package main

// The file chooser behind the path fields.
//
// The page cannot offer one itself: a webview's <input type="file"> hands the
// page a File object, never a path, and the firmware scans need a path the
// unpacker can open. Uploading a 9 GB super.img just to learn where it is would
// be absurd, so the dialog is the system's own and the app opens it:
// PowerShell's WinForms dialogs on Windows, zenity or kdialog on Linux.
//
// Nothing here reads or writes the chosen file. The endpoint returns a string,
// which is exactly what a user could type into the same field, so it adds no
// power to the page — only a way to answer the question without a path.

import (
	"net/http"
	"os"
	"path/filepath"
	"strings"
)

// pickerKind is what the dialog is after. A file and a folder need different
// dialogs on every platform, so the page says which one it wants.
type pickerKind string

const (
	pickFile   pickerKind = "file"
	pickFolder pickerKind = "folder"
)

// pickAsk is everything a dialog needs: which kind, and the folder to open at.
// Start is a directory even when the field holds a file — see startDir.
type pickAsk struct {
	Kind  pickerKind
	Start string
}

func (k pickerKind) title() string {
	if k == pickFolder {
		return "Choose the ROM folder or an unpacked tree"
	}
	return "Choose a super.img, a Samsung AP file, or a partition image"
}

// startDir turns what is already in the field into a folder a dialog can open
// at: a folder is itself, a file is its parent, and anything that is not there
// is dropped so the dialog falls back to its own default.
func startDir(field string) string {
	field = strings.TrimSpace(field)
	if field == "" {
		return ""
	}
	if st, err := os.Stat(field); err == nil && st.IsDir() {
		return field
	}
	dir := filepath.Dir(field)
	if dir == "." || dir == string(filepath.Separator) {
		return ""
	}
	if st, err := os.Stat(dir); err == nil && st.IsDir() {
		return dir
	}
	return ""
}

// handlePick opens the platform's chooser and answers with the path it
// returned. An empty path is a cancellation, not a failure: the page leaves the
// field as it was.
func (a *App) handlePick(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Kind  string `json:"kind"`
		Start string `json:"start"`
	}
	if !decode(w, r, &body) {
		return
	}
	kind := pickerKind(strings.TrimSpace(body.Kind))
	if kind != pickFile && kind != pickFolder {
		writeError(w, http.StatusBadRequest, `kind has to be "file" or "folder"`)
		return
	}
	if len(body.Start) > 4096 {
		writeError(w, http.StatusBadRequest, "that path is too long to be one")
		return
	}
	ask := pickAsk{Kind: kind, Start: startDir(body.Start)}

	// One dialog at a time: the request blocks until the user answers, and a
	// second click while the first is open would stack a second modal window on
	// top of it.
	a.pickMu.Lock()
	defer a.pickMu.Unlock()
	path, err := a.chosenPath(ask)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"path": path})
}

// chosenPath is the dialog, unless a test has replaced it. Going through a
// method keeps the handler testable without a window and without a global.
func (a *App) chosenPath(ask pickAsk) (string, error) {
	if a.picker != nil {
		return a.picker(ask)
	}
	return pickPath(ask)
}
