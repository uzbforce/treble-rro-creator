//go:build android || linux

// Command xiaomi-fod switches a Xiaomi touch panel into fingerprint-on-display
// mode, which is the one thing a GSI cannot do for the vendor fingerprint HAL.
//
// The stock flow is:
//
//	MIUI FingerprintService
//	  -> vendor.xiaomi.hardware.fingerprintextension.extCmd(4, 3)
//	  -> vendor.xiaomi.hardware.touchfeature.setModeValue(10, 3)
//	  -> /dev/xiaomi-touch ioctl(0x5400, {10, 3})
//
// A GSI has no MIUI fingerprint client, so the last call never happens. The
// vendor Goodix HAL then never sees fod_press_status change, never reports a
// finger, and the sensor appears dead even though the geometry is right.
//
// This helper issues the same ioctl directly. The daemon follows the state
// machine MIUI uses, as seen in the touch driver's dmesg: the panel is armed
// with value 3 (FOD plus the AOD wake bit) when the screen turns off, stays
// armed while the keyguard is up, and is released after the device is unlocked,
// when no fingerprint UI is on screen. It also exposes the local-HBM ioctl used
// by the HAL, for diagnostics.
//
// Build for a device (no CGO, static):
//
//	GOOS=android GOARCH=arm64 CGO_ENABLED=0 GO111MODULE=off \
//	    go build -trimpath -ldflags="-s -w" -o xiaomi-fod main.go
package main

import (
	"context"
	"encoding/binary"
	"fmt"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"
	"unsafe"
)

const (
	touchDevice = "/dev/xiaomi-touch"
	dispDevice  = "/dev/mi_display/disp_feature"

	// ioctl(2) requests from the vendor HALs. Both take a small struct by
	// pointer; the values are stable across Xiaomi kernels 5.x.
	ioctlTouchSetMode = 0x5400     // struct { int mode; int value; }
	ioctlLocalHBM     = 0x400c440e // struct { uint64_t reserved; uint32_t value; }

	// fodArmedValue is what MIUI writes to mode 10 when it arms the panel: bit
	// 1 is FOD, bit 2 is the AOD wake path. The driver logs it as
	// "Mode:FOD fod_status = 3".
	fodArmedValue = 3
)

// setTouchMode writes one touchfeature mode. Mode 10 is "FOD"; value 3 arms
// it (FOD + AOD), 0 releases it.

func setTouchMode(mode, value int) error {
	f, err := os.OpenFile(touchDevice, os.O_RDWR, 0)
	if err != nil {
		return err
	}
	defer f.Close()

	arg := [2]int32{int32(mode), int32(value)}
	if _, _, errno := syscall.Syscall(syscall.SYS_IOCTL, f.Fd(),
		ioctlTouchSetMode, uintptr(unsafe.Pointer(&arg[0]))); errno != 0 {
		return errno
	}
	return nil
}

// setLocalHBM drives the panel's local high-brightness mode: 2 on, 1 off,
// 0 cancel. The vendor fingerprint HAL normally does this from its FOD engine;
// it is exposed here so a user can check the ioctl without flashing anything.
func setLocalHBM(value int) error {
	f, err := os.OpenFile(dispDevice, os.O_RDWR, 0)
	if err != nil {
		return err
	}
	defer f.Close()

	var arg [12]byte
	binary.LittleEndian.PutUint64(arg[0:8], 1)
	binary.LittleEndian.PutUint32(arg[8:12], uint32(value))
	if _, _, errno := syscall.Syscall(syscall.SYS_IOCTL, f.Fd(),
		ioctlLocalHBM, uintptr(unsafe.Pointer(&arg[0]))); errno != 0 {
		return errno
	}
	return nil
}

// screenOn reads the panel backlight. A zero/absent backlight means the screen
// is off; every Android device with a display exposes one of these nodes.
func screenOn() (on bool, known bool) {
	paths := []string{
		"/sys/class/backlight/panel0-backlight/brightness",
		"/sys/class/leds/lcd-backlight/brightness",
	}
	if more, _ := filepath.Glob("/sys/class/backlight/*/brightness"); len(more) > 0 {
		paths = append(paths, more...)
	}

	for _, p := range paths {
		raw, err := os.ReadFile(p)
		if err != nil {
			continue
		}
		v, err := strconv.Atoi(strings.TrimSpace(string(raw)))
		if err != nil {
			continue
		}
		return v > 0, true
	}
	return false, false
}

