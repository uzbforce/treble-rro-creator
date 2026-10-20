package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
	"sync"
	"time"
)

const appTitle = "Treble RRO Creator"

// Verb is one command build.sh understands, in the shape the UI draws it.
type Verb struct {
	Name  string   `json:"name"`
	Label string   `json:"label"`
	Arg   string   `json:"arg"`
	Hint  string   `json:"hint"`
	Flags []string `json:"flags"`
}

// ---------------------------------------------------------------------------
// The commands the app is allowed to run
// ---------------------------------------------------------------------------
// Each entry is one thing `build.sh` already does; the GUI only chooses which
// one to run. Flags are per verb on purpose: `--all` means "also remove config
// and device files" and is meaningless on a build, so the UI disables it and
// the server rejects it. Keeping the table here (not only in the JS) means a
// hand-written POST cannot widen what the app will execute.
var verbTable = []Verb{
	{
		Name:  "build",
		Label: "Build",
		Arg:   "build",
		Hint:  "Compile and sign the module, and the submission zips",
		Flags: []string{"--with-vendor-hals", "--allow-unknown-resources"},
	},
	{
		Name:  "dryrun",
		Label: "Dry run",
		Arg:   "--dry-run",
		Hint:  "Print the resources config.env emits, build nothing",
		Flags: nil,
	},
	{
		Name:  "check",
		Label: "Check",
		Arg:   "check",
		Hint:  "Validate config.env, build nothing",
		Flags: nil,
	},
	{
		Name:  "doctor",
		Label: "Doctor",
		Arg:   "doctor",
		Hint:  "Check the toolchain, install nothing",
		Flags: nil,
	},
	{
		Name:  "setup",
		Label: "Setup",
		Arg:   "setup",
		Hint:  "Install or repair the build tools",
		Flags: []string{"--force"},
	},
	{
		Name:  "clean",
		Label: "Clean",
		Arg:   "clean",
		Hint:  "Remove build output",
		Flags: []string{"--all"},
	},
}

func lookupVerb(name string) (Verb, bool) {
	for _, v := range verbTable {
		if v.Name == name {
			return v, true
		}
	}
	return Verb{}, false
}

// buildArgs turns a verb and its ticked flags into the argv for bash.
//
// -y is always appended: the child has no terminal, so anything that would
// prompt has to take its default instead of blocking forever on stdin. That is
// also why --with-vendor-hals becomes reachable at all — build.sh only honours
// it together with --yes.
func buildArgs(verb string, flags []string) ([]string, error) {
	v, ok := lookupVerb(verb)
	if !ok {
		return nil, fmt.Errorf("unknown command %q", verb)
	}
	args := []string{"--noprofile", "--norc", "./build.sh", v.Arg}
	for _, f := range flags {
		if !contains(v.Flags, f) {
			return nil, fmt.Errorf("%s is not available with %s", f, v.Name)
		}
		args = append(args, f)
	}
	return append(args, "-y"), nil
}

func contains(list []string, want string) bool {
	for _, s := range list {
		if s == want {
			return true
		}
	}
	return false
}

// ---------------------------------------------------------------------------
// Persisted state
// ---------------------------------------------------------------------------
// Settings is all the app remembers. It is deliberately two paths and nothing
// else: config.env belongs to the clone, and the build reads it from there.
type Settings struct {
	Clone string `json:"clone"`
	Bash  string `json:"bash"`
}

// App is the whole program state. root and bash can change at runtime from the
// UI, so both are read through the mutex rather than captured at startup.
type App struct {
	mu       sync.RWMutex
	settings Settings
	file     string
	root     string
	bash     string
	runner   *Runner

	// The update check is cached separately: it can block on the network, and
	// nothing that answers /api/state may wait for a fetch.
	updMu   sync.Mutex
	upd     UpdateInfo
	updWhen time.Time
	updBusy bool
}

