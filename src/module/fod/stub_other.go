//go:build !android && !linux

// The helper talks to Android vendor nodes with Linux ioctls. This stub keeps
// `go build ./...` working on the Windows host the desktop app is built on;
// the real file is compiled for GOOS=android (and Linux, for testing the code
// on a desktop kernel).
package main

import (
	"fmt"
	"os"
)

func main() {
	fmt.Fprintln(os.Stderr, "xiaomi-fod is built for Android: GOOS=android GOARCH=arm64")
	os.Exit(2)
}
