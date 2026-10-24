package main

import (
	"encoding/json"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const udfpsSampleConfig = `# =============================================================================
# Treble Overlay — Device Configuration
# =============================================================================

# ── Fingerprint (UDFPS) ───────────────────────────────────────────────────
# HAS_UDFPS also registers config_biometric_sensors (0:2:15 by default).
HAS_UDFPS=false
UDFPS_X=0000
#UDFPS_Y=0000
UDFPS_RADIUS=0000

# ── Light sensor type ─────────────────────────────────────────────────────
LIGHT_SENSOR_TYPE="android.sensor.light"
`

const udfpsProbeJSON = `{
  "mode": "device",
  "device": {
    "serial": "XYZ", "model": "Redmi Note 17", "codename": "zephyr",
    "rom": "GSI (axion_gsi-user)", "isGsi": true,
    "width": 1080, "height": 2396, "density": 450
  },
  "aapt2": "",
  "candidates": [
    {
      "kind": "overlay", "source": "overlay:me.phh.treble.overlay.xiaomi.zephyr.udfps",
      "label": "overlay me.phh.treble.overlay.xiaomi.zephyr.udfps",
      "x": 540, "y": 2198, "radius": 89,
      "confidence": "high", "score": 95,
      "detail": "preinstalled overlay, from /system/product/overlay/treble-overlay-xiaomi-zephyr-udfps.apk"
    },
    {
      "kind": "props", "source": "xiaomi-fod-props", "label": "Xiaomi FOD rectangle",
      "x": 540, "y": 2198, "radius": 89,
      "confidence": "high", "score": 97,
      "detail": "persist.vendor.sys.fp.fod.location.X_Y=451,2109"
    }
  ],
  "chosen": {
    "kind": "props", "source": "xiaomi-fod-props",
    "x": 540, "y": 2198, "radius": 89, "confidence": "high"
  },
  "warnings": [],
  "notes": [],
  "files": [
    {"path": "/system/product/overlay/treble-overlay-xiaomi-zephyr-udfps.apk", "role": "enabled overlay"}
  ]
}`

// writeUDFPSClone makes a clone-shaped folder whose probe script answers with
// the JSON above, so the handler can be tested without adb, a phone or aapt2.
func writeUDFPSClone(t *testing.T, body string) string {
	t.Helper()
	root, _ := testClone(t)
	script := filepath.Join(root, "stuff", "scripts", "udfps-probe.sh")
	if err := os.WriteFile(script, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "config.env"), []byte(udfpsSampleConfig), 0o644); err != nil {
		t.Fatal(err)
	}
	return root
}

func testAppWithBash(t *testing.T, root string) *App {
	t.Helper()
	bash, err := findBash()
	if err != nil {
		t.Skip("no bash on this machine")
	}
	return &App{root: root, bash: bash}
}

