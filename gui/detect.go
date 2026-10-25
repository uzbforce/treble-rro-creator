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
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

// ---------------------------------------------------------------------------
// Detect
// ---------------------------------------------------------------------------
// stuff/scripts/device-probe.sh does the asking: it reads the panel geometry
// from dumpsys, the framework resources from `cmd overlay lookup`, and the OEM
// overlays from an unpacked ROM. This side runs it, hands its JSON to the page,
// and writes the rows the user ticks into config.env.
//
// Same split as the UDFPS tab on purpose: the CLI and the window then answer the
// same question the same way, and docs/detect.md documents one command.
type DetectDevice struct {
	Serial   string `json:"serial"`
	Model    string `json:"model"`
	Codename string `json:"codename"`
	ROM      string `json:"rom"`
	IsGSI    bool   `json:"isGsi"`
	Width    int    `json:"width"`
	Height   int    `json:"height"`
	Density  int    `json:"density"`
}

type DetectFact struct {
	Key        string `json:"key"`
	Label      string `json:"label"`
	Unit       string `json:"unit"`
	Value      string `json:"value"`
	Source     string `json:"source"`
	Confidence string `json:"confidence"`
	Kind       string `json:"kind"`
	Detail     string `json:"detail"`
}

type DetectFile struct {
	Path string `json:"path"`
	Role string `json:"role"`
}

type DetectReport struct {
	Mode     string        `json:"mode"`
	Device   *DetectDevice `json:"device,omitempty"`
	Firmware string        `json:"firmware,omitempty"`
	Aapt2    string        `json:"aapt2"`
	Facts    []DetectFact  `json:"facts"`
	Warnings []string      `json:"warnings"`
	Notes    []string      `json:"notes"`
	Files    []DetectFile  `json:"files"`
}

// One probe at a time: two would fight over adb and the temporary folder, and
// the page only ever draws one result.
var detectMu sync.Mutex

func (a *App) detectScript() string {
	return filepath.Join(a.Root(), "stuff", "scripts", "device-probe.sh")
}

