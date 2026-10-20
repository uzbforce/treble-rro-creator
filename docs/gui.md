# Desktop app (Windows / Linux)

The app is a **launcher**, not a second builder. Every button is a command
`build.sh` already understands, so what it produces is byte-for-byte what the
CLI produces from the same `config.env`.

That is also why there is nothing to keep in sync: the app lives in `gui/`
inside the clone, runs `./build.sh` from that clone, and reads `docs/` from it
too. `git pull` updates the CLI, the app and the manual together.

## Get it

From the clone, one command:

```bash
git clone https://github.com/uzbforce/treble-rro-creator   # or -b BETA
cd treble-rro-creator
./gui.sh                  # Linux
gui.cmd                   # Windows (double-click it too)
```

The first launch builds the app and tells you what is missing if anything is
(Go, plus MinGW-w64 gcc on Windows or the WebKitGTK headers on Linux). After
that it starts straight away, and it rebuilds on its own only when the Go
sources or the UI changed — `./gui.sh --rebuild` forces it.

Building by hand, when you want the binary without launching it:

```bash
./gui/build.sh            # console build
gui\build.cmd --release   # no console window behind the app
```

**From a release** (once one is published): download the archive for your
platform, unpack it *into the clone* (so `gui/` sits next to `build.sh`), and run
the executable. Windows builds are unsigned, so SmartScreen shows "Windows
protected your PC" once — **More info → Run anyway**.

Nothing else has to be installed beyond what the CLI already needs (Git for
Windows, JDK 17+). The window is drawn by the engine the system already has:
WebView2 on Windows, WebKitGTK on Linux.

## What it does

| Button | Runs | Use it when |
|---|---|---|
| **Build** | `build.sh build -y` | normal build; writes `out/*.zip` and `out/apks/*.apk` |
| **Dry run** | `build.sh --dry-run -y` | see which resources `config.env` emits, build nothing |
| **Check** | `build.sh check -y` | validate `config.env` before spending a build on it |
| **Doctor** | `build.sh doctor -y` | something is missing; find what |
| **Setup** | `build.sh setup -y` | install or repair the Android build tools |
| **Clean** | `build.sh clean -y` | discard `out/` (tick `--all` to also drop config and device files) |

Flags appear only on the commands that accept them:

- `--with-vendor-hals` — include `src/vendor/` in the module (Build)
- `--allow-unknown-resources` — build even if a resource is missing (Build)
- `--force` — re-pick the resource dictionary (Setup)
- `--all` — also remove config and device files (Clean)

`-y` is always appended: the app has no terminal for the script to ask
questions in, so anything that would prompt takes its default instead of
blocking forever.

The green **Stop** button kills the whole process tree, not just `bash` — a
cancelled build does not leave `aapt2` writing into `out/`.

**Last build** — what `out/` holds — sits folded at the bottom of the Build
pane. It opens itself when a build finishes and stays out of the way otherwise,
so the window no longer opens on a list of files from some earlier run.

## The other tabs

- **config.env** — a form, not a textarea. One row per setting: a switch (that
  is the `#` in front of the line, so off is still a comment the build ignores),
  the value, and **ⓘ** for the paragraph the file already has above that key.
  A key with no note of its own inherits the section's introduction, so ⓘ is
  never empty. **edit the raw file** flips to the text view — the file as it
  really is — when you want to paste or compare.

  Saving writes only the rows you changed. Headings, prose, blank lines, the
  order of the sections and the quoting of every untouched line come back byte
  for byte, and a row you did not touch is never rewritten at all. **Check**
  saves, then runs `build.sh check`, so a typo is reported by the code that
  actually parses the file rather than by a second parser here.
- **Docs** — `docs/*.md` from the clone, rendered in place. Links to another
  page open in the same window; external links open in your real browser.