// keyguardShowing asks WindowManager whether the lock screen is up. `dumpsys
// window policy` is a small dump and has carried the KeyguardStateMonitor
// "mIsShowing=" line since Android 9, with the delegate's "showing=" line as
// the fallback. Returning known=false means "cannot tell", which the caller
// treats as still locked.
func keyguardShowing() (showing bool, known bool) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, "dumpsys", "window", "policy").Output()
	if err != nil || len(out) == 0 {
		return false, false
	}
	s := string(out)

	if i := strings.Index(s, "KeyguardStateMonitor"); i >= 0 {
		if j := strings.Index(s[i:], "mIsShowing="); j >= 0 {
			rest := s[i+j+len("mIsShowing="):]
			return strings.HasPrefix(rest, "true"), true
		}
	}
	if i := strings.Index(s, "KeyguardServiceDelegate"); i >= 0 {
		for _, line := range strings.Split(s[i:], "\n") {
			line = strings.TrimSpace(line)
			if strings.HasPrefix(line, "showing=") {
				return strings.HasPrefix(line, "showing=true"), true
			}
		}
	}
	return false, false
}

// fodArmed is the state MIUI leaves the panel in: mode 10 on while the screen
// is off or the keyguard is showing, and off once the device is unlocked with
// the screen on. When a state cannot be read, stay armed rather than risk a
// dead sensor.
func fodArmed() (want int, reason string) {
	on, scrKnown := screenOn()
	locked, lockKnown := keyguardShowing()

	want = 1
	switch {
	case scrKnown && !on:
		reason = "screen off"
	case scrKnown && on && lockKnown && !locked:
		want = 0
		reason = "screen on, unlocked"
	case scrKnown && on && lockKnown && locked:
		reason = "screen on, keyguard showing"
	case !scrKnown:
		reason = "screen state unknown"
	default:
		reason = "keyguard state unknown"
	}
	return want, reason
}

// runDaemon keeps the touch panel in the mode MIUI would have it in. The vendor
// HAL only listens to the touch controller while the panel is in that mode;
// without it a finger never reaches the fingerprint core.
func runDaemon() {
	logger := log.New(os.Stderr, "xiaomi-fod: ", log.LstdFlags)
	last := -1
	lastErr := ""

	for {
		want, reason := fodArmed()
		value := 0
		if want == 1 {
			value = fodArmedValue
		}
		if value != last {
			if err := setTouchMode(10, value); err != nil {
				if msg := err.Error(); msg != lastErr {
					logger.Printf("touch mode %d: %v", value, err)
					lastErr = msg
				}
			} else {
				logger.Printf("touch mode 10 = %d (%s)", value, reason)
				last = value
				lastErr = ""
			}
		}
		time.Sleep(2 * time.Second)
	}
}

func usage() {
	fmt.Fprintln(os.Stderr, "usage: xiaomi-fod touch MODE VALUE | hbm VALUE | daemon")
	os.Exit(2)
}

func main() {
	if len(os.Args) < 2 {
		usage()
	}

	var err error
	switch os.Args[1] {
	case "touch":
		if len(os.Args) != 4 {
			usage()
		}
		mode, e1 := strconv.Atoi(os.Args[2])
		value, e2 := strconv.Atoi(os.Args[3])
		if e1 != nil || e2 != nil {
			usage()
		}
		err = setTouchMode(mode, value)
	case "hbm":
		if len(os.Args) != 3 {
			usage()
		}
		value, e := strconv.Atoi(os.Args[2])
		if e != nil {
			usage()
		}
		err = setLocalHBM(value)
	case "daemon":
		runDaemon()
		return
	default:
		usage()
	}

	if err != nil {
		fmt.Fprintln(os.Stderr, "xiaomi-fod:", err)
		os.Exit(1)
	}
}
