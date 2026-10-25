package main

import (
	"encoding/json"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const detectSampleConfig = `# =============================================================================
# Treble Overlay — Device Configuration
# =============================================================================

# ── Display ───────────────────────────────────────────────────────────────
# Screen corner radius. Also the reference for the padding below.
ROUNDED_CORNER_RADIUS=000
# Status bar height in px, portrait and landscape. The effective height is
# max(this value, display-cutout inset).
STATUS_BAR_HEIGHT=000
STATUS_BAR_HEIGHT_LANDSCAPE=00
#DISPLAY_CUTOUT="M-35.93,0C-29.26,0,-23.46,3.85,-22.46,9.56l.12.73 @dp"

# ── Refresh Rate ──────────────────────────────────────────────────────────
DEFAULT_REFRESH_RATE=000
PEAK_REFRESH_RATE=000

# ── Feature Flags ─────────────────────────────────────────────────
HAS_AOD=false
HAS_DOZE=false
HAS_DOUBLE_TAP_WAKE=false
`

const detectProbeJSON = `{
  "mode": "device",
  "device": {
    "serial": "XYZ", "model": "Redmi Note 17", "codename": "zephyr",
    "rom": "GSI (axion_gsi-user)", "isGsi": true,
    "width": 1080, "height": 2396, "density": 450
  },
  "aapt2": "",
  "facts": [
    {
      "key": "ROUNDED_CORNER_RADIUS", "label": "Corner radius", "unit": "px",
      "value": "135", "source": "display hardware", "confidence": "high",
      "kind": "runtime", "detail": "dumpsys display: RoundedCorners radius 135px"
    },
    {
      "key": "STATUS_BAR_HEIGHT", "label": "Status bar height", "unit": "px",
      "value": "113", "source": "framework resource", "confidence": "medium",
      "kind": "resource", "detail": "cmd overlay lookup returned 113.0px"
    },
    {
      "key": "DISPLAY_CUTOUT", "label": "Display cutout path", "unit": "",
      "value": "M 0,0 L 120,0 L 120,80 L 0,80 Z @dp", "source": "firmware: framework-res.apk",
      "confidence": "high", "kind": "firmware", "detail": "sets config_mainBuiltInDisplayCutout"
    }
  ],
  "warnings": ["no cutout is configured on this GSI"],
  "notes": ["on a GSI the framework resource can be the GSI's default"],
  "files": [
    {"path": "/system/product/overlay/treble-overlay-xiaomi-zephyr.apk", "role": "enabled overlay"}
  ]
}`

func writeDetectClone(t *testing.T, body string) string {
	t.Helper()
	root, _ := testClone(t)
	script := filepath.Join(root, "stuff", "scripts", "device-probe.sh")
	if err := os.WriteFile(script, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "config.env"), []byte(detectSampleConfig), 0o644); err != nil {
		t.Fatal(err)
	}
	return root
}

func detectFindKey(t *testing.T, doc ConfigDoc, key string) ConfigEntry {
	t.Helper()
	for _, s := range doc.Sections {
		for _, e := range s.Entries {
			if e.Key == key {
				return e
			}
		}
	}
	t.Fatalf("config has no %s entry", key)
	return ConfigEntry{}
}

func TestDetectReportParses(t *testing.T) {
	var report DetectReport
	if err := json.Unmarshal([]byte(detectProbeJSON), &report); err != nil {
		t.Fatalf("sample report does not parse: %v", err)
	}
	if report.Device == nil || !report.Device.IsGSI || report.Device.Density != 450 {
		t.Fatalf("device block lost: %+v", report.Device)
	}
	if len(report.Facts) != 3 {
		t.Fatalf("want 3 facts, got %d", len(report.Facts))
	}
	if report.Facts[0].Key != "ROUNDED_CORNER_RADIUS" || report.Facts[0].Value != "135" {
		t.Fatalf("first fact lost: %+v", report.Facts[0])
	}
}

func TestDetectProbeHandler(t *testing.T) {
	root := writeDetectClone(t, "#!/usr/bin/env bash\ncat <<'JSON'\n"+detectProbeJSON+"\nJSON\n")
	app := testAppWithBash(t, root)

	rec := call(t, app.handleDetect, "POST", "/api/detect", map[string]any{
		"action": "probe", "mode": "device",
	})
	if rec.Code != http.StatusOK {
		t.Fatalf("probe failed (%d): %s", rec.Code, rec.Body.String())
	}
	var body struct {
		Report DetectReport `json:"report"`
	}
	decodeBody(t, rec, &body)
	if len(body.Report.Facts) != 3 || body.Report.Device == nil {
		t.Fatalf("handler lost the report: %+v", body.Report)
	}
	if len(body.Report.Warnings) != 1 || len(body.Report.Files) != 1 {
		t.Fatalf("warnings/files lost: %+v", body.Report)
	}
}

