package main

import (
	"context"
	"crypto/rand"
	"embed"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"sort"
	"strings"
	"time"
)

//go:embed ui
var uiFiles embed.FS

// ---------------------------------------------------------------------------
// Why the UI is served at all
// ---------------------------------------------------------------------------
// The window is a webview pointed at a loopback URL. That is also what makes
// -browser and the Termux front-end free: same HTML, same handlers, no second
// UI to keep in sync with this one.
//
// The risk of a local server is that *any* page in the user's browser can POST
// to 127.0.0.1, and these handlers start build.sh. Two things stop that:
//
//  1. everything lives under a random /<token>/ prefix generated at launch, and
//     the page only learns it by being navigated to it — a cross-origin fetch
//     cannot read our HTML, so it cannot discover the prefix;
//  2. requests a browser marks as cross-site are refused outright.
//
// The listener is bound to 127.0.0.1, never 0.0.0.0, so nothing off-machine can
// reach it at all.
func (a *App) serve(port int) (net.Listener, string, *http.Server, error) {
	token, err := randomToken()
	if err != nil {
		return nil, "", nil, err
	}
	ln, err := net.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", port))
	if err != nil {
		return nil, "", nil, fmt.Errorf("could not open a loopback port: %w", err)
	}

	base := "/" + token
	assets, err := fs.Sub(uiFiles, "ui")
	if err != nil {
		return nil, "", nil, err
	}

	mux := http.NewServeMux()
	mux.HandleFunc(base, func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, base+"/", http.StatusFound)
	})
	mux.HandleFunc(base+"/api/state", a.guard("GET", a.handleState))
	mux.HandleFunc(base+"/api/settings", a.guard("POST", a.handleSettings))
	mux.HandleFunc(base+"/api/config", a.guard("POST", a.handleConfig))
	mux.HandleFunc(base+"/api/run", a.guard("POST", a.handleRun))
	mux.HandleFunc(base+"/api/cancel", a.guard("POST", a.handleCancel))
	mux.HandleFunc(base+"/api/log", a.guard("GET", a.handleLog))
	mux.HandleFunc(base+"/api/adb/log", a.guard("GET", a.handleAdbLog))
	mux.HandleFunc(base+"/api/open", a.guard("POST", a.handleOpen))
	mux.HandleFunc(base+"/api/docs", a.guard("GET", a.handleDocs))
	mux.HandleFunc(base+"/api/doc", a.guard("GET", a.handleDoc))
	mux.HandleFunc(base+"/api/update", a.guard("POST", a.handleUpdate))
	mux.HandleFunc(base+"/api/config/apply", a.guard("POST", a.handleConfigApply))
	mux.HandleFunc(base+"/api/addons", a.guard("GET", a.handleAddons))
	mux.HandleFunc(base+"/api/addons/save", a.guard("POST", a.handleAddonsSave))
	mux.HandleFunc(base+"/api/adb", a.guard("POST", a.handleAdb))
	mux.HandleFunc(base+"/api/adb/devices", a.guard("GET", a.handleAdbDevices))
	mux.HandleFunc(base+"/api/adb/install", a.guard("POST", a.handleAdbInstall))
	mux.HandleFunc(base+"/api/adb/detect", a.guard("POST", a.handleAdbDetect))
	mux.HandleFunc(base+"/api/adb/match-prop", a.guard("POST", a.handleMatchProp))
	mux.HandleFunc(base+"/api/extract", a.guard("POST", a.handleExtract))
	mux.HandleFunc(base+"/api/udfps", a.guard("POST", a.handleUDFPS))
	mux.HandleFunc(base+"/api/detect", a.guard("POST", a.handleDetect))
	mux.HandleFunc(base+"/api/pick", a.guard("POST", a.handlePick))
	mux.HandleFunc(base+"/api/url", a.guard("POST", a.handleURL))

	// The src/ workspace: the file manager, its two editors and the checks behind
	// them (see files.go). Uploads are the only route that is not JSON.
	mux.HandleFunc(base+"/api/files", a.guard("GET", a.handleFiles))
	mux.HandleFunc(base+"/api/files/read", a.guard("GET", a.handleFileRead))
	mux.HandleFunc(base+"/api/files/write", a.guard("POST", a.handleFileWrite))
	mux.HandleFunc(base+"/api/files/check", a.guard("POST", a.handleFileCheck))
	mux.HandleFunc(base+"/api/files/upload", a.guard("POST", a.handleFileUpload))
	mux.HandleFunc(base+"/api/files/delete", a.guard("POST", a.handleFileDelete))
	mux.HandleFunc(base+"/api/files/mkdir", a.guard("POST", a.handleFileMkdir))
	mux.HandleFunc(base+"/api/files/toggle", a.guard("POST", a.handleFileToggle))
	mux.Handle(base+"/", http.StripPrefix(base, http.FileServer(http.FS(assets))))

	srv := &http.Server{Handler: mux, ReadHeaderTimeout: 10 * time.Second}
	url := "http://" + ln.Addr().String() + base + "/"
	return ln, url, srv, nil
}