func udfpsFindKey(t *testing.T, doc ConfigDoc, key string) ConfigEntry {
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

func TestUDFPSReportParses(t *testing.T) {
	var report UDFPSReport
	if err := json.Unmarshal([]byte(udfpsProbeJSON), &report); err != nil {
		t.Fatalf("sample report does not parse: %v", err)
	}
	if report.Device == nil || !report.Device.IsGSI {
		t.Fatalf("device block lost: %+v", report.Device)
	}
	if len(report.Candidates) != 2 {
		t.Fatalf("want 2 candidates, got %d", len(report.Candidates))
	}
	if report.Chosen == nil || report.Chosen.X != 540 || report.Chosen.Radius != 89 {
		t.Fatalf("chosen not read: %+v", report.Chosen)
	}
}

func TestUDFPSProbeHandler(t *testing.T) {
	root := writeUDFPSClone(t, "#!/usr/bin/env bash\ncat <<'JSON'\n"+udfpsProbeJSON+"\nJSON\n")
	app := testAppWithBash(t, root)

	rec := call(t, app.handleUDFPS, "POST", "/api/udfps", map[string]any{
		"action": "probe", "mode": "device",
	})
	if rec.Code != http.StatusOK {
		t.Fatalf("probe failed (%d): %s", rec.Code, rec.Body.String())
	}
	var body struct {
		Report UDFPSReport `json:"report"`
	}
	decodeBody(t, rec, &body)
	if body.Report.Chosen == nil || body.Report.Chosen.Y != 2198 {
		t.Fatalf("handler lost the report: %+v", body.Report)
	}
	if len(body.Report.Files) != 1 {
		t.Fatalf("files list lost: %+v", body.Report.Files)
	}
}

// The handler test above calls the function directly; this one goes through the
// real server so the route, the method guard and the JSON shape are covered too.
func TestUDFPSRouteIsServed(t *testing.T) {
	root := writeUDFPSClone(t, "#!/usr/bin/env bash\ncat <<'JSON'\n"+udfpsProbeJSON+"\nJSON\n")
	app := testAppWithBash(t, root)

	ln, url, srv, err := app.serve(0)
	if err != nil {
		t.Fatalf("serve: %v", err)
	}
	go srv.Serve(ln)
	defer srv.Close()

	body := strings.NewReader(`{"action":"probe","mode":"device"}`)
	res, err := http.Post(url+"api/udfps", "application/json", body)
	if err != nil {
		t.Fatalf("post: %v", err)
	}
	defer res.Body.Close()
	if res.StatusCode != http.StatusOK {
		t.Fatalf("route returned %d", res.StatusCode)
	}
	var out struct {
		Report UDFPSReport `json:"report"`
	}
	if err := json.NewDecoder(res.Body).Decode(&out); err != nil {
		t.Fatalf("response is not JSON: %v", err)
	}
	if out.Report.Device == nil || out.Report.Device.Width != 1080 {
		t.Fatalf("device info lost: %+v", out.Report.Device)
	}
}

func TestUDFPSProbeHandlerReportsScriptFailure(t *testing.T) {
	root := writeUDFPSClone(t, "#!/usr/bin/env bash\necho 'no device in adb devices' >&2\nexit 3\n")
	app := testAppWithBash(t, root)

	rec := call(t, app.handleUDFPS, "POST", "/api/udfps", map[string]any{
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
	if !strings.Contains(body.Error, "no device") || !strings.Contains(body.Log, "no device") {
		t.Fatalf("stderr was not passed through: %+v", body)
	}
}

func TestUDFPSApplyWritesConfig(t *testing.T) {
	root, _ := testClone(t)
	path := filepath.Join(root, "config.env")
	if err := os.WriteFile(path, []byte(udfpsSampleConfig), 0o644); err != nil {
		t.Fatal(err)
	}

	doc, text, err := applyUDFPSValues(root, 540, 2198, 89)
	if err != nil {
		t.Fatalf("apply failed: %v", err)
	}
	for key, want := range map[string]string{
		"HAS_UDFPS": "true", "UDFPS_X": "540", "UDFPS_Y": "2198", "UDFPS_RADIUS": "89",
	} {
		if got := udfpsFindKey(t, doc, key); got.Value != want || !got.Enabled {
			t.Fatalf("%s = %q (enabled=%v), want %q enabled", key, got.Value, got.Enabled, want)
		}
	}
	// The prose and the unrelated line survive a save.
	for _, keep := range []string{
		"# HAS_UDFPS also registers config_biometric_sensors",
		`LIGHT_SENSOR_TYPE="android.sensor.light"`,
	} {
		if !strings.Contains(text, keep) {
			t.Fatalf("apply dropped %q:\n%s", keep, text)
		}
	}
	// A commented-out row is switched on instead of duplicated.
	if strings.Count(text, "UDFPS_Y=") != 1 {
		t.Fatalf("UDFPS_Y was duplicated:\n%s", text)
	}
}

func TestUDFPSApplyRejectsBadValues(t *testing.T) {
	root, _ := testClone(t)
	if err := os.WriteFile(filepath.Join(root, "config.env"), []byte(udfpsSampleConfig), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, _, err := applyUDFPSValues(root, 540, 2198, 5); err == nil {
		t.Fatal("a 5 px radius was accepted")
	}
	if _, _, err := applyUDFPSValues(root, 0, 2198, 89); err == nil {
		t.Fatal("x=0 was accepted")
	}
}

func TestUDFPSApplyNeedsTheKeys(t *testing.T) {
	root, _ := testClone(t)
	if err := os.WriteFile(filepath.Join(root, "config.env"), []byte("DEVICE_MODEL=\"x\"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	_, _, err := applyUDFPSValues(root, 540, 2198, 89)
	if err == nil || !strings.Contains(err.Error(), "config.env.example") {
		t.Fatalf("missing keys should point at config.env.example, got %v", err)
	}
}