func (a *App) runDetect(mode, dir, serial string) (*DetectReport, string, error) {
	detectMu.Lock()
	defer detectMu.Unlock()

	root := a.Root()
	if !isClone(root) {
		return nil, "", errors.New("no clone selected — pick the folder that has build.sh")
	}
	script := a.detectScript()
	if !fileExists(script) {
		return nil, "", errors.New("stuff/scripts/device-probe.sh is missing — update the clone")
	}
	bash := a.Bash()
	if bash == "" {
		return nil, "", errors.New("no bash found — install Git for Windows, or set the bash path")
	}

	args := []string{"--noprofile", "--norc", script, "--json"}
	if mode == "firmware" {
		args = append(args, "--firmware", dir)
	} else if serial != "" {
		// Several phones can be attached; the probe must not guess. See
		// stuff/scripts/adb-device.sh for the CLI side of the same rule.
		args = append(args, "--device", serial)
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

	var report DetectReport
	if err := json.Unmarshal(out, &report); err != nil {
		return nil, log, fmt.Errorf("could not read the probe's output: %w", err)
	}
	if report.Facts == nil {
		report.Facts = []DetectFact{}
	}
	if report.Warnings == nil {
		report.Warnings = []string{}
	}
	if report.Notes == nil {
		report.Notes = []string{}
	}
	if report.Files == nil {
		report.Files = []DetectFile{}
	}
	return &report, log, nil
}

// ---------------------------------------------------------------------------
// Writing the values
// ---------------------------------------------------------------------------
// Only the keys the display overlay actually reads are accepted. A typo would
// otherwise drop a line into config.env that the build ignores silently, and
// the page would report success.
func detectIntRule(min, max int, what string) func(string) (string, error) {
	return func(raw string) (string, error) {
		v := strings.TrimSpace(raw)
		v = strings.TrimSuffix(strings.TrimSuffix(v, "px"), "Hz")
		n, err := strconv.Atoi(strings.TrimSpace(v))
		if err != nil {
			return "", fmt.Errorf("%s must be a whole number, got %q", what, raw)
		}
		if n < min || n > max {
			return "", fmt.Errorf("%s %d is outside %d–%d — check the unit", what, n, min, max)
		}
		return strconv.Itoa(n), nil
	}
}

func detectBoolRule(raw string) (string, error) {
	switch strings.TrimSpace(strings.ToLower(raw)) {
	case "true":
		return "true", nil
	case "false":
		return "false", nil
	default:
		return "", fmt.Errorf("a feature flag is true or false, got %q", raw)
	}
}

// config_displayLightSensorType is a sensor type name, not a number: AOSP's
// android.sensor.light, or an OEM's com.samsung.sensor.physical_light. Anything
// with a space or a quote in it would break config.env rather than configure
// the framework, so only dot-separated identifiers are accepted.
var sensorType = regexp.MustCompile(`^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+$`)

func detectSensorTypeRule(raw string) (string, error) {
	v := strings.TrimSpace(raw)
	if v == "" {
		return "", errors.New("the light sensor type is empty")
	}
	if strings.ContainsRune(v, '<') {
		return "", errors.New("that is still the placeholder text, not a sensor type")
	}
	if len(v) > 128 {
		return "", errors.New("that is too long to be a sensor type")
	}
	if !sensorType.MatchString(v) {
		return "", fmt.Errorf("a sensor type is dot-separated names like android.sensor.light, got %q", raw)
	}
	return v, nil
}

func detectCutoutRule(raw string) (string, error) {
	v := strings.TrimSpace(raw)
	if v == "" {
		return "", errors.New("the cutout path is empty")
	}
	if strings.ContainsAny(v, "\r\n") {
		return "", errors.New("a cutout path cannot contain a line break")
	}
	if strings.ContainsRune(v, '<') {
		return "", errors.New("that is still the placeholder text, not a path")
	}
	if len(v) > 4096 {
		return "", errors.New("the cutout path is too long to be a display cutout")
	}
	if !strings.HasPrefix(v, "M") && !strings.HasPrefix(v, "m") {
		return "", errors.New("a cutout path starts with M (moveto), like \"M 0,0 L 120,0 ...\"")
	}
	return v, nil
}

var detectKeys = map[string]func(string) (string, error){
	"ROUNDED_CORNER_RADIUS":       detectIntRule(0, 400, "corner radius"),
	"STATUS_BAR_HEIGHT":           detectIntRule(24, 400, "status bar height"),
	"STATUS_BAR_HEIGHT_LANDSCAPE": detectIntRule(24, 400, "landscape status bar height"),
	"DEFAULT_REFRESH_RATE":        detectIntRule(24, 240, "default refresh rate"),
	"PEAK_REFRESH_RATE":           detectIntRule(24, 240, "peak refresh rate"),
	"DISPLAY_CUTOUT":              detectCutoutRule,
	"BRIGHTNESS_MAX":              detectIntRule(0, 255, "maximum brightness"),
	"BRIGHTNESS_MIN":              detectIntRule(0, 255, "minimum brightness"),
	"BRIGHTNESS_DEFAULT":          detectIntRule(0, 255, "default brightness"),
	"BRIGHTNESS_DIM":              detectIntRule(0, 255, "dim brightness"),
	"BRIGHTNESS_DARK":             detectIntRule(0, 255, "dark brightness"),
	"BRIGHTNESS_DOZE":             detectIntRule(0, 255, "doze brightness"),
	"HAS_AOD":                     detectBoolRule,
	"HAS_DOZE":                    detectBoolRule,
	"HAS_DOUBLE_TAP_WAKE":         detectBoolRule,
	"HAS_BURN_IN_PROTECTION":      detectBoolRule,
	"HAS_VOLTE":                   detectBoolRule,
	"HAS_5G":                      detectBoolRule,
	"LIGHT_SENSOR_TYPE":           detectSensorTypeRule,
	"HAS_SAMSUNG_FOD":             detectBoolRule,
	"HAS_SAMSUNG_VIBRATOR":        detectBoolRule,
	"HAS_SAMSUNG_FINGERPRINT":     detectBoolRule,
}

func applyDetectValues(root string, values map[string]string) (ConfigDoc, string, error) {
	if len(values) == 0 {
		return ConfigDoc{}, "", errors.New("nothing was selected")
	}

	keys := make([]string, 0, len(values))
	for k := range values {
		keys = append(keys, k)
	}
	sort.Strings(keys)

	want := make(map[string]string, len(values))
	for _, k := range keys {
		rule, ok := detectKeys[k]
		if !ok {
			return ConfigDoc{}, "", fmt.Errorf("%s is not a display setting this tab writes", k)
		}
		v, err := rule(values[k])
		if err != nil {
			return ConfigDoc{}, "", err
		}
		want[k] = v
	}

	path := filepath.Join(root, "config.env")
	raw, err := os.ReadFile(path)
	if err != nil {
		return ConfigDoc{}, "", errors.New("config.env is missing — run Build once, or Clean --all to recreate it")
	}
	text := string(raw)
	doc, _ := parseConfig(text)

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
		// Whatever is left was never found: say which key, not just "failed".
		missing := make([]string, 0, len(want))
		for k := range want {
			missing = append(missing, k)
		}
		sort.Strings(missing)
		return ConfigDoc{}, "", fmt.Errorf("config.env has no %s line — restore it from config.env.example", strings.Join(missing, " / "))
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

// firmwareDir turns what the page sent into a folder a probe can read. The path
// may be a tree the user unpacked, a ROM folder, a bare super.img or a Samsung
// AP; prepareFirmware extracts the parts of the image the probes need.
func firmwareDir(mode, path string) (string, *FirmwareSource, error) {
	switch mode {
	case "device":
		return "", nil, nil
	case "firmware":
		src, err := prepareFirmware(path)
		if err != nil {
			return "", nil, err
		}
		return src.Dir, src, nil
	default:
		return "", nil, errors.New("unknown mode")
	}
}

// probeLog joins the parts of a run's log in the order they happened: what was
// unpacked, which tools had to be installed, then the probe's own messages.
func probeLog(parts ...string) string {
	var out []string
	for _, p := range parts {
		if p = strings.TrimSpace(p); p != "" {
			out = append(out, p)
		}
	}
	return strings.Join(out, "\n")
}

func (a *App) handleDetect(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Action string            `json:"action"`
		Mode   string            `json:"mode"`
		Path   string            `json:"path"`
		XML    string            `json:"xml"`
		Values map[string]string `json:"values"`
		Serial string            `json:"serial"`
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
		dir, fw, err := firmwareDir(mode, body.Path)
		if err != nil {
			writeError(w, http.StatusBadRequest, err.Error())
			return
		}
		toolLog, err := a.ensureProbeTools(mode)
		if err != nil {
			writeJSON(w, http.StatusBadGateway, map[string]any{"error": err.Error(), "log": probeLog(fwLog(fw), toolLog)})
			return
		}

		// The probe picks the only device and stops with the list when there are
		// several; the page sends the picker's serial so it never has to guess.
		report, log, err := a.runDetect(mode, dir, safeToken(body.Serial))
		log = probeLog(fwLog(fw), toolLog, log)
		if err != nil {
			writeJSON(w, http.StatusBadGateway, map[string]any{"error": err.Error(), "log": log, "firmware": fw})
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{"report": report, "log": log, "firmware": fw})

	case "power":
		mode := body.Mode
		if mode == "" {
			mode = "device"
		}
		dir, fw, err := firmwareDir(mode, body.Path)
		if err != nil {
			writeError(w, http.StatusBadRequest, err.Error())
			return
		}
		toolLog, err := a.ensureProbeTools(mode)
		if err != nil {
			writeJSON(w, http.StatusBadGateway, map[string]any{"error": err.Error(), "log": probeLog(fwLog(fw), toolLog)})
			return
		}
		profile, log, err := a.runPowerProfile(mode, dir, safeToken(body.Serial))
		log = probeLog(fwLog(fw), toolLog, log)
		if err != nil {
			writeJSON(w, http.StatusBadGateway, map[string]any{"error": err.Error(), "log": log, "firmware": fw})
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{"profile": profile, "log": log, "firmware": fw})

	case "power-save":
		path, items, err := savePowerProfile(a.Root(), body.XML)
		if err != nil {
			writeError(w, http.StatusBadRequest, err.Error())
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{"path": path, "items": items})

	case "apply":
		root := a.Root()
		if !isClone(root) {
			writeError(w, http.StatusBadRequest, "no clone selected")
			return
		}
		doc, text, err := applyDetectValues(root, body.Values)
		if err != nil {
			writeError(w, http.StatusBadRequest, err.Error())
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{"config": doc, "text": text})

	default:
		writeError(w, http.StatusBadRequest, "unknown action")
	}
}