func randomToken() (string, error) {
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return hex.EncodeToString(b), nil
}

func (a *App) guard(method string, h http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if r.Method != method {
			w.Header().Set("Allow", method)
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		if r.Header.Get("Sec-Fetch-Site") == "cross-site" {
			http.Error(w, "forbidden", http.StatusForbidden)
			return
		}
		h(w, r)
	}
}

// ---------------------------------------------------------------------------
// Handlers
// ---------------------------------------------------------------------------
func (a *App) handleState(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, a.State())
}

// handleSettings remembers the clone and the bash binary. Nothing is run here:
// a wrong path is stored and reported by /api/state so the field stays visible
// and editable instead of being rejected on a typo.
func (a *App) handleSettings(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Clone string `json:"clone"`
		Bash  string `json:"bash"`
	}
	if !decode(w, r, &body) {
		return
	}
	if err := a.setPaths(body.Clone, body.Bash); err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, a.State())
}

// handleConfig writes config.env exactly as typed. The file is the interface
// build.sh reads, comments included, so it is saved verbatim rather than
// round-tripped through a form.
func (a *App) handleConfig(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Text string `json:"text"`
	}
	if !decode(w, r, &body) {
		return
	}
	root := a.Root()
	if !isClone(root) {
		writeError(w, http.StatusBadRequest, "no clone selected")
		return
	}
	if len(body.Text) > 1<<20 {
		writeError(w, http.StatusRequestEntityTooLarge, "config.env is limited to 1 MiB")
		return
	}
	if err := os.WriteFile(filepath.Join(root, "config.env"), []byte(body.Text), 0o644); err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"path": filepath.Join(root, "config.env")})
}

func (a *App) handleRun(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Verb  string   `json:"verb"`
		Flags []string `json:"flags"`
		// Sudo is the password the app collected after the installer said it
		// needed one. It lives in this request, a 0600 file for the duration of
		// the run, and the page's memory — never in a log or the clone.
		Sudo string `json:"sudo"`
	}
	if !decode(w, r, &body) {
		return
	}
	args, err := buildArgs(body.Verb, body.Flags)
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	// Only these two verbs install anything (see ensure_toolchain). A password
	// for check or clean would be carried for nothing.
	if body.Sudo != "" && body.Verb != "build" && body.Verb != "setup" {
		writeError(w, http.StatusBadRequest, "that command does not install anything")
		return
	}
	extraEnv, cleanup, err := a.sudoEnv(body.Sudo)
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	if err := a.runner.StartEnv(a.Root(), a.Bash(), args, "build.sh "+body.Verb, false, extraEnv, cleanup); err != nil {
		// start() already ran cleanup on its own failure paths.
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	writeJSON(w, http.StatusAccepted, a.runner.Snapshot())
}