func TestDetectRouteIsServed(t *testing.T) {
	root := writeDetectClone(t, "#!/usr/bin/env bash\ncat <<'JSON'\n"+detectProbeJSON+"\nJSON\n")
	app := testAppWithBash(t, root)

	ln, url, srv, err := app.serve(0)
	if err != nil {
		t.Fatalf("serve: %v", err)
	}
	go srv.Serve(ln)
	defer srv.Close()

	body := strings.NewReader(`{"action":"probe","mode":"device"}`)
	res, err := http.Post(url+"api/detect", "application/json", body)
	if err != nil {
		t.Fatalf("post: %v", err)
	}
	defer res.Body.Close()
	if res.StatusCode != http.StatusOK {
		t.Fatalf("route returned %d", res.StatusCode)
	}
	var out struct {
		Report DetectReport `json:"report"`
	}
	if err := json.NewDecoder(res.Body).Decode(&out); err != nil {
		t.Fatalf("response is not JSON: %v", err)
	}
	if out.Report.Device == nil || out.Report.Device.Width != 1080 {
		t.Fatalf("device info lost: %+v", out.Report.Device)
	}
}

func TestDetectProbeReportsScriptFailure(t *testing.T) {
	root := writeDetectClone(t, "#!/usr/bin/env bash\necho 'adb: no devices/emulators found' >&2\nexit 3\n")
	app := testAppWithBash(t, root)

	rec := call(t, app.handleDetect, "POST", "/api/detect", map[string]any{
		"action": "probe", "mode": "device",
	})
	if rec.Code != http.StatusBadGateway {
		t.Fatalf("want 502, got %d: %s", rec.Code, rec.Body.String())
	}
	var body struct {
		Error string `json:"error"`
		Log   string `json:"log"`
	}
	decodeBody(t, rec, &body)
	if !strings.Contains(body.Error, "no devices") || !strings.Contains(body.Log, "no devices") {
		t.Fatalf("stderr was not passed through: %+v", body)
	}
}

func TestDetectApplyWritesConfig(t *testing.T) {
	root, _ := testClone(t)
	path := filepath.Join(root, "config.env")
	if err := os.WriteFile(path, []byte(detectSampleConfig), 0o644); err != nil {
		t.Fatal(err)
	}

	doc, text, err := applyDetectValues(root, map[string]string{
		"ROUNDED_CORNER_RADIUS": "135",
		"STATUS_BAR_HEIGHT":     "113",
		"DEFAULT_REFRESH_RATE":  "120",
		"PEAK_REFRESH_RATE":     "120",
		"DISPLAY_CUTOUT":        "M 0,0 L 120,0 L 120,80 L 0,80 Z @dp",
	})
	if err != nil {
		t.Fatalf("apply failed: %v", err)
	}
	for key, want := range map[string]string{
		"ROUNDED_CORNER_RADIUS": "135",
		"STATUS_BAR_HEIGHT":     "113",
		"DEFAULT_REFRESH_RATE":  "120",
		"PEAK_REFRESH_RATE":     "120",
		"DISPLAY_CUTOUT":        "M 0,0 L 120,0 L 120,80 L 0,80 Z @dp",
	} {
		if got := detectFindKey(t, doc, key); got.Value != want || !got.Enabled {
			t.Fatalf("%s = %q (enabled=%v), want %q enabled", key, got.Value, got.Enabled, want)
		}
	}
	// The commented-out cutout is switched on, quoted, and not duplicated.
	if strings.Count(text, "DISPLAY_CUTOUT=") != 1 {
		t.Fatalf("DISPLAY_CUTOUT was duplicated:\n%s", text)
	}
	if !strings.Contains(text, `DISPLAY_CUTOUT="M 0,0 L 120,0 L 120,80 L 0,80 Z @dp"`) {
		t.Fatalf("cutout was not written quoted:\n%s", text)
	}
	// The prose above the rows survives.
	if !strings.Contains(text, "# max(this value, display-cutout inset).") {
		t.Fatalf("apply dropped the comment:\n%s", text)
	}
}

