package main

import (
	"os"
	"path/filepath"
)

// ---------------------------------------------------------------------------
// config.env when the clone has none
// ---------------------------------------------------------------------------
// config.env is device data, not source: it is git-ignored, and a copy is kept
// in stuff/backups/ so a re-clone or `git clean -xdf` does not lose the
// answers. `build.sh` restores it the same way (ensure_config in
// stuff/scripts/common.sh); doing it here too means the Config tab always opens
// a real file instead of an empty form, including when the app is the first
// thing started after a clone.
//
// Nothing is invented: with no backup and no shipped default the file stays
// missing, and the app's own "no config.env" handling takes over.
func ensureConfigFile(root string) {
	if root == "" {
		return
	}
	cfg := filepath.Join(root, "config.env")
	backup := filepath.Join(root, "stuff", "backups", "config.env")

	if raw, err := os.ReadFile(cfg); err == nil {
		// Keep the backup current: it is what puts the file back. Only write it
		// when it differs, so its mtime does not change on every launch.
		if old, err := os.ReadFile(backup); err == nil && string(old) == string(raw) {
			return
		}
		if os.MkdirAll(filepath.Dir(backup), 0o755) == nil {
			_ = os.WriteFile(backup, raw, 0o644)
		}
		return
	}

	for _, src := range []string{
		backup,
		filepath.Join(root, "stuff", "templates", "recoveries", "config.env"),
	} {
		raw, err := os.ReadFile(src)
		if err != nil {
			continue
		}
		if os.WriteFile(cfg, raw, 0o644) == nil {
			return
		}
	}
}