//go:build !windows

package main

// The Linux file chooser.
//
// There is no dialog in a bare X session: the desktop's own helper is the only
// thing that draws one, so zenity is used when it is installed and kdialog for
// a KDE box. Termux and a headless shell have neither, and the error says so —
// the path field still takes a typed path.

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"strings"
)

func pickPath(ask pickAsk) (string, error) {
	if z, err := exec.LookPath("zenity"); err == nil {
		return runChooser(z, zenityArgs(ask)...)
	}
	if k, err := exec.LookPath("kdialog"); err == nil {
		return runChooser(k, kdialogArgs(ask)...)
	}
	return "", errors.New("no file chooser was found (install zenity or kdialog), or type the path instead")
}

func zenityArgs(ask pickAsk) []string {
	args := []string{"--file-selection", "--title=" + ask.Kind.title()}
	if ask.Kind == pickFolder {
		args = append(args, "--directory")
	} else {
		args = append(args,
			"--file-filter=Firmware images | *.img *.bin *.tar *.md5 *.lz4",
			"--file-filter=All files | *")
	}
	// The trailing separator opens the dialog at that folder instead of
	// selecting the folder itself as the answer.
	if ask.Start != "" {
		args = append(args, "--filename="+strings.TrimRight(ask.Start, string(os.PathSeparator))+string(os.PathSeparator))
	}
	return args
}

func kdialogArgs(ask pickAsk) []string {
	args := []string{"--title", ask.Kind.title()}
	if ask.Kind == pickFolder {
		args = append(args, "--getexistingdirectory", ask.Start)
		return args
	}
	filter := "Firmware images (*.img *.bin *.tar *.md5 *.lz4)|*.img *.bin *.tar *.md5 *.lz4\\nAll files|*"
	args = append(args, "--getopenfilename", ask.Start, filter)
	return args
}

// runChooser starts one desktop helper and reads the answer it prints. Both
// zenity and kdialog use exit status 1 for "the user closed the dialog", which
// is a cancellation rather than a failure.
func runChooser(bin string, args ...string) (string, error) {
	out, err := exec.Command(bin, args...).CombinedOutput()
	if err != nil {
		var exit *exec.ExitError
		if errors.As(err, &exit) && exit.ExitCode() == 1 {
			return "", nil
		}
		detail := strings.TrimSpace(string(out))
		if detail == "" {
			detail = err.Error()
		}
		return "", fmt.Errorf("the file chooser did not open: %s", detail)
	}
	return strings.TrimSpace(string(out)), nil
}
