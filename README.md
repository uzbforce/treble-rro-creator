# Treble RRO Creator

Build a **Magisk / KernelSU / APatch module** that adapts a GSI (Generic System Image) to
your phone's hardware: rounded corners, display cutout, brightness curve, UDFPS,
AOD/doze, 5G/VoLTE — and optional vendor HALs for fingerprint or vibrator.

Two ways in, same tool: the **desktop app**, which puts every setting and the
whole build in a window, or **one command** from a terminal. Both edit the same
`config.env` and run the same build.

```bash
treble-rro-creator.cmd    # Windows: the app (double-click it too)
./treble-rro-creator.sh   # Linux: the app
./build.sh                # or just build: Linux / Termux / Git Bash
build.cmd                 #                 Windows
```

The first run installs the Android build tools automatically (about 33 MB on
disk; on Linux it uses your package manager when permitted, and otherwise
prints the exact command to run). Every later run goes straight to the build.

---

## Requirements

| Platform | What you need |
|---|---|
| **Windows** | [Git for Windows](https://git-scm.com/download/win) + JDK 17 or newer (`winget install EclipseAdoptium.Temurin.17.JDK`) |
| **Linux** | `bash`, `curl`, `unzip`, `zip` and JDK 17+. `./build.sh` can install the rest with your package manager, or use `./build.sh setup` |
| **Termux** | Termux from **F-Droid** (not Google Play). See [docs/termux.md](docs/termux.md) |
| **Phone** | A GSI-based ROM and a root manager (KernelSU, KSU Next, APatch or Magisk) |

---

## Quick start

### Desktop app (Windows / Linux)

The window is the same tool: it finds the clone it lives in, edits `config.env`,
and runs the same `build.sh` commands — **Build**, **Dry run**, **Check**,
**Doctor**, **Setup**, **Clean** — with the output streaming into a pane.
Nothing is reimplemented, so the app and the CLI can be mixed freely.

It also covers what used to need a terminal: `config.env` as a form (a switch
per setting, ⓘ for the note the file already carries, the raw file one click
away); a **Device** tab with an adb console, the commands worth running on a
phone, and a button that installs platform-tools if you do not have them; and a
**Files** tab that is the `src/` workspace — drop a vendor HAL tree in, disable
a file out of the build without deleting it, and write the SELinux rules and
VINTF manifests a custom HAL needs, checked as you type. The header tells you
when a newer release exists, and an update that would overwrite your own edits
asks first and backs them up.

```bash
git clone https://github.com/uzbforce/treble-rro-creator
cd treble-rro-creator
./treble-rro-creator.sh   # Linux   — builds itself first (Go and missing GTK/WebKitGTK headers are installed for you)
treble-rro-creator.cmd    # Windows — double-clickable, no console left open; Go is downloaded, MinGW gcc needed once
```

The first launch builds it and says what is missing if anything is. **Setup**,
and the first build, install the Android tools with the distro's package
manager — when sudo asks for a password, the app asks for it in a dialog and
repeats the command, so nothing has to be typed into a terminal. Later launches
open straight away, and a `git pull` only triggers a rebuild when the Go
sources actually changed. Full guide, including what each button does and what
to do when no window appears: [docs/gui.md](docs/gui.md).

### Windows (command line)

1. Install **Git for Windows** and **JDK 17+**.
2. Clone or download this project.
3. Double-click **`build.cmd`**.

From a terminal (cmd, PowerShell, VS Code) run `build.cmd` — from PowerShell use
`.\build.cmd`. Do **not** run the `.sh` files in a WSL terminal on a Windows
drive; see [docs/windows.md](docs/windows.md) for why and what to do instead.

### Linux

```bash
git clone https://github.com/uzbforce/treble-rro-creator
cd treble-rro-creator
./build.sh
```

### Termux

```bash
pkg install -y git
cd ~ && git clone https://github.com/uzbforce/treble-rro-creator
cd treble-rro-creator
./build.sh
```

Full Termux walkthrough: [docs/termux.md](docs/termux.md).

---

## Configure your device

Open `config.env`. Only a few values are required:

| Setting | What it is | How to find it |
|---|---|---|
| `DEVICE_CODENAME` | Device codename, e.g. `r3q` | `adb shell getprop ro.product.device` |
| `DEVICE_MANUFACTURER` | Manufacturer, e.g. `samsung` | `adb shell getprop ro.product.manufacturer` |
| `DEVICE_MODEL` | Model name, e.g. `SM-A908N` | `adb shell getprop ro.product.model` |
| `DEVICE_PROP_NAME` | Property the overlay matches | `persist.sys.overlay.<codename>` (set by the module), or empty for no condition |
| `DEVICE_PROP_VALUE` | Value the overlay matches | `true` for a `persist.sys.*` property |
| `ROUNDED_CORNER_RADIUS` | Screen corner radius in px | Measure or take from your stock overlay |
| `STATUS_BAR_HEIGHT` | Status bar height in px | Take from your stock overlay |

Everything else is optional and documented in
[docs/configuration.md](docs/configuration.md).

> **First run without `config.env`?** `build.sh` offers the example config
> (Samsung A90 5G) or writes a placeholder and tells you what to edit.
>
> **`power_profile.xml` matters.** Replace
> `src/framework/res/xml/power_profile.xml` with your device's file —
> see [docs/device-extraction.md](docs/device-extraction.md#power-profile-power_profilexml--mandatory).
> Until you do, the empty template is detected and **left out** of the APK
> instead of wiping the GSI's battery and CPU data.

---

## Commands

`build.sh` and `build.cmd` are the only entry points. Everything else in the
project is called by them.

| Command | What it does |
|---|---|
| `./treble-rro-creator.sh` / `treble-rro-creator.cmd` | **Open the desktop app** — the window for everything below. Builds it on the first run, then just launches it. |
| `./build.sh` | Build. Installs missing tools first. |
| `./build.sh setup` | Install or repair the toolchain (menu: distro / resource version) |
| `./build.sh doctor` | Check the toolchain, install nothing (exit 0 = ready) |
| `./build.sh check` | Validate `config.env`, build nothing |
| `./build.sh --dry-run` | Print the resources `config.env` emits, build nothing |
| `./build.sh clean` | Remove `stuff/build/` and `out/` |
| `./build.sh clean --all` | Start over for a different device (restores templates) |

Options: `-y` / `--yes` (no prompts), `--with-vendor-hals` (with `--yes`),
`--dry-run` (resource plan only), `--allow-unknown-resources` (build even when a
resource is missing from the dictionary — see the audit note below), `--force`
(with `setup`: re-pick the resource dictionary), `--help`.

`--dry-run` is the fast feedback loop: it generates the resource XML from
`config.env` and prints every resource it would emit (type, name, value, which
overlay APK), without aapt2, signing or packaging. `check` reports the same
config warnings and stops there.

To check the project itself (the WebUI's resource-table writer, the manifest it
renders from, script syntax, documentation anchors):

```bash
bash stuff/tests/run.sh    # what CI runs, no Android tools needed
```

On Windows, use the same words with `build.cmd`:
`build.cmd setup`, `build.cmd doctor`, `build.cmd clean --all`.

---

## Output

Everything is written to `out/`:

| File | Purpose |
|---|---|
| `out/apks/<name>.apk` | Framework overlay (signed) |
| `out/apks/<name>-systemui.apk` | SystemUI overlay (signed, if used) |
| `out/<name>-ksu.zip` | **Module zip** — install this in any supported manager |
| `out/<name>-hardware-overlay.zip` | Sources to submit to the Doze-off overlay repo |
| `out/<name>-hardware-overlay-test.zip` | Test build of the repo version |

Install `out/<name>-ksu.zip` in KernelSU, KSU Next, APatch or Magisk and reboot.

### Getting it built into the GSI (no module)

`out/<name>-hardware-overlay.zip` is the source tree the
[Doze-off overlay repo](https://github.com/Doze-off/vendor_hardware_overlay)
compiles into the GSI builds: submit it as a pull request (base branch `pie`)
and the device gets the overlay with no module to install or update. The zip
contains the exact folders, the `overlay.mk` lines and a `HOW-TO-SUBMIT.md`
filled in for your device; read **[docs/submission.md](docs/submission.md)**
first — the wiki's `+*brand/model*` match pattern never matches anything, and
this project writes the exact value instead.
The zip is a standard module: the same file works in all four managers (the
`-ksu` suffix is historical; it is not KernelSU-only). It contains the normal
`customize.sh` that KSU/APatch source and Magisk's `META-INF` installer, plus
the shared `webroot/` page.

> ⚠️ **KernelSU / KSU Next:** use **Magic Mount** (or Hybrid Mount with magic
> mount). **Do not use OverlayFS** — it can bootloop the device.
>
> ⚠️ Do not copy APKs into `/system/product/overlay/` by hand. Dynamic
> partitions do not keep them, and they miss the permissions the module sets.

### Live editing (module WebUI)

The module ships a page under `webroot/`. Open the module and tap **WebUI** to
change the corner radius, status bar height/padding and a few toggles, then
apply them **without rebuilding or reflashing**: the page writes the value into
`resources.arsc` of the overlay APK that is already installed (a pristine copy
is kept for **Reset**) and restarts the framework so it is read. A value the
build did not ship — `config.env` leaves the optional padding keys commented
out — is added to that table first, so a commented-out key no longer blocks the
sliders. That is the only way to set a dimension at runtime —
`cmd overlay fabricate` rejects the dimension type outright, so it is only used
for the doze boolean.

- **KernelSU / KSU Next / APatch:** built in — the module page has a WebUI
  button.
- **Magisk:** the official app has no WebUI. Open the same page with a WebUI
  host such as **WebUI X** (MMRL / portable), **KsuWebUI** or **MMRL**. They
  provide a root exec bridge that the page detects, so the page and helper are
  shared by every manager.

Below the five sliders, **All resources** lists everything else the build
writes — booleans, integers, strings and the remaining dimens — from
`webui-manifest.json`, which `build.sh` generates from the same XML it compiles.
Values that are not one value (auto-brightness arrays, landscape-only configs,
`power_profile.xml`) are shown read-only and still need a rebuild.

Two safety nets: saved values survive a module update (they re-apply onto the
new APKs the next time the page is opened), and if a patch ever prevents a
complete boot the next boot restores the build's APKs automatically. Details
and limits: [docs/webui.md](docs/webui.md).

Both overlays are **static** RROs: Android enables them during boot, and
`cmd overlay enable` cannot change them afterwards. Verify after reboot:

```bash
adb shell cmd overlay list | grep <your-package>
adb shell cmd overlay lookup <your-package> android:dimen/rounded_corner_radius
adb shell cmd overlay lookup <your-package> android:dimen/status_bar_height_default
```

Every build also writes `out/<name>-overrides.txt`, listing each resource as
`APPLIES` or `IGNORED` against the target framework. If a generated name does
not exist in the target, the build refuses to continue — a resource Android
does not recognise is silently ignored, which is how an overlay can look
correct and change nothing.

The status bar uses `status_bar_height_default` (Android 12L+), not the old
`status_bar_height`; both are generated, including a landscape variant. See
[docs/configuration.md](docs/configuration.md#status-bar-height).

---

## Project layout

```
.
├── build.sh / build.cmd        ← the command line
├── treble-rro-creator.sh/.cmd  ← desktop app: build if stale, then launch
├── config.env                  ← your device settings (created on first run)
├── config.env.example          ← filled-in Samsung A90 5G example
├── src/
│   ├── framework/res/          framework overlay resources (+ power_profile.xml)
│   ├── systemui/res/          SystemUI overlay resources
│   ├── module/                 optional overrides + sepolicy.rule
│   ├── webui/                  shared WebUI page + apply.sh (packed as webroot/)
│   └── vendor/                 optional extracted vendor HALs (git-ignored)
├── docs/                       guides
├── out/                        APKs and flashable zips (git-ignored)
├── gui/                        desktop app sources (+ go.mod at the root)
└── stuff/                      everything the build uses and you do not
    ├── scripts/                internals used by build.sh (not run directly)
    ├── templates/              reference scripts + clean templates
    ├── keys/                   platform signing key (shipped)
    ├── windows/                helpers for build.cmd
    ├── tests/                  the checks CI runs
    ├── tools/                  downloaded toolchain (git-ignored)
    ├── build/                  intermediate files (git-ignored)
    └── backups/                copies made before clean/rebuild (git-ignored)
```

The root keeps only what you act on: the two entry points, `config.env`, `src/`
(the resources you edit), `docs/`, `gui/` and `out/` (where the APKs and zips
appear). Everything else moved into `stuff/` — one folder instead of nine. The
signing key, the templates, the tests and the downloaded toolchain all keep
their own names there, so `keys/platform.pk8` became
`stuff/keys/platform.pk8`.

---

## Coming from an older version?

The scripts were merged and the folders reorganised. Old commands and files
still work like this:

| You used to run | Run now |
|---|---|
| `./setup.sh` / `setup.cmd` | `./build.sh setup` / `build.cmd setup` |
| `./setup.sh --doctor` / `setup.cmd --doctor` | `./build.sh doctor` / `build.cmd doctor` |
| `./cleanup.sh` / `cleanup.cmd` | `./build.sh clean` / `build.cmd clean` |
| `./build.sh` / `build.cmd` | unchanged |

| Old location | New location |
|---|---|
| `res/` | `src/framework/res/` |
| `systemui_overlay/res/` | `src/systemui/res/` |
| `customize.sh`, `service.sh`, `sepolicy.rule` | `src/module/` (scripts are generated by default) |
| `system/vendor/` | `src/vendor/` |
| `TEMPLATE RECOVERIES (Don't touch)/` | `stuff/templates/recoveries/` (fallback for `clean --all` when there is no `.git`) |
| `YOUR BACKUPS/` | `stuff/backups/` |
| `keys/`, `scripts/`, `templates/`, `tests/`, `windows/`, `tools/`, `build/`, `backups/` | the same names inside `stuff/` |

`build.sh` moves anything it still finds in the old places into the new layout
on the next run: the file is copied first and the old location is removed only
afterwards, so an existing checkout keeps working after a `git pull`. If both
locations exist, it warns and leaves the old one alone instead of overwriting
the new one.

---

## Documentation

| Guide | Contents |
|---|---|
| [docs/submission.md](docs/submission.md) | Getting the overlay built into the GSI (Doze-off repo PR) |
| [docs/configuration.md](docs/configuration.md) | Every `config.env` option |
| [docs/webui.md](docs/webui.md) | KernelSU WebUI: change values without rebuilding |
| [docs/windows.md](docs/windows.md) | Windows, PowerShell, VS Code and WSL |
| [docs/termux.md](docs/termux.md) | Building on the phone |
| [docs/device-extraction.md](docs/device-extraction.md) | Extracting vendor HALs and `power_profile.xml` |
| [docs/udfps.md](docs/udfps.md) | Finding UDFPS coordinates |
| [docs/troubleshooting.md](docs/troubleshooting.md) | Doctor, bootloops, SELinux, overlay inactive |
| [docs/how-it-works.md](docs/how-it-works.md) | RROs, module mechanics, build steps |

---

*Built for the GSI community. Reference device: Samsung Galaxy A90 5G (SM-A908N / r3q).*

MIT licensed — see [LICENSE](LICENSE).
