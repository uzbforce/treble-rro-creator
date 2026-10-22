package main

import (
	"archive/zip"
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"time"
)

// ---------------------------------------------------------------------------
// adb, without asking the user to install the Android SDK
// ---------------------------------------------------------------------------
// The Device tab is the one part of the app that talks to the phone, and the
// docs it backs (docs/device-extraction.md) are full of `adb pull` one-liners.
// Requiring platform-tools to be installed and on PATH put a setup step in
// front of the first useful thing the app does, so:
//
//   - an adb that is on PATH is used as-is, so an existing install wins;
//   - otherwise "Download platform-tools" fetches Google's official zip once
//     and unpacks it into stuff/tools/platform-tools (gitignored, next to the other
//     downloaded tools). Unzipping is Go's own archive/zip, so nothing else has
//     to be installed to make that work.
//
// The download is a button, not a background surprise: it is ~15 MB and the
// user should see the size and the progress in the log pane.
const platformToolsBase = "https://dl.google.com/android/repository/platform-tools-latest-"

type AdbInfo struct {
	Path        string `json:"path"`
	Source      string `json:"source"` // "path", "tools" or "" when missing
	Version     string `json:"version"`
	Available   bool   `json:"available"`
	Installable bool   `json:"installable"`
	URL         string `json:"url"`
	Error       string `json:"error"`
}

// AdbPreset is one read-only question worth asking a phone, with the reason it
// is worth asking. They are the commands the guides spell out, so the user does
// not have to retype (or mistype) `ro.product.vendor.device` to find out
// whether their vendor partition knows the real codename.
type AdbPreset struct {
	ID     string   `json:"id"`
	Group  string   `json:"group"`
	Label  string   `json:"label"`
	Why    string   `json:"why"`
	Args   []string `json:"args"`
	Needs  []string `json:"needs"` // "codename" / "manufacturer", for the UI
	Advice string   `json:"advice"`
}

