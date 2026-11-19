// ---------------------------------------------------------------------------
// gui/unpack_dest_test.go — the folder -out may and may not empty
// ---------------------------------------------------------------------------
// The unpacker clears its destination before extracting, which is correct for
// the temp folder it made itself and destructive for a path the user typed. The
// guard is the only thing between `-unpack super.img -out ~/Documents` and the
// loss of Documents, so each case below is a folder that must survive.
package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestCheckUnpackDest(t *testing.T) {
	base := t.TempDir()
	firmware := filepath.Join(base, "super.img")
	// A bare file: classify() would reject it, which is why the guard runs
	// before the source is read — the refusal has to win over "not a firmware".
	if err := os.WriteFile(firmware, []byte("firmware"), 0o644); err != nil {
		t.Fatal(err)
	}
	other := filepath.Join(base, "notes.txt")
	if err := os.WriteFile(other, []byte("not a folder"), 0o644); err != nil {
		t.Fatal(err)
	}

	empty := filepath.Join(base, "empty")
	if err := os.MkdirAll(empty, 0o755); err != nil {
		t.Fatal(err)
	}

	unrelated := filepath.Join(base, "pictures")
	if err := os.MkdirAll(unrelated, 0o755); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"holiday.jpg", "bills.pdf"} {
		if err := os.WriteFile(filepath.Join(unrelated, name), []byte("mine"), 0o644); err != nil {
			t.Fatal(err)
		}
	}

	owned := filepath.Join(base, "owned")
	if err := os.MkdirAll(filepath.Join(owned, "system"), 0o755); err != nil {
		t.Fatal(err)
	}
	markUnpackDir(owned, "some-key")

	cases := []struct {
		name  string
		dest  string
		force bool
		want  string // empty means: allowed
	}{
		{"the firmware itself", firmware, false, "firmware being read"},
		{"the firmware itself, forced", firmware, true, "firmware being read"},
		{"the folder that holds the firmware", base, false, "holds the firmware"},
		{"the folder that holds the firmware, forced", base, true, "holds the firmware"},
		{"a file", other, false, "not a folder"},
		{"a folder this tool did not write", unrelated, false, "did not write"},
		{"the same folder, forced", unrelated, true, ""},
		{"a previous extraction", owned, false, ""},
		{"an empty folder", empty, false, ""},
		{"nothing there yet", filepath.Join(base, "new", "tree"), false, ""},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			err := checkUnpackDest(tc.dest, firmware, tc.force)
			if tc.want == "" {
				if err != nil {
					t.Fatalf("expected the destination to be allowed, got %v", err)
				}
				return
			}
			if err == nil {
				t.Fatalf("expected a refusal mentioning %q", tc.want)
			}
			if !strings.Contains(err.Error(), tc.want) {
				t.Fatalf("refusal should say %q, got %v", tc.want, err)
			}
		})
	}
}

// A refused destination has to be refused before anything is deleted, and the
// message has to name what -force would empty.
func TestUnpackLeavesARefusedFolderAlone(t *testing.T) {
	base := t.TempDir()
	firmware := filepath.Join(base, "super.img")
	if err := os.WriteFile(firmware, []byte("not really a super image"), 0o644); err != nil {
		t.Fatal(err)
	}
	dest := filepath.Join(base, "documents")
	if err := os.MkdirAll(dest, 0o755); err != nil {
		t.Fatal(err)
	}
	keep := filepath.Join(dest, "thesis.txt")
	if err := os.WriteFile(keep, []byte("mine"), 0o644); err != nil {
		t.Fatal(err)
	}

	_, err := unpackFirmwareTo(firmware, dest, false)
	if err == nil {
		t.Fatal("expected the unpacker to refuse this destination")
	}
	if !strings.Contains(err.Error(), "did not write") || !strings.Contains(err.Error(), "thesis.txt") {
		t.Fatalf("error should say why and what is there: %v", err)
	}
	if raw, readErr := os.ReadFile(keep); readErr != nil || string(raw) != "mine" {
		t.Fatalf("the refused folder was touched: %v", readErr)
	}
}