func TestDetectApplyRejectsBadValues(t *testing.T) {
	root, _ := testClone(t)
	if err := os.WriteFile(filepath.Join(root, "config.env"), []byte(detectSampleConfig), 0o644); err != nil {
		t.Fatal(err)
	}
	cases := map[string]map[string]string{
		"refresh out of range": {"PEAK_REFRESH_RATE": "500"},
		"not a number":         {"STATUS_BAR_HEIGHT": "tall"},
		"cutout is not a path": {"DISPLAY_CUTOUT": "a notch"},
		"placeholder":          {"DISPLAY_CUTOUT": "<path>"},
		"unknown key":          {"HAS_UDFPS": "true"},
	}
	for name, values := range cases {
		if _, _, err := applyDetectValues(root, values); err == nil {
			t.Fatalf("%s was accepted", name)
		}
	}
}

func TestDetectApplyWritesFeatureFlags(t *testing.T) {
	root, _ := testClone(t)
	path := filepath.Join(root, "config.env")
	if err := os.WriteFile(path, []byte(detectSampleConfig), 0o644); err != nil {
		t.Fatal(err)
	}
	doc, _, err := applyDetectValues(root, map[string]string{
		"HAS_AOD": "true", "HAS_DOZE": "true", "HAS_DOUBLE_TAP_WAKE": "false",
	})
	if err != nil {
		t.Fatalf("apply failed: %v", err)
	}
	if got := detectFindKey(t, doc, "HAS_AOD"); got.Value != "true" || !got.Enabled {
		t.Fatalf("HAS_AOD = %q (enabled=%v)", got.Value, got.Enabled)
	}
	if got := detectFindKey(t, doc, "HAS_DOUBLE_TAP_WAKE"); got.Value != "false" || !got.Enabled {
		t.Fatalf("HAS_DOUBLE_TAP_WAKE = %q", got.Value)
	}
	if _, _, err := applyDetectValues(root, map[string]string{"HAS_AOD": "yes"}); err == nil {
		t.Fatal("HAS_AOD=yes was accepted")
	}
}

// The probe reads a sensor *string* and three vendor switches. The write path
// has to accept them, keep the quotes config.env uses for strings, and refuse a
// sensor type that would not survive being sourced by bash.
func TestDetectApplyWritesSensorTypeAndVendorFlags(t *testing.T) {
	root, _ := testClone(t)
	path := filepath.Join(root, "config.env")
	text := detectSampleConfig + "\nLIGHT_SENSOR_TYPE=\"android.sensor.light\"\n" +
		"HAS_SAMSUNG_FOD=false\nHAS_SAMSUNG_VIBRATOR=false\nHAS_SAMSUNG_FINGERPRINT=false\n"
	if err := os.WriteFile(path, []byte(text), 0o644); err != nil {
		t.Fatal(err)
	}

	doc, written, err := applyDetectValues(root, map[string]string{
		"LIGHT_SENSOR_TYPE":       "com.samsung.sensor.physical_light",
		"HAS_SAMSUNG_FOD":         "true",
		"HAS_SAMSUNG_VIBRATOR":    "false",
		"HAS_SAMSUNG_FINGERPRINT": "true",
	})
	if err != nil {
		t.Fatalf("apply failed: %v", err)
	}
	if got := detectFindKey(t, doc, "LIGHT_SENSOR_TYPE"); got.Value != "com.samsung.sensor.physical_light" {
		t.Fatalf("LIGHT_SENSOR_TYPE = %q", got.Value)
	}
	if got := detectFindKey(t, doc, "HAS_SAMSUNG_FOD"); got.Value != "true" {
		t.Fatalf("HAS_SAMSUNG_FOD = %q", got.Value)
	}
	if !strings.Contains(written, `LIGHT_SENSOR_TYPE="com.samsung.sensor.physical_light"`) {
		t.Fatalf("sensor type was not written quoted:\n%s", written)
	}

	for _, bad := range []string{"", "<type>", "physical light", "android.sensor.light; reboot", "a" + strings.Repeat("b", 200)} {
		if _, _, err := applyDetectValues(root, map[string]string{"LIGHT_SENSOR_TYPE": bad}); err == nil {
			t.Fatalf("LIGHT_SENSOR_TYPE=%q was accepted", bad)
		}
	}
}

func TestDetectApplyNeedsTheKeys(t *testing.T) {
	root, _ := testClone(t)
	if err := os.WriteFile(filepath.Join(root, "config.env"), []byte("DEVICE_MODEL=\"x\"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	_, _, err := applyDetectValues(root, map[string]string{"ROUNDED_CORNER_RADIUS": "135"})
	if err == nil || !strings.Contains(err.Error(), "config.env.example") {
		t.Fatalf("missing keys should point at config.env.example, got %v", err)
	}
}