// sudoEnv turns a password from the dialog into what `sudo -A` needs.
//
// The password goes into a 0600 file rather than the child's environment: an
// environment entry is inherited by everything the build starts, while the file
// can be removed the moment the run ends (Runner.finish does exactly that).
func (a *App) sudoEnv(password string) ([]string, func(), error) {
	if password == "" {
		return nil, nil, nil
	}
	helper := filepath.Join(a.Root(), "stuff", "scripts", "sudo-askpass.sh")
	st, err := os.Stat(helper)
	if err != nil {
		return nil, nil, errors.New("the sudo helper is missing — update the clone (git pull) and try again")
	}
	// Windows has no executable bit: every file would fail this check there,
	// and the helper is never run on Windows anyway (no sudo to ask).
	if runtime.GOOS != "windows" && st.Mode()&0o111 == 0 {
		return nil, nil, errors.New("the sudo helper is not executable — update the clone (git pull) and try again")
	}
	dir, err := os.MkdirTemp("", "rro-sudo-")
	if err != nil {
		return nil, nil, err
	}
	path := filepath.Join(dir, "password")
	if err := os.WriteFile(path, []byte(password+"\n"), 0o600); err != nil {
		os.RemoveAll(dir)
		return nil, nil, err
	}
	cleanup := func() { os.RemoveAll(dir) }
	return []string{"SUDO_ASKPASS=" + helper, "RRO_SUDO_PASSWORD_FILE=" + path}, cleanup, nil
}

// handleCancel stops whatever is running. There is one Stop button per console
// but only one job at a time (see Gate), so asking both runners is the same as
// asking the one that has something to stop.
func (a *App) handleCancel(w http.ResponseWriter, r *http.Request) {
	if err := a.runner.Cancel(); err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	if a.adbRunner != nil {
		if err := a.adbRunner.Cancel(); err != nil {
			writeError(w, http.StatusBadRequest, err.Error())
			return
		}
	}
	writeJSON(w, http.StatusOK, a.runner.Snapshot())
}

// handleLog is the Build console: a server-sent event stream, one JSON LogLine
// per event, replayed from the buffer first so a reload does not lose the run
// in progress.
func (a *App) handleLog(w http.ResponseWriter, r *http.Request) {
	a.streamLog(w, r, a.runner)
}

// handleAdbLog is the same stream for the Device console. It is a separate
// buffer on a separate Runner, so an adb command no longer appears in the build
// log and a build no longer wipes the device console.
func (a *App) handleAdbLog(w http.ResponseWriter, r *http.Request) {
	if a.adbRunner == nil {
		http.Error(w, "no device console", http.StatusInternalServerError)
		return
	}
	a.streamLog(w, r, a.adbRunner)
}

func (a *App) streamLog(w http.ResponseWriter, r *http.Request, run *Runner) {
	flusher, ok := w.(http.Flusher)
	if !ok {
		http.Error(w, "streaming unsupported", http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Connection", "keep-alive")
	w.WriteHeader(http.StatusOK)

	snapshot := run.Snapshot()
	for _, line := range snapshot.Lines {
		writeEvent(w, line)
	}
	flusher.Flush()

	lines, stop := run.Subscribe()
	defer stop()

	// Comment pings keep a webview from closing an idle stream while a long
	// aapt2 step prints nothing.
	ticker := time.NewTicker(20 * time.Second)
	defer ticker.Stop()

	for {
		select {
		case <-r.Context().Done():
			return
		case line := <-lines:
			writeEvent(w, line)
			flusher.Flush()
		case <-ticker.C:
			fmt.Fprint(w, ": ping\n\n")
			flusher.Flush()
		}
	}
}

func writeEvent(w io.Writer, line LogLine) {
	b, err := json.Marshal(line)
	if err != nil {
		return
	}
	fmt.Fprintf(w, "data: %s\n\n", b)
}

// handleOpen reveals something in the file manager. Only three targets exist,
// so the endpoint cannot be used to open an arbitrary path.
func (a *App) handleOpen(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Target string `json:"target"`
	}
	if !decode(w, r, &body) {
		return
	}
	root := a.Root()
	var path string
	switch body.Target {
	case "out":
		path = filepath.Join(root, "out")
	case "root":
		path = root
	case "config":
		path = filepath.Join(root, "config.env")
	default:
		writeError(w, http.StatusBadRequest, "unknown target")
		return
	}
	if !dirExists(root) {
		writeError(w, http.StatusBadRequest, "no clone selected")
		return
	}
	if body.Target == "out" {
		if err := os.MkdirAll(path, 0o755); err != nil {
			writeError(w, http.StatusInternalServerError, err.Error())
			return
		}
	}
	if err := openPath(path); err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"opened": path})
}

