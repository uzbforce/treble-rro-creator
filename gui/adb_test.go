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
