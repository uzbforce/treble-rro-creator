<p align="center">
  <img src="assets/icon.png" width="120" alt="Treble RRO Creator">
</p>

<h1 align="center">Treble RRO Creator</h1>

<p align="center">Builds the overlay module that teaches a GSI about your phone's screen, brightness curve and fingerprint sensor.</p>

<p align="center">
  <a href="https://github.com/uzbforce/treble-rro-creator"><img alt="Platform" src="https://img.shields.io/badge/platform-Windows%20%7C%20Linux%20%7C%20Termux-B93D0E?style=flat-square"></a>
  <a href="docs/configuration.md"><img alt="Settings" src="https://img.shields.io/badge/config-one%20env%20file-B93D0E?style=flat-square"></a>
  <a href="#output"><img alt="Output" src="https://img.shields.io/badge/output-flashable%20module-B93D0E?style=flat-square"></a>
  <a href="LICENSE"><img alt="License" src="https://img.shields.io/badge/license-MIT-1F2328?style=flat-square"></a>
</p>

---

A GSI boots generic: square screen corners, no cutout, a brightness curve written for some other panel, and an in-display fingerprint reader it cannot locate. This project writes a static RRO with the real values and packs it into one zip you install with Magisk, KernelSU / KSU Next or APatch.

Two front ends run the same build off the same `config.env`:

| | Windows | Linux | Termux |
|---|---|---|---|
| **Desktop app** | `treble-rro-creator.cmd` | `./treble-rro-creator.sh` | not available |
| **Terminal menu** | `build.cmd` | `./build.sh` | `./build.sh` |

The app has tabs for Build, config.env, Addons, Device (adb console), Auto Detect, UDFPS, Files and Docs. The menu offers the same jobs as numbered choices, and it is the whole interface on Termux or over ssh.

## Quick start

```bash
git clone https://github.com/uzbforce/treble-rro-creator
cd treble-rro-creator
./build.sh          # Linux, Termux, Git Bash  → terminal menu
```

```bat
build.cmd           :: Windows               → terminal menu
```

1. `2` config.env — fill in codename, manufacturer, model, corner radius, status bar height.
2. `5` Auto Detect, `6` UDFPS, `7` Match property — read those numbers off the phone instead of guessing.
3. `1` → `2` Build. The module lands in `out/`.

The first run installs what is missing: aapt2, zipalign, apksigner, Java and the `framework-res.apk` resource dictionary. Later runs skip straight to the menu.

Full walkthroughs: [docs/gui.md](docs/gui.md) · [docs/windows.md](docs/windows.md) · [docs/termux.md](docs/termux.md).

## Requirements

