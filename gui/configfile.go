package main

import (
	"fmt"
	"regexp"
	"strings"
)

// ---------------------------------------------------------------------------
// config.env as a form
// ---------------------------------------------------------------------------
// config.env is sourced by bash, so it has to stay a text file: comments are
// documentation, `#` in front of a key is how a feature is switched off, and
// the order of the lines is the order of the sections people read. The app used
// to show it in a textarea, which is honest but means the user has to know bash
// quoting rules to change a number.
//
// So the file is parsed here and edited line-wise: the form knows the key, the
// value and whether the line is commented out, and a save rewrites only the
// lines that changed. Everything else in the file — headings, prose, blank
// lines, the `#` on features that are off — is preserved byte for byte. That is
// also why the raw view is still there: if parsing ever gets something wrong,
// the user can see what the file actually says.
type ConfigEntry struct {
	Line    int      `json:"line"`
	Key     string   `json:"key"`
	Value   string   `json:"value"`
	Enabled bool     `json:"enabled"`
	Comment []string `json:"comment"`
}

type ConfigSection struct {
	Title   string        `json:"title"`
	Note    []string      `json:"note"`
	Entries []ConfigEntry `json:"entries"`
}

type ConfigDoc struct {
	Sections []ConfigSection `json:"sections"`
	Total    int             `json:"total"`
	Enabled  int             `json:"enabled"`
}

// Lookup returns an enabled value, treating a leftover template placeholder
// ("<device_codename>") as "not set" — it is not a name, and the adb presets
// would otherwise happily grep the device for the literal angle brackets.
func (d ConfigDoc) Lookup(key string) string {
	for _, s := range d.Sections {
		for _, e := range s.Entries {
			if e.Key != key || !e.Enabled {
				continue
			}
			v := strings.TrimSpace(e.Value)
			if v == "" || strings.HasPrefix(v, "<") {
				return ""
			}
			return v
		}
	}
	return ""
}

func (d ConfigDoc) LookupAll(key string) []string {
	var out []string
	for _, s := range d.Sections {
		for _, e := range s.Entries {
			if e.Key == key && e.Enabled {
				v := strings.TrimSpace(e.Value)
				if v != "" && !strings.HasPrefix(v, "<") {
					out = append(out, v)
				}
			}
		}
	}
	return out
}

var (
	// "# ── Device identity ─────────────" — a section heading.
	configHeading = regexp.MustCompile(`^\s*#\s*─+\s*(.*?)\s*─*\s*$`)
	// KEY=value, optionally commented out. Keys in this file are upper case;
	// requiring that keeps prose lines ("# More: docs/…=…") out of the form.
	configKey = regexp.MustCompile(`^(\s*)(#\s*)?([A-Z][A-Z0-9_]*)\s*=(.*)$`)
	// A value that bash will read back unchanged without quotes.
	plainValue = regexp.MustCompile(`^[A-Za-z0-9_.,:/+@%=-]*$`)
)

// parseConfig turns the file into sections and entries. It never fails on
// content: an unparsable line is simply not shown in the form and is left
// untouched on save.
func parseConfig(text string) (ConfigDoc, error) {
	// Non-nil slices so the JSON the page receives is always [] and never null:
	// a section that is only a heading would otherwise break the renderer.
	doc := ConfigDoc{Sections: []ConfigSection{}}
	lines := strings.Split(text, "\n")
	var cur *ConfigSection
	var pending []string // the comment run directly above the next key

	newSection := func() *ConfigSection {
		doc.Sections = append(doc.Sections, ConfigSection{Entries: []ConfigEntry{}, Note: []string{}})
		return &doc.Sections[len(doc.Sections)-1]
	}

	for i, raw := range lines {
		line := strings.TrimRight(raw, "\r")

		if m := configHeading.FindStringSubmatch(line); m != nil {
			s := newSection()
			s.Title = strings.TrimSpace(m[1])
			cur = s
			pending = nil
			continue
		}
		if cur == nil {
			cur = newSection()
		}

		if m := configKey.FindStringSubmatch(line); m != nil {
			value, _ := splitValue(m[4])
			entry := ConfigEntry{
				Line:    i,
				Key:     m[3],
				Value:   value,
				Enabled: m[2] == "",
				Comment: pending,
			}
			cur.Entries = append(cur.Entries, entry)
			doc.Total++
			if entry.Enabled {
				doc.Enabled++
			}
			pending = nil
			continue
		}

		if strings.TrimSpace(line) == "" {
			// A blank line ends a comment block: a key is described by the text
			// right above it, not by every paragraph since the last key.
			pending = nil
			continue
		}

		if strings.HasPrefix(strings.TrimSpace(line), "#") {
			text := strings.TrimSpace(strings.TrimPrefix(strings.TrimSpace(line), "#"))
			pending = append(pending, text)
			if len(cur.Entries) == 0 {
				cur.Note = append(cur.Note, text)
			}
			continue
		}

		// Anything else (a stray command, an array) stays in the file and out
		// of the form.
		pending = nil
	}

	// A section's blurb is stored twice on purpose: once as the section's
	// introduction (always visible) and once as the first key's comment, so
	// clicking ⓘ on that row answers the question where the user asked it.
	//
	// A key with no note of its own inherits the section's, so ⓘ is never a
	// dead button: in this file the explanation for a group of lines is
	// written once, above the first of them.
	for si := range doc.Sections {
		s := &doc.Sections[si]
		if len(s.Note) == 0 {
			continue
		}
		for ei := range s.Entries {
			if len(s.Entries[ei].Comment) == 0 {
				s.Entries[ei].Comment = s.Note
			}
		}
	}
	return doc, nil
}

