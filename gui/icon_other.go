//go:build !windows

package main

// setWindowIcon does nothing here: on Linux the window is a GtkWindow made by
// webview_go, and setting its icon would mean a C call into GTK from a file that
// is otherwise platform-neutral. The webview still shows the page's own icon in
// its tab/task entry, and the build is unaffected.
func setWindowIcon(string) {}