var adbPresets = []AdbPreset{
	// ---- identity -------------------------------------------------------
	{
		ID: "devices", Group: "identity", Label: "adb devices -l",
		Why:  "Which phones adb can see, and whether each one is authorized.",
		Args: []string{"devices", "-l"},
	},
	{
		ID: "manufacturer", Group: "identity", Label: "ro.product.manufacturer",
		Why:  "DEVICE_MANUFACTURER (lower case in config.env).",
		Args: []string{"shell", "getprop", "ro.product.manufacturer"},
	},
	{
		ID: "model", Group: "identity", Label: "ro.product.model",
		Why:  "DEVICE_MODEL — the marketing model number, e.g. SM-A908N.",
		Args: []string{"shell", "getprop", "ro.product.model"},
	},
	{
		ID: "codename-system", Group: "identity", Label: "ro.product.device",
		Why:    "The codename this ROM thinks it is running on. On a GSI that is usually the GSI's own name, not your phone's.",
		Args:   []string{"shell", "getprop", "ro.product.device"},
		Advice: "If this is something like mivendor or phh_treble, try the vendor and bootimage entries below.",
	},
	{
		ID: "codename-vendor", Group: "identity", Label: "ro.product.vendor.device",
		Why:    "The codename read from the vendor partition — the best answer when the vendor image is still the stock one.",
		Args:   []string{"shell", "getprop", "ro.product.vendor.device"},
		Advice: "This is the value DEVICE_CODENAME should have.",
	},
	{
		ID: "codename-boot", Group: "identity", Label: "ro.product.bootimage.device",
		Why:  "The boot image's idea of the codename — another survivor on some GSIs.",
		Args: []string{"shell", "getprop", "ro.product.bootimage.device"},
	},
	{
		ID: "codename-hardware", Group: "identity", Label: "ro.boot.hardware",
		Why:  "The SoC/board name the bootloader passes to Android (e.g. qcom).",
		Args: []string{"shell", "getprop", "ro.boot.hardware"},
	},
	{
		ID: "fingerprint", Group: "identity", Label: "ro.vendor.build.fingerprint",
		Why:  "The stock build fingerprint. It names the device, the region and the build, and the UDFPS HAL is matched on it.",
		Args: []string{"shell", "getprop", "ro.vendor.build.fingerprint"},
	},
	{
		ID: "android", Group: "identity", Label: "Android version and SDK",
		Why:  "Shows the GSI's Android release, the API level, and whether Treble is on.",
		Args: []string{"shell", "getprop", "ro.build.version.release", "ro.build.version.sdk", "ro.treble.enabled"},
	},

	// ---- finding the match property -------------------------------------
	{
		ID: "grep-codename", Group: "match", Label: "properties whose value is your codename",
		Why:    "Every property a zygote overlay can be matched on that already carries your device name. Pick one from the list for DEVICE_PROP_NAME.",
		Args:   []string{"shell", "getprop", "|", "grep", "-i", "{codename}"},
		Needs:  []string{"codename"},
		Advice: "Prefer persist.* or ro.product.* over ro.vendor.*: on many GSIs zygote cannot read the vendor namespace, and the overlay silently does nothing.",
	},
	{
		ID: "grep-device", Group: "match", Label: "properties that look like a device name",
		Why:  "A wider net for the same question, when the codename does not appear anywhere.",
		Args: []string{"shell", "getprop", "|", "grep", "-iE", "device|codename|hardware"},
	},
	{
		ID: "overlay-list", Group: "match", Label: "overlays and their state",
		Why:  "Is the module's overlay built, and does it show [x]? An [x] alone does not prove it applied — check a value below.",
		Args: []string{"shell", "cmd", "overlay", "list", "--user", "0"},
	},
	{
		ID: "overlay-lookup", Group: "match", Label: "what the framework actually resolved",
		Why:    "The real test: the value the framework reports for a resource the overlay sets. Compare it with config.env.",
		Args:   []string{"shell", "cmd", "overlay", "lookup", "treble-overlay-{manufacturer}-{codename}", "android:dimen/status_bar_height_default"},
		Needs:  []string{"codename", "manufacturer"},
		Advice: "Run it with the overlay enabled and disabled to see the difference. \"could not be found\" means nothing is applied.",
	},
	{
		ID: "match-treble", Group: "match", Label: "treble overlay packages",
		Why:  "Only the overlays this project installs, without the framework's own list.",
		Args: []string{"shell", "pm", "list", "packages", "|", "grep", "-i", "treble-overlay"},
	},

	// ---- display --------------------------------------------------------
	{
		ID: "wm-size", Group: "display", Label: "screen size",
		Why:  "The resolution the framework believes it has; a scaling change here moves every corner and status bar value.",
		Args: []string{"shell", "wm", "size"},
	},
	{
		ID: "wm-density", Group: "display", Label: "density",
		Why:  "dp ↔ px depends on this. STATUS_BAR_HEIGHT is px, most padding values are dp.",
		Args: []string{"shell", "wm", "density"},
	},
	{
		ID: "cutout", Group: "display", Label: "display cutout",
		Why:  "The notch/cutout the display reports — the source for DISPLAY_CUTOUT and the reference an overlay's status bar height must beat.",
		Args: []string{"shell", "dumpsys", "display", "|", "grep", "-i", "-A", "3", "cutout"},
	},
	{
		ID: "corners", Group: "display", Label: "rounded corner radius",
		Why:  "The corner radius the framework is using, so ROUNDED_CORNER_RADIUS can match it instead of being guessed.",
		Args: []string{"shell", "dumpsys", "window", "|", "grep", "-iE", "rounded corner|corner radius"},
	},

	// ---- fingerprint hardware -------------------------------------------
	{
		ID: "udfps-props", Group: "fingerprint", Label: "fingerprint properties",
		Why:  "Which fingerprint HAL the phone talks to. In-display sensors show up as goodix, fpc or udfps here.",
		Args: []string{"shell", "getprop", "|", "grep", "-iE", "fod|udfps|fingerprint|goodix|fpc"},
	},
	{
		ID: "udfps-input", Group: "fingerprint", Label: "in-display sensor geometry",
		Why:  "The sensor's reported size and position, which is what UDFPS_X / UDFPS_Y / UDFPS_RADIUS have to agree with.",
		Args: []string{"shell", "dumpsys", "input", "|", "grep", "-i", "-A", "6", "-E", "goodix|fpc|udfps"},
	},
	{
		ID: "framework-res", Group: "fingerprint", Label: "the jar the overlay compiles against",
		Why:  "Confirms /system/framework/framework-res.apk exists and how big it is — the source of the resource table a build needs.",
		Args: []string{"shell", "ls", "-l", "/system/framework/framework-res.apk"},
	},
}