func (a *App) handleDocs(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, listDocs(a.Root()))
}

func (a *App) handleDoc(w http.ResponseWriter, r *http.Request) {
	text, err := readDoc(a.Root(), r.URL.Query().Get("name"))
	if err != nil {
		writeError(w, http.StatusNotFound, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"text": text})
}

// handleExtract pulls the files the docs tell the user to pull by hand. The
// long ones go through the runner so they stream and can be cancelled; nothing
// here writes outside stuff/tools/, so a failed pull cannot damage a clone.
func (a *App) handleExtract(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Action string `json:"action"`
	}
	if !decode(w, r, &body) {
		return
	}
	adb := a.adbPath()
	if adb == "" {
		writeError(w, http.StatusBadRequest, "adb was not found on PATH and stuff/tools/platform-tools is missing")
		return
	}
	root := a.Root()
	if !isClone(root) {
		writeError(w, http.StatusBadRequest, "no clone selected")
		return
	}
	if err := os.MkdirAll(filepath.Join(root, "stuff", "tools"), 0o755); err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}

	switch body.Action {
	case "framework-res":
		// build.sh looks for stuff/tools/framework-res.apk and uses it as the
		// platform jar; a local copy is what makes a build work without the SDK.
		// adb reports transfer progress on stderr; merged so a good pull reads as
		// normal output instead of an error.
		err := a.adbRunner.Start(root, adb,
			[]string{"pull", "/system/framework/framework-res.apk", filepath.Join("stuff", "tools", "framework-res.apk")},
			"adb pull framework-res.apk", true)
		if err != nil {
			writeError(w, http.StatusBadRequest, err.Error())
			return
		}
	case "vendor":
		// One root shell makes the tarball on the device, one pull brings it
		// back. Extracting it is left to the user: docs/device-extraction.md
		// explains why it has to happen one level above src/vendor.
		// 2>&1 on each adb call, so progress is not red while a genuine shell
		// error still is.
		script := fmt.Sprintf(
			`'%s' shell su -c 'tar -czf /data/local/tmp/vendor_full.tar.gz -C / vendor' 2>&1 && '%s' pull /data/local/tmp/vendor_full.tar.gz stuff/tools/vendor.tar.gz 2>&1`,
			adb, adb)
		err := a.adbRunner.Start(root, a.Bash(),
			[]string{"--noprofile", "--norc", "-c", script},
			"adb pull full vendor", false)
		if err != nil {
			writeError(w, http.StatusBadRequest, err.Error())
			return
		}
	default:
		writeError(w, http.StatusBadRequest, "unknown action")
		return
	}
	writeJSON(w, http.StatusAccepted, a.adbRunner.Snapshot())
}

// handleURL opens a link from the docs in the user's real browser. Without it
// a click would navigate the webview away from the app, where there is no Back.
func (a *App) handleURL(w http.ResponseWriter, r *http.Request) {
	var body struct {
		URL string `json:"url"`
	}
	if !decode(w, r, &body) {
		return
	}
	u := strings.TrimSpace(body.URL)
	if len(u) > 2048 || !(strings.HasPrefix(u, "https://") || strings.HasPrefix(u, "http://")) {
		writeError(w, http.StatusBadRequest, "only http(s) links can be opened")
		return
	}
	if err := openURL(u); err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"opened": u})
}

// ---------------------------------------------------------------------------
// Update
// ---------------------------------------------------------------------------
// "check" may take a few seconds (it is a fetch); "pull" fast-forwards the
// clone, after backing up any local edit the update would overwrite when the
// user agreed to it. Both report what happened instead of only a status code,
// because the next question is always "what did it do to my files"".
func (a *App) handleUpdate(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Action string `json:"action"`
		Backup bool   `json:"backup"`
	}
	if !decode(w, r, &body) {
		return
	}

	switch body.Action {
	case "check":
		writeJSON(w, http.StatusOK, a.RefreshUpdate())
	case "pull":
		res, err := a.pullUpdate(body.Backup)
		if err != nil {
			if errors.Is(err, errClash) {
				// Not a mistake: the dialog has to list the files first.
				writeJSON(w, http.StatusConflict, map[string]any{
					"error": err.Error(),
					"clash": a.Update().Clash,
				})
				return
			}
			writeError(w, http.StatusBadRequest, err.Error())
			return
		}
		writeJSON(w, http.StatusOK, res)
	default:
		writeError(w, http.StatusBadRequest, "unknown action")
	}
}

