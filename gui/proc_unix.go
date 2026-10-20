//go:build !windows

package main

import (
	"errors"
	"os/exec"
	"syscall"
)

// setProcAttr gives the child its own process group, so killTree can signal the
// group instead of just bash.
func setProcAttr(cmd *exec.Cmd) {
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
}

func killTree(cmd *exec.Cmd) error {
	if cmd == nil || cmd.Process == nil {
		return nil
	}
	// The negative pid signals the whole group; bash's children go with it.
	if err := syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL); err != nil {
		return cmd.Process.Kill()
	}
	return nil
}

// findBash looks in the places a shell actually lives. Termux is included
// because the same binary runs there under the browser front-end.
func findBash() (string, error) {
	for _, c := range []string{
		"/bin/bash",
		"/usr/bin/bash",
		"/usr/local/bin/bash",
		"/data/data/com.termux/files/usr/bin/bash",
	} {
		if fileExists(c) {
			return c, nil
		}
	}
	if p, err := exec.LookPath("bash"); err == nil {
		return p, nil
	}
	return "", errors.New("bash was not found on PATH")
}

func adbName() string { return "adb" }

func openPath(path string) error {
	return exec.Command("xdg-open", path).Start()
}

func openURL(url string) error {
	return exec.Command("xdg-open", url).Start()
}