// ---------------------------------------------------------------------------
// Locating adb
// ---------------------------------------------------------------------------
// A PATH install is preferred over the copy in stuff/tools/: a user who keeps theirs
// updated should not be silently downgraded to whatever was downloaded once.
func (a *App) adbPath() string {
	if p, err := exec.LookPath(adbName()); err == nil {
		return p
	}
	if p := a.localAdb(); fileExists(p) {
		return p
	}
	return ""
}

func (a *App) toolsDir() string {
	if root := a.Root(); dirExists(root) {
		return filepath.Join(root, "stuff", "tools")
	}
	// No clone yet: platform-tools is not device-specific, so the per-user
	// cache is a better home than the folder next to the executable.
	if cache, err := os.UserCacheDir(); err == nil {
		return filepath.Join(cache, "TrebleRROCreator", "tools")
	}
	return filepath.Join(exeDir(), "tools")
}

func (a *App) localAdb() string {
	return filepath.Join(a.toolsDir(), "platform-tools", adbName())
}

// adbVersionCache keeps the status line from spawning a process on every poll:
// /api/state is fetched every 20 seconds.
var adbVersionCache struct {
	mu    sync.Mutex
	path  string
	value string
	at    time.Time
}

func (a *App) AdbInfo() AdbInfo {
	info := AdbInfo{}
	if url, err := platformToolsURL(); err == nil {
		info.Installable = true
		info.URL = url
	}

	info.Path = a.adbPath()
	switch {
	case info.Path == "":
		info.Error = "adb was not found on PATH and stuff/tools/platform-tools is empty"
		return info
	case strings.HasPrefix(filepath.Clean(info.Path), filepath.Clean(a.toolsDir())):
		info.Source = "tools"
	default:
		info.Source = "path"
	}
	info.Available = true
	info.Version = adbVersion(info.Path)
	return info
}

func adbVersion(adb string) string {
	adbVersionCache.mu.Lock()
	if adbVersionCache.path == adb && time.Since(adbVersionCache.at) < 2*time.Minute {
		v := adbVersionCache.value
		adbVersionCache.mu.Unlock()
		return v
	}
	adbVersionCache.mu.Unlock()

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, adb, "version")
	setProcAttr(cmd)
	out, err := cmd.Output()
	version := ""
	if err == nil {
		// First line is "Android Debug Bridge version 1.0.41".
		version = firstLine(string(out))
		version = strings.TrimSpace(strings.TrimPrefix(version, "Android Debug Bridge version"))
	}

	adbVersionCache.mu.Lock()
	adbVersionCache.path = adb
	adbVersionCache.value = version
	adbVersionCache.at = time.Now()
	adbVersionCache.mu.Unlock()
	return version
}

func platformToolsURL() (string, error) {
	switch runtime.GOOS {
	case "windows":
		return platformToolsBase + "windows.zip", nil
	case "linux":
		return platformToolsBase + "linux.zip", nil
	case "darwin":
		return platformToolsBase + "darwin.zip", nil
	}
	return "", fmt.Errorf("Google does not publish platform-tools for %s", runtime.GOOS)
}

