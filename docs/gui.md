# Desktop app (Windows / Linux)

The app is a **launcher and a workspace**, not a second builder. Every build
button is a command `build.sh` already understands, so what it produces is
byte-for-byte what the CLI produces from the same `config.env`; the files it
edits are the files the build reads, under `src/`.

That is also why there is nothing to keep in sync: the app lives in `gui/`
inside the clone, runs `./build.sh` from that clone, and reads `docs/` from it
too. `git pull` updates the CLI, the app and the manual together.

## Get it

From the clone, one command:

```bash
git clone https://github.com/uzbforce/treble-rro-creator   # or -b BETA
cd treble-rro-creator
./treble-rro-creator.sh   # Linux
treble-rro-creator.cmd    # Windows (double-click it too)
```

The launchers used to be called `gui.sh` and `gui.cmd`; a shortcut or note from
before the rename needs pointing at the new file. Nothing else changed.

The first launch builds the app, and what the build needs it installs or
downloads itself. Go is fetched from go.dev into `stuff/tools/_go/` when the
machine has none (a distro's package is skipped when it is older than `go.mod`
asks for, so nothing has to be installed by hand); the next launch finds that
copy and does not download again. On Linux the missing GTK/WebKitGTK headers and
pkg-config come from the distro's own package manager — apt on Debian/Ubuntu,
pacman on Arch, dnf on Fedora — after your sudo password if one is required. On
Windows, the MinGW-w64 gcc the window links with is downloaded too: a ~260 MB
WinLibs zip (about 1 GB unpacked) into `stuff/tools/_mingw/`, unpacked with the
`unzip` Git for Windows already carries, so there is no MSYS2 shell to open and
no `PATH` to edit. Only Git for Windows itself has to be installed by hand. After that it starts
straight away, and it rebuilds on its own only when the Go sources or the UI
changed — `./treble-rro-creator.sh --rebuild` forces it.

The page is **embedded in the executable**, so a build is what makes the window
match `gui/`: editing `app.js` without relinking changes nothing on screen.
That relink needs a C compiler (both it and Go are downloaded); without one the
launcher still starts the binary that is already in `gui/bin/`, and says so when
that binary is older than the sources.

**No console window stays behind the app.** On Windows the launcher always
builds the window-only variant (linked without a console) and starts it in the
background — double-clicked or typed into a cmd window, the black window closes
as soon as the app is up, and the app outlives it. Build messages are printed
by the launcher before that happens; the app's own failures are appended to
`gui.log` next to the executable. `--browser` is the one case that stays in the
console, because that is where the server is watched and stopped. The launcher
reads the executable's own header to decide, so a binary from a release archive
is judged by what it is, and switching to a console build and back relinks
once.

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
| **Setup** | `build.sh setup -y` | install or repair the Android build tools (asks for the sudo password when it needs it) |
| **Clean** | `build.sh clean -y` | discard `out/` (tick `--all` to also drop config and device files) |

Flags appear only on the commands that accept them:

- `--with-vendor-hals` — include `src/vendor/` in the module (Build)
- `--allow-unknown-resources` — build even if a resource is missing (Build)
- `--force` — re-pick the resource dictionary (Setup)
- `--all` — also remove config and device files (Clean)

`-y` is always appended: the app has no terminal for the script to ask
questions in, so anything that would prompt takes its default instead of
blocking forever. The one question the app answers itself is **sudo's
password**: when installing the tools needs root, the run stops, the app asks
for the password in a dialog, and the same command is repeated with it. The
password is kept in that window's memory and handed to `sudo -A` (through
`stuff/scripts/sudo-askpass.sh`) via a private file that is deleted when the
run ends. **Setup** therefore installs rather than printing a command, and
**Build** repairs a partial toolchain the same way.

The green **Stop** button kills the whole process tree, not just `bash` — a
cancelled build does not leave `aapt2` writing into `out/`.

Downloads move while they happen: pacman (and `adb pull`) repaint one line with
carriage returns, and the pane updates that line in place as each chunk arrives
instead of showing it only once the retrieval ends.

