package main

import (
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"
)

// The installer says it needs a password with one protocol line. It must never
// reach the pane: emit turns it into a note, marks the run, and finish emits the
// separate line the page turns into the dialog.
func TestSudoMarkerBecomesDialogSignal(t *testing.T) {
	r := NewRunner()
	r.emit("err", sudoMarker)

	snap := r.Snapshot()
	if !snap.Sudo {
		t.Fatal("the marker did not mark the run as needing sudo")
	}
	for _, line := range snap.Lines {
		if strings.Contains(line.Text, sudoMarker) {
			t.Fatalf("marker leaked into the log: %q", line.Text)
		}
	}

	r.finish(errors.New("exit 1"))
	snap = r.Snapshot()
	sawSudo := false
	for _, line := range snap.Lines {
		if line.Stream == "sudo" {
			sawSudo = true
		}
	}
	if !sawSudo {
		t.Fatal("a failed run that needs a password must publish the sudo line")
	}
}

// mergeEnv has to drop the app's own value for a key we are overriding: the
// child's getenv reads the first copy, so leaving both would make the override
// depend on how the app was launched.
func TestMergeEnvOverrides(t *testing.T) {
	got := mergeEnv(
		[]string{"PATH=/bin", "SUDO_ASKPASS=/old/askpass"},
		[]string{"SUDO_ASKPASS=/new/askpass", "RRO_SUDO_PASSWORD_FILE=/tmp/pw"},
	)
	joined := strings.Join(got, "\n")
	if strings.Contains(joined, "/old/askpass") {
		t.Fatalf("the inherited askpass survived: %q", got)
	}
	for _, want := range []string{"PATH=/bin", "SUDO_ASKPASS=/new/askpass", "RRO_SUDO_PASSWORD_FILE=/tmp/pw"} {
		if !strings.Contains(joined, want) {
			t.Fatalf("mergeEnv lost %q: %q", want, got)
		}
	}
}

// sudoEnv is the whole handshake on the Go side: a private file with the
// password, the two environment entries sudo -A needs, and a cleanup that
// removes the file.
func TestSudoEnv(t *testing.T) {
	root := t.TempDir()
	helper := filepath.Join(root, "stuff", "scripts", "sudo-askpass.sh")
	if err := os.MkdirAll(filepath.Dir(helper), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(helper, []byte("#!/bin/sh\nexit 1\n"), 0o755); err != nil {
		t.Fatal(err)
	}

	a := &App{}
	a.root = root

	env, cleanup, err := a.sudoEnv("hunter2")
	if err != nil {
		t.Fatal(err)
	}
	if cleanup == nil {
		t.Fatal("no cleanup — the password file would outlive the run")
	}
	if len(env) != 2 || env[0] != "SUDO_ASKPASS="+helper {
		t.Fatalf("unexpected env: %q", env)
	}

	path := strings.TrimPrefix(env[1], "RRO_SUDO_PASSWORD_FILE=")
	if path == env[1] || path == "" {
		t.Fatalf("no password file in %q", env)
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if string(data) != "hunter2\n" {
		t.Fatalf("password file holds %q", data)
	}
	if runtime.GOOS != "windows" {
		st, err := os.Stat(path)
		if err != nil {
			t.Fatal(err)
		}
		if st.Mode().Perm() != 0o600 {
			t.Fatalf("password file is %o, want 0600", st.Mode().Perm())
		}
	}

	cleanup()
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatalf("the password file was not removed (stat: %v)", err)
	}

	if env, cleanup, err := a.sudoEnv(""); err != nil || env != nil || cleanup != nil {
		t.Fatalf("an empty password should add nothing: env=%q cleanup set=%v err=%v", env, cleanup != nil, err)
	}
}

// A password must not travel with a verb that can never install anything.
func TestHandleRunSudoOnlyForInstallingVerbs(t *testing.T) {
	a := &App{runner: NewRunner()}
	req := httptest.NewRequest(http.MethodPost, "/api/run", strings.NewReader(`{"verb":"clean","sudo":"x"}`))
	rec := httptest.NewRecorder()
	a.handleRun(rec, req)
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("status %d, want 400: %s", rec.Code, rec.Body.String())
	}
}

// A progress bar repaints with \r. The live page must see each repaint (so a
// download is visibly moving) while the replay buffer keeps one line, and CRLF
// must stay an ordinary line ending.
func TestProgressRepaints(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("bash is not on the runner's path")
	}
	bash, err := exec.LookPath("bash")
	if err != nil {
		t.Skip("bash not found")
	}

	r := NewRunner()
	ch, stop := r.Subscribe()
	defer stop()

	script := "printf 'one\\r'; sleep 0.05; printf 'two\\r'; sleep 0.05; printf 'done\\n'; printf 'crlf\\r\\n'"
	if err := r.Start(t.TempDir(), bash, []string{"-c", script}, "test", false); err != nil {
		t.Fatal(err)
	}

	var live []LogLine
	timeout := time.After(10 * time.Second)