// ---------------------------------------------------------------------------
// Installing platform-tools
// ---------------------------------------------------------------------------
// installPlatformTools downloads and unpacks into stuff/tools/platform-tools. It is
// called from a goroutine so the progress lands in the log pane through the
// runner's in-process job, and it reports lines rather than percentages it
// cannot know (the CDN does not always send a length).
func (a *App) installPlatformTools(report func(string)) error {
	url, err := platformToolsURL()
	if err != nil {
		return err
	}
	dir := a.toolsDir()
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return fmt.Errorf("could not create %s: %w", dir, err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Minute)
	defer cancel()

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return err
	}
	req.Header.Set("User-Agent", "treble-rro-creator")

	report("GET " + url)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return fmt.Errorf("download failed: %w (check the connection, or install platform-tools yourself and put adb on PATH)", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("download failed: %s answered %s", url, resp.Status)
	}

	tmp, err := os.CreateTemp(dir, "platform-tools-*.zip")
	if err != nil {
		return err
	}
	tmpName := tmp.Name()
	defer os.Remove(tmpName)

	total := resp.ContentLength
	if total > 0 {
		report(fmt.Sprintf("downloading %s (%.1f MB)", filepath.Base(tmpName), float64(total)/(1<<20)))
	} else {
		report("downloading " + filepath.Base(tmpName))
	}

	written, err := copyWithProgress(tmp, resp.Body, total, report)
	tmp.Close()
	if err != nil {
		return fmt.Errorf("download failed after %s: %w", humanBytes(written), err)
	}
	report(fmt.Sprintf("downloaded %s", humanBytes(written)))

	report("unpacking into " + filepath.Join(dir, "platform-tools"))
	if err := unzipPlatformTools(tmpName, dir); err != nil {
		return err
	}

	adb := a.localAdb()
	if !fileExists(adb) {
		return errors.New("the archive did not contain platform-tools/" + adbName() + " — the download may be a proxy error page")
	}
	if runtime.GOOS != "windows" {
		_ = os.Chmod(adb, 0o755)
	}
	if v := adbVersion(adb); v != "" {
		report("adb " + v + " ready at " + adb)
	} else {
		report("unpacked, but `adb version` did not answer — try running it by hand: " + adb)
	}
	return nil
}

func copyWithProgress(dst io.Writer, src io.Reader, total int64, report func(string)) (int64, error) {
	buf := make([]byte, 128*1024)
	var written int64
	last := time.Now()
	nextStep := int64(0)
	for {
		n, err := src.Read(buf)
		if n > 0 {
			if _, werr := dst.Write(buf[:n]); werr != nil {
				return written, werr
			}
			written += int64(n)
			if time.Since(last) > 400*time.Millisecond {
				last = time.Now()
				if total > 0 {
					pct := written * 100 / total
					if pct >= nextStep {
						nextStep = pct + 10
						report(fmt.Sprintf("  %3d%%  %s / %s", pct, humanBytes(written), humanBytes(total)))
					}
				} else {
					report("  " + humanBytes(written))
				}
			}
		}
		if err == io.EOF {
			return written, nil
		}
		if err != nil {
			return written, err
		}
	}
}

// unzipPlatformTools extracts only platform-tools/ and only regular files, so a
// crafted archive cannot write outside the folder it was downloaded into.
func unzipPlatformTools(archive, dest string) error {
	zr, err := zip.OpenReader(archive)
	if err != nil {
		return fmt.Errorf("the download is not a zip file: %w", err)
	}
	defer zr.Close()

	const prefix = "platform-tools/"
	extracted := 0
	for _, f := range zr.File {
		if !strings.HasPrefix(f.Name, prefix) {
			continue
		}
		rel := path.Clean(strings.TrimPrefix(f.Name, prefix))
		if rel == "." || rel == "" {
			continue
		}
		if strings.HasPrefix(rel, "..") || path.IsAbs(rel) || strings.Contains(rel, ":") {
			return fmt.Errorf("refusing an unsafe path in the archive: %s", f.Name)
		}
		target := filepath.Join(dest, "platform-tools", filepath.FromSlash(rel))

		if f.FileInfo().IsDir() {
			if err := os.MkdirAll(target, 0o755); err != nil {
				return err
			}
			continue
		}
		if !f.Mode().IsRegular() {
			continue // no symlinks or devices from an archive
		}
		if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
			return err
		}

		rc, err := f.Open()
		if err != nil {
			return err
		}
		out, err := os.Create(target)
		if err != nil {
			rc.Close()
			return err
		}
		// platform-tools ships executables; 0755 keeps them runnable on Linux
		// and macOS, and means nothing on Windows.
		_, copyErr := io.Copy(out, rc)
		rc.Close()
		closeErr := out.Close()
		if copyErr != nil {
			return copyErr
		}
		if closeErr != nil {
			return closeErr
		}
		if err := os.Chmod(target, 0o755); err != nil && runtime.GOOS != "windows" {
			return err
		}
		extracted++
	}
	if extracted == 0 {
		return errors.New("the archive held no platform-tools/ files")
	}
	return nil
}

