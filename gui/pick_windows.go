//go:build windows

package main

// The Windows file chooser.
//
// It is PowerShell plus WinForms rather than a COM binding in Go: IFileOpenDialog
// is a hundred lines of vtable work that needs an STA thread and a window owner,
// and it is the same dialog PowerShell opens here. The cost is a process start
// (a few hundred milliseconds) on a click that ends in a modal window anyway.
//
// The answer travels through a temp file, not stdout: a path can hold any
// Unicode character, and a redirected PowerShell console would re-encode it
// through an OEM code page. Nothing is written when the user cancels, so the
// file existing is the answer.

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
)

// pickScript is the dialog. The inputs arrive as environment variables, so a
// title or a folder name with quotes in it cannot break the script.
const pickScript = `
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
[System.Windows.Forms.Application]::EnableVisualStyles()
if ($env:RRO_PICK_KIND -eq 'folder') {
    $d = New-Object System.Windows.Forms.FolderBrowserDialog
    $d.Description = $env:RRO_PICK_TITLE
    $d.ShowNewFolderButton = $true
    if ($env:RRO_PICK_START) {
        try { $d.SelectedPath = $env:RRO_PICK_START } catch { }
    }
    $ok = $d.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK
    $value = $d.SelectedPath
} else {
    $d = New-Object System.Windows.Forms.OpenFileDialog
    $d.Title = $env:RRO_PICK_TITLE
    $d.Filter = 'Firmware images (*.img;*.bin;*.tar;*.md5;*.lz4)|*.img;*.bin;*.tar;*.md5;*.lz4|All files (*.*)|*.*'
    $d.CheckFileExists = $true
    $d.CheckPathExists = $true
    $d.Multiselect = $false
    if ($env:RRO_PICK_START) {
        try { $d.InitialDirectory = $env:RRO_PICK_START } catch { }
    }
    $ok = $d.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK
    $value = $d.FileName
}
if ($ok -and $value) {
    [System.IO.File]::WriteAllText($env:RRO_PICK_OUT, $value, (New-Object System.Text.UTF8Encoding($false)))
}
`

func pickPath(ask pickAsk) (string, error) {
	ps, err := powershellPath()
	if err != nil {
		return "", err
	}

	// A file the script has not written yet: CreateTemp gets a unique name, and
	// removing it makes "exists" mean "the user chose something".
	f, err := os.CreateTemp("", "treble-rro-pick-*.txt")
	if err != nil {
		return "", err
	}
	out := f.Name()
	f.Close()
	if err := os.Remove(out); err != nil {
		return "", err
	}
	defer os.Remove(out)

	cmd := exec.Command(ps, "-NoProfile", "-NonInteractive", "-STA",
		"-ExecutionPolicy", "Bypass", "-Command", pickScript)
	cmd.Env = append(os.Environ(),
		"RRO_PICK_KIND="+string(ask.Kind),
		"RRO_PICK_TITLE="+ask.Kind.title(),
		"RRO_PICK_START="+ask.Start,
		"RRO_PICK_OUT="+out,
	)
	// The dialog is its own window; the PowerShell console behind it must not
	// flash on screen.
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true}
	if msg, err := cmd.CombinedOutput(); err != nil {
		detail := strings.TrimSpace(string(msg))
		if detail == "" {
			detail = err.Error()
		}
		return "", fmt.Errorf("the file chooser did not open: %s", detail)
	}

	raw, err := os.ReadFile(out)
	if errors.Is(err, os.ErrNotExist) {
		return "", nil // closed the dialog
	}
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(strings.TrimPrefix(string(raw), "\ufeff")), nil
}

// powershellPath finds Windows PowerShell, and then PowerShell 7 for a machine
// where the built-in one was removed.
func powershellPath() (string, error) {
	if p, err := exec.LookPath("powershell.exe"); err == nil {
		return p, nil
	}
	if p, err := exec.LookPath("pwsh.exe"); err == nil {
		return p, nil
	}
	if root := os.Getenv("SystemRoot"); root != "" {
		p := filepath.Join(root, "System32", "WindowsPowerShell", "v1.0", "powershell.exe")
		if fileExists(p) {
			return p, nil
		}
	}
	return "", errors.New("Windows PowerShell was not found, so the file chooser cannot open — type the path instead")
}
