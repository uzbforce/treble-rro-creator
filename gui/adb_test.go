package main

import (
	"archive/zip"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestSplitCommand pins the parsing of the one text box the user gets. The
// important cases are the ones a naive strings.Fields gets wrong: the pipe that
// belongs to the phone's shell, and paths with spaces.
func TestSplitCommand(t *testing.T) {
	cases := []struct {
		name    string
		in      string
		want    []string
		wantErr bool
	}{
		{name: "simple", in: "devices -l", want: []string{"devices", "-l"}},
		{name: "shell pipe", in: "shell getprop | grep -i r3q",
			want: []string{"shell", "getprop", "|", "grep", "-i", "r3q"}},
		{name: "double quotes", in: `pull "/sdcard/My Files/a b.txt"`, want: []string{"pull", "/sdcard/My Files/a b.txt"}},
		{name: "single quotes", in: `shell echo 'one two'`, want: []string{"shell", "echo", "one two"}},
		{name: "escaped space", in: `pull /sdcard/a\ b.txt`, want: []string{"pull", "/sdcard/a b.txt"}},
		{name: "empty quoted arg", in: `shell echo ""`, want: []string{"shell", "echo", ""}},
		{name: "extra spaces", in: "  install   -r   x.apk ", want: []string{"install", "-r", "x.apk"}},
		{name: "unclosed quote", in: `pull "abc`, wantErr: true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got, err := splitCommand(tc.in)
			if tc.wantErr {
				if err == nil {
					t.Fatalf("expected an error, got %q", got)
				}
				return
			}
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if strings.Join(got, "\x00") != strings.Join(tc.want, "\x00") {
				t.Fatalf("got  %q\nwant %q", got, tc.want)
			}
		})
	}
}

func TestAdbArgs(t *testing.T) {
	got, err := adbArgs("adb shell getprop ro.product.device")
	if err != nil {
		t.Fatal(err)
	}
	if strings.Join(got, " ") != "shell getprop ro.product.device" {
		t.Fatalf("a pasted line kept its leading adb: %q", got)
	}

	// A bare newline is just a separator, but one inside quotes would end up
	// inside an argument, and adb would see two commands in one argv.
	for _, bad := range []string{"", "   ", "adb", "adb.exe", "shell \"a\nb\""} {
		if _, err := adbArgs(bad); err == nil {
			t.Fatalf("adbArgs(%q) should have failed", bad)
		}
	}
}

func TestResolvePlaceholders(t *testing.T) {
	got, err := resolvePlaceholders(
		[]string{"shell", "getprop", "|", "grep", "-i", "{codename}"},
		map[string]string{"codename": "r3q", "manufacturer": "samsung"},
	)
	if err != nil {
		t.Fatal(err)
	}
	if got[len(got)-1] != "r3q" {
		t.Fatalf("codename was not substituted: %q", got)
	}

	if _, err := resolvePlaceholders([]string{"lookup", "{codename}"}, map[string]string{}); err == nil {
		t.Fatal("an unfilled placeholder was passed through as a literal")
	}
}

func TestSafeToken(t *testing.T) {
	for _, ok := range []string{"r3q", "SM-A908N", "nothing.here", "a_b"} {
		if safeToken(ok) != ok {
			t.Fatalf("%q was rejected", ok)
		}
	}
	for _, bad := range []string{"r3q; rm -rf /", "a b", "$(id)", strings.Repeat("a", 65)} {
		if safeToken(bad) != "" {
			t.Fatalf("%q was accepted", bad)
		}
	}
}

// TestPresetsAreComplete is a drift guard: an entry with no id, no reason or a
// {placeholder} nobody fills would produce a button that runs the wrong thing.
func TestPresetsAreComplete(t *testing.T) {
	seen := map[string]bool{}
	for _, p := range adbPresets {
		if p.ID == "" || p.Label == "" || p.Why == "" || len(p.Args) == 0 {
			t.Fatalf("preset %q is incomplete: %+v", p.ID, p)
		}
		if seen[p.ID] {
			t.Fatalf("duplicate preset id %q", p.ID)
		}
		seen[p.ID] = true

		joined := strings.Join(p.Args, " ")
		for _, token := range []string{"{codename}", "{manufacturer}"} {
			need := "codename"
			if token == "{manufacturer}" {
				need = "manufacturer"
			}
			if strings.Contains(joined, token) && !contains(p.Needs, need) {
				t.Fatalf("preset %q uses %s but does not declare it in Needs", p.ID, token)
			}
		}
	}
	if len(adbPresets) < 10 {
		t.Fatalf("only %d presets — the Device tab would be nearly empty", len(adbPresets))
	}
}