// splitValue mirrors the two ways this file writes a value: bare, or inside
// quotes. The quote character is remembered so a save writes the same style.
func splitValue(raw string) (string, byte) {
	s := strings.TrimSpace(raw)
	if len(s) >= 2 {
		if q := s[0]; q == '"' || q == '\'' {
			if s[len(s)-1] == q && !escapedAt(s, len(s)-1) {
				return unescape(s[1:len(s)-1], q), q
			}
		}
	}
	return s, 0
}

func escapedAt(s string, i int) bool {
	n := 0
	for j := i - 1; j >= 0 && s[j] == '\\'; j-- {
		n++
	}
	return n%2 == 1
}

// unescape only undoes what formatValue adds. A lone backslash (\d) is text,
// exactly as bash reads it inside double quotes.
func unescape(s string, quote byte) string {
	if quote != '"' {
		return s
	}
	var b strings.Builder
	for i := 0; i < len(s); i++ {
		if s[i] == '\\' && i+1 < len(s) && (s[i+1] == '\\' || s[i+1] == '"') {
			b.WriteByte(s[i+1])
			i++
			continue
		}
		b.WriteByte(s[i])
	}
	return b.String()
}

// ---------------------------------------------------------------------------
// Saving
// ---------------------------------------------------------------------------
// ConfigEdit is one row the user changed. Key is sent back so a save cannot
// land on a different line than the one the form was showing: if the file was
// edited outside the app in the meantime, the key no longer matches and the
// save is refused instead of quietly rewriting the wrong setting.
type ConfigEdit struct {
	Line    int    `json:"line"`
	Key     string `json:"key"`
	Value   string `json:"value"`
	Enabled bool   `json:"enabled"`
}

func applyConfigEdits(text string, edits []ConfigEdit) (string, error) {
	if len(edits) == 0 {
		return text, nil
	}
	if len(edits) > 512 {
		return "", fmt.Errorf("too many changes in one save")
	}

	lines := strings.Split(text, "\n")
	seen := make(map[int]struct{}, len(edits))

	for _, e := range edits {
		if e.Line < 0 || e.Line >= len(lines) {
			return "", fmt.Errorf("%s: line %d is not in the file any more — reload", e.Key, e.Line+1)
		}
		if _, dup := seen[e.Line]; dup {
			return "", fmt.Errorf("%s: two changes for line %d", e.Key, e.Line+1)
		}
		seen[e.Line] = struct{}{}

		if strings.ContainsAny(e.Value, "\r\n\x00") {
			return "", fmt.Errorf("%s: a value cannot contain a line break", e.Key)
		}

		cr := ""
		line := lines[e.Line]
		if strings.HasSuffix(line, "\r") {
			cr = "\r"
			line = strings.TrimSuffix(line, "\r")
		}

		m := configKey.FindStringSubmatch(line)
		if m == nil {
			return "", fmt.Errorf("%s: line %d is no longer a setting — reload", e.Key, e.Line+1)
		}
		if m[3] != e.Key {
			return "", fmt.Errorf("the file changed on disk: line %d is %s now — reload", e.Line+1, m[3])
		}

		current, quote := splitValue(m[4])
		if current == e.Value && (m[2] == "") == e.Enabled {
			// Nothing actually changed. Not rewriting the line is what makes a
			// no-op save byte-for-byte: the file has lines whose quoting is
			// already odd (#HW_OVERLAY_PRIORITY=<number>), and a form save must
			// not restyle a row the user did not touch.
			continue
		}

		// Keep the marker the file used if the row is unchanged, drop it when
		// the switch went on, and add a plain '#' when it went off.
		hash := m[2]
		switch {
		case e.Enabled:
			hash = ""
		case hash == "":
			hash = "#"
		}
		lines[e.Line] = m[1] + hash + e.Key + "=" + formatValue(e.Value, quote, m[4]) + cr
	}

	return strings.Join(lines, "\n"), nil
}

// formatValue keeps the file's own style: a value that was quoted stays
// quoted, a bare number stays bare, and a value that bash would re-split (a
// path with spaces, a cutout path) gets the quotes it needs.
func formatValue(value string, quote byte, original string) string {
	if quote != '"' && quote != '\'' && plainValue.MatchString(value) {
		return value
	}
	if quote == '\'' && !strings.ContainsRune(value, '\'') {
		return "'" + value + "'"
	}
	return `"` + escapeDouble(value) + `"`
}

func escapeDouble(s string) string {
	var b strings.Builder
	for i := 0; i < len(s); i++ {
		switch s[i] {
		case '\\', '"':
			b.WriteByte('\\')
		}
		b.WriteByte(s[i])
	}
	return b.String()
}
