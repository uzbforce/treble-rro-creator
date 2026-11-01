package main

import (
	"os"
	"path/filepath"
	"strings"
)

// toolVersion reads stuff/VERSION, the one place the tool's own version is
// written. The shell scripts read the same file (stuff/scripts/common.sh), so
// the CLI and the app cannot drift apart. A copy without the file simply reports
// no version instead of failing.
func toolVersion(root string) string {
	b, err := os.ReadFile(filepath.Join(root, "stuff", "VERSION"))
	if err != nil {
		return ""
	}
	v := strings.TrimSpace(string(b))
	// One line only: a stray blank line or a trailing comment is not part of it.
	if i := strings.IndexAny(v, "\r\n"); i >= 0 {
		v = strings.TrimSpace(v[:i])
	}
	if len(v) > 24 {
		return ""
	}
	return v
}
