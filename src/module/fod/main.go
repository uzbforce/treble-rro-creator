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
// armed while the keyguard is up or a fingerprint client is running (settings
// enrollment, in-app prompts), and is released otherwise. The vendor HAL's own
// FOD engine will not light the panel on a GSI (it waits for a MIUI client that
// never runs), so the daemon also drives local HBM: on while a finger is on the
// sensor. A press that arrives with the display asleep also wakes the screen,
// because the HAL aborts the auth with ui-ready timeout when no fingerprint UI
// is up to answer it. The hbm command exposes the same
// ioctl for diagnostics.
//
// The other half of the vendor FOD stack is the display node the HAL opens;
// the module's post-fs-data.sh re-creates it. See docs/udfps.md.
//
// Build for a device (no CGO, static):
//
//	GOOS=android GOARCH=arm64 CGO_ENABLED=0 GO111MODULE=off \
//	    go build -trimpath -ldflags="-s -w" -o xiaomi-fod main.go
package main

import (
	"bufio"
	"context"
	"encoding/binary"
	"fmt"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
	"unsafe"
)

const (
	touchDevice = "/dev/xiaomi-touch"

	// The vendor FOD engine opens /dev/mi_display/disp_feature. MIUI creates
	// that path; on a GSI the kernel only publishes /dev/disp_feature, and the
	// module's post-fs-data.sh re-creates the expected one (same major:minor,
	// system:system, vendor_displayfeature_device label). Both are tried here
	// so the diagnostic also works before that fix has run.
	dispDevice    = "/dev/mi_display/disp_feature"
	dispDeviceAlt = "/dev/disp_feature"

	// ioctl(2) requests from the vendor HALs. Both take a small struct by
	// pointer; the values are stable across Xiaomi kernels 5.x.
	ioctlTouchSetMode = 0x5400     // struct { int mode; int value; }
	ioctlLocalHBM     = 0x400c440e // struct { uint64_t reserved; uint32_t value; }

	// fodArmedValue is what MIUI writes to mode 10 when it arms the panel: bit
	// 1 is FOD, bit 2 is the AOD wake path. The driver logs it as
	// "Mode:FOD fod_status = 3".
	fodArmedValue = 3

	// fodPressNode flips to 1 while the touch controller reports a finger in
	// the sensor area, but only while the panel is in FOD mode.
	fodPressNode = "/sys/devices/virtual/touch/touch_dev/fod_press_status"

	// The panel state (screen, keyguard, fingerprint client) costs dumpsys
	// calls, so each part is refreshed on its own schedule. The press flag is a
	// sysfs read and is polled much faster, because HBM has to come on with the
	// finger and go off when it lifts.
	statePoll    = 2 * time.Second // ioctl retry backoff
	keyguardPoll = 2 * time.Second // dumpsys window policy, locked
	unlockedPoll = 5 * time.Second // dumpsys window policy, unlocked
	promptPoll   = 5 * time.Second // dumpsys fingerprint (fallback)
	pressPoll    = 50 * time.Millisecond
	hbmHoldOff   = 150 * time.Millisecond
	wakeGrace    = 3 * time.Second
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
	lastErr := fmt.Errorf("no display feature node (%s or %s)", dispDevice, dispDeviceAlt)
	for _, path := range []string{dispDevice, dispDeviceAlt} {
		f, err := os.OpenFile(path, os.O_RDWR, 0)
		if err != nil {
			lastErr = err
			continue
		}

		var arg [12]byte
		binary.LittleEndian.PutUint64(arg[0:8], 1)
		binary.LittleEndian.PutUint32(arg[8:12], uint32(value))
		_, _, errno := syscall.Syscall(syscall.SYS_IOCTL, f.Fd(),
			ioctlLocalHBM, uintptr(unsafe.Pointer(&arg[0])))
		f.Close()
		if errno != 0 {
			lastErr = errno
			continue
		}
		return nil
	}
	return lastErr
}

var (
	backlightOnce  sync.Once
	backlightPaths []string
)

// backlightNodes is resolved once: the glob is the only expensive part, and the
// daemon reads the screen state on every press poll.
func backlightNodes() []string {
	backlightOnce.Do(func() {
		backlightPaths = []string{
			"/sys/class/backlight/panel0-backlight/brightness",
			"/sys/class/leds/lcd-backlight/brightness",
		}
		if more, _ := filepath.Glob("/sys/class/backlight/*/brightness"); len(more) > 0 {
			backlightPaths = append(backlightPaths, more...)
		}
	})
	return backlightPaths
}

