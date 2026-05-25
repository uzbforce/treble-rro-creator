# Treble Overlay Project
# IF YOU INSTALL VIA KSU/N AS A MODULE, DON'T FORGET TO INSTALL MOUNT SYSTEM LIKE MAGIC MOUNT OR OverlayFS
IF YOU ARE HAVING PROBLEMS WITH UNDERSTANDING, INSTALL freebuff CLI, install npm first:
For Debian/Ubuntu: "sudo apt install npm" 
For Arch: "sudo pacman -S npm"

THEN INSTALL freebuff cli:
Debian/Ubuntu/Arch: "npm install -g freebuff"

AND THEN START CLI using "freebuff" SO YOU CAN USE FREE AI CLI TO WORK ON THIS

================ Process ================

Create **Runtime Resource Overlays (RRO)** for Android GSI (Generic System Image) to adapt it to your device.

This project builds a Magisk/KSU module containing:
- **Framework-res overlay** — device-specific resource overrides (display cutout, rounded corners, brightness calibration, auto-brightness curves, UDFPS, 5G/VoLTE, etc.)
- **SystemUI overlay** — SystemUI tweaks (doze/AOD behavior)
- **Vendor HALs** — optional device-specific HAL binaries (fingerprint, vibrator, etc.)

All device-specific settings are in **[`config.env`](config.env)** — edit that file, then run `./build.sh`.

> **Reference device throughout this guide:** Samsung Galaxy A90 5G (SM-A908 / r3q)  
> Snapdragon 855, 6.7" FHD+ Super AMOLED, UDFPS Goodix ET715

---

## 📋 Table of Contents