- **Device** — everything that needs the phone, in one place:
  - **adb** — an `adb` already on `PATH` is used as it is. When there is none,
    **Download platform-tools** fetches Google's official zip once (~8 MB) and
    unpacks it into `tools/platform-tools` (gitignored, next to the other
    downloaded tools). No Android SDK, and nothing else has to be installed to
    unzip it. The chip on the left says which adb is in use and its version.
  - **Command** — one box for anything adb understands: `devices -l`,
    `shell …`, `pull …`. Pipes belong to the *phone's* shell, so
    `shell getprop | grep -i r3q` works as typed, and nothing goes through a
    shell on your machine. `↑` / `↓` walk your history; **Stop** kills a
    `dumpsys` that is taking too long.
  - **Useful commands** — the read-only commands the guides spell out, each with
    one line on what the answer is for: identity props (`ro.product.device` vs
    `ro.product.vendor.device`), the search for a property whose value is your
    codename (the candidates for `DEVICE_PROP_NAME`), display size, density,
    cutout and corner radius, and the in-display fingerprint geometry.

    Commands that need a name fill it from the **codename** / **manufacturer**
    boxes. They start out as whatever `config.env` says; **Detect from device**
    asks the phone and prefers `ro.product.vendor.device`, which is the value
    that survives on a GSI when `ro.product.device` only names the GSI itself.
  - The two pulls the guides ask for: `framework-res.apk` →
    `tools/framework-res.apk` (the platform jar `build.sh` looks for) and the
    full vendor tarball → `tools/vendor.tar.gz`. The tarball is **not**
    extracted for you; see [device-extraction.md](device-extraction.md) for why
    it has to be unpacked one level above `src/vendor`.

## Updates

The chip in the header is about a **newer release**, not about your own edits.
The app runs `git fetch` at startup and every ten minutes, and shows
`N new commits` when the branch upstream has moved. Click it to see the files
the update changes — and, because `config.env` is a file people edit, the
settings it rewrites there.

Before anything is pulled, those files are compared with your uncommitted edits:

- **no overlap** — **Update now** runs `git pull --ff-only`. Your edits are not
touched.
- **overlap** — the button becomes **Back up my edits and update**. The files in
  the way are copied to `backups/pre-update-<time>/`, replaced by the pulled
  version, and then the pull runs. Nothing is thrown away without a copy, and
  the dialog lists what changed so you can retype the values you care about.

A branch with no upstream, or a checkout without `.git`, only says so; it is not
an error. If the update touches `gui/`, the dialog tells you to close the window
and start it again (`gui.sh` / `gui.cmd` rebuild it) — the build scripts are
already the new ones, because they are read from disk on every run.

## Where it keeps settings

Two paths only — the clone, and the `bash` binary:

1. `gui.json` next to the executable, when that folder is writable (a portable
   unpack keeps its paths when moved);
2. otherwise `%APPDATA%\TrebleRROCreator\gui.json` on Windows,
   `~/.config/TrebleRROCreator/gui.json` on Linux.

Click the clone or bash chip in the header to change them. On Windows the app
accepts **Git Bash only**: WSL's `bash` cannot run the native Windows build
tools, and mixing the two is the most common way to get a confusing failure
(see [windows.md](windows.md)).

## When it does not work

| Symptom | Cause |
|---|---|
| "no bash" chip is red | Git for Windows is not installed, or `bash.exe` on PATH is WSL's |
| "no clone" chip is red | the folder does not contain `build.sh` and `scripts/` |
| nothing opens at all | no window can be created: run `./gui.sh --browser`, which serves the same UI on `127.0.0.1` and opens your default browser |
| window opens, then closes | look for `gui.log` next to the executable |
| a build that works in a terminal fails here | run **Doctor**, then compare with the CLI output: the app adds `-y` and nothing else |
| "adb was not found" | install platform-tools with the button in the Device tab, or put `adb` on `PATH` yourself |
| the update chip never appears | the branch has no upstream, or `git fetch` cannot reach the remote — the dialog says which |

Command line options, for the cases where you want to pin something:

```bash
./gui.sh -clone /path/to/clone    # drive another clone
./gui.sh --browser                # no native window
./gui.sh -port 8765               # fixed port, when 8765 is known free
./gui.sh -debug                   # webview devtools
```

The launcher passes anything it does not recognise straight to the binary
(`gui/bin/treble-rro-creator-gui`), so those flags work in either place.

## Android

There is no Android app yet, and the desktop binary cannot become one — an APK
needs a Kotlin/Java activity to host a WebView. On Android, use the CLI in
Termux ([termux.md](termux.md)); the module's own WebUI still handles editing
values after install ([webui.md](webui.md)).
