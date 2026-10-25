// Command gui is the desktop front-end for the overlay builder.
//
// It is a launcher, not a second implementation: every job it offers is a
// command build.sh already understands. The app finds a clone, finds bash,
// runs `bash ./build.sh <verb> <flags> -y` in the clone, and streams the
// output into a log pane. Nothing about config.env, aapt2 or signing is
// reimplemented here, so `git pull` upgrades the GUI and the build together.
//
// The UI is plain HTML served on 127.0.0.1 over a random path prefix and
// shown in a native window (Windows: WebView2, Linux: WebKitGTK). Pass
// -browser to use the default browser instead, which also works on machines
// where the webview dependency is missing.
package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"time"
)

func main() {
	var (
		clone   = flag.String("clone", "", "clone to drive (default: the clone this app lives in, then the saved setting)")
		port    = flag.Int("port", 0, "loopback port for the UI server (0 picks a free one)")
		browser = flag.Bool("browser", false, "show the UI in the default browser instead of a native window")
		debug   = flag.Bool("debug", false, "enable the webview developer tools")

		unpack   = flag.String("unpack", "", "unpack a super.img, a Samsung AP tar.md5 or a ROM folder into a readable tree, then exit")
		unpackTo = flag.String("out", "", "where -unpack writes (default: a folder under the system temp dir)")
		unpackJS = flag.Bool("json", false, "with -unpack, print the result as JSON")
	)
	flag.Parse()

	// -unpack is the Detect tab's unpacking without the window: same code, so a
	// script and the button cannot disagree about what ends up on disk.
	if *unpack != "" {
		os.Exit(unpackCLI(*unpack, *unpackTo, *unpackJS))
	}

	if !windowReady {
		fmt.Fprintln(os.Stderr, "built without CGO: opening the UI in the default browser instead of a window")
	}

	app, err := newApp(*clone)
	if err != nil {
		fatalf("%v", err)
	}

	ln, url, srv, err := app.serve(*port)
	if err != nil {
		fatalf("%v", err)
	}

	go func() {
		if err := srv.Serve(ln); err != nil && err != http.ErrServerClosed {
			log.Printf("ui server: %v", err)
		}
	}()

	// Closing the window must not leave the listener (or a build) behind.
	defer func() {
		ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		defer cancel()
		_ = srv.Shutdown(ctx)
		app.runner.Cancel()
		if app.adbRunner != nil {
			app.adbRunner.Cancel()
		}
	}()

	log.Printf("ui: %s", url)
	if err := openUI(url, appTitle, *debug, *browser); err != nil {
		fatalf("%v", err)
	}
}

// fatalf prints to stderr and exits. With -H windowsgui there is no console,
// so it also leaves a log next to the executable.
func fatalf(format string, args ...any) {
	msg := fmt.Sprintf(format, args...)
	fmt.Fprintln(os.Stderr, "error:", msg)
	if p := filepath.Join(exeDir(), "gui.log"); p != "" {
		if f, err := os.OpenFile(p, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644); err == nil {
			fmt.Fprintf(f, "%s %s\n", time.Now().Format(time.RFC3339), msg)
			f.Close()
		}
	}
	os.Exit(1)
}
