# gui/ — the desktop launcher

A Go program that finds a clone, finds bash, and runs `build.sh` for you.

The module lives at the repository root (`../go.mod`) so a checkout is one Go
project, but every source file is here and `go build ./gui` works from the
root. The CLI still needs no Go toolchain: `build.sh` never touches this
folder.

**User documentation lives in [../docs/gui.md](../docs/gui.md).** This file is
for working on the app itself.

## Shape

| File | What it holds |
|---|---|
| `main.go` | flags, wiring, shutdown; no logic |
| `app.go` | settings, clone and bash discovery, the verb table, state for the UI |
| `run.go` | one console: the child process (or in-process job), its log ring buffer and subscribers, plus `Gate`, the one-job-at-a-time token the two consoles share |
| `git.go` | update check (`git fetch` + behind/ahead + which local edits collide) and the safe pull |
| `configfile.go` | the config.env parser and the line-wise writer behind the form |
| `files.go` | the src/ workspace: safe relative paths, listing, read/write, upload, delete, and "disable" as a move into `src/.disabled/` — plus the sepolicy and VINTF checks |
| `adb.go` | adb discovery, the platform-tools download/unzip, the command tokenizer and the presets |
| `server.go` | loopback HTTP handlers, the two log streams (`/api/log`, `/api/adb/log`), embed of `ui/`, token prefix |
| `proc_windows.go` | Git Bash discovery, `taskkill /T`, Explorer, WebView2 host |
| `proc_unix.go` | `/bin/bash`, process-group kill, `xdg-open` |
| `window_cgo.go` | the native window (`//go:build cgo && (windows || linux)`) |
| `window_no_cgo.go` | same program, browser instead (`//go:build !cgo …`) |
| `icon.go`, `icon.ico` | the app mark, embedded for the window icon |
| `icon_windows.go` | `setWindowIcon`: `WM_SETICON` on the window WebView2 created |
| `icon_other.go` | the same call, doing nothing (the GTK window keeps its own) |
| `browser.go` | opens the UI in the default browser and waits for Ctrl+C |
| `ui/` | one page, one stylesheet, one script; no bundler, no `node_modules` |
| `*_test.go` | argv, clone discovery, config round trip, adb parsing, update/pull against a temp git repo |
| `build.sh`, `build.cmd` | build the app |
| `../treble-rro-creator.sh`, `../treble-rro-creator.cmd` | build-if-needed and launch; what users actually run |
| `../go.mod`, `../go.sum` | the module, at the root so the whole clone is one Go project |

The UI is embedded with `go:embed`, so a released binary is a single file. Docs
are **not** embedded: they are read from the clone at run time, because the app
is installed into a clone anyway and a second copy would drift.

## Build and run

```bash
./treble-rro-creator.sh                    # build if stale, then launch — the normal path
./treble-rro-creator.sh --rebuild          # force a build first
./treble-rro-creator.sh --detach           # accepted for scripts; the hand-off is the default
./gui/build.sh              # build only (console build, for debugging)
./gui/build.sh --release    # stripped; no console window on Windows
gui\build.cmd --release     # same from cmd/PowerShell
```

| Platform | Needs |
|---|---|
| Windows | Go 1.23+ (downloaded into `stuff/tools/go/` when missing), MinGW-w64 gcc on PATH (`pacman -S mingw-w64-x86_64-gcc` in MSYS2), Git for Windows at run time |
| Linux | Go 1.23+ (downloaded into `stuff/tools/go/` when missing, or skipped when the distro's is too old), plus gcc, pkg-config and the GTK3/WebKitGTK headers — installed automatically with apt, pacman or dnf when missing (4.1 is shimmed to the 4.0 name webview_go asks for) |

`CGO_ENABLED=0 ./gui/build.sh` builds without a C compiler and without
WebKitGTK; the app then serves the same UI to the default browser instead of a
window. That is the only difference — same handlers, same behaviour.

### Why there is no cross-compilation

`CGO_ENABLED=1` cannot cross-compile without a full target toolchain: the
Windows build needs MinGW, the Linux build needs a Linux gcc plus WebKitGTK.
Each release target is therefore built on its own runner, which is also the only
way to know the binary links. A `CGO_ENABLED=0` build *can* cross-compile:

```bash
CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -o dist/gui-linux-arm64 .
```

## Tests

```bash
CGO_ENABLED=0 go test ./...               # from the repo root; also runs from stuff/tests/run.sh
```

The tests cover what can break silently: the argv handed to bash (including the
trailing `-y`), the verb/flag allow-list, clone detection, settings round-trip,
`docs/` path traversal, the codename candidates the Device tab offers, and that
every verb still exists in `build.sh`. For the workspace they pin the path rules
(`..`, absolute paths, drive letters, `src/.disabled` itself), the disable/
enable move, uploads that keep relative paths and refuse traversal, and both
checkers (a missing `;`, an AIDL manifest carrying HIDL syntax). Nothing in them
needs a window, a C compiler or a phone.

## Security model

The window is a webview pointed at `127.0.0.1`. A local server is reachable by
any page in the user's browser, and these handlers start a build, so:

- the listener binds `127.0.0.1` only;
- every route lives under a random 128-bit `/<token>/` prefix created at launch,
  and the page only learns it by being navigated to it — a cross-origin fetch
  cannot read our HTML, so it cannot learn the token;
- requests marked `Sec-Fetch-Site: cross-site` are refused;
- the endpoint surface is an allow-list (`build.sh` verbs, five flags, three
  open targets, `http(s)` links, and file operations whose paths are relative to
  `src/` and re-validated server-side), not "run this program" or "write this
  path";
- the sudo password from the install dialog is kept in the page's memory,
  written to a `0600` temporary file for the run that needs it, handed to
  `sudo -A` through `stuff/scripts/sudo-askpass.sh`, and deleted when that run
  ends. It is never written into the clone and never logged.
