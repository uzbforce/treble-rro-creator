// ---------------------------------------------------------------------------
// gui/configseed_test.go — where config.env comes from in a fresh clone
// ---------------------------------------------------------------------------
// config.env is not tracked, so a clone starts without one. The app must have a
// file in place before the Config tab reads it, and must never overwrite the
// user's own values with the shipped default.
package main

import (
	"os"
	"path/filepath"
	"testing"
)

func writeFile(t *testing.T, path, body string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestEnsureConfigFileSeedsFromTheDefault(t *testing.T) {
	root := t.TempDir()
	writeFile(t, filepath.Join(root, "stuff", "templates", "recoveries", "config.env"), "DEVICE_MODEL=\"<model>\"\n")

	ensureConfigFile(root)

	raw, err := os.ReadFile(filepath.Join(root, "config.env"))
	if err != nil {
		t.Fatalf("a fresh clone should get a config.env: %v", err)
	}
	if string(raw) != "DEVICE_MODEL=\"<model>\"\n" {
		t.Fatalf("seeded the wrong content: %q", raw)
	}
	backup, err := os.ReadFile(filepath.Join(root, "stuff", "backups", "config.env"))
	if err != nil || string(backup) != string(raw) {
		t.Fatalf("the new config should also be backed up: %v", err)
	}
}

func TestEnsureConfigFilePrefersTheBackup(t *testing.T) {
	root := t.TempDir()
	writeFile(t, filepath.Join(root, "stuff", "templates", "recoveries", "config.env"), "DEVICE_MODEL=\"<model>\"\n")
	writeFile(t, filepath.Join(root, "stuff", "backups", "config.env"), "DEVICE_MODEL=\"mine\"\n")

	ensureConfigFile(root)

	raw, err := os.ReadFile(filepath.Join(root, "config.env"))
	if err != nil {
		t.Fatal(err)
	}
	if string(raw) != "DEVICE_MODEL=\"mine\"\n" {
		t.Fatalf("the user's backup should win over the default, got %q", raw)
	}
}

func TestEnsureConfigFileLeavesAnExistingConfigAlone(t *testing.T) {
	root := t.TempDir()
	writeFile(t, filepath.Join(root, "stuff", "templates", "recoveries", "config.env"), "DEVICE_MODEL=\"<model>\"\n")
	writeFile(t, filepath.Join(root, "config.env"), "DEVICE_MODEL=\"A90\"\n")

	ensureConfigFile(root)

	raw, err := os.ReadFile(filepath.Join(root, "config.env"))
	if err != nil || string(raw) != "DEVICE_MODEL=\"A90\"\n" {
		t.Fatalf("an existing config.env must not be replaced: %q %v", raw, err)
	}
	backup, err := os.ReadFile(filepath.Join(root, "stuff", "backups", "config.env"))
	if err != nil || string(backup) != "DEVICE_MODEL=\"A90\"\n" {
		t.Fatalf("the backup should follow the file in use: %q %v", backup, err)
	}
}

func TestEnsureConfigFileInventsNothing(t *testing.T) {
	root := t.TempDir()
	ensureConfigFile(root)
	if fileExists(filepath.Join(root, "config.env")) {
		t.Fatal("with no backup and no default there is nothing to seed from")
	}
}