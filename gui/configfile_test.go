package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const sampleConfig = `# =============================================================================
# Treble Overlay — Device Configuration
# =============================================================================
# Read me first.

# ── Device identity ───────────────────────────────────────────────────────
# Drives the module/overlay names.
DEVICE_MANUFACTURER="samsung"
DEVICE_MODEL="SM-A908N"
DEVICE_CODENAME="r3q"

# ── Status bar padding ────────────────────────────────────────────────────
#   >>> OFF BY DEFAULT — uncomment the three lines to turn it on.
#
# Set all three to the SAME number.
#STATUS_BAR_CONTENT_PADDING=34
#STATUS_BAR_PADDING_START=34
#STATUS_BAR_PADDING_END=34

# ── Display ───────────────────────────────────────────────────────────────
ROUNDED_CORNER_RADIUS=100
HAS_UDFPS=false
#UDFPS_X=540
`

func findKey(t *testing.T, doc ConfigDoc, key string) ConfigEntry {
	t.Helper()
	for _, s := range doc.Sections {
		for _, e := range s.Entries {
			if e.Key == key {
				return e
			}
		}
	}
	t.Fatalf("%s was not parsed out of the file", key)
	return ConfigEntry{}
}

func TestParseConfigSectionsAndEntries(t *testing.T) {
	doc, err := parseConfig(sampleConfig)
	if err != nil {
		t.Fatal(err)
	}
	if doc.Total != 9 {
		t.Fatalf("total = %d, want 9 (%v)", doc.Total, keys(doc))
	}
	if doc.Enabled != 5 {
		t.Fatalf("enabled = %d, want 5 (%v)", doc.Enabled, keys(doc))
	}

	var titles []string
	for _, s := range doc.Sections {
		titles = append(titles, s.Title)
	}
	want := []string{"", "Device identity", "Status bar padding", "Display"}
	if strings.Join(titles, "|") != strings.Join(want, "|") {
		t.Fatalf("sections = %q, want %q", titles, want)
	}

	manufacturer := findKey(t, doc, "DEVICE_MANUFACTURER")
	if manufacturer.Value != "samsung" || !manufacturer.Enabled {
		t.Fatalf("DEVICE_MANUFACTURER = %+v", manufacturer)
	}
	if !strings.Contains(strings.Join(manufacturer.Comment, "\n"), "Drives the module") {
		t.Fatalf("the comment above the key was not attached: %q", manufacturer.Comment)
	}

	padding := findKey(t, doc, "STATUS_BAR_PADDING_START")
	if padding.Enabled {
		t.Fatal("a commented-out key must parse as off")
	}
	if padding.Value != "34" {
		t.Fatalf("value = %q, want 34", padding.Value)
	}
	if !strings.Contains(strings.Join(padding.Comment, "\n"), "OFF BY DEFAULT") {
		t.Fatalf("the note block above a commented key was not attached: %q", padding.Comment)
	}

	// The blurb above a section's first key is both the section's introduction
	// and that key's ⓘ text: the note is visible once, the ⓘ only on a click.
	identity := doc.Sections[1]
	if len(identity.Note) == 0 {
		t.Fatal("the section note is empty")
	}
	if !strings.Contains(strings.Join(identity.Entries[0].Comment, "\n"), "Drives the module") {
		t.Fatalf("the first key lost its comment: %q", identity.Entries[0].Comment)
	}

	// A key with no comment keeps an empty one; the ⓘ button is disabled.
	if got := findKey(t, doc, "UDFPS_X"); len(got.Comment) != 0 {
		t.Fatalf("UDFPS_X picked up a comment: %q", got.Comment)
	}
}

func keys(doc ConfigDoc) []string {
	var out []string
	for _, s := range doc.Sections {
		for _, e := range s.Entries {
			out = append(out, e.Key)
		}
	}
	return out
}

// TestApplyConfigEditsRewritesOnlyTheLinesTouched is the contract the form
// relies on: headings, prose and every untouched key come back byte for byte.
func TestApplyConfigEditsRewritesOnlyTheLinesTouched(t *testing.T) {
	doc, err := parseConfig(sampleConfig)
	if err != nil {
		t.Fatal(err)
	}
	radius := findKey(t, doc, "ROUNDED_CORNER_RADIUS")
	padding := findKey(t, doc, "STATUS_BAR_PADDING_START")
	manufacturer := findKey(t, doc, "DEVICE_MANUFACTURER")

	out, err := applyConfigEdits(sampleConfig, []ConfigEdit{
		{Line: radius.Line, Key: "ROUNDED_CORNER_RADIUS", Value: "120", Enabled: true},
		{Line: padding.Line, Key: "STATUS_BAR_PADDING_START", Value: "40", Enabled: true},
	})
	if err != nil {
		t.Fatal(err)
	}

	if !strings.Contains(out, "\nROUNDED_CORNER_RADIUS=120\n") {
		t.Fatalf("the value was not rewritten:\n%s", out)
	}
	if !strings.Contains(out, "\nSTATUS_BAR_PADDING_START=40\n") {
		t.Fatalf("the commented line was not enabled:\n%s", out)
	}
	if !strings.Contains(out, "#STATUS_BAR_CONTENT_PADDING=34") {
		t.Fatal("a line that was not edited changed")
	}
	if strings.Count(out, "\n") != strings.Count(sampleConfig, "\n") {
		t.Fatal("the number of lines changed")
	}

	// Turning one off is the same operation in reverse, and keeps the comment.
	out, err = applyConfigEdits(out, []ConfigEdit{
		{Line: manufacturer.Line, Key: "DEVICE_MANUFACTURER", Value: "samsung", Enabled: false},
	})
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(out, "\n#DEVICE_MANUFACTURER=\"samsung\"\n") {
		t.Fatalf("disabling a key did not comment it out:\n%s", out)
	}

	again, err := parseConfig(out)
	if err != nil {
		t.Fatal(err)
	}
	if findKey(t, again, "DEVICE_MANUFACTURER").Enabled {
		t.Fatal("the file says off but the parser says on")
	}
}