func newApp(explicitClone string) (*App, error) {
	a := &App{runner: NewRunner(), file: settingsFile()}
	a.settings = loadSettings(a.file)

	a.root = chooseClone(explicitClone, a.settings.Clone)

	a.bash = a.settings.Bash
	if a.bash == "" || !fileExists(a.bash) {
		if b, err := findBash(); err == nil {
			a.bash = b
		}
	}
	// The first check happens while the window is still drawing.
	go a.watchUpdates()
	return a, nil
}

func (a *App) Root() string {
	a.mu.RLock()
	defer a.mu.RUnlock()
	return a.root
}

func (a *App) Bash() string {
	a.mu.RLock()
	defer a.mu.RUnlock()
	return a.bash
}

// setPaths validates and remembers the two paths the user picked. An invalid
// clone is accepted as long as it is a directory: the UI shows a warning and
// keeps the path visible instead of silently discarding what was typed.
func (a *App) setPaths(clone, bash string) error {
	clone = strings.TrimSpace(clone)
	bash = strings.TrimSpace(bash)

	if clone != "" {
		abs, err := filepath.Abs(clone)
		if err != nil {
			return err
		}
		st, err := os.Stat(abs)
		if err != nil || !st.IsDir() {
			return fmt.Errorf("%s is not a folder", clone)
		}
		clone = abs
	}
	if bash != "" && !fileExists(bash) {
		return fmt.Errorf("%s does not exist", bash)
	}

	a.mu.Lock()
	a.root = clone
	if bash != "" {
		a.bash = bash
	}
	file := a.file
	a.mu.Unlock()

	// Only what the user picked is written down. An auto-detected bash is left
	// out on purpose, so a Git upgrade is picked up on the next launch instead
	// of being pinned to the old path.
	return saveSettings(file, Settings{Clone: clone, Bash: bash})
}

// ---------------------------------------------------------------------------
// Where settings live
// ---------------------------------------------------------------------------
func exeDir() string {
	exe, err := os.Executable()
	if err != nil {
		return "."
	}
	if resolved, err := filepath.EvalSymlinks(exe); err == nil {
		exe = resolved
	}
	return filepath.Dir(exe)
}

// settingsFile prefers a file next to the executable so a copied folder keeps
// its paths (portable install), and falls back to the user's config directory
// when the app sits somewhere read-only such as Program Files.
func settingsFile() string {
	dir := exeDir()
	if dirWritable(dir) {
		return filepath.Join(dir, "gui.json")
	}
	if cfg, err := os.UserConfigDir(); err == nil {
		return filepath.Join(cfg, "TrebleRROCreator", "gui.json")
	}
	return filepath.Join(dir, "gui.json")
}

func dirWritable(dir string) bool {
	f, err := os.CreateTemp(dir, ".write-test-*")
	if err != nil {
		return false
	}
	name := f.Name()
	f.Close()
	os.Remove(name)
	return true
}

func loadSettings(path string) Settings {
	var s Settings
	b, err := os.ReadFile(path)
	if err != nil {
		return Settings{}
	}
	if json.Unmarshal(b, &s) != nil {
		return Settings{}
	}
	return s
}

func saveSettings(path string, s Settings) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	b, err := json.MarshalIndent(s, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(path, append(b, '\n'), 0o644)
}

// ---------------------------------------------------------------------------
// Finding the clone and bash
// ---------------------------------------------------------------------------
// isClone asks for the two things every build needs: the entry point and the
// modules it sources. config.env is deliberately not required — a fresh clone
// has no config.env until setup runs.
func isClone(dir string) bool {
	if dir == "" {
		return false
	}
	return fileExists(filepath.Join(dir, "build.sh")) && dirExists(filepath.Join(dir, "scripts"))
}

// chooseClone looks in the order a user would expect: what they passed on the
// command line, what they picked last time, the clone the app was installed
// into, then the working directory. An invalid explicit or saved path is still
// returned so the UI can show it and let them fix it.
func chooseClone(explicit, saved string) string {
	for _, c := range []string{explicit, saved, selfClone(), cwdClone()} {
		if isClone(c) {
			if abs, err := filepath.Abs(c); err == nil {
				return abs
			}
			return c
		}
	}
	for _, c := range []string{explicit, saved} {
		if c != "" {
			if abs, err := filepath.Abs(c); err == nil {
				return abs
			}
			return c
		}
	}
	return ""
}