func humanBytes(n int64) string {
	switch {
	case n >= 1<<20:
		return fmt.Sprintf("%.1f MB", float64(n)/(1<<20))
	case n >= 1<<10:
		return fmt.Sprintf("%.0f kB", float64(n)/(1<<10))
	}
	return strconv.FormatInt(n, 10) + " B"
}

// ---------------------------------------------------------------------------
// Running a command the user typed
// ---------------------------------------------------------------------------
// adb is executed directly with an argv — never through a shell — so a typo or
// a stray `;` in the box cannot run anything on this machine. The device side
// is different by design: `adb shell …` sends the rest of the line to the
// phone's own shell, pipes included, which is what makes the presets above a
// single readable line instead of an argument puzzle.
func splitCommand(s string) ([]string, error) {
	var (
		args  []string
		cur   strings.Builder
		quote rune
		esc   bool
		begun bool
	)
	flush := func() {
		if begun {
			args = append(args, cur.String())
			cur.Reset()
			begun = false
		}
	}
	for _, r := range s {
		switch {
		case esc:
			cur.WriteRune(r)
			esc = false
			begun = true
		case r == '\\' && quote != '\'':
			esc = true
			begun = true
		case quote != 0:
			if r == quote {
				quote = 0
			} else {
				cur.WriteRune(r)
			}
			begun = true
		case r == '"' || r == '\'':
			quote = r
			begun = true
		case r == ' ' || r == '\t' || r == '\r' || r == '\n':
			flush()
		default:
			cur.WriteRune(r)
			begun = true
		}
	}
	if esc {
		cur.WriteByte('\\')
	}
	if quote != 0 {
		return nil, errors.New("a quote is not closed")
	}
	flush()
	return args, nil
}

// adbArgs turns whatever was typed into argv for adb: a leading "adb" is
// dropped so a pasted line from the docs works as typed.
func adbArgs(command string) ([]string, error) {
	args, err := splitCommand(strings.TrimSpace(command))
	if err != nil {
		return nil, err
	}
	if len(args) == 0 {
		return nil, errors.New("type an adb command first")
	}
	if base := strings.ToLower(filepath.Base(args[0])); base == "adb" || base == "adb.exe" {
		args = args[1:]
	}
	if len(args) == 0 {
		return nil, errors.New("that is just the word adb — add a command")
	}
	if len(args) > 64 {
		return nil, errors.New("that is a lot of arguments for one command")
	}
	for _, a := range args {
		if strings.ContainsAny(a, "\x00\n") {
			return nil, errors.New("a command cannot contain a line break")
		}
		if len(a) > 4096 {
			return nil, errors.New("one of the arguments is unreasonably long")
		}
	}
	return args, nil
}

// resolvePlaceholders fills the {codename} / {manufacturer} tokens from what the
// user typed in the Device tab (which starts out as whatever config.env says).
func resolvePlaceholders(args []string, values map[string]string) ([]string, error) {
	out := make([]string, len(args))
	for i, a := range args {
		for token, v := range values {
			a = strings.ReplaceAll(a, "{"+token+"}", v)
		}
		if strings.Contains(a, "{") && strings.Contains(a, "}") {
			return nil, errors.New("this command needs a value that is not known yet — fill it in above")
		}
		out[i] = a
	}
	return out, nil
}