// screenOn reads the panel backlight. A zero/absent backlight means the screen
// is off; every Android device with a display exposes one of these nodes.
func screenOn() (on bool, known bool) {
	for _, p := range backlightNodes() {
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

// fingerprintBusy asks the fingerprint service whether an authentication or
// enrollment client is running. `dumpsys fingerprint` prints
// "Current operation: null" when idle and the client's name otherwise. This is
// the GSI stand-in for the MIUI fingerprint client that arms the panel: it
// covers enrollment and in-app prompts, where the screen is on and the keyguard
// is not showing, so keyguardShowing() alone would release the panel too early.
func fingerprintBusy() bool {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, "dumpsys", "fingerprint").Output()
	if err != nil || len(out) == 0 {
		return false
	}
	s := string(out)
	const key = "Current operation:"
	i := strings.Index(s, key)
	if i < 0 {
		return false
	}
	line := s[i+len(key):]
	if j := strings.IndexByte(line, '\n'); j >= 0 {
		line = line[:j]
	}
	line = strings.TrimSpace(line)
	return line != "" && line != "null"
}

// panelSignals caches the two dump-based reads that decide whether the panel
// should be armed. The keyguard dump is large, so it is refreshed every
// keyguardPoll; the fingerprint dump is small and a prompt can appear at any
// moment, so it is refreshed every promptPoll while the screen is on. Neither
// blocks the press loop.
type panelSignals struct {
	mu        sync.Mutex
	locked    bool
	lockKnown bool
	busy      bool
}

func (p *panelSignals) setKeyguard(locked, known bool) {
	p.mu.Lock()
	p.locked, p.lockKnown = locked, known
	p.mu.Unlock()
}

func (p *panelSignals) setBusy(busy bool) {
	p.mu.Lock()
	p.busy = busy
	p.mu.Unlock()
}

func (p *panelSignals) snapshot() (locked, lockKnown, busy bool) {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.locked, p.lockKnown, p.busy
}

func (p *panelSignals) watch() {
	go func() {
		for {
			// While the panel is off, panelArmed() already answers "armed"; the
			// dump would only burn CPU in doze. Forgetting the value also makes
			// the first moment after a wake count as armed until the keyguard
			// says otherwise, which is what the lock screen wants.
			if on, _ := screenOn(); !on {
				p.setKeyguard(false, false)
				time.Sleep(500 * time.Millisecond)
				continue
			}
			locked, known := keyguardShowing()
			p.setKeyguard(locked, known)
			if known && locked {
				time.Sleep(keyguardPoll)
			} else {
				time.Sleep(unlockedPoll)
			}
		}
	}()
	go func() {
		for {
			if on, _ := screenOn(); on {
				p.setBusy(fingerprintBusy())
			} else {
				p.setBusy(false)
			}
			time.Sleep(promptPoll)
		}
	}()
	go p.watchUdfpsOverlay()
}

// watchUdfpsOverlay follows SystemUI's UDFPS window logs. The overlay appearing
// is the earliest signal that a fingerprint prompt exists - opening enrollment
// or an in-app biometric prompt shows it before anything is touched - and this
// costs nothing while no line arrives. Polling dumpsys fingerprint for the same
// answer four times a second was measurably expensive on a phone that spends
// most of its time on the lock screen, so that poll is only a 5 s fallback.
func (p *panelSignals) watchUdfpsOverlay() {
	for {
		// -T 1 starts at the last buffered line instead of replaying the whole
		// buffer, which would otherwise flip the flag from stale lines.
		cmd := exec.Command("logcat", "-b", "main", "-T", "1", "-s",
			"UdfpsController:V", "UdfpsControllerOverlay:V")
		// Take the reader down with the daemon; a restarted daemon must not
		// leave the previous logcat running.
		cmd.SysProcAttr = &syscall.SysProcAttr{Pdeathsig: syscall.SIGKILL}
		out, err := cmd.StdoutPipe()
		if err != nil {
			time.Sleep(5 * time.Second)
			continue
		}
		if err := cmd.Start(); err != nil {
			time.Sleep(5 * time.Second)
			continue
		}

		sc := bufio.NewScanner(out)
		for sc.Scan() {
			line := sc.Text()
			switch {
			case strings.Contains(line, "showUdfpsOverlay"):
				p.setBusy(true)
			case strings.Contains(line, "hideUdfpsControllerOverlay"),
				strings.Contains(line, "hideUdfpsOverlay"):
				p.setBusy(false)
			}
		}
		cmd.Wait()
		time.Sleep(2 * time.Second)
	}
}

// panelArmed mirrors the state MIUI leaves the panel in: armed while the screen
// is off, the keyguard is showing, or a fingerprint client is running
// (enrollment and in-app biometric prompts), released once none of those is
// true. When a state cannot be read, stay armed rather than risk a dead sensor.
func panelArmed(on, scrKnown bool, locked, lockKnown, busy bool) (bool, string) {
	switch {
	case scrKnown && !on:
		return true, "screen off"
	case !scrKnown:
		return true, "screen state unknown"
	case lockKnown && locked:
		return true, "screen on, keyguard showing"
	case lockKnown && !locked && busy:
		return true, "fingerprint prompt active"
	case lockKnown && !locked:
		return false, "screen on, unlocked, no fingerprint prompt"
	case busy:
		return true, "fingerprint prompt active"
	default:
		return true, "keyguard state unknown"
	}
}

// fodPressed reports whether the touch controller currently sees a finger in
// the sensor area. The node only changes while the panel is in FOD mode, which
// is exactly when HBM is wanted.
func fodPressed() bool {
	raw, err := os.ReadFile(fodPressNode)
	if err != nil {
		return false
	}
	return strings.TrimSpace(string(raw)) == "1"
}

// runDaemon keeps the touch panel in the mode MIUI would have it in. The vendor
// HAL only listens to the touch controller while the panel is in that mode;
// without it a finger never reaches the fingerprint core.
//
// HBM follows the press flag instead of the UI: MIUI's HAL lights the sensor
// area when the finger lands and turns it off when it lifts, so the bright spot
// is not permanently on while the lock screen is up. A short hold-off keeps it
// lit long enough for the HAL to finish the capture.
func runDaemon() {
	logger := log.New(os.Stderr, "xiaomi-fod: ", log.LstdFlags|log.Lmicroseconds)
	lastTouch, lastHBM := -1, -1
	lastTouchErr, lastHBMErr := "", ""

	sig := &panelSignals{}
	sig.watch()

	nextTouch := time.Time{}
	nextHBM := time.Time{}
	var holdUntil time.Time

	// Waking from screen-off almost always lands on the keyguard, but the
	// cached keyguard state still describes the unlocked screen from before.
	// Treat the first seconds after a wake as armed so the first touch lights
	// the sensor instead of waiting for the next keyguard dump.
	var wakeArmed time.Time
	screenWasOn := false
	busyWas := false
	lastPress := false

	for {
		now := time.Now()
		on, scrKnown := screenOn()
		if on && !screenWasOn {
			wakeArmed = now.Add(wakeGrace)
		}
		screenWasOn = on

		locked, lockKnown, busy := sig.snapshot()
		arm, why := panelArmed(on, scrKnown, locked, lockKnown, busy)
		if !arm && now.Before(wakeArmed) {
			arm, why = true, "screen just turned on"
		}

		touch := 0
		if arm {
			touch = fodArmedValue
		}
		if touch != lastTouch && now.After(nextTouch) {
			if err := setTouchMode(10, touch); err != nil {
				nextTouch = now.Add(statePoll)
				if msg := err.Error(); msg != lastTouchErr {
					logger.Printf("touch mode %d: %v", touch, err)
					lastTouchErr = msg
				}
			} else {
				logger.Printf("touch mode 10 = %d (%s)", touch, why)
				lastTouch = touch
				lastTouchErr = ""
			}
		}

		hbm := 1
		pressed := false
		if arm {
			pressed = fodPressed()
			if pressed {
				holdUntil = now.Add(hbmHoldOff)
			} else if busyWas && !busy {
				// A prompt that was up is gone and the finger is off: the
				// capture is over, so drop the rest of the hold instead of
				// leaving the sensor lit for another frame's worth.
				holdUntil = time.Time{}
			}
			if now.Before(holdUntil) {
				hbm = 2
			}
		} else {
			holdUntil = time.Time{}
		}
		if hbm != lastHBM && now.After(nextHBM) {
			if err := setLocalHBM(hbm); err != nil {
				nextHBM = now.Add(statePoll)
				if msg := err.Error(); msg != lastHBMErr {
					logger.Printf("local hbm %d: %v", hbm, err)
					lastHBMErr = msg
				}
			} else {
				if hbm == 2 {
					logger.Printf("local hbm = 2 (finger down, %s)", why)
				} else {
					logger.Printf("local hbm = 1 (%s)", why)
				}
				lastHBM = hbm
				lastHBMErr = ""
			}
		}

		// A press with the display asleep never reaches SystemUI: the vendor HAL
		// starts an auth, asks for the fingerprint UI and gives up after 1.5 s
		// when nothing answers (GF_ERROR_UI_READY_TIMEOUT). Waking the display
		// brings the keyguard's prompt up inside that window, which is what MIUI
		// does. The wake runs in the background so the press loop keeps its
		// cadence and HBM is already lit when the panel comes up.
		if pressed && !on && !lastPress {
			go wakeDisplay(logger)
		}
		lastPress = pressed

		busyWas = busy
		time.Sleep(pressPoll)
	}
}

// wakeDisplay turns the screen on for a press that arrived while it was off.
// `input keyevent 224` (KEYCODE_WAKEUP) is the only wake path a native binary
// has; it starts app_process (~160 ms) and the backlight is up about 300 ms
// after that, which still fits the HAL's 1500 ms wait for the fingerprint UI.
func wakeDisplay(logger *log.Logger) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if out, err := exec.CommandContext(ctx, "input", "keyevent", "224").CombinedOutput(); err != nil {
		logger.Printf("wake: %v (%s)", err, strings.TrimSpace(string(out)))
		return
	}
	logger.Printf("wake: display on (finger down while off)")
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