// ---------------------------------------------------------------------------
// The config.env form
// ---------------------------------------------------------------------------
// handleConfigApply saves the rows the form changed. Edits are addressed by
// line number AND key, so a save from a stale page fails loudly instead of
// rewriting whatever moved into that line.
func (a *App) handleConfigApply(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Edits []ConfigEdit `json:"edits"`
	}
	if !decode(w, r, &body) {
		return
	}
	root := a.Root()
	if !isClone(root) {
		writeError(w, http.StatusBadRequest, "no clone selected")
		return
	}
	path := filepath.Join(root, "config.env")
	text, err := os.ReadFile(path)
	if err != nil {
		writeError(w, http.StatusBadRequest, "config.env is missing — run Build once, or Clean --all to recreate it")
		return
	}

	next, err := applyConfigEdits(string(text), body.Edits)
	if err != nil {
		writeError(w, http.StatusConflict, err.Error())
		return
	}
	if next != string(text) {
		if err := os.WriteFile(path, []byte(next), 0o644); err != nil {
			writeError(w, http.StatusInternalServerError, err.Error())
			return
		}
	}
	doc, _ := parseConfig(next)
	writeJSON(w, http.StatusOK, map[string]any{"config": doc, "text": next})
}

// ---------------------------------------------------------------------------
// Addons
// ---------------------------------------------------------------------------
// An addon is a tweak the module owns: either a Settings value it writes on the
// phone (the volume panel side, the screen timeout) or, for the overlay addons,
// a resource the build bakes into the APK. Either way the choice lives in
// src/module/addons.conf instead of config.env, which is why the tab is
// separate from the config form.
//
// The catalog and the rules are in src/webui/addons.sh — the same file the
// module ships as webroot/addons.sh and the phone's page runs — so this tab is
// a form over that script rather than a second list to keep in sync. The script
// is told where the clone's src/module/addons.conf is, which is the file
// build.sh packs into the module.
const addonsScript = "src/webui/addons.sh"

// The script validates both; these only keep a request from being turned into
// shell syntax. The page can only send what it rendered, but a request is not
// the page.
var (
	addonID     = regexp.MustCompile(`^[a-z0-9_]+$`)
	addonChoice = regexp.MustCompile(`^[a-z0-9]+$`)
)

// addonsEnv points the helper at the clone instead of an installed module.
// Paths are POSIX: Git Bash on Windows reads a backslash as an escape.
func (a *App) addonsEnv() []string {
	root := filepath.ToSlash(a.Root())
	return []string{
		"ADDONS_DIR=" + root,
		"ADDONS_CONF=" + root + "/src/module/addons.conf",
	}
}

func (a *App) runAddons(args ...string) ([]byte, error) {
	root := a.Root()
	if !isClone(root) {
		return nil, errors.New("no clone selected")
	}
	bash := a.Bash()
	if !fileExists(bash) {
		return nil, errors.New("bash was not found — pick it with the Path chip")
	}
	// Short on purpose: six `settings` calls on a phone, and no work at all in
	// the clone.
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, bash, append([]string{addonsScript}, args...)...)
	// Hide the console Windows would otherwise flash for this child. The tab
	// runs the helper on open and on every save, so an un-hidden window is a
	// black rectangle blinking at the user each time.
	setProcAttr(cmd)
	cmd.Dir = root
	// A stale ADDONS_* in the app's own environment would otherwise win over
	// the paths below (Windows keeps the first duplicate in the block).
	env := make([]string, 0, len(os.Environ())+2)
	for _, kv := range os.Environ() {
		if strings.HasPrefix(kv, "ADDONS_") {
			continue
		}
		env = append(env, kv)
	}
	cmd.Env = append(env, a.addonsEnv()...)
	var stderr strings.Builder
	cmd.Stderr = &stderr
	out, err := cmd.Output()
	if err != nil {
		msg := strings.TrimSpace(stderr.String())
		if msg == "" {
			msg = err.Error()
		}
		return nil, errors.New(msg)
	}
	return out, nil
}