// walkUpForClone finds the nearest clone at or above dir.
//
// The app can be in gui/bin/ (a build from this repo), in gui/ (a release
// unpacked into the clone), or at the clone root, and the shell it was started
// from can be anywhere. Walking up covers all of those without a first-run
// wizard or a guessed default path.
func walkUpForClone(dir string) string {
	for i := 0; i < 4 && dir != ""; i++ {
		if isClone(dir) {
			return dir
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			break
		}
		dir = parent
	}
	return ""
}

func selfClone() string { return walkUpForClone(exeDir()) }

func cwdClone() string {
	wd, err := os.Getwd()
	if err != nil {
		return ""
	}
	return walkUpForClone(wd)
}

func fileExists(p string) bool {
	if p == "" {
		return false
	}
	st, err := os.Stat(p)
	return err == nil && !st.IsDir()
}

func dirExists(p string) bool {
	if p == "" {
		return false
	}
	st, err := os.Stat(p)
	return err == nil && st.IsDir()
}

// ---------------------------------------------------------------------------
// Reading the clone
// ---------------------------------------------------------------------------
type Doc struct {
	Name  string `json:"name"`
	Title string `json:"title"`
}

// listDocs reads docs/*.md from the clone. The GUI ships no copy of the manual:
// the app is installed into a clone, so the docs it shows are the docs that
// match the scripts it runs.
func listDocs(root string) []Doc {
	entries, err := os.ReadDir(filepath.Join(root, "docs"))
	if err != nil {
		return nil
	}
	docs := make([]Doc, 0, len(entries))
	for _, e := range entries {
		if e.IsDir() || !strings.HasSuffix(e.Name(), ".md") {
			continue
		}
		docs = append(docs, Doc{Name: e.Name(), Title: docTitle(filepath.Join(root, "docs", e.Name()))})
	}
	sort.Slice(docs, func(i, j int) bool { return docs[i].Name < docs[j].Name })
	return docs
}

func docTitle(path string) string {
	b, err := os.ReadFile(path)
	if err != nil {
		return strings.TrimSuffix(filepath.Base(path), ".md")
	}
	for _, line := range strings.Split(string(b), "\n") {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, "# ") {
			return strings.TrimSpace(strings.TrimPrefix(line, "# "))
		}
	}
	return strings.TrimSuffix(filepath.Base(path), ".md")
}

// readDoc refuses anything outside docs/*.md so a crafted name cannot walk out
// of the clone.
func readDoc(root, name string) (string, error) {
	name = filepath.Base(name)
	if name == "." || name == string(filepath.Separator) || !strings.HasSuffix(name, ".md") {
		return "", errors.New("not a doc")
	}
	b, err := os.ReadFile(filepath.Join(root, "docs", name))
	if err != nil {
		return "", err
	}
	return string(b), nil
}

func readConfig(root string) string {
	b, err := os.ReadFile(filepath.Join(root, "config.env"))
	if err != nil {
		return ""
	}
	return string(b)
}

type OutFile struct {
	Name string `json:"name"`
	Path string `json:"path"`
	Size int64  `json:"size"`
	Mod  int64  `json:"mod"`
}

// listOut lists what the last builds produced, newest first. Two levels is
// enough for out/*.zip and out/apks/*.apk and keeps a stale out/ from turning
// into a directory browser.
func listOut(root string) []OutFile {
	base := filepath.Join(root, "out")
	var files []OutFile
	_ = filepath.WalkDir(base, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return nil
		}
		rel, relErr := filepath.Rel(base, p)
		if relErr != nil {
			return nil
		}
		if d.IsDir() {
			if rel != "." && strings.Count(rel, string(filepath.Separator)) >= 1 {
				return fs.SkipDir
			}
			return nil
		}
		info, infoErr := d.Info()
		if infoErr != nil {
			return nil
		}
		files = append(files, OutFile{
			Name: rel,
			Path: p,
			Size: info.Size(),
			Mod:  info.ModTime().Unix(),
		})
		return nil
	})
	sort.Slice(files, func(i, j int) bool { return files[i].Mod > files[j].Mod })
	if len(files) > 40 {
		files = files[:40]
	}
	return files
}

