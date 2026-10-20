//go:build cgo && (windows || linux)

package main

import webview "github.com/webview/webview_go"

// windowReady tells main whether a real window is available in this build.
// Without CGO (or on a platform webview_go does not support) the app falls back
// to the browser, which is the same UI on the same handlers.
const windowReady = true

// openUI shows the loopback page in a native window and blocks until it closes.
//
// The window is WebView2 on Windows and WebKitGTK on Linux, i.e. the engine the
// user's browser already has — there is no bundled renderer, which is what
// keeps the binary around ten megabytes instead of two hundred.
func openUI(url, title string, debug, forceBrowser bool) error {
	if forceBrowser {
		return runBrowser(url)
	}

	w := webview.NewWindow(debug, nil)
	defer w.Destroy()

	w.SetTitle(title)
	w.SetSize(1120, 780, webview.HintNone)
	w.Navigate(url)
	w.Run()
	return nil
}
