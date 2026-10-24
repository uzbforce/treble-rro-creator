//go:build windows

package main

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
)

// setProcAttr keeps the console from flashing for every child (git, adb, bash)
// and puts the process in its own group so a cancel can take the whole tree.
func setProcAttr(cmd *exec.Cmd) {
	if cmd.SysProcAttr == nil {
		cmd.SysProcAttr = &syscall.SysProcAttr{}
	}
	cmd.SysProcAttr.HideWindow = true
	cmd.SysProcAttr.CreationFlags |= 0x00000200 // CREATE_NEW_PROCESS_GROUP
}

// killTree kills bash *and* what it started. Without /T a cancel leaves aapt2
// running with its output pointed at a file nothing will ever close.
func killTree(cmd *exec.Cmd) error {
	if cmd == nil || cmd.Process == nil {
		return nil
	}
	kill := exec.Command("taskkill", "/F", "/T", "/PID", strconv.Itoa(cmd.Process.Pid))
	kill.SysProcAttr = &syscall.SysProcAttr{HideWindow: true}
	out, err := kill.CombinedOutput()
	if err == nil {
		return nil
	}
	// taskkill fails for a process that already exited, which is not an error
	// worth reporting. Fall back to terminating bash itself and only surface a
	// message when that fails too.
	if kerr := cmd.Process.Kill(); kerr != nil {
		return fmt.Errorf("could not stop the build: %s: %w", strings.TrimSpace(string(out)), kerr)
	}
	return nil
}

// findBash mirrors stuff/windows/run-bash.cmd: the two standard Git for Windows
// locations first, then anything called bash.exe on PATH — accepted only if it
// reports an MSYS/Cygwin environment, because WSL's bash cannot see the native
// Windows build tools.
func findBash() (string, error) {
	var candidates []string
	if pf := os.Getenv("ProgramFiles"); pf != "" {
		candidates = append(candidates, filepath.Join(pf, "Git", "bin", "bash.exe"))
	}
	if la := os.Getenv("LocalAppData"); la != "" {
		candidates = append(candidates, filepath.Join(la, "Programs", "Git", "bin", "bash.exe"))
	}
	if p, err := exec.LookPath("bash.exe"); err == nil {
		candidates = append(candidates, p)
	}
	for _, c := range candidates {
		if isMSYSBash(c) {
			return c, nil
		}
	}
	return "", errors.New("Git for Windows was not found (https://git-scm.com/download/win)")
}

func isMSYSBash(path string) bool {
	if !fileExists(path) {
		return false
	}
	probe := exec.Command(path, "--noprofile", "--norc", "-c", "uname -s")
	probe.SysProcAttr = &syscall.SysProcAttr{HideWindow: true}
	out, err := probe.Output()
	if err != nil {
		return false
	}
	uname := strings.ToUpper(string(out))
	return strings.Contains(uname, "MINGW") ||
		strings.Contains(uname, "MSYS") ||
		strings.Contains(uname, "CYGWIN")
}

func adbName() string { return "adb.exe" }

// openPath reveals a file or folder in Explorer. A file is selected rather than
// opened, so a click on config.env cannot launch it in Notepad and lock it.
func openPath(path string) error {
	st, err := os.Stat(path)
	if err != nil {
		return err
	}
	if st.IsDir() {
		return exec.Command("explorer.exe", path).Start()
	}
	return exec.Command("explorer.exe", "/select,"+path).Start()
}

func openURL(url string) error {
	return exec.Command("rundll32.exe", "url.dll,FileProtocolHandler", url).Start()
}