**Last build** — what `out/` holds — sits folded at the bottom of the Build
pane. It opens itself when a build finishes and stays out of the way otherwise,
so the window no longer opens on a list of files from some earlier run.

## The other tabs

- **config.env** — a form, not a textarea. One row per setting: a switch (that
  is the `#` in front of the line, so off is still a comment the build ignores),
  the value, and **ⓘ** for the paragraph the file already has above that key.
  A key with no note of its own inherits the section's introduction, so ⓘ is
  never empty. The form shows the section headings and nothing else of the
  file's prose: every explanation is one click away behind its row's ⓘ rather
  than repeated on screen. **edit the raw file** flips to the text view — the
  file as it really is — when you want to paste or compare.

  Saving writes only the rows you changed. Headings, prose, blank lines, the
  order of the sections and the quoting of every untouched line come back byte
  for byte, and a row you did not touch is never rewritten at all. **Check**
  saves, then runs `build.sh check`, so a typo is reported by the code that
  actually parses the file rather than by a second parser here.

  Under *Overlay activation* sits **Match property**: it asks the selected phone
  which properties carry its codename, whether zygote can read them and whether
  the value survives a GSI, ranks the answers with the reasons, and stages
  `HW_OVERLAY_MATCH_PROP` / `_VALUE` when you click **Use**. If no property
  passes all three tests it says so and keeps the working default
  (`persist.sys.overlay.<codename>`) instead of selling a guess; the rows are
  still listed with the reasons they fell short (a shared `mivendor`, a GSI
  `generic`, a `build_prop` that a GSI renames) — see
  [configuration.md](configuration.md#choosing-the-match-property).
- **Files** — the `src/` workspace, so placing a HAL never means leaving the
  window. The tree is exactly what the build reads: `framework/` and `systemui/`
  resources, `module/` scripts, the optional `vendor/` HAL tree and `webui/`.

  - **Placing files** — click a folder to open it in the right pane (what it
    holds, how big it is, what is disabled) and make it the upload target, then
    drop files on the tree or use **Upload files** / **Upload folder**. The pane
    also carries its own **Upload here** / **New here** buttons, so the answer
    to "where will this land?" is on screen before the picker opens. The caret
    expands and collapses a folder; clicking its name always shows its contents.
    Relative paths are kept, so a dumped `vendor/bin/hw/…` tree arrives in that
    shape instead of flattened into one folder. `framework-res.apk`'s
    `power_profile.xml` can be dropped straight into `framework/res/xml/`.
  - **New…** creates an empty file, a folder, a VINTF manifest from an AIDL or
    HIDL template, or a commented SELinux starter. The manifest template takes
    the HAL name and interface from the file name
    (`android.hardware.biometrics.fingerprint.xml` →
    `android.hardware.biometrics.fingerprint` / `IFingerprint`), so the file is
    a real fragment before it is edited.
  - **Disable** moves a file or a whole folder into `src/.disabled/`; **Enable**
    puts it back. The build never looks there, so a HAL can be switched off
    without deleting it — and it stays in the clone, so an update or a later
    build still has it. The tree keeps a disabled item exactly where it was,
    greyed with a `disabled` badge, because its location is the useful part;
    clicking it still opens it (and its folder), read-only in effect until it
    is enabled again.
  - **Delete** is the only action that cannot be undone, so it always asks
    first. The confirmation puts **Delete** on the left and **Cancel** on the
    right, with Cancel styled as the primary button and focused when the dialog
    opens, so Enter or Escape keeps the file.
  - **Editing and checks** — text files open in place and save with the button
    or `Ctrl+S`. Two kinds are checked while you type (and on open and save):
    `src/module/sepolicy.rule` (a rule without its `;`, an unbalanced `{ }`, an
    indented rule the build's `grep` will miss, a `<placeholder>` left in, or a
    file with no `allow` line at all — which `build.sh` skips) and any
    `src/vendor/etc/vintf/manifest/*.xml` (HIDL versioning or `<fqname>` on an
    AIDL HAL, a missing instance, `format=` that is neither, XML that does not
    parse). They are warnings and errors on screen only: the file is yours and
    always saves.

  Uploads are capped at 256 MiB per file. Nothing outside `src/` can be
  reached: every path is relative and re-validated by the server.
- **Docs** — `docs/*.md` from the clone, rendered in place. Links to another
  page open in the same window; external links open in your real browser.
- **Device** — everything that needs the phone, in one place:
  - **adb** — an `adb` already on `PATH` is used as it is. When there is none,
    **Download platform-tools** fetches Google's official zip once (~8 MB) and
    unpacks it into `stuff/tools/platform-tools` (gitignored, next to the other
    downloaded tools). No Android SDK, and nothing else has to be installed to
    unzip it. The line under the heading says which adb is in use and its
    version.
  - **device** — the phone every command goes to. With one attached there is
    nothing to choose; with several, the list is filled from `adb devices -l`
    and the pick is remembered, so a second phone on the desk never silently
    takes the answer. The same picker sits at the top of the Detect and UDFPS
    tabs, because that is where the choice matters, and **Reload devices**
    re-reads the list after a replug. A phone that is attached but not ready is
    shown with its state (unauthorized, offline, no permissions) instead of
    being left out — see
    [detect.md](detect.md#more-than-one-phone).
  - **Command** — one box for anything adb understands: `devices -l`,
    `shell …`, `pull …`. Pipes belong to the *phone's* shell, so
    `shell getprop | grep -i r3q` works as typed, and nothing goes through a
    shell on your machine. `↑` / `↓` walk your history; **Stop** kills a
    `dumpsys` that is taking too long. Its output lands in the console under the
    box, **not** in the Build pane: the two consoles keep separate logs, so a
    build never buries an adb answer and an adb command never wipes a build.
  - **Useful commands** — the read-only commands the guides spell out, each with
    one line on what the answer is for: identity props (`ro.product.device` vs
    `ro.product.vendor.device`), the search for a property whose value is your
    codename (the candidates for `DEVICE_PROP_NAME`), display size, density,
    cutout and corner radius, and the in-display fingerprint geometry.

    Commands that need a name fill it from the **codename** / **manufacturer**
    boxes. They start out as whatever `config.env` says; **Detect from device**
    asks the phone and prefers `ro.product.vendor.device`, which is the value
    that survives on a GSI when `ro.product.device` only names the GSI itself.

    No single property is right on every phone, so the answer comes with the
    command that produced it: a note appears under the codename box saying
    which `getprop` answered. If that is not your device (a GSI reporting its
    own name is the usual case), **Wrong? Try another command** fills the box
    from the next property that had a value — `ro.product.odm.device`,
    `ro.product.bootimage.device`, `ro.product.device`, `ro.build.product` — and
    tells you which one it used. Typing a codename by hand dismisses the note.
  - The two pulls the guides ask for: `framework-res.apk` →
    `stuff/tools/framework-res.apk` (the platform jar `build.sh` looks for) and the
    full vendor tarball → `stuff/tools/vendor.tar.gz`. The tarball is **not**
    extracted for you; see [device-extraction.md](device-extraction.md) for why
    it has to be unpacked one level above `src/vendor`.
- **UDFPS** — the sensor-geometry question on its own, because it is the one
  value in `config.env` that is a fact about the hardware rather than a taste.
  **Read from the connected phone** runs `stuff/scripts/udfps-probe.sh`: it
  reads the vendor FOD properties, follows `cmd overlay dump` to the enabled
  overlay and dumps that APK's `config_udfps_sensor_props` with `aapt2`, and
  falls back to the HAL and kernel sources when neither answers. The rows are
  every answer with its source, confidence and coordinates, plus what was read
  and anything the probe could not do (no aapt2, an unreadable overlay).

  **Scan firmware** does the same against a ROM instead of a phone: give it the
  fastboot ROM's `super.img`, a Samsung `AP_*.tar.md5`, the ROM folder, or a
  tree you already unpacked. A bare image is unpacked first, and the answer
  line says what came out of it (`Unpacked super.img · 8 partitions · 1299
  files`). **Use the selected values** writes `UDFPS_X` / `UDFPS_Y` /
  `UDFPS_RADIUS` and switches `HAS_UDFPS` on, through the same line-addressed
  save as the config form.
  [udfps.md](udfps.md) explains each source and the arithmetic behind the
  numbers.
- **Detect** — the other settings that are facts about the panel or the ROM
  rather than style: the cutout path, corner radius, status bar height, refresh
  rates, the six brightness integers, and the `HAS_*` feature flags.
  **Read from the connected phone** runs `stuff/scripts/device-probe.sh`, which
  reads the panel geometry from `dumpsys`, the framework resources from
  `cmd overlay lookup`, and the enabled overlay APKs with `aapt2`; **Scan
  firmware** takes the same path for a `super.img`, a Samsung `AP_*.tar.md5`,
  a ROM folder or an extracted tree. Every answer keeps its source and a
  confidence, and two sources that disagree stay as two rows — that is usually
  an OEM value next to the GSI's default. Tick the rows you want and **Write the
  ticked values** saves them through the same line-addressed path as the config
  form, so comments and the order of the file survive.
  [detect.md](detect.md) has the source table and the GSI caveats.

  **Power profile** is the same idea for a file instead of a value: **Read from
  the connected phone** (or **from the folder**) extracts
  `res/xml/power_profile.xml` from the overlay or `framework-res.apk`, converts
  the compiled tree back to XML and shows it; **Save** writes
  `src/framework/res/xml/power_profile.xml`, which is the file the build
  compiles into the overlay.

### Unpacking a ROM

The three scans share one unpacker, and it is part of the app rather than a
command it shells out to. Give the path field any of these and it works out
which one it is:

| You point at | What happens |
| --- | --- |
| a tree you unpacked (`system/build.prop`, `product/overlay/…`) | read as it is |
| a fastboot ROM folder (`images/super.img` inside) | `images/super.img` is unpacked |
| `super.img` (or a sparse/`lz4`-wrapped one) | LP metadata read, each partition opened |
| a Samsung `AP_*.tar.md5` (or a plain `.tar`) | the `.img` / `.img.lz4` members are opened |
| a bare `system.img` / `product.img` | opened directly |

Partitions can be `ext4` or `erofs`; compressed EROFS files (`lz4`, including
the compacted cluster maps Android writes) are decompressed too, because
`build.prop` and `init.rc` are usually compressed. So there is nothing to
install for the unpacking itself — not `lpunpack`, not `simg2img`, not `7z` —
on Windows, Linux or Termux.

The path fields have **File…** and **Folder…** buttons that open the system's
own chooser: PowerShell's dialog on Windows, `zenity` or `kdialog` on Linux.
Typing the path still works, and is the only way on Termux, where the buttons
say that no chooser is installed.

Only the files the probes actually open are copied out: `*.prop`, overlay APKs,
`framework-res.apk`, and `etc/**/*.rc|*.xml`. That is a few hundred MB out of a
9 GB image, and it takes a couple of seconds. The result lands in
`<temp>/treble-rro-firmware/<name>/` and is cached, keyed on the source file's
size and mtime, so a second scan does not unpack again. The same code is the
`-unpack` flag:

```bash
./treble-rro-creator.sh -unpack path/to/super.img
./treble-rro-creator.sh -unpack path/to/AP_*.tar.md5 -out ~/rom
```

On Windows the same flags go through `treble-rro-creator.cmd`.

The scans themselves read the APKs with `aapt2`. If it is not there yet, the app
runs `./build.sh setup -y` first, which is the installer a build uses: apt on
Debian/Ubuntu, pacman on Arch, pkg on Termux, and a download into
`stuff/tools/` on Windows or where no package manager is available.

## Updates

The **Check for updates** button in the header is about a **newer release**, not
about your own edits. The app runs `git fetch` at startup and every ten minutes;
the dot on the button turns green when the branch upstream has moved, and the
tooltip says how far. Click it to see the files the update changes — and,
because `config.env` is a file people edit, the settings it rewrites there.

Before anything is pulled, those files are compared with your uncommitted edits:

- **no overlap** — **Update now** runs `git pull --ff-only`. Your edits are not
touched.
- **overlap** — the button becomes **Back up my edits and update**. The files in
  the way are copied to `stuff/backups/pre-update-<time>/`, replaced by the pulled
  version, and then the pull runs. Nothing is thrown away without a copy, and
  the dialog lists what changed so you can retype the values you care about.

A branch with no upstream, or a checkout without `.git`, only says so; it is not
an error. If the update touches `gui/`, the dialog tells you to close the window
and start it again (`treble-rro-creator.sh` / `treble-rro-creator.cmd` rebuild it) — the build scripts are
already the new ones, because they are read from disk on every run.

## Where it keeps settings

Two paths only — the clone, and the `bash` binary:

1. `gui.json` next to the executable, when that folder is writable (a portable
   unpack keeps its paths when moved);
2. otherwise `%APPDATA%\TrebleRROCreator\gui.json` on Windows,
   `~/.config/TrebleRROCreator/gui.json` on Linux.

Both are changed in one place: the **Path** button in the header opens the
dialog, and its dot is green only when the pair is usable (hover it to see which
of the two is wrong). On Windows the app accepts **Git Bash only**: WSL's `bash`
cannot run the native Windows build tools, and mixing the two is the most common
way to get a confusing failure (see [windows.md](windows.md)).

## When it does not work

| Symptom | Cause |
|---|---|
| the **Path** dot is red | hover it: the tooltip says which half is wrong — bash missing (Git for Windows not installed, or `bash.exe` on PATH is WSL's) or the folder not being a clone (no `build.sh` and `stuff/scripts/`) |
| nothing opens at all | no window can be created: run `./treble-rro-creator.sh --browser`, which serves the same UI on `127.0.0.1` and opens your default browser |
| window opens, then closes | look for `gui.log` next to the executable |
| the console stays open behind the window | the binary is a console build and could not be relinked: the window needs a C compiler (Linux: gcc with the GTK/WebKitGTK headers; Windows: MinGW-w64, downloaded by the build). Fix what the build reported, then `./treble-rro-creator.sh --rebuild`. `--browser` keeps the console on purpose |
| a build that works in a terminal fails here | run **Doctor**, then compare with the CLI output: the app adds `-y` and nothing else |
| "adb was not found" | install platform-tools with the button in the Device tab, or put `adb` on `PATH` yourself |
| the update dot never turns green | the branch has no upstream, `git fetch` cannot reach the remote, or you are up to date — the dialog says which |
| the window shows an older UI than `gui/` | the page is embedded in `gui/bin/treble-rro-creator-gui`, and the relink needs a C compiler for the window. The launcher says when it is starting a binary older than the sources — fix what the build reported, then run `./treble-rro-creator.sh --rebuild` |
| a file looks greyed out in the Files tree | it is disabled: the row stays in place with a `disabled` badge while the file lives in `src/.disabled/`. **↺** puts it back |
| "that folder does not exist" after uploading | the target folder changed underneath the window (another program removed it) — press **↻** and pick it again |

Command line options, for the cases where you want to pin something:

```bash
./treble-rro-creator.sh -clone /path/to/clone    # drive another clone
./treble-rro-creator.sh --browser                # no native window
./treble-rro-creator.sh --detach                 # kept for scripts; the hand-off is the default
./treble-rro-creator.sh -port 8765               # fixed port, when 8765 is known free
./treble-rro-creator.sh -debug                   # webview devtools
```

The launcher passes anything it does not recognise straight to the binary
(`gui/bin/treble-rro-creator-gui`), so those flags work in either place.

## Android

There is no Android app yet, and the desktop binary cannot become one — an APK
needs a Kotlin/Java activity to host a WebView. On Android, use the CLI in
Termux ([termux.md](termux.md)); the module's own WebUI still handles editing
values after install ([webui.md](webui.md)).
