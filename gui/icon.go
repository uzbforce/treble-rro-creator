package main

import _ "embed"

// windowIcon is the mark in the window's title bar and on its taskbar button.
// An .ico holds several sizes, so the window manager picks the one it needs: 16
// px for the title bar, 32 px for the taskbar at 100%, 256 px on a large one.
//
//go:embed icon.ico
var windowIcon []byte