// addonsDoc is the helper's own JSON, passed through: the page renders exactly
// what the module will enforce.
func (a *App) addonsDoc() (map[string]any, error) {
	out, err := a.runAddons("list")
	if err != nil {
		return nil, err
	}
	var doc map[string]any
	if err := json.Unmarshal(out, &doc); err != nil {
		return nil, fmt.Errorf("the addons helper did not return JSON: %v", err)
	}
	return doc, nil
}

func (a *App) handleAddons(w http.ResponseWriter, r *http.Request) {
	doc, err := a.addonsDoc()
	if err != nil {
		writeError(w, http.StatusBadGateway, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, doc)
}

// handleAddonsSave stores the choices, which is also what applies them: the
// script's `set` writes the file and makes the values true on the phone when
// there is one. A phone is not required — the file is what the build packs.
func (a *App) handleAddonsSave(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Values map[string]string `json:"values"`
		Reset  bool              `json:"reset"`
	}
	if !decode(w, r, &body) {
		return
	}

	if body.Reset {
		if _, err := a.runAddons("reset"); err != nil {
			writeError(w, http.StatusBadGateway, err.Error())
			return
		}
	} else {
		pairs := make([]string, 0, len(body.Values))
		for id, value := range body.Values {
			if !addonID.MatchString(id) {
				writeError(w, http.StatusBadRequest, "not an addon id: "+id)
				return
			}
			if !addonChoice.MatchString(value) {
				writeError(w, http.StatusBadRequest, "not an addon value: "+value)
				return
			}
			pairs = append(pairs, id+"="+value)
		}
		sort.Strings(pairs)
		if len(pairs) > 0 {
			if _, err := a.runAddons(append([]string{"set"}, pairs...)...); err != nil {
				writeError(w, http.StatusBadGateway, err.Error())
				return
			}
		}
	}

	doc, err := a.addonsDoc()
	if err != nil {
		writeError(w, http.StatusBadGateway, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, doc)
}

// ---------------------------------------------------------------------------
// adb
// ---------------------------------------------------------------------------
// handleAdb runs one adb command through the runner, so its output streams into
// the console and Stop works on a `dumpsys` that is taking too long.
func (a *App) handleAdb(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Command      string `json:"command"`
		Preset       string `json:"preset"`
		Codename     string `json:"codename"`
		Manufacturer string `json:"manufacturer"`
		Serial       string `json:"serial"`
	}
	if !decode(w, r, &body) {
		return
	}
	root := a.Root()
	if !isClone(root) {
		writeError(w, http.StatusBadRequest, "no clone selected")
		return
	}
	adb := a.adbPath()
	if adb == "" {
		writeError(w, http.StatusBadRequest, "adb is not installed yet — use \"Download platform-tools\" first")
		return
	}

	values := map[string]string{
		"codename":     safeToken(body.Codename),
		"manufacturer": safeToken(body.Manufacturer),
	}
	if doc, err := parseConfig(readConfig(root)); err == nil {
		if values["codename"] == "" {
			values["codename"] = safeToken(doc.Lookup("DEVICE_CODENAME"))
		}
		if values["manufacturer"] == "" {
			values["manufacturer"] = safeToken(doc.Lookup("DEVICE_MANUFACTURER"))
		}
	}

	var args []string
	label := "adb"
	if body.Preset != "" {
		p, ok := lookupPreset(body.Preset)
		if !ok {
			writeError(w, http.StatusBadRequest, "unknown preset")
			return
		}
		for _, need := range p.Needs {
			if values[need] == "" {
				writeError(w, http.StatusBadRequest, fmt.Sprintf("this command needs %s — fill it in first", need))
				return
			}
		}
		resolved, err := resolvePlaceholders(p.Args, values)
		if err != nil {
			writeError(w, http.StatusBadRequest, err.Error())
			return
		}
		args = resolved
		label = "adb " + strings.Join(args, " ")
	} else {
		parsed, err := adbArgs(body.Command)
		if err != nil {
			writeError(w, http.StatusBadRequest, err.Error())
			return
		}
		args = parsed
		label = "adb " + strings.Join(args, " ")
	}

	// Which phone. A typed `-s` is left alone; otherwise the picker's serial is
	// prepended. Commands that do not talk to a device (version, devices, the
	// server verbs) accept the selector and ignore it, so no command needs a
	// special case here.
	if serial := safeToken(body.Serial); serial != "" && !adbArgsHaveSerial(args) {
		args = append([]string{"-s", serial}, args...)
		label = "adb -s " + serial + " " + strings.Join(args[2:], " ")
	}

	if err := a.adbRunner.Start(root, adb, args, label, true); err != nil {
		writeError(w, http.StatusConflict, err.Error())
		return
	}
	writeJSON(w, http.StatusAccepted, a.adbRunner.Snapshot())
}

