package main

import (
	"fmt"
	"os"
	"os/signal"
	"syscall"
)

// runBrowser shows the UI in the default browser and blocks until the process
// is interrupted.
//
// It backs two cases: -browser, and a build without CGO (no C compiler or
// WebKitGTK at build time). Closing the tab does not stop the process — the
// server has no way to see the tab go away — so the terminal says how to quit.
func runBrowser(url string) error {
	if err := openURL(url); err != nil {
		fmt.Println("could not open a browser:", err)
	}
	fmt.Println("UI:", url)
	fmt.Println("Press Ctrl+C to quit.")

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, os.Interrupt, syscall.SIGTERM)
	<-stop
	return nil
}
