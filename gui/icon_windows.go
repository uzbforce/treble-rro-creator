//go:build windows

package main

import (
	"os"
	"syscall"
	"time"
	"unsafe"
)

var (
	user32           = syscall.NewLazyDLL("user32.dll")
	procFindWindowW  = user32.NewProc("FindWindowW")
	procSendMessageW = user32.NewProc("SendMessageW")
	procLoadImageW   = user32.NewProc("LoadImageW")
	procGetMetric    = user32.NewProc("GetSystemMetrics")
)

const (
	wmSetIcon      = 0x0080
	iconSmall      = 0
	iconBig        = 1
	imageIcon      = 1
	lrLoadFromFile = 0x00000010

	smCXIcon   = 11
	smCYIcon   = 12
	smCXSmIcon = 49
	smCYSmIcon = 50
)

// setWindowIcon gives the native window (and so the taskbar button) the app's
// mark.
//
// WebView2 owns the window and webview_go exposes no icon call, so this finds
// the window by the title main set and sends WM_SETICON with both the small and
// the large icon. The handle comes from the embedded .ico written to a temporary
// file — LoadImage reads a file — and the file is removed as soon as the handle
// exists; the handle itself stays valid.
//
// It runs on its own goroutine before the message loop starts, so the look-up
// polls briefly instead of assuming the window is titled already.
func setWindowIcon(title string) {
	path, err := writeTempIcon()
	if err != nil {
		return
	}
	defer os.Remove(path)

	small := loadIcon(path, metric(smCXSmIcon), metric(smCYSmIcon))
	big := loadIcon(path, metric(smCXIcon), metric(smCYIcon))
	if small == 0 && big == 0 {
		return
	}

	want, err := syscall.UTF16PtrFromString(title)
	if err != nil {
		return
	}
	for i := 0; i < 100; i++ {
		hwnd, _, _ := procFindWindowW.Call(0, uintptr(unsafe.Pointer(want)))
		if hwnd != 0 {
			if small != 0 {
				procSendMessageW.Call(hwnd, wmSetIcon, iconSmall, small)
			}
			if big != 0 {
				procSendMessageW.Call(hwnd, wmSetIcon, iconBig, big)
			}
			return
		}
		time.Sleep(100 * time.Millisecond)
	}
}

func metric(index int) int {
	v, _, _ := procGetMetric.Call(uintptr(index))
	return int(v)
}

func writeTempIcon() (string, error) {
	f, err := os.CreateTemp("", "treble-rro-creator-*.ico")
	if err != nil {
		return "", err
	}
	defer f.Close()
	if _, err := f.Write(windowIcon); err != nil {
		os.Remove(f.Name())
		return "", err
	}
	return f.Name(), nil
}

// loadIcon asks for an exact size, which is what makes Windows pick the right
// image out of the .ico instead of the first one in it.
func loadIcon(path string, cx, cy int) uintptr {
	p, err := syscall.UTF16PtrFromString(path)
	if err != nil {
		return 0
	}
	h, _, _ := procLoadImageW.Call(
		0,
		uintptr(unsafe.Pointer(p)),
		imageIcon,
		uintptr(cx),
		uintptr(cy),
		lrLoadFromFile,
	)
	return h
}
