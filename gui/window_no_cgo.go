//go:build !cgo || !(windows || linux)

package main

// windowReady is false in a build without CGO, which is the build that needs no
// C compiler or WebKitGTK headers. The app still works: it opens the same UI in
// the default browser.
const windowReady = false

func openUI(url, title string, debug, forceBrowser bool) error {
	return runBrowser(url)
}
