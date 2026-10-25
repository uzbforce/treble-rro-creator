//go:build !windows

package main

import (
	"strings"
	"testing"
)

func hasArg(args []string, want string) bool {
	for _, a := range args {
		if a == want {
			return true
		}
	}
	return false
}

func TestZenityArgs(t *testing.T) {
	file := zenityArgs(pickAsk{Kind: pickFile, Start: "/roms"})
	for _, want := range []string{
		"--file-selection",
		"--filename=/roms/", // a trailing separator opens the dialog there
		"--file-filter=Firmware images | *.img *.bin *.tar *.md5 *.lz4",
		"--file-filter=All files | *",
	} {
		if !hasArg(file, want) {
			t.Fatalf("a file dialog needs %q, got %v", want, file)
		}
	}
	if hasArg(file, "--directory") {
		t.Fatalf("a file dialog must not be a folder dialog: %v", file)
	}

	folder := zenityArgs(pickAsk{Kind: pickFolder})
	if !hasArg(folder, "--directory") {
		t.Fatalf("a folder dialog needs --directory, got %v", folder)
	}
	for _, a := range folder {
		if strings.HasPrefix(a, "--file-filter=") || strings.HasPrefix(a, "--filename=") {
			t.Fatalf("the folder dialog got a filter or a start it was not given: %v", folder)
		}
	}
}

func TestKdialogArgs(t *testing.T) {
	file := kdialogArgs(pickAsk{Kind: pickFile, Start: "/roms"})
	if !hasArg(file, "--getopenfilename") {
		t.Fatalf("a file dialog needs --getopenfilename, got %v", file)
	}
	if !hasArg(file, "/roms") {
		t.Fatalf("the start folder was dropped: %v", file)
	}
	folder := kdialogArgs(pickAsk{Kind: pickFolder, Start: "/roms"})
	if !hasArg(folder, "--getexistingdirectory") || !hasArg(folder, "/roms") {
		t.Fatalf("a folder dialog needs --getexistingdirectory and the start, got %v", folder)
	}
}