// ---------------------------------------------------------------------------
// The update check, shared by every handler and the background refresher
// ---------------------------------------------------------------------------
// A fetch is a network round trip, so /api/state must never wait for one: it
// returns whatever the last check found, and the check itself runs on its own
// (startup, every ten minutes, and when the user opens the update dialog).
const updateEvery = 10 * time.Minute

func (a *App) invalidateUpdate() {
	a.updMu.Lock()
	a.updWhen = time.Time{}
	a.updMu.Unlock()
}

// Update returns the cached answer. It is what the header chip renders.
func (a *App) Update() UpdateInfo {
	a.updMu.Lock()
	defer a.updMu.Unlock()
	return a.upd
}

// RefreshUpdate checks now and returns the fresh answer, unless another caller
// is already checking (a window that opened twice must not fetch twice).
func (a *App) RefreshUpdate() UpdateInfo {
	a.updMu.Lock()
	if a.updBusy {
		cached := a.upd
		a.updMu.Unlock()
		return cached
	}
	a.updBusy = true
	a.updMu.Unlock()

	info := checkUpdate(a.Root())

	a.updMu.Lock()
	a.upd = info
	a.updWhen = time.Now()
	a.updBusy = false
	a.updMu.Unlock()
	return info
}

func (a *App) updateFresh() bool {
	a.updMu.Lock()
	defer a.updMu.Unlock()
	return !a.updWhen.IsZero() && time.Since(a.updWhen) < updateEvery
}

// watchUpdates keeps the chip honest without blocking anything: one check at
// startup, then one per updateEvery. Failures are stored in the info and shown
// as "could not check", never as a modal.
func (a *App) watchUpdates() {
	if !isClone(a.Root()) {
		return
	}
	a.RefreshUpdate()
	for {
		time.Sleep(updateEvery)
		if !isClone(a.Root()) {
			continue
		}
		if a.runner.Snapshot().Running {
			// A build may be changing files; a fetch would just add noise.
			continue
		}
		a.RefreshUpdate()
	}
}

// ---------------------------------------------------------------------------
// State handed to the UI
// ---------------------------------------------------------------------------
type State struct {
	Clone      string      `json:"clone"`
	CloneValid bool        `json:"cloneValid"`
	Bash       string      `json:"bash"`
	BashValid  bool        `json:"bashValid"`
	ConfigText string      `json:"configText"`
	Config     ConfigDoc   `json:"config"`
	Branch     string      `json:"branch"`
	Commit     string      `json:"commit"`
	Dirty      bool        `json:"dirty"`
	Platform   string      `json:"platform"`
	Verbs      []Verb      `json:"verbs"`
	Docs       []Doc       `json:"docs"`
	Out        []OutFile   `json:"out"`
	Run        RunState    `json:"run"`
	Update     UpdateInfo  `json:"update"`
	Adb        AdbInfo     `json:"adb"`
	Presets    []AdbPreset `json:"adbPresets"`
}

func (a *App) State() State {
	a.mu.RLock()
	root, bash := a.root, a.bash
	a.mu.RUnlock()

	branch, commit, dirty := gitInfo(root)
	text := readConfig(root)
	config, _ := parseConfig(text)
	return State{
		Clone:      root,
		CloneValid: isClone(root),
		Bash:       bash,
		BashValid:  fileExists(bash),
		ConfigText: text,
		Config:     config,
		Branch:     branch,
		Commit:     commit,
		Dirty:      dirty,
		Platform:   runtime.GOOS,
		Verbs:      verbTable,
		Docs:       listDocs(root),
		Out:        listOut(root),
		Run:        a.runner.Snapshot(),
		Update:     a.Update(),
		Adb:        a.AdbInfo(),
		Presets:    adbPresets,
	}
}
