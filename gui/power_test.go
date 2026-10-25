package main

import (
	"encoding/xml"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// Trimmed from the real `aapt2 dump xmltree framework-res.apk --file
// res/xml/power_profile.xml` of a HyperOS phone: an item with text, an array of
// values, a nested element with an unprefixed integer attribute, and the
// namespace header. Keeping the shape real is the point of the test.
const powerTree = `N: android=http://schemas.android.com/apk/res/android
E: device (line=20)
  A: name="Android" (Raw: "Android")
    E: item (line=38)
      A: name="ambient.on.display0" (Raw: "ambient.on.display0")
        T: '0.1'
    E: array (line=73)
      A: name="radio.on" (Raw: "radio.on")
        E: value (line=74)
            T: '0.2'
        E: value (line=75)
            T: '0.1'
    E: item (line=122)
      A: name="battery.capacity" (Raw: "battery.capacity")
        T: '1000'
    E: modem (line=171)
        E: sleep (line=172)
            T: '0'
        E: transmit (line=178)
          A: level=1
            T: '0'
`

func TestXMLTreeToXML(t *testing.T) {
	body, items, err := xmltreeToXML(powerTree)
	if err != nil {
		t.Fatalf("converter failed: %v", err)
	}
	if items != 3 {
		t.Fatalf("counted %d items/arrays, want 3", items)
	}
	for _, want := range []string{
		`<device name="Android">`,
		`<item name="ambient.on.display0">0.1</item>`,
		`<array name="radio.on">`,
		`<value>0.2</value>`,
		`<item name="battery.capacity">1000</item>`,
		`<transmit level="1">0</transmit>`,
	} {
		if !strings.Contains(body, want) {
			t.Fatalf("converted XML is missing %q:\n%s", want, body)
		}
	}
	var probe struct {
		XMLName xml.Name
	}
	if err := xml.Unmarshal([]byte(body), &probe); err != nil {
		t.Fatalf("converted XML does not parse: %v", err)
	}
	if probe.XMLName.Local != "device" {
		t.Fatalf("root is %q, want device", probe.XMLName.Local)
	}
}

func TestXMLTreeToXMLRejectsUnusableTrees(t *testing.T) {
	cases := map[string]string{
		"resource reference": "E: device\n  A: name=\"x\"\n  E: item\n    A: name=\"n\"\n    A: foo=@0x7f010000\n",
		"wrong root":         "E: resources\n  E: item\n",
		"no items":           "E: device\n  A: name=\"Android\"\n",
		"two roots":          "E: device\nE: device\n",
	}
	for name, tree := range cases {
		if _, _, err := xmltreeToXML(tree); err == nil {
			t.Fatalf("%s was accepted", name)
		}
	}
}

func TestPowerProfileHandler(t *testing.T) {
	root := writeDetectClone(t, "#!/usr/bin/env bash\ncat <<'TREE'\n# source: /system/framework/framework-res.apk\n"+powerTree+"TREE\n")
	app := testAppWithBash(t, root)

	rec := call(t, app.handleDetect, "POST", "/api/detect", map[string]any{
		"action": "power", "mode": "device",
	})
	if rec.Code != http.StatusOK {
		t.Fatalf("power read failed (%d): %s", rec.Code, rec.Body.String())
	}
	var body struct {
		Profile PowerProfile `json:"profile"`
	}
	decodeBody(t, rec, &body)
	if body.Profile.Source != "/system/framework/framework-res.apk" {
		t.Fatalf("source lost: %+v", body.Profile)
	}
	if body.Profile.Items != 3 || !strings.Contains(body.Profile.XML, `<device name="Android">`) {
		t.Fatalf("profile not converted: %d items", body.Profile.Items)
	}
}

func TestPowerProfileHandlerReportsFailure(t *testing.T) {
	root := writeDetectClone(t, "#!/usr/bin/env bash\necho 'no res/xml/power_profile.xml in /system/framework/framework-res.apk' >&2\nexit 4\n")
	app := testAppWithBash(t, root)

	rec := call(t, app.handleDetect, "POST", "/api/detect", map[string]any{
		"action": "power", "mode": "device",
	})
	if rec.Code != http.StatusBadGateway {
		t.Fatalf("want 502, got %d", rec.Code)
	}
	var body struct {
		Error string `json:"error"`
	}
	decodeBody(t, rec, &body)
	if !strings.Contains(body.Error, "power_profile") {
		t.Fatalf("stderr was not passed through: %+v", body)
	}
}

func TestSavePowerProfile(t *testing.T) {
	root, _ := testClone(t)
	body, _, err := xmltreeToXML(powerTree)
	if err != nil {
		t.Fatal(err)
	}

	path, items, err := savePowerProfile(root, body)
	if err != nil {
		t.Fatalf("save failed: %v", err)
	}
	if want := filepath.Join(root, "src", "framework", "res", "xml", "power_profile.xml"); path != want {
		t.Fatalf("wrote %s, want %s", path, want)
	}
	if items != 3 {
		t.Fatalf("counted %d items, want 3", items)
	}
	onDisk, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if string(onDisk) != body {
		t.Fatal("written file differs from the profile")
	}
}

// The guard that keeps the AOSP placeholder out of the source tree lives in the
// script; --check-profile exposes it without adb, so a regression here is caught
// by `go test` instead of by a wrong power_profile.xml on a phone.
const genericPowerTree = `E: device (line=20)
  A: name="Android" (Raw: "Android")
    E: item (line=38)
      A: name="ambient.on.display0" (Raw: "ambient.on.display0")
        T: '0.1'
    E: item (line=122)
      A: name="battery.capacity" (Raw: "battery.capacity")
        T: '1000'
    E: array (line=101)
      A: name="cpu.speeds.cluster0" (Raw: "cpu.speeds.cluster0")
        E: value (line=102)
            T: '400000'
`

const realPowerTree = `E: device (line=36)
  A: name="Android" (Raw: "Android")
    E: item (line=46)
      A: name="screen.on" (Raw: "screen.on")
        T: '149.73'
    E: item (line=58)
      A: name="battery.capacity" (Raw: "battery.capacity")
        T: '7700'
`

func TestProfileGuard(t *testing.T) {
	bash, err := findBash()
	if err != nil {
		t.Skip("no bash on this machine")
	}
	script, err := filepath.Abs(filepath.Join("..", "stuff", "scripts", "device-probe.sh"))
	if err != nil {
		t.Fatal(err)
	}
	if !fileExists(script) {
		t.Skip("device-probe.sh is not in this checkout")
	}

	cases := []struct {
		name string
		tree string
		want bool
	}{
		{"AOSP placeholder", genericPowerTree, false},
		{"vendor profile", realPowerTree, true},
	}
	for _, c := range cases {
		cmd := exec.Command(bash, "--noprofile", "--norc", script, "--check-profile")
		cmd.Stdin = strings.NewReader(c.tree)
		out, err := cmd.CombinedOutput()
		got := err == nil
		if got != c.want {
			t.Fatalf("%s: guard said %v (%q), want %v", c.name, got, strings.TrimSpace(string(out)), c.want)
		}
	}
}

func TestSavePowerProfileRejectsGarbage(t *testing.T) {
	root, _ := testClone(t)
	for _, body := range []string{"", "not xml", "<resources><item name=\"x\">1</item></resources>", "<device></device>"} {
		if _, _, err := savePowerProfile(root, body); err == nil {
			t.Fatalf("saved %q", body)
		}
	}
}