| Platform | Needs |
|---|---|
| **Windows** | [Git for Windows](https://git-scm.com/download/win) and JDK 17+ (`winget install EclipseAdoptium.Temurin.17.JDK`) |
| **Linux** | `bash`, `curl` or `wget`, `unzip`, `zip`, JDK 17+ — `./build.sh setup` installs the rest |
| **Termux** | Termux from **F-Droid**, not Google Play; `pkg install git`, then `./build.sh` |
| **Phone** | A GSI-based ROM and any of Magisk, KernelSU, KSU Next, APatch |

Root is only needed on Termux, where the phone probes read the device the tool is running on (`tsu ./build.sh`).

## What it configures

| Area | Settings |
|---|---|
| Screen shape | `ROUNDED_CORNER_RADIUS`, `DISPLAY_CUTOUT`, waterfall edges |
| Status bar | `STATUS_BAR_HEIGHT`, landscape variant, paddings, privacy dot |
| Brightness | dim / dark / doze / min / max, auto-brightness, `power_profile.xml` |
| Display timing | `DEFAULT_REFRESH_RATE`, `PEAK_REFRESH_RATE`, AOD, doze, burn-in protection |
| Fingerprint | `HAS_UDFPS`, `UDFPS_X` / `_Y` / `_RADIUS`, Samsung FOD, optional vendor HAL |
| Radios and extras | `HAS_5G`, `HAS_VOLTE`, double-tap-to-wake |
| Module only | addons (`src/module/addons.conf`), live WebUI page, `sepolicy.rule`, VINTF fragments |

Every key, its default and accepted values: [docs/configuration.md](docs/configuration.md).

## config.env

Required:

| Key | Example | Where it comes from |
|---|---|---|
| `DEVICE_CODENAME` | `r3q` | `adb shell getprop ro.product.device` |
| `DEVICE_MANUFACTURER` | `samsung` | `getprop ro.product.manufacturer` |
| `DEVICE_MODEL` | `SM-A908N` | `getprop ro.product.model` |
| `DEVICE_PROP_NAME` | `persist.sys.overlay.r3q` | set by the module; leave empty for an unconditional overlay |
| `DEVICE_PROP_VALUE` | `true` | value the key above must equal |
| `ROUNDED_CORNER_RADIUS` | `135` | stock overlay, or measured on the screen |
| `STATUS_BAR_HEIGHT` | `113` | stock overlay, or `dumpsys window` |

Everything else has a default and can be left alone.

Two things worth knowing before the first build:

- **`src/framework/res/xml/power_profile.xml` must be yours.** Until you replace it, the empty template is detected and left out of the APK rather than overwriting the GSI's battery and CPU data. See [docs/device-extraction.md](docs/device-extraction.md#power-profile-power_profilexml--mandatory).
- **No `config.env` yet?** The first run offers the filled-in Samsung A90 5G example (`config.env.example`) or writes a placeholder that says what to edit.

## Commands

| Command | Does |
|---|---|
| `./build.sh` | Terminal menu; a plain build when there is no terminal |
| `./build.sh build` | Build, installing missing tools first |
| `./build.sh setup` | Install or repair the toolchain |
| `./build.sh doctor` | Check the toolchain, change nothing (exit 0 = ready) |
| `./build.sh check` | Validate `config.env`, build nothing |
| `./build.sh --dry-run` | Print every resource the config emits, build nothing |
| `./build.sh clean` | Remove `stuff/build/` and `out/` |
| `./build.sh clean --all` | Start over for a different device (restores templates) |
| `./build.sh menu` | Force the menu when there is no terminal |

Flags: `-y` / `--yes`, `--with-vendor-hals`, `--allow-unknown-resources`, `--force` (with `setup`), `--help`. Same words on Windows with `build.cmd`.

`--dry-run` is the fast loop: it prints type, name, value and target APK for each resource without aapt2, signing or packaging.

To check the project itself (scripts, resource writer, docs anchors), run `bash stuff/tests/run.sh` — this is what CI runs, and it needs no Android tools.

## Output

| File | Use |
|---|---|
| `out/<name>-ksu.zip` | **The module.** Install in Magisk, KernelSU, KSU Next or APatch, then reboot |
| `out/apks/<name>.apk` | Signed framework overlay |
| `out/apks/<name>-systemui.apk` | Signed SystemUI overlay, when generated |
| `out/<name>-hardware-overlay.zip` | Source tree to submit to the [Doze-off overlay repo](https://github.com/Doze-off/vendor_hardware_overlay) |
| `out/<name>-hardware-overlay-test.zip` | Test module for that source tree |
| `out/<name>-overrides.txt` | Every resource marked `APPLIES` or `IGNORED` against the target framework |

The `-ksu` suffix is historical; the zip is a standard module and works in all four managers. To copy the build to `/sdcard/treble-rro-creator`, use `8` Files → `1` Copy.

> **KernelSU / KSU Next:** mount with Magic Mount, or Hybrid Mount in magic mode. OverlayFS mounts fine but turns one bad `sepolicy.rule` or VINTF fragment into a bootloop. Reasoning in [docs/how-it-works.md](docs/how-it-works.md#the-flashable-module).

Two more things the build will not do for you: do not copy the APKs into `/system/product/overlay/` by hand (dynamic partitions drop them and the module's permissions are missing), and expect the overlays to be static — Android enables them at boot, `cmd overlay enable` changes nothing afterwards.

## After installing

**WebUI.** The module carries a page in `webroot/`. Open it from the manager (KernelSU, KSU Next, APatch) and change corner radius, status bar height or paddings without rebuilding: it writes the value into `resources.arsc` of the installed APK and restarts the framework. Magisk needs a WebUI host such as WebUI X, KsuWebUI or MMRL. Notes: [docs/webui.md](docs/webui.md).

**Addons.** Tweaks that are not `config.env` keys: volume panel side, keep-screen-on, hide clock, 180° rotation, notch masking. Pick them in the app under Addons; live ones are re-applied on boot, overlay ones are written into the APK. List: [docs/addons.md](docs/addons.md).

**Submitting to the GSI.** `out/<name>-hardware-overlay.zip` contains the folders, the `overlay.mk` lines and a filled-in `HOW-TO-SUBMIT.md`. Read [docs/submission.md](docs/submission.md) before the pull request — the wiki's `+*brand/model*` pattern never matches, and the zip writes the exact property value instead.

Verify an active overlay:

```bash
adb shell cmd overlay list | grep <your-package>
adb shell cmd overlay lookup <your-package> android:dimen/rounded_corner_radius
```

## Project layout

| Path | Holds |
|---|---|
| `build.sh`, `build.cmd` | Entry point: menu and build |
| `treble-rro-creator.sh`, `.cmd` | Desktop app; builds itself first |
| `config.env` | Your device values |
| `src/framework/res/`, `src/systemui/res/` | Overlay resources you edit |
| `src/module/` | Module overrides, `sepolicy.rule`, `addons.conf` |
| `src/webui/` | WebUI page and `apply.sh`, packed as `webroot/` |
| `src/vendor/` | Extracted vendor HALs, optional and git-ignored |
| `out/` | APKs, zips, override report (git-ignored) |
| `gui/` | Desktop app sources (GTK + WebKit, Go) |
| `docs/` | Guides |
| `stuff/` | Scripts, templates, signing key, tests, downloaded tools, build scratch |

## Docs

| Guide | Covers |
|---|---|
| [configuration.md](docs/configuration.md) | Every `config.env` key |
| [detect.md](docs/detect.md) | Reading cutout, corners, status bar, refresh rate |
| [udfps.md](docs/udfps.md) | Fingerprint coordinates and touch-panel FOD mode |
| [addons.md](docs/addons.md) | Module tweaks |
| [webui.md](docs/webui.md) | Editing values after install |
| [submission.md](docs/submission.md) | Getting the overlay into the GSI |
| [device-extraction.md](docs/device-extraction.md) | Vendor HALs and `power_profile.xml` |
| [gui.md](docs/gui.md) | Desktop app |
| [windows.md](docs/windows.md) | Windows, PowerShell, WSL |
| [termux.md](docs/termux.md) | Building on the phone |
| [troubleshooting.md](docs/troubleshooting.md) | Build failures, bootloops, inactive overlays |
| [how-it-works.md](docs/how-it-works.md) | RRO mechanics and build steps |

## Upgrading from an older layout

`build.sh` moves anything it finds in the old paths (`res/`, `systemui_overlay/res/`, `YOUR BACKUPS/`, root-level `scripts/` and friends) into the current ones on the next run, copying first and deleting afterwards. Old commands map straight across: `setup.sh` → `build.sh setup`, `setup.sh --doctor` → `build.sh doctor`, `cleanup.sh` → `build.sh clean`.

---

Reference device: Samsung Galaxy A90 5G (SM-A908N / `r3q`). MIT licensed — see [LICENSE](LICENSE).