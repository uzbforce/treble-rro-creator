package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"
)

// ---------------------------------------------------------------------------
// UDFPS
// ---------------------------------------------------------------------------
// stuff/scripts/udfps-probe.sh does the actual asking: it reads the vendor FOD
// properties, pulls the enabled overlays and dumps their resource tables, or
// walks an unpacked firmware tree. All this side does is run it, hand its JSON
// to the page, and write the three config.env lines when the user picks a row.
//
// Keeping the logic in the script is deliberate. The CLI and the window then
// answer the same question the same way, and the guide in docs/udfps.md can
// document one command instead of two implementations.
type UDFPSCandidate struct {
	Kind       string `json:"kind"`
	Source     string `json:"source"`
	Label      string `json:"label"`
	X          int    `json:"x"`
	Y          int    `json:"y"`
	Radius     int    `json:"radius"`
	Confidence string `json:"confidence"`
	Score      int    `json:"score"`
	Detail     string `json:"detail"`
}

type UDFPSChosen struct {
	Kind       string `json:"kind"`
	Source     string `json:"source"`
	X          int    `json:"x"`
	Y          int    `json:"y"`
	Radius     int    `json:"radius"`
	Confidence string `json:"confidence"`
}

type UDFPSDevice struct {
	Serial   string `json:"serial"`
	Model    string `json:"model"`
	Codename string `json:"codename"`
	ROM      string `json:"rom"`
	IsGSI    bool   `json:"isGsi"`
	Width    int    `json:"width"`
	Height   int    `json:"height"`
	Density  int    `json:"density"`
}

type UDFPSFile struct {
	Path string `json:"path"`
	Role string `json:"role"`
}

type UDFPSReport struct {
	Mode       string           `json:"mode"`
	Device     *UDFPSDevice     `json:"device,omitempty"`
	Firmware   string           `json:"firmware,omitempty"`
	Aapt2      string           `json:"aapt2"`
	Candidates []UDFPSCandidate `json:"candidates"`
	Chosen     *UDFPSChosen     `json:"chosen"`
	Warnings   []string         `json:"warnings"`
	Notes      []string         `json:"notes"`
	Files      []UDFPSFile      `json:"files"`
}

// One probe at a time: two of them would fight over the same adb connection and
// the same temporary folder, and the page only ever draws one result.
var udfpsMu sync.Mutex

func (a *App) aapt2Path() string {
	root := a.Root()
	for _, p := range []string{
		filepath.Join(root, "stuff", "tools", "aapt2"),
		filepath.Join(root, "stuff", "tools", "aapt2.exe"),
	} {
		if fileExists(p) {
			return p
		}
	}
	if p, err := exec.LookPath("aapt2"); err == nil {
		return p
	}
	return ""
}

func (a *App) udfpsScript() string {
	return filepath.Join(a.Root(), "stuff", "scripts", "udfps-probe.sh")
}

// runProbe executes the script and returns its parsed report. stderr is kept
// because a failure there is usually the only explanation the user gets: adb's
// "no devices/emulators found" and aapt2's resource errors both land there.
func (a *App) runProbe(mode, dir string) (*UDFPSReport, string, error) {
	udfpsMu.Lock()
	defer udfpsMu.Unlock()

	root := a.Root()
	if !isClone(root) {
		return nil, "", errors.New("no clone selected — pick the folder that has build.sh")
	}
	script := a.udfpsScript()
	if !fileExists(script) {
		return nil, "", errors.New("stuff/scripts/udfps-probe.sh is missing — update the clone")
	}
	bash := a.Bash()
	if bash == "" {
		return nil, "", errors.New("no bash found — install Git for Windows, or set the bash path")
	}

	args := []string{"--noprofile", "--norc", script, "--json"}
	if mode == "firmware" {
		args = append(args, "--firmware", dir)
	}
	timeout := 3 * time.Minute
	if mode == "firmware" {
		timeout = 10 * time.Minute
	}
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()

	cmd := exec.CommandContext(ctx, bash, args...)
	cmd.Dir = root
	env := append(os.Environ(), "TERM=dumb")
	if adb := a.adbPath(); adb != "" {
		env = append(env, "ADB="+adb)
	}
	if aapt2 := a.aapt2Path(); aapt2 != "" {
		env = append(env, "AAPT2="+aapt2)
	}
	cmd.Env = env

	var stderr strings.Builder
	cmd.Stderr = &stderr
	out, err := cmd.Output()
	log := strings.TrimSpace(stderr.String())

	if ctx.Err() == context.DeadlineExceeded {
		return nil, log, fmt.Errorf("the probe took longer than %s and was stopped", timeout)
	}
	if err != nil {
		msg := log
		if msg == "" {
			msg = err.Error()
		}
		return nil, log, errors.New(msg)
	}

	var report UDFPSReport
	if err := json.Unmarshal(out, &report); err != nil {
		return nil, log, fmt.Errorf("could not read the probe's output: %w", err)
	}
	// JSON null for "nothing found" is normal; the page wants [] so it can map
	// over the lists without guarding every one of them.
	if report.Candidates == nil {
		report.Candidates = []UDFPSCandidate{}
	}
	if report.Warnings == nil {
		report.Warnings = []string{}
	}
	if report.Notes == nil {
		report.Notes = []string{}
	}
	if report.Files == nil {
		report.Files = []UDFPSFile{}
	}
	return &report, log, nil
}