// handleAdbDevices is what the picker reads: every attached phone and its state.
func (a *App) handleAdbDevices(w http.ResponseWriter, r *http.Request) {
	devices, err := a.adbDevices()
	if err != nil {
		writeError(w, http.StatusBadGateway, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"devices": devices,
		"ready":   len(readyAdbDevices(devices)),
	})
}

// handleAdbInstall downloads platform-tools once. It is the only job that runs
// inside this process, so it holds the runner's slot like a child would.
func (a *App) handleAdbInstall(w http.ResponseWriter, r *http.Request) {
	if err := a.adbRunner.Begin("downloading platform-tools"); err != nil {
		writeError(w, http.StatusConflict, err.Error())
		return
	}
	go func() {
		err := a.installPlatformTools(a.adbRunner.Note)
		a.adbRunner.FinishJob(err)
	}()
	writeJSON(w, http.StatusAccepted, a.adbRunner.Snapshot())
}

// DetectCandidate is one property that answered with a value, and what that
// property is. The Device tab offers them in this order.
type DetectCandidate struct {
	Prop  string `json:"prop"`
	Note  string `json:"note"`
	Value string `json:"value"`
}

// DetectResult is what "Detect from device" found: the answer it would use, and
// every other command that also had something to say.
type DetectResult struct {
	Codename     string            `json:"codename"`
	Manufacturer string            `json:"manufacturer"`
	Model        string            `json:"model"`
	Prop         string            `json:"prop"`
	Candidates   []DetectCandidate `json:"candidates"`
}

// codenameProps is the order the codename is looked for in. The vendor
// partition keeps the stock name on most GSIs, so it is asked first;
// ro.product.device is near the end because on a GSI it only names the GSI
// itself. No single property is right on every phone — which is why the answer
// is offered with the command that produced it, and the others are one click
// away in the UI.
var codenameProps = []DetectCandidate{
	{Prop: "ro.product.vendor.device", Note: "vendor partition — the usual survivor on a GSI"},
	{Prop: "ro.product.odm.device", Note: "ODM partition"},
	{Prop: "ro.product.bootimage.device", Note: "boot image"},
	{Prop: "ro.product.device", Note: "system property — often the GSI's own name"},
	{Prop: "ro.build.product", Note: "legacy build.prop name"},
}

// detectCodenames asks every candidate property and keeps the answers that
// mean something, in priority order and without duplicates. Every one is asked,
// not just the first that answers: the ones that had a value are what "Wrong?
// Try another command" cycles through, and that has to work without another
// round trip to the phone.
func detectCodenames(probe func(string) string) []DetectCandidate {
	out := []DetectCandidate{}
	seen := make(map[string]bool, len(codenameProps))
	for _, c := range codenameProps {
		value := probe(c.Prop)
		if value == "" || strings.EqualFold(value, "unknown") || seen[value] {
			continue
		}
		seen[value] = true
		out = append(out, DetectCandidate{Prop: c.Prop, Note: c.Note, Value: value})
	}
	return out
}