1. [Quick Start](#-quick-start)
2. [Project Structure](#-project-structure)
3. [How It Works](#-how-it-works)
4. [Customizing for Your Device](#-customizing-for-your-device)
5. [Build Script Reference](#-build-script-reference)
6. [Vendor HALs (Advanced)](#-vendor-hals-advanced)
7. [Troubleshooting](#-troubleshooting)
8. [Safety Guide](#-safety-guide)
9. [Reference: Samsung A90 5G Values](#-reference-samsung-a90-5g-values)

---

## 🚀 Quick Start

### Prerequisites

**Quickest way** — run the setup script (downloads tools locally, no root needed):

```bash
./setup.sh
```

Or install via your package manager:

```bash
# ── Debian / Ubuntu / Linux Mint ──
sudo apt install -y aapt android-sdk-build-tools apksigner android-framework-res

# ── Arch Linux / Manjaro (via AUR) ──
yay -S android-sdk-build-tools android-sdk-platform-tools
# Or use sdkmanager:
#   ./tools/cmdline-tools/bin/sdkmanager --sdk_root=tools/android-sdk "build-tools;35.0.0"

# ── Fedora / RHEL ──
# No official packages — use sdkmanager:
#   ./tools/cmdline-tools/bin/sdkmanager --sdk_root=tools/android-sdk "build-tools;35.0.0"

# ── macOS (Homebrew) ──
brew install --cask android-platform-tools
# Then use sdkmanager for build-tools:
#   ./tools/cmdline-tools/bin/sdkmanager --sdk_root=tools/android-sdk "build-tools;35.0.0"
```

You also need the **Android framework-res APK** for compilation (setup.sh handles this):
- **Option 1:** `sudo apt install android-framework-res` (Debian/Ubuntu)
- **Option 2:** Pull from your device: `adb pull /system/framework/framework-res.apk tools/`
- **Option 3:** From Android SDK: `./tools/cmdline-tools/bin/sdkmanager --sdk_root=tools/android-sdk "platforms;android-35"`

### Build

```bash
# 1. Edit config.env with YOUR device's values
nano config.env

# 2. Build
./build.sh

# Output files (in project root):
#   treble-overlay-<device>.apk           — Framework overlay APK
#   treble-overlay-<device>-systemui.apk  — SystemUI overlay APK (optional)
#   treble-overlay-<device>-ksu.zip        — Flashable KSU/Magisk module
```

> **First run?** If `config.env` doesn't exist, `build.sh` will create one with default values (Samsung A90 5G reference). Edit it to match your device and re-run.

### Deploy

```bash
# Via KernelSU (recommended — persistent across reboots)
adb push treble-overlay-<device>-ksu.zip /sdcard/
adb shell su -c 'ksud module install /sdcard/treble-overlay-<device>-ksu.zip'
adb reboot

# Via Magisk
# Open Magisk app → Modules → Install from storage → select the .zip
```

> ⚠️ **Do NOT push APKs directly to /system/product/overlay/ — they won't persist on dynamic partitions!** Always use the KSU/Magisk module.

### Verify

```bash
# Check overlay is enabled
adb shell cmd overlay list | grep <your-package>

# Look up a specific resource value
adb shell cmd overlay lookup <your-package> android:dimen/rounded_corner_radius

# Check loaded properties
adb shell su -c 'getprop | grep -E "udfps|fingerprint|ims"'
```

---

## 📁 Project Structure

```
├── config.env                        # ← YOUR DEVICE SETTINGS (edit this first!)
├── build.sh                          # Build script (reads config.env)
├── customize.sh                      # KSU install script (SELinux permissions)
├── service.sh                        # Post-boot init (properties, HAL startup)
├── module.prop                       # KSU module metadata (auto-generated)
├── sepolicy.rule                     # SELinux policy extensions (template — add your rules here)
├── sepolicy.rule.example             # Reference: Samsung A90 5G SELinux rules
├── vendor_extraction_guide.md        # Guide for extracting vendor HAL files
├── .gitignore
├── README.md                         # This file
│
├── res/                              # Framework-res overlay resources
│   ├── values/
│   │   ├── config.xml                # Main config: brightness, cutout, UDFPS, radio, IMS
│   │   ├── bools.xml                 # Feature flags: UDFPS, AOD, doze, VoLTE
│   │   ├── dimens.xml                # Corner radius, status bar height
│   │   └── integers.xml              # Auto-brightness levels and curves
│   └── xml/
│       └── power_profile.xml         # Battery power profile
│
├── systemui_overlay/                 # SystemUI overlay (doze/AOD fix)
│   ├── AndroidManifest.xml           # Auto-generated from config.env
│   └── res/values/config.xml         # Doze/DOZE_SUSPEND control
│
├── system/vendor/                    # Vendor HAL binaries (optional, see vendor_extraction_guide.md)
│   ├── bin/hw/                       # Fingerprint, vibrator, etc.
│   ├── lib64/                        # Shared libraries
│   └── etc/
│       ├── init/                     # .rc files for HAL services
│       └── vintf/manifest/           # VINTF manifest fragments
│
├── AndroidManifest.xml               # Framework overlay manifest (auto-generated)
├── Android.mk                        # AOSP build integration
└── keys/
    ├── platform.pk8                  # AOSP platform signing key
    └── platform.x509.pem             # AOSP platform certificate
```

---

## 🧠 How It Works

### Overlay Mechanism

An RRO (Runtime Resource Overlay) is an APK that overrides values in the target package (the Android framework) without modifying the framework itself. At boot, `idmap2` creates a mapping between overlay resources and framework resources.

```
GSI framework-res.apk  ← idmap2 ←  Our overlay APK
(original values)                 (overridden values)
```

The overlay activates when `ro.product.device` matches your codename (set in `config.env`).

### Deployment via KSU Module

GSIs use **dynamic partitions** — `/system/product/overlay/` doesn't persist across reboots. A KSU module works because:
1. KSU stores modules in `/data/adb/modules/<module_id>/`
2. At boot, `bind mount` overlays the module's files onto `/system/product/overlay/`
3. The overlay APK is automatically picked up by the package manager

### Properties vs Settings

A common point of confusion: **system properties** and **global settings** are different namespaces.

| Mechanism | Command | Used for | Persists? |
|-----------|---------|----------|-----------|
| System property | `setprop persist.sys.udfps.custom 1` | Phh-Treble features (UDFPS, IMS, brightness) | ✅ Yes (`persist.*`) |
| Global setting | `settings put global preferred_network_mode 26` | Android framework settings | ✅ Yes |

**Always use `setprop` for Phh-Treble features** — they read from system properties, not global settings.

### Boot Sequence

1. Module installed → `customize.sh` runs: sets SELinux contexts
2. Device boots → `service.sh` runs: enables overlays, starts HALs, sets properties
3. Overlays activated → resources overridden
4. Features working → UDFPS, AOD, brightness, 5G/VoLTE

---

## 🎛 Customizing for Your Device

### 1. Edit config.env (required)

This is the main configuration file. Set:

| Setting | What it controls | Reference (A90 5G) |
|---------|-----------------|--------------------|
| `OVERLAY_NAME` | Output file names, module ID | `treble-overlay-samsung-r3q` |
| `OVERLAY_PACKAGE` | Android package name | `me.phh.treble.overlay.samsung.r3q` |
| `DEVICE_PROP_VALUE` | Device codename for overlay matching | `r3q` |
| `ROUNDED_CORNER_RADIUS` | Display corner radius in pixels | `100` |
| `STATUS_BAR_HEIGHT` | Status bar height in pixels | `76` |
| `HAS_UDFPS` | Under-display fingerprint sensor | `true` |
| `UDFPS_X/Y/RADIUS` | Sensor position on screen | `540`, `2145`, `114` |
| `HAS_AOD` | Always-On Display support | `true` |
| `HAS_5G` / `HAS_VOLTE` | Connectivity features | `true` |

### 2. Edit resource XML files (as needed)

These contain the more complex overrides. The config.env drives simple values; these XML files hold arrays, paths, and detailed config:

| File | What to customize | Reference (A90 5G) |
|------|------------------|--------------------|
| `res/values/dimens.xml` | Corner radius, status bar height | 100px radius, 76px bar |
| `res/values/config.xml` | Display cutout path (SVG), light sensor type, brightness levels, IMS packages | Infinity-U notch SVG, `com.samsung.sensor.physical_light` |
| `res/values/bools.xml` | Feature toggles beyond config.env | UDFPS, AOD, doze, VoLTE, burn-in protection |
| `res/values/integers.xml` | Auto-brightness lux→backlight curve | 28-level curve from stock OneUI |
| `res/xml/power_profile.xml` | Battery drain estimates per component | 4400mAh with SD855 CPU clusters |
| `systemui_overlay/res/values/config.xml` | Doze/AOD sleep behavior | `doze_suspend_display_state_supported=false` |

### 3. Update device match (critical)

The overlay activates based on a system property. By default it matches `ro.product.device`. In `config.env`, set:

```env
DEVICE_PROP_NAME="ro.product.device"
DEVICE_PROP_VALUE="your_device_codename"
```

To find your codename:
```bash
adb shell getprop ro.product.device
```

> **⚠️ Why not ro.vendor.build.fingerprint?** AOSP's `PatternMatcher.PATTERN_SIMPLE_GLOB` does NOT match `/` in file paths. Using glob patterns on the fingerprint (which contains slashes) can fail silently. Using `ro.product.device` with a literal value is **simpler and more reliable**.

### 4. Remove or replace vendor files (optional)

The `system/vendor/` directory contains Samsung A90 5G-specific HAL binaries. If you're building for a different device:
- **Replace** with your own files (see [vendor_extraction_guide.md](vendor_extraction_guide.md))
- **Remove** the `system/vendor/` directory entirely for a pure overlay-only module

The build script **gracefully skips** vendor sections if directories are empty or don't exist.

---

## 🔨 Build Script Reference

### First run (no config.env)

```
$ ./build.sh

  ╔══════════════════════════════════════════════════════╗
  ║           Treble Overlay Builder                     ║
  ╚══════════════════════════════════════════════════════╝

  Device:    Samsung Galaxy A90 5G (SM-A908)
  Codename:  r3q (prop: ro.product.device=r3q)
  Overlay:   treble-overlay-samsung-r3q
  Android:   16 (API 36)

  ━━━ Checking dependencies ━━━
  ✓ All tools found
  ✓ Platform JAR: /usr/share/android-framework-res/framework-res.apk
  ...

  ━━━ Building KSU/Magisk module ━━━
  ━━━ Build mode ━━━
  → No vendor HAL files found — building overlay-only

  ━━━ Building KSU/Magisk module ━━━
  → sepolicy.rule skipped (overlay-only build)
  ✓ service.sh generated with package: me.phh.treble.overlay.samsung.r3q
  → Vendor HAL files skipped (overlay-only build)
  ✓ KSU module packaged

  ╔══════════════════════════════════════════════════════╗
  ║              BUILD COMPLETE ✓                        ║
  ╚══════════════════════════════════════════════════════╝
```

### Build steps (automatic)

1. **Load config.env** — all device settings
2. **Generate manifests** — `AndroidManifest.xml`, `systemui_overlay/AndroidManifest.xml`, `module.prop`
3. **Compile** — `aapt2 compile` resource XML → `.flat` binary
4. **Link** — `aapt2 link` → unsigned APK
5. **Zipalign** — memory alignment optimization
6. **Sign** — `apksigner` with platform key
7. **Package KSU module** — APKs + vendor files + scripts → .zip
8. **Verify** — `apksigner verify` + file sizes

### Output files

| File | Description |
|------|-------------|
| `{OVERLAY_NAME}.apk` | Framework-res overlay — the main overlay APK |
| `{OVERLAY_NAME}-systemui.apk` | SystemUI overlay — only if `systemui_overlay/res/` has content |
| `{OVERLAY_NAME}-ksu.zip` | Flashable module for KSU/Magisk |
| `AndroidManifest.xml` | **Regenerated** from config.env each build |
| `module.prop` | **Regenerated** from config.env each build |

> ⚠️ **AndroidManifest.xml and module.prop are auto-generated!** Edit `config.env` instead of these files directly. Your changes will be overwritten on the next build.

---

## 🧪 Vendor HALs (Advanced)

Some features require proprietary vendor HAL binaries to work on a GSI:
- **Fingerprint sensor** — the GSI's default AOSP HAL may not talk to your device's sensor
- **Vibrator** — Samsung's proprietary vibrator HAL vs AOSP's default
- **Display** — custom display HALs for AOD, HBM, etc.

### How it works

The vendor partition on stock firmware contains:
- HAL binary (e.g., `fingerprint@2.3-service.samsung`)
- Init .rc file (defines the service)
- VINTF manifest fragment (declares the HIDL interface)
- Shared libraries (needed by the binary)
- SELinux policy (allows access to device nodes and sysfs)

When you flash a GSI, **system is replaced but vendor is kept**. However, the GSI doesn't know about your vendor's custom HALs. By shipping them in the KSU module, they get bind-mounted over the vendor partition at boot.

### Extracting from your device

See the full guide: **[vendor_extraction_guide.md](vendor_extraction_guide.md)**

Quick checklist:
```bash
# 1. Check what HALs your device has
adb shell ls -la /vendor/bin/hw/
adb shell ls -la /vendor/etc/init/
adb shell ls -la /vendor/etc/vintf/manifest/

# 2. Identify what's needed (features not working on GSI)
# 3. Extract: binary + .rc + VINTF + libs
# 4. Add SELinux rules to sepolicy.rule
    #    See sepolicy.rule.example for a reference (Samsung A90 5G)
# 5. Update customize.sh for new contexts
# 6. Build and test
```

> **⚠️ WARNING:** Shipping wrong HAL binaries or VINTF manifests can cause **bootloops**. See [Safety Guide](#-safety-guide).

---

## 🔍 Troubleshooting

### Overlay not active (`[ ]` in `cmd overlay list`)

| Cause | Check | Fix |
|-------|-------|-----|
| Condition mismatch | `adb shell getprop ro.product.device` | Update `DEVICE_PROP_VALUE` in config.env |
| APK not installed | `adb shell ls -la /system/product/overlay/` | Re-flash KSU module |
| idmap error | `adb logcat -d \| grep -iE "overlay\|idmap"` | Remove non-existent resources from XML |

### "service 'idmap' died" in logcat

A resource in your overlay doesn't exist in the GSI's framework-res.apk. Check:
```bash
adb shell cmd overlay lookup <your_package> <resource_type>/<resource_name>
```
If it returns an error, the resource doesn't exist in the GSI and should be removed from your overlay.

**Resources verified NOT to exist on A16 GSI:**
- `config_udfps_sensor_props` (use `persist.sys.udfps.*` props instead)
- `config_biometric_sensors` (handle via FP HAL / props)
- `networkAttributes`, `radioAttributes` (use IMS overlay + props)
- `config_carrier_volte_provisioned`
- Various `config_autoBrightness*` arrays (depends on GSI)

### Device bootloops after module install

See [Safety Guide — Bootloop Recovery](#bootloop-recovery).

### Features not working

| Feature | Check this | Common fix |
|---------|-----------|------------|
| Corner radius | `cmd overlay lookup <pkg> android:dimen/rounded_corner_radius` | Confirm overlay is enabled |
| UDFPS/FOD | `adb shell dumpsys fingerprint` | Check `persist.sys.udfps.*` props |
| AOD/Doze | `adb shell dumpsys power \| grep -i doze` | Set `config_displayBlanksAfterDoze=false` |
| Brightness | `adb shell getprop persist.sys.samsung.full_brightness` | Check brightness watchdog in service.sh |
| 5G/VoLTE | `adb shell dumpsys ims` | Enable `slsiims_telephony` overlay |
| Fingerprint authenticating | `adb logcat -d \| grep -i finger` | Check SELinux denials, vendorCode errors |

### Overlay enabled but resources not applying

```bash
# Check if another overlay overrides the same resources at higher priority
adb shell dumpsys overlay | grep -A30 <your_package>
```

---

## 🛡 Safety Guide

### Bootloop Recovery

If your device bootloops after flashing a module:

```bash
# Via recovery
adb reboot recovery
adb shell mount /data
adb shell rm -rf /data/adb/modules/<module_id>
adb shell reboot
```

Replace `<module_id>` with the value of `id=` in your `module.prop` (e.g., `treble-overlay-samsung-r3q`).

### SELinux Denials

SELinux denials are **silent** on many kernels — the device boots but features silently fail. Always check:

```bash
adb logcat -b all -d | grep "avc: denied"
```

Common denial signatures:
```
avc: denied { read write } for pid=... scontext=u:r:hal_fingerprint_default:s0
avc: denied { execute } for pid=... scontext=u:r:init:s0 tcontext=...:hal_fingerprint_default_exec
avc: denied { rw_file_perms } for ... tcontext=...:fingerprint_sensor_device:s0
```

### VINTF Manifest Safety

Adding VINTF manifest fragments from a different device **can cause HAL manager crashes at boot**, which manifests as:
- Complete bootloop (HAL manager can't start)
- Missing HALs (fingerprint, vibrator, camera, etc.)
- System UI crashes

**Only include VINTF fragments from your exact device model.**

### Testing Protocol

1. **Start minimal** — overlay-only (no vendor HALs), verify it boots
2. **Add one HAL at a time** — fingerprint first, test, then vibrator, etc.
3. **Test each change** — flash, reboot, check logcats, verify features
4. **Keep backups** — save working versions before adding new components

---

## 📖 Reference: Samsung A90 5G Values

These are the values used throughout this project for the reference device. Use them as a template for your own device.

### Display

| Parameter | Value | Notes |
|-----------|-------|-------|
| Resolution | 1080×2400 | FHD+ Super AMOLED |
| DPI | 420 | from `ro.sf.lcd_density` |
| Corner radius | 100px | Stock vendor RRO value |
| Status bar height | 76px | Matches waterdrop notch |
| QS offset height | 76px | Must match status bar |
| Refresh rate | 60Hz | Panel max |
| Cutout shape | Infinity-U (waterdrop) | SVG: `M-35.93,0...` |

### UDFPS (Goodix ET715)

| Parameter | Value | Source |
|-----------|-------|--------|
| X position | 540 | Screen center (half of 1080) |
| Y position | 2145 | From device tree overlay |
| Radius | 114 | From device tree overlay |
| Sensor type | Optical in-display | Goodix ET715 |
| HAL bridge | AOSP v2.3 → Samsung v3.0 | `fingerprint@2.3-service.samsung` |

### Brightness

| Parameter | Value | Notes |
|-----------|-------|-------|
| Dim | 15 | Minimum before flicker |
| Dark | 3 | Auto-brightness floor |
| Doze/AOD | 60 | Adjusted up from stock 17 |
| Min/Max | 0–255 | Standard range |
| Default | 128 | Mid-point |
| Auto-brightness levels | 28 | From stock OneUI 4.1 |

### Battery

| Parameter | Value | Notes |
|-----------|-------|-------|
| Capacity (nom) | 4400 mAh | Typical: 4500 mAh |
| CPU | 1×Cortex-A76 + 3×A76 + 4×A55 | Snapdragon 855 |

### Connectivity

| Feature | Status on A90 5G | Mechanism |
|---------|------------------|-----------|
| 5G NR | NSA (LTE+NR) | `slsiims_telephony` overlay + properties |
| VoLTE | Via Samsung IMS | `persist.sys.phh.ims.sec=true` |
| RIL | Samsung libsec-ril.so | IMS via `slsiims_telephony` |

### Critical Doze Configuration

```xml
<!-- SystemUI overlay — prevents DOZE_SUSPEND crash -->
<!-- Without this, Samsung's hwcomposer can't handle DOZE_SUSPEND→DOZE transition
     on GSI, causing: "trackPendingFrame: Invalid present fence" -->
<bool name="doze_suspend_display_state_supported">false</bool>

<!-- Framework overlay — prevents display blanking in doze -->
<bool name="config_displayBlanksAfterDoze">false</bool>
```

### Verified Properties (set in service.sh)

```bash
# UDFPS
setprop persist.sys.udfps.custom 1
setprop persist.sys.udfps.x 540
setprop persist.sys.udfps.y 2145
setprop persist.sys.udfps.size 114
setprop persist.sys.phh.samsung_fingerprint 1

# Brightness
setprop persist.sys.samsung.full_brightness true
setprop persist.sys.qcom-brightness -1
setprop persist.sys.phh.disable_display_doze_suspend true

# 5G / VoLTE
setprop persist.sys.phh.ims.sec true
setprop persist.sys.phh.force_display_5g 1
setprop persist.sys.phh.radio.nr 1
setprop persist.dbg.volte_avail_ovr 1
setprop persist.dbg.allow_ims_off 0

# IMS overlays
cmd overlay enable me.phh.treble.overlay.slsiims_telephony
cmd overlay disable me.phh.treble.overlay.cafims_telephony
```

---

## 📚 Additional Resources

- **[vendor_extraction_guide.md](vendor_extraction_guide.md)** — Detailed guide for extracting vendor HAL binaries
- **[config.env](config.env)** — Your device's configuration file
- **Phh-Treble documentation** — [GitHub: phhusson/treble_experimentations](https://github.com/phhusson/treble_experimentations)

---

*Built for the GSI community. Reference device: Samsung Galaxy A90 5G (SM-A908 / r3q).*