// applyUDFPSValues writes the three coordinates plus HAS_UDFPS into config.env.
//
// It goes through the same line-addressed edit path as the config form, so a
// commented-out row is switched on rather than duplicated, and the prose above
// it is left alone.
func applyUDFPSValues(root string, x, y, radius int) (ConfigDoc, string, error) {
	if x <= 0 || y <= 0 || radius <= 0 {
		return ConfigDoc{}, "", errors.New("the coordinates must be positive numbers")
	}
	if radius < 20 || radius > 400 {
		return ConfigDoc{}, "", fmt.Errorf("radius %d is not a fingerprint sensor radius", radius)
	}

	path := filepath.Join(root, "config.env")
	raw, err := os.ReadFile(path)
	if err != nil {
		return ConfigDoc{}, "", errors.New("config.env is missing — run Build once, or Clean --all to recreate it")
	}
	text := string(raw)
	doc, _ := parseConfig(text)

	want := map[string]string{
		"HAS_UDFPS":    "true",
		"UDFPS_X":      strconv.Itoa(x),
		"UDFPS_Y":      strconv.Itoa(y),
		"UDFPS_RADIUS": strconv.Itoa(radius),
	}
	edits := []ConfigEdit{}
	for _, section := range doc.Sections {
		for _, e := range section.Entries {
			value, ok := want[e.Key]
			if !ok {
				continue
			}
			delete(want, e.Key) // first occurrence wins
			if e.Value == value && e.Enabled {
				continue
			}
			edits = append(edits, ConfigEdit{Line: e.Line, Key: e.Key, Value: value, Enabled: true})
		}
	}
	if len(want) > 0 {
		keys := make([]string, 0, len(want))
		for k := range want {
			keys = append(keys, k)
		}
		return ConfigDoc{}, "", fmt.Errorf("config.env has no %s line — restore it from config.env.example", strings.Join(keys, " / "))
	}

	next, err := applyConfigEdits(text, edits)
	if err != nil {
		return ConfigDoc{}, "", err
	}
	if next != text {
		if err := os.WriteFile(path, []byte(next), 0o644); err != nil {
			return ConfigDoc{}, "", err
		}
	}
	out, _ := parseConfig(next)
	return out, next, nil
}

func (a *App) handleUDFPS(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Action string `json:"action"`
		Mode   string `json:"mode"`
		Path   string `json:"path"`
		X      int    `json:"x"`
		Y      int    `json:"y"`
		Radius int    `json:"radius"`
	}
	if !decode(w, r, &body) {
		return
	}

	switch body.Action {
	case "probe":
		mode := body.Mode
		if mode == "" {
			mode = "device"
		}
		dir := ""
		if mode == "firmware" {
			dir = strings.TrimSpace(body.Path)
			if dir == "" {
				writeError(w, http.StatusBadRequest, "point it at the folder that holds the unpacked ROM")
				return
			}
			abs, err := filepath.Abs(dir)
			if err != nil {
				writeError(w, http.StatusBadRequest, err.Error())
				return
			}
			info, err := os.Stat(abs)
			if err != nil || !info.IsDir() {
				writeError(w, http.StatusBadRequest, "not a folder: "+dir)
				return
			}
			dir = abs
		} else if mode != "device" {
			writeError(w, http.StatusBadRequest, "unknown mode")
			return
		}

		report, log, err := a.runProbe(mode, dir)
		if err != nil {
			writeJSON(w, http.StatusBadGateway, map[string]any{"error": err.Error(), "log": log})
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{"report": report, "log": log})

	case "apply":
		root := a.Root()
		if !isClone(root) {
			writeError(w, http.StatusBadRequest, "no clone selected")
			return
		}
		doc, text, err := applyUDFPSValues(root, body.X, body.Y, body.Radius)
		if err != nil {
			writeError(w, http.StatusBadRequest, err.Error())
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{"config": doc, "text": text})

	default:
		writeError(w, http.StatusBadRequest, "unknown action")
	}
}
