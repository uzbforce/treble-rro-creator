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
	mux.HandleFunc(base+"/api/open", a.guard("POST", a.handleOpen))
	mux.HandleFunc(base+"/api/docs", a.guard("GET", a.handleDocs))
	mux.HandleFunc(base+"/api/doc", a.guard("GET", a.handleDoc))
	mux.HandleFunc(base+"/api/update", a.guard("POST", a.handleUpdate))
	mux.HandleFunc(base+"/api/config/apply", a.guard("POST", a.handleConfigApply))
	mux.HandleFunc(base+"/api/adb", a.guard("POST", a.handleAdb))
	mux.HandleFunc(base+"/api/adb/install", a.guard("POST", a.handleAdbInstall))
	mux.HandleFunc(base+"/api/adb/detect", a.guard("POST", a.handleAdbDetect))
	mux.HandleFunc(base+"/api/extract", a.guard("POST", a.handleExtract))
	mux.HandleFunc(base+"/api/url", a.guard("POST", a.handleURL))
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
	}
	if !decode(w, r, &body) {
		return
	}
	args, err := buildArgs(body.Verb, body.Flags)
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	if err := a.runner.Start(a.Root(), a.Bash(), args, "build.sh "+body.Verb, false); err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	writeJSON(w, http.StatusAccepted, a.runner.Snapshot())
}

func (a *App) handleCancel(w http.ResponseWriter, r *http.Request) {
	if err := a.runner.Cancel(); err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, a.runner.Snapshot())
}

// handleLog is a server-sent event stream: one JSON LogLine per event, replayed
// from the buffer first so a reload does not lose the run in progress.
func (a *App) handleLog(w http.ResponseWriter, r *http.Request) {
	flusher, ok := w.(http.Flusher)
	if !ok {
		http.Error(w, "streaming unsupported", http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Connection", "keep-alive")
	w.WriteHeader(http.StatusOK)

	snapshot := a.runner.Snapshot()
	for _, line := range snapshot.Lines {
		writeEvent(w, line)
	}
	flusher.Flush()

	lines, stop := a.runner.Subscribe()
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
// here writes outside tools/, so a failed pull cannot damage a clone.
func (a *App) handleExtract(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Action string `json:"action"`
	}
	if !decode(w, r, &body) {
		return
	}
	adb := a.adbPath()
	if adb == "" {
		writeError(w, http.StatusBadRequest, "adb was not found on PATH and tools/platform-tools is missing")
		return
	}
	root := a.Root()
	if !isClone(root) {
		writeError(w, http.StatusBadRequest, "no clone selected")
		return
	}
	if err := os.MkdirAll(filepath.Join(root, "tools"), 0o755); err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}

	switch body.Action {
	case "framework-res":
		// build.sh looks for tools/framework-res.apk and uses it as the platform
		// jar; a local copy is what makes a build work without the SDK.
		// adb reports transfer progress on stderr; merged so a good pull reads as
		// normal output instead of an error.
		err := a.runner.Start(root, adb,
			[]string{"pull", "/system/framework/framework-res.apk", filepath.Join("tools", "framework-res.apk")},
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
			`'%s' shell su -c 'tar -czf /data/local/tmp/vendor_full.tar.gz -C / vendor' 2>&1 && '%s' pull /data/local/tmp/vendor_full.tar.gz tools/vendor.tar.gz 2>&1`,
			adb, adb)
		err := a.runner.Start(root, a.Bash(),
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
	writeJSON(w, http.StatusAccepted, a.runner.Snapshot())
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

	if err := a.runner.Start(root, adb, args, label, true); err != nil {
		writeError(w, http.StatusConflict, err.Error())
		return
	}
	writeJSON(w, http.StatusAccepted, a.runner.Snapshot())
}

// handleAdbInstall downloads platform-tools once. It is the only job that runs
// inside this process, so it holds the runner's slot like a child would.
func (a *App) handleAdbInstall(w http.ResponseWriter, r *http.Request) {
	if err := a.runner.Begin("downloading platform-tools"); err != nil {
		writeError(w, http.StatusConflict, err.Error())
		return
	}
	go func() {
		err := a.installPlatformTools(a.runner.Note)
		a.runner.FinishJob(err)
	}()
	writeJSON(w, http.StatusAccepted, a.runner.Snapshot())
}

// handleAdbDetect asks the phone for the values the presets need, so the user
// does not have to read one command's output and type it into another box.
func (a *App) handleAdbDetect(w http.ResponseWriter, r *http.Request) {
	adb := a.adbPath()
	if adb == "" {
		writeError(w, http.StatusBadRequest, "adb is not installed yet — use \"Download platform-tools\" first")
		return
	}
	probe := func(prop string) string {
		out, err := runCapture(adb, "shell", "getprop", prop)
		if err != nil {
			return ""
		}
		return strings.TrimSpace(out)
	}

	manufacturer := probe("ro.product.manufacturer")
	model := probe("ro.product.model")
	// The vendor partition keeps the stock name on most GSIs; product.device is
	// only used when the vendor value is empty or a placeholder of its own.
	codename := probe("ro.product.vendor.device")
	if codename == "" || strings.EqualFold(codename, "unknown") {
		codename = probe("ro.product.device")
	}

	if codename == "" && manufacturer == "" && model == "" {
		writeError(w, http.StatusBadGateway, "the phone did not answer — is it connected and authorized? (adb devices)")
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{
		"codename":     codename,
		"manufacturer": manufacturer,
		"model":        model,
	})
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
	r.Body = http.MaxBytesReader(w, r.Body, 1<<20)
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