// handleAdbDetect asks the phone for the values the presets need, so the user
// does not have to read one command's output and type it into another box.
func (a *App) handleAdbDetect(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Serial string `json:"serial"`
	}
	if !decode(w, r, &body) {
		return
	}
	adb := a.adbPath()
	if adb == "" {
		writeError(w, http.StatusBadRequest, "adb is not installed yet — use \"Download platform-tools\" first")
		return
	}
	serial, err := a.deviceSerialFor(body.Serial)
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	probe := func(prop string) string {
		out, err := runCapture(adb, "-s", serial, "shell", "getprop", prop)
		if err != nil {
			return ""
		}
		return strings.TrimSpace(out)
	}

	res := DetectResult{Candidates: []DetectCandidate{}}
	res.Manufacturer = probe("ro.product.manufacturer")
	res.Model = probe("ro.product.model")
	res.Candidates = detectCodenames(probe)
	if len(res.Candidates) > 0 {
		res.Codename = res.Candidates[0].Value
		res.Prop = res.Candidates[0].Prop
	}

	if res.Codename == "" && res.Manufacturer == "" && res.Model == "" {
		writeError(w, http.StatusBadGateway, "the phone did not answer — is it connected and authorized? (adb devices)")
		return
	}
	writeJSON(w, http.StatusOK, res)
}

// handleMatchProp ranks the properties this phone could be matched on, for the
// Overlay activation section of the Config tab. The two getprop dumps are read
// from the same selected phone as every other device action; nothing is written
// here — the page stages the two config.env lines and the user saves them.
func (a *App) handleMatchProp(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Serial string `json:"serial"`
	}
	if !decode(w, r, &body) {
		return
	}
	adb := a.adbPath()
	if adb == "" {
		writeError(w, http.StatusBadRequest, "adb is not installed yet — use \"Download platform-tools\" first")
		return
	}
	serial, err := a.deviceSerialFor(body.Serial)
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}

	// Values and SELinux areas come from two commands: `getprop -Z` prints the
	// area only, and both streams are one adb round trip each.
	valuesOut, err := runCapture(adb, "-s", serial, "shell", "getprop")
	if err != nil {
		writeError(w, http.StatusBadGateway, "the phone did not answer getprop: "+err.Error())
		return
	}
	// The labels are the second-best signal, never required: `getprop -Z` is
	// missing on old Android, and without it the ranking still works (the card
	// says readability is unchecked instead of refusing to answer).
	labels := map[string]string{}
	if labelsOut, err := runCapture(adb, "-s", serial, "shell", "getprop", "-Z"); err == nil {
		labels = parseGetpropLabels(labelsOut)
	}

	report := rankMatchProps(parseGetprop(valuesOut), labels)
	report.Serial = serial
	if report.Codename == "" && report.Model == "" {
		writeError(w, http.StatusBadGateway, "the phone reported no identity properties — is it still connected?")
		return
	}
	writeJSON(w, http.StatusOK, report)
}

func lookupPreset(id string) (AdbPreset, bool) {
	for _, p := range adbPresets {
		if p.ID == id {
			return p, true
		}
	}
	return AdbPreset{}, false
}

// safeToken keeps a value from being pasted into a command box unexamined: it
// is only ever used to fill {codename}/{manufacturer} in a preset.
func safeToken(s string) string {
	s = strings.TrimSpace(s)
	if len(s) > 64 {
		return ""
	}
	for _, r := range s {
		switch {
		case r >= 'a' && r <= 'z', r >= 'A' && r <= 'Z', r >= '0' && r <= '9', r == '.', r == '_', r == '-':
		default:
			return ""
		}
	}
	return s
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------
func runCapture(program string, args ...string) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, program, args...)
	setProcAttr(cmd)
	out, err := cmd.CombinedOutput()
	return strings.TrimSpace(string(out)), err
}

func decode(w http.ResponseWriter, r *http.Request, dst any) bool {
	return decodeLimit(w, r, dst, 1<<20)
}

// decodeLimit is the same for a body that is legitimately bigger than a config
// form: saving a resource XML or a manifest.
func decodeLimit(w http.ResponseWriter, r *http.Request, dst any, limit int64) bool {
	r.Body = http.MaxBytesReader(w, r.Body, limit)
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()
	if err := dec.Decode(dst); err != nil {
		writeError(w, http.StatusBadRequest, "could not read the request: "+err.Error())
		return false
	}
	return true
}

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}

func writeError(w http.ResponseWriter, code int, msg string) {
	writeJSON(w, code, map[string]string{"error": msg})
}