func writeZip(t *testing.T, path string, entries map[string]string) {
	t.Helper()
	f, err := os.Create(path)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()

	zw := zip.NewWriter(f)
	for name, body := range entries {
		w, err := zw.CreateHeader(&zip.FileHeader{Name: name, Method: zip.Deflate})
		if err != nil {
			t.Fatal(err)
		}
		if _, err := w.Write([]byte(body)); err != nil {
			t.Fatal(err)
		}
	}
	if err := zw.Close(); err != nil {
		t.Fatal(err)
	}
}

func TestUnzipPlatformTools(t *testing.T) {
	dir := t.TempDir()
	archive := filepath.Join(dir, "pt.zip")
	writeZip(t, archive, map[string]string{
		"platform-tools/adb":            "binary",
		"platform-tools/lib/libc++.so":  "lib",
		"platform-tools-not-ours/x.txt": "ignored",
		"somewhere/else.txt":            "ignored",
	})

	dest := filepath.Join(dir, "out")
	if err := os.MkdirAll(dest, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := unzipPlatformTools(archive, dest); err != nil {
		t.Fatal(err)
	}
	if b, err := os.ReadFile(filepath.Join(dest, "platform-tools", "adb")); err != nil || string(b) != "binary" {
		t.Fatalf("adb was not extracted: %v %q", err, b)
	}
	if _, err := os.Stat(filepath.Join(dest, "platform-tools", "lib", "libc++.so")); err != nil {
		t.Fatalf("subdirectory was not extracted: %v", err)
	}
	if _, err := os.Stat(filepath.Join(dest, "somewhere")); err == nil {
		t.Fatal("a file outside platform-tools/ was extracted")
	}
}

// TestUnzipRejectsTraversal: the zip comes from the network, so an entry that
// climbs out of the destination must be refused, not joined.
func TestUnzipRejectsTraversal(t *testing.T) {
	dir := t.TempDir()
	archive := filepath.Join(dir, "evil.zip")
	writeZip(t, archive, map[string]string{
		"platform-tools/../../escaped.txt": "pwned",
	})
	dest := filepath.Join(dir, "out")
	if err := os.MkdirAll(dest, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := unzipPlatformTools(archive, dest); err == nil {
		t.Fatal("an archive with a ../ entry was accepted")
	}
	if _, err := os.Stat(filepath.Join(dir, "escaped.txt")); err == nil {
		t.Fatal("the traversal actually wrote outside the destination")
	}
}

func TestUnzipRejectsNonZip(t *testing.T) {
	dir := t.TempDir()
	notZip := filepath.Join(dir, "proxy-error.zip")
	if err := os.WriteFile(notZip, []byte("<html>blocked</html>"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := unzipPlatformTools(notZip, dir); err == nil {
		t.Fatal("an HTML error page was accepted as platform-tools")
	}
}

func TestHumanBytes(t *testing.T) {
	if got := humanBytes(1536); got != "2 kB" {
		t.Fatalf("humanBytes(1536) = %q", got)
	}
	if got := humanBytes(3 << 20); got != "3.0 MB" {
		t.Fatalf("humanBytes(3MB) = %q", got)
	}
}

// `adb devices -l` is not a clean table: the same stream carries the daemon
// start notice, header and version-mismatch lines, and a phone that is attached
// but unauthorized has to survive parsing with its state intact.
func TestParseAdbDevices(t *testing.T) {
	out := "List of devices attached\n" +
		"* daemon not running; starting now at tcp:5037\n" +
		"RFCM90F5BBX            device product:lineage_r3q model:SM_A908N device:r3q transport_id:36\n" +
		"595648cf1cdc           device product:zephyr_global model:26012RN62A device:zephyr transport_id:37\n" +
		"0123456789AB           unauthorized usb:1-1 transport_id:3\n" +
		"emulator-5554          offline\n" +
		"\n"

	devices := parseAdbDevices(out)
	if len(devices) != 4 {
		t.Fatalf("parsed %d devices, want 4: %+v", len(devices), devices)
	}
	if devices[0].Serial != "RFCM90F5BBX" || devices[0].Model != "SM_A908N" || devices[0].Product != "lineage_r3q" {
		t.Fatalf("first device = %+v", devices[0])
	}
	if devices[0].Label != "SM_A908N (lineage_r3q)" {
		t.Fatalf("label = %q", devices[0].Label)
	}
	if devices[2].State != "unauthorized" {
		t.Fatalf("unauthorized state was lost: %+v", devices[2])
	}
	if devices[3].State != "offline" || devices[3].Label != "no model reported" {
		t.Fatalf("offline device = %+v", devices[3])
	}
	if got := len(readyAdbDevices(devices)); got != 2 {
		t.Fatalf("%d ready devices, want 2", got)
	}
}

func TestPickAdbSerial(t *testing.T) {
	devices := []AdbDevice{
		{Serial: "A90", State: "device", Model: "SM_A908N"},
		{Serial: "REDMI", State: "device", Model: "26012RN62A"},
		{Serial: "OLD", State: "unauthorized"},
	}

	if got, err := pickAdbSerial(devices, "REDMI"); err != nil || got != "REDMI" {
		t.Fatalf("explicit pick = %q, %v", got, err)
	}
	if _, err := pickAdbSerial(devices, ""); err == nil {
		t.Fatal("two ready devices with no pick was accepted")
	} else if !strings.Contains(err.Error(), "choose one") {
		t.Fatalf("error does not say what to do: %v", err)
	}
	if _, err := pickAdbSerial(devices, "OLD"); err == nil || !strings.Contains(err.Error(), "unauthorized") {
		t.Fatalf("unauthorized pick = %v", err)
	}
	if _, err := pickAdbSerial(devices, "GONE"); err == nil || !strings.Contains(err.Error(), "is not attached") {
		t.Fatalf("stale pick = %v", err)
	}
	if _, err := pickAdbSerial(devices, "A90 "); err != nil {
		t.Fatalf("a trailing space in the pick broke it: %v", err)
	}

	one := devices[:1]
	if got, err := pickAdbSerial(one, ""); err != nil || got != "A90" {
		t.Fatalf("single ready device = %q, %v", got, err)
	}
	if _, err := pickAdbSerial(nil, ""); err == nil || !strings.Contains(err.Error(), "no device is connected") {
		t.Fatalf("empty list = %v", err)
	}
	if _, err := pickAdbSerial(devices[2:], ""); err == nil || !strings.Contains(err.Error(), "no device is ready") {
		t.Fatalf("nothing ready = %v", err)
	}
}

func TestAdbArgsHaveSerial(t *testing.T) {
	if !adbArgsHaveSerial([]string{"-s", "X", "shell", "true"}) {
		t.Fatal("-s was not recognised")
	}
	if adbArgsHaveSerial([]string{"shell", "true"}) {
		t.Fatal("a command without a selector was treated as one")
	}
}

// `adb devices -l` is a stream, not a table: the daemon's chatter and a version
// warning share it with the list, the same serial can appear twice, and a
// wireless transport looks like an address. None of that may reach the picker.
func TestParseAdbDevicesHardening(t *testing.T) {
	out := "List of devices attached\n" +
		"adb server version (41) doesn't match this client (39); killing...\n" +
		"* daemon started successfully *\n" +
		"192.168.0.31:5555      device product:lineage_r3q model:SM_A908N device:r3q\n" +
		"RFCM90F5BBX            device product:lineage_r3q model:SM_A908N device:r3q\n" +
		"RFCM90F5BBX            device product:lineage_r3q model:SM_A908N device:r3q\n" +
		"595648cf1cdc           unauthorized usb:1-1 transport_id:37\n"

	devices := parseAdbDevices(out)
	if len(devices) != 3 {
		t.Fatalf("parsed %d devices, want 3 (chatter dropped, duplicate merged): %+v", len(devices), devices)
	}
	if devices[0].Serial != "192.168.0.31:5555" || !strings.Contains(devices[0].Label, "[wireless]") {
		t.Fatalf("wireless device = %+v", devices[0])
	}
	if devices[1].Serial != "RFCM90F5BBX" || strings.Contains(devices[1].Label, "[wireless]") {
		t.Fatalf("usb device = %+v", devices[1])
	}
	if len(readyAdbDevices(devices)) != 2 {
		t.Fatalf("%d ready devices, want 2", len(readyAdbDevices(devices)))
	}
}

func TestAdbConnecting(t *testing.T) {
	if !adbConnecting([]AdbDevice{{Serial: "X", State: "connecting"}}) {
		t.Fatal("a connecting device was not noticed")
	}
	if adbConnecting([]AdbDevice{{Serial: "X", State: "device"}, {Serial: "Y", State: "offline"}}) {
		t.Fatal("ready/offline devices were treated as connecting")
	}
}