wait:
	for {
		select {
		case line := <-ch:
			live = append(live, line)
			if line.Stream == "done" {
				break wait
			}
		case <-timeout:
			t.Fatal("the child did not finish")
		}
	}

	var repaints []string
	for _, line := range live {
		if strings.Contains(line.Text, "\r") {
			t.Fatalf("carriage return left in a line: %q", line.Text)
		}
		if line.Stream == "progress" {
			repaints = append(repaints, line.Text)
		}
	}
	if len(repaints) != 2 || repaints[0] != "one" || repaints[1] != "two" {
		t.Fatalf("live repaints = %q, want [one two]", repaints)
	}

	var buffered []string
	crlf := false
	for _, line := range r.Snapshot().Lines {
		if line.Stream == "progress" {
			buffered = append(buffered, line.Text)
		}
		if line.Stream == "out" && line.Text == "crlf" {
			crlf = true
		}
	}
	if len(buffered) != 1 || buffered[0] != "two" {
		t.Fatalf("buffered repaints = %q, want just [two]", buffered)
	}
	if !crlf {
		t.Fatal("CRLF was not treated as a normal line ending")
	}
}

func TestSudoEnvWithoutHelper(t *testing.T) {
	a := &App{}
	a.root = t.TempDir()
	if _, _, err := a.sudoEnv("x"); err == nil {
		t.Fatal("expected an error when the clone has no askpass helper")
	}
}

// The end-to-end path: POST /api/run with a password runs build.sh with the
// askpass environment, strips the marker from the log, publishes the sudo line,
// and deletes the password file when the child exits.
func TestHandleRunSudoHandshake(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("the handshake is a Linux/macOS path")
	}
	bash, err := exec.LookPath("bash")
	if err != nil {
		t.Skip("bash not found")
	}

	root := t.TempDir()
	helper := filepath.Join(root, "stuff", "scripts", "sudo-askpass.sh")
	if err := os.MkdirAll(filepath.Dir(helper), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(helper, []byte("#!/bin/sh\nexit 1\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	// Records what the child was handed, then behaves like toolchain.sh when it
	// cannot ask for a password.
	script := "#!/bin/sh\n" +
		"printf '%s\\n' \"$SUDO_ASKPASS\" > askpass.path\n" +
		"printf '%s\\n' \"$RRO_SUDO_PASSWORD_FILE\" > password.path\n" +
		"echo '" + sudoMarker + "' >&2\n" +
		"exit 1\n"
	if err := os.WriteFile(filepath.Join(root, "build.sh"), []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}

	a := &App{runner: NewRunner()}
	a.root = root
	a.bash = bash

	req := httptest.NewRequest(http.MethodPost, "/api/run", strings.NewReader(`{"verb":"setup","sudo":"hunter2"}`))
	rec := httptest.NewRecorder()
	a.handleRun(rec, req)
	if rec.Code != http.StatusAccepted {
		t.Fatalf("status %d: %s", rec.Code, rec.Body.String())
	}

	deadline := time.Now().Add(10 * time.Second)
	var snap RunState
	for {
		snap = a.runner.Snapshot()
		if !snap.Running {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("the run did not finish")
		}
		time.Sleep(10 * time.Millisecond)
	}

	if !snap.Sudo {
		t.Fatalf("the run was not marked as needing sudo: %+v", snap.Lines)
	}
	sawSudo := false
	for _, line := range snap.Lines {
		if strings.Contains(line.Text, sudoMarker) {
			t.Fatalf("marker leaked into the pane: %q", line.Text)
		}
		if line.Stream == "sudo" {
			sawSudo = true
		}
	}
	if !sawSudo {
		t.Fatal("no sudo line for the page")
	}

	gotAskpass, err := os.ReadFile(filepath.Join(root, "askpass.path"))
	if err != nil {
		t.Fatal(err)
	}
	if strings.TrimSpace(string(gotAskpass)) != helper {
		t.Fatalf("child saw SUDO_ASKPASS=%q, want %q", gotAskpass, helper)
	}

	gotPath, err := os.ReadFile(filepath.Join(root, "password.path"))
	if err != nil {
		t.Fatal(err)
	}
	passwordFile := strings.TrimSpace(string(gotPath))
	if passwordFile == "" {
		t.Fatal("child saw no RRO_SUDO_PASSWORD_FILE")
	}
	if _, err := os.Stat(passwordFile); !os.IsNotExist(err) {
		t.Fatalf("the password file outlived the run (stat: %v)", err)
	}
}