// TestApplyConfigEditsKeepsQuoteStyle: a quoted value stays quoted, a bare
// number stays bare, and a value bash would split gets quotes.
func TestApplyConfigEditsKeepsQuoteStyle(t *testing.T) {
	doc, _ := parseConfig(sampleConfig)
	cases := []struct {
		key   string
		value string
		want  string
	}{
		{"DEVICE_MANUFACTURER", "nothing", `DEVICE_MANUFACTURER="nothing"`},
		{"DEVICE_MANUFACTURER", "SM A908 with space", `DEVICE_MANUFACTURER="SM A908 with space"`},
		{"ROUNDED_CORNER_RADIUS", "0", "ROUNDED_CORNER_RADIUS=0"},
		{"DEVICE_MODEL", "", `DEVICE_MODEL=""`},
	}
	for _, tc := range cases {
		e := findKey(t, doc, tc.key)
		out, err := applyConfigEdits(sampleConfig, []ConfigEdit{
			{Line: e.Line, Key: e.Key, Value: tc.value, Enabled: true},
		})
		if err != nil {
			t.Fatalf("%s: %v", tc.key, err)
		}
		if !strings.Contains(out, "\n"+tc.want+"\n") {
			t.Fatalf("%s = %q was written as one of these, not %q:\n%s", tc.key, tc.value, tc.want, out)
		}
	}
}

// TestApplyConfigEditsRefusesStalePage: the line number must still hold the same
// key. Without this check a save from a window opened before an outside edit
// would rewrite whatever slid into that line.
func TestApplyConfigEditsRefusesStalePage(t *testing.T) {
	doc, _ := parseConfig(sampleConfig)
	radius := findKey(t, doc, "ROUNDED_CORNER_RADIUS")

	if _, err := applyConfigEdits(sampleConfig, []ConfigEdit{
		{Line: radius.Line, Key: "SOME_OTHER_KEY", Value: "1", Enabled: true},
	}); err == nil {
		t.Fatal("a save for a key that is not on that line was accepted")
	}
	if _, err := applyConfigEdits(sampleConfig, []ConfigEdit{
		{Line: 9999, Key: "ROUNDED_CORNER_RADIUS", Value: "1", Enabled: true},
	}); err == nil {
		t.Fatal("a save past the end of the file was accepted")
	}
	if _, err := applyConfigEdits(sampleConfig, []ConfigEdit{
		{Line: radius.Line, Key: "ROUNDED_CORNER_RADIUS", Value: "1\nrm -rf /", Enabled: true},
	}); err == nil {
		t.Fatal("a value with a line break was accepted")
	}
}

// TestRealConfigRoundTrips runs the same no-op save over the clone's own
// config.env. It is the cheapest way to keep the parser honest about the file
// that actually ships: any quoting or comment quirk shows up here.
func TestRealConfigRoundTrips(t *testing.T) {
	path := filepath.Join("..", "config.env")
	text, err := os.ReadFile(path)
	if err != nil {
		t.Skip("config.env not found; running outside the clone")
	}
	doc, err := parseConfig(string(text))
	if err != nil {
		t.Fatal(err)
	}
	if doc.Total < 20 {
		t.Fatalf("only %d settings found in config.env — the parser lost most of the file", doc.Total)
	}

	var edits []ConfigEdit
	for _, s := range doc.Sections {
		for _, e := range s.Entries {
			edits = append(edits, ConfigEdit{Line: e.Line, Key: e.Key, Value: e.Value, Enabled: e.Enabled})
		}
	}
	if len(edits) > 512 {
		t.Skip("too many settings for one save; the limit is exercised in the handler")
	}
	out, err := applyConfigEdits(string(text), edits)
	if err != nil {
		t.Fatal(err)
	}
	if out != string(text) {
		// Point at the first line that moved instead of dumping 200 lines.
		in := strings.Split(string(text), "\n")
		got := strings.Split(out, "\n")
		for i := 0; i < len(in) && i < len(got); i++ {
			if in[i] != got[i] {
				t.Fatalf("line %d changed by a no-op save:\n in: %q\nout: %q", i+1, in[i], got[i])
			}
		}
		t.Fatalf("a no-op save changed the file (%d in, %d out)", len(in), len(got))
	}
}

func TestConfigDocLookupIgnoresPlaceholders(t *testing.T) {
	doc, _ := parseConfig(sampleConfig)
	if got := doc.Lookup("DEVICE_CODENAME"); got != "r3q" {
		t.Fatalf("Lookup = %q, want r3q", got)
	}
	if got := doc.Lookup("STATUS_BAR_PADDING_START"); got != "" {
		t.Fatalf("a commented-out key answered %q", got)
	}

	placeholder, _ := parseConfig("DEVICE_CODENAME=\"<device_codename>\"\n")
	if got := placeholder.Lookup("DEVICE_CODENAME"); got != "" {
		t.Fatalf("a template placeholder answered %q, want nothing", got)
	}
}

func TestParseConfigKeepsCRLF(t *testing.T) {
	text := "# ── A ─────────\r\nKEY=1\r\n"
	doc, _ := parseConfig(text)
	entry := findKey(t, doc, "KEY")
	out, err := applyConfigEdits(text, []ConfigEdit{
		{Line: entry.Line, Key: "KEY", Value: "2", Enabled: true},
	})
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasSuffix(out, "KEY=2\r\n") {
		t.Fatalf("CRLF was not preserved: %q", out)
	}
}
