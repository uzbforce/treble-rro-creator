# Treble Overlay Project

# 🧠 MANDATORY REQUIREMENT: AT LEAST ONE FUNCTIONAL BRAINCELL 🧠
> **STOP.** If you are about to DM the developer or complain in the chat without reading this guide, **DON'T.**  
> 99% of your "issues" are caused by not following the instructions below. **READ THE ENTIRE GUIDE BEFORE ASKING QUESTIONS.**

---

> 💡 **New to RRO overlays?** This tool generates a Magisk/KSU module that adapts a GSI to your device's hardware. Just edit `config.env` and run `./build.sh`.

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

## Termux (Android) Master Guide
Building RROs straight on your phone is now supported. ARM Branch is for termux

**Important:** Do NOT use /sdcard. You MUST clone to the internal home directory.

1. **Install Termux:** [F-Droid version](https://f-droid.org/en/packages/com.termux/) is required for the latest build tools, **DO NOT USE TERMUX FROM GOOGLE PLAY**.

   Run these commands one by one. **Do NOT skip steps.**
   ```bash
   termux-setup-storage
   
   # Update repositories (MANDATORY)
   apt update
   
   # Upgrade existing packages
   apt upgrade -y
   
   # Install build dependencies (Use apt, NOT pkg)
   apt install git aapt2 apksigner android-tools openjdk-17 unzip zip curl tsu -y
   ```
3. **Download Project:**
   ```bash
   cd ~
   git clone -b main https://github.com/uzbforce/treble-rro-creator
   cd treble-rro-creator
   chmod +x *.sh
   ```
4. **Setup & Build:**
   ```bash
   ./setup.sh  # Selection [3], then Choose Option [1] (Android 13 - Recommended)
   ```
   Configure `config.env` using mtmanager (`/data/data/com.termux/files/home/treble-rro-creator/`), or using:
   ```bash
   nano config.env
   ```
   > 💡 **Nano Tip:** After editing, press `Ctrl+O` followed by `Enter` to save, then `Ctrl+X` to exit.

   Then Build:
   ```bash
   ./build.sh
   ```
5. **Install:**
   You can either manually copy the ksu module manually via mtmanager with the path given above or:
   ```bash
   cp out/*.zip /sdcard/
   ```
   Install Meta magic mount rs module first and reboot if installin via KSU/N.
   Flash the copied zip file in your root manager app and reboot.
---

## PC Installation

### Tools
Install via your package manager:

```bash
# Debian / Ubuntu / Linux Mint
sudo apt install -y aapt android-sdk-build-tools apksigner android-framework-res

# Arch Linux / Manjaro
# Install basics: sudo pacman -S android-tools jdk-openjdk
# Then run ./setup.sh to get aapt2/apksigner via local download or AUR
```

### Resource Dictionary (framework-res.apk)
You need a reference file so `aapt2` can find system IDs. **Android 13** is the most stable version for this purpose. 

> ⚠️ **Warning:** Pulled files from your phone often fail because they are "optimized" (resources stripped) by the manufacturer. **Always use the download option.**

**Recommended:** Run `./setup.sh` and choose the **Download Android 13** option. It works on both PC and Termux.

---

## 🛠️ Build & Deploy

```bash
# 1. Edit config.env with YOUR device's values
nano config.env
```
> 💡 **Nano Tip:** Press `Ctrl+O` then `Enter` to save, and `Ctrl+X` to exit.

```bash
# 2. Build
./build.sh

# Output files (in out/):
#   out/apks/<device>.apk                     — Framework overlay APK (signed)
#   out/apks/<device>-systemui.apk            — SystemUI overlay APK (signed, optional)
#   out/<device>-ksu.zip                      — Flashable KSU/Magisk module
#   out/<device>-hardware-overlay.zip         — Source-based overlay for GSI repos
```

### 🌐 Treble Hardware Overlay Repository Support **(EXPERIMENTAL FOR NOW)**

This tool can also generate a package compatible with the [Treble Hardware Overlay Repo](https://github.com/Doze-off/vendor_hardware_overlay). This is useful for contributing your device's overlay to be included in GSIs by default.

- **Output:** `{OVERLAY_NAME}-hardware-overlay.zip`
- **Structure:** `Manufacturer/Codename/` containing `Android.mk`, `AndroidManifest.xml`, and the `res/` folder.
- **Usage:** Extract the zip and copy the manufacturer folder into your clone of the hardware overlay repository to submit a Pull Request.

---

> **First run?**
 If you haven't edited `config.env` yet, `build.sh` will create rro with **generic** values. And config.env.example contains example values.

### Deploy

> ⚠️ **IMPORTANT (KernelSU / KSU Next Users):**  
> If you are using KernelSU or KSU Next, you **MUST** install a mount system like **Magic Mount** (or similar) to make overlays work. Without it, the APK will not be placed in `/system/product/overlay/` correctly and will not activate.
>
> ❌ **DO NOT use 'OverlayFS'** — this has a high chance of causing a **BOOTLOOP**. OverlayFS is dangerous for SELinux policies and VINTF manifests as a module
```bash
# Via KernelSU (recommended — persistent across reboots)
# 1. Open KernelSU App → Modules → Install from storage → select the .zip
# OR via CLI:
adb push out/treble-overlay-<device>-ksu.zip /sdcard/
adb shell su -c 'ksud module install /sdcard/treble-overlay-<device>-ksu.zip'
adb reboot

# Via Magisk
# Open Magisk app → Modules → Install from storage → select the .zip
```

> ⚠️ **Do NOT push APKs directly to /system/product/overlay/ — they won't persist and won't have enough permissions!** Always use the KSU/Magisk module.

### Verify
Just take a look at the corner roundness during animations, brightness etc

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
├── config.env.example                # Reference example (Samsung A90 5G)
├── build.sh                          # Build script (reads config.env)
├── setup.sh                          # Tool installer (aapt2, zipalign, framework-res)
├── cleanup.sh                        # Build artifact cleaner
├── customize.sh                      # KSU install script (auto-generated if not present)
├── service.sh                        # Post-boot init (auto-generated if not present), You can edit and add extra tweaks if you know what you're doing.
├── sepolicy.rule                     # SELinux policy (template for vendor HALs)
├── vendor_extraction_guide.md        # Guide for extracting vendor HAL files
├── README.md                         # This file
│
├── res/                              # Framework-res overlay resources
│   ├── values/
│   │   ├── config.xml                # Universal AOSP defaults only
│   │   ├── bools.xml                 # Universal bools (nav bar, hotswap, etc.)
│   │   ├── generated.xml             # ⚡ Auto-generated from config.env (DO NOT EDIT)
│   │   └── integers.xml              # Auto-brightness arrays (replace with stock)
│   └── xml/
│       └── power_profile.xml         # Replace with your stock power profile
│
├── systemui_overlay/                 # SystemUI overlay (doze/AOD behavior)
│   ├── AndroidManifest.xml           # Auto-generated
│   └── res/values/
│       ├── config.xml                # Universal doze defaults
│       └── generated.xml             # ⚡ Auto-generated from config.env
│
├── system/vendor/                    # Vendor HAL binaries (optional)
│   ├── bin/hw/                       # Fingerprint, vibrator HALs
│   ├── lib64/                        # Shared libraries
│   └── etc/init/ + vintf/manifest/   # Init .rc + VINTF fragments
│
├── out/                              # Build output directory
│   ├── apks/                         # Signed APKs
│   └── *.zip                         # Flashable modules
├── keys/
│   ├── platform.pk8                  # AOSP platform signing key
│   └── platform.x509.pem             # AOSP platform certificate
├── AndroidManifest.xml                # Auto-generated
├── Android.mk                         # AOSP build integration
```

---

## 🧠 How It Works

### Overlay Mechanism

A RRO (Runtime Resource Overlay) is an APK that overrides values in the target package (the Android framework) without modifying the framework itself. At boot, `idmap2` creates a mapping between overlay resources and framework resources.

```
GSI framework-res.apk  ← idmap2 ←  Our overlay APK
(original values)                 (overridden values)
```

The overlay activates when `ro.product.device` or `ro.product.vendor.device` matches your codename (set in `config.env`).

### Deployment via KSU Module

GSIs use **dynamic partitions** — `/system/product/overlay/` doesn't persist across reboots. A KSU module works because:
1. KSU stores modules in `/data/adb/modules/<module_id>/`
2. At boot, `bind mount` overlays the module's files onto `/system/product/overlay/`
3. The overlay APK is automatically picked up by the package manager
4. And it will give the overlay apks required permissions

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

### 2. Apply device-specific values from config.env (recommended)

Most device values are set directly in `config.env`. See the file for all available options.

**Comment out** any value with `#` to skip it — build.sh will not generate that resource.

### 3. Extract stock overlay APKs for advanced values (optional)

For values beyond config.env (power profile, auto-brightness curves, biometric sensors, radio config), extract from your **stock overlay APKs** following the [TrebleDroid guide](https://github.com/TrebleDroid/treble_experimentations/wiki/How-to-create-an-overlay%3F):

```bash
# 1. Pull the stock overlay APKs from your device
adb pull /system/product/overlay/framework-res__auto_generated_rro_product.apk
adb pull /system/vendor/overlay/framework-res__auto_generated_rro_vendor.apk

# 2. Decompile with apktool
apktool d framework-res__auto_generated_rro_product.apk -o product/
apktool d framework-res__auto_generated_rro_vendor.apk -o vendor/

# 3. Compare product vs vendor — only keep what's DIFFERENT or missing in vendor
#    (these are product-specific values that get LOST when flashing a GSI)
```

| Where to put it | What values | How |
|----------------|------------|-----|
| `config.env` (OPTIONAL STOCK VALUES) | Simple bools, strings, integers (radio, power decouple, etc.) | Uncomment the matching variable |
| `config.env` (OPTIONAL STOCK VALUES) | Auto-brightness arrays | Set `AUTO_BRIGHTNESS_LEVELS` and `AUTO_BRIGHTNESS_BACKLIGHT_VALUES` (space-separated) |
| `res/xml/power_profile.xml` | CPU/battery power profile from `product/res/xml/` | Replace the file entirely |
| `res/values/config.xml` (bottom section) | Any other values not in config.env | Place in the marked section |

> 💡 **Only include values that differ between product and vendor overlays.**
> If a value exists in BOTH, the vendor value survives the GSI flash — the overlay doesn't need it.

### 4. Update device match (critical)

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

The build script **gracefully skips** vendor sections if you set the HALs to false in config.env, and do not set them to true unless you have a proper files in place, or it will cause the phone into bootloop.

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
| `out/apks/{OVERLAY_NAME}.apk` | Framework-res overlay — the main overlay APK |
| `out/apks/{OVERLAY_NAME}-systemui.apk` | SystemUI overlay (optional) |
| `out/{OVERLAY_NAME}-ksu.zip` | Flashable module for KSU/Magisk |
| `out/{OVERLAY_NAME}-hardware-overlay.zip` | Source-based overlay for GSI repo submission |
| `out/{OVERLAY_NAME}-hardware-overlay-test.zip` | Test module for the repo version |
| `AndroidManifest.xml` (project root) | Auto-generated — edit config.env instead |
| `module.prop` (project root) | Auto-generated — edit config.env instead |

> ⚠️ **AndroidManifest.xml and module.prop are auto-generated!** Edit `config.env` instead of these files directly. Your changes will be overwritten on the next build.

---

## 🧪 Vendor HALs (Advanced)

Some features require proprietary vendor HAL binaries to work on a GSI.

### 🚀 The HIDL vs AIDL Shift (Android 14-16+)

Starting with Android 14 (and becoming strictly enforced in Android 16), Google has moved from **HIDL** to **AIDL** for HALs.
- **HIDL (Older):** Most stock vendor partitions ship these.
- **AIDL (Modern):** Required by newer GSIs for features like **UDFPS** and **Vibrator**.

If your fingerprint sensor doesn't work on Android 16 despite having the stock HALs, you likely need **AIDL HALs** sourced from a Custom ROM (like LineageOS) for your device.

### How it works

The vendor partition on stock firmware contains:
- HAL binary (e.g. `android.hardware.biometrics.fingerprint-service.samsung` [AIDL])
- Init .rc file (defines the service)
- VINTF manifest fragment (declares the interface)
- Shared libraries (needed by the binary)
- SELinux policy (allows access to device nodes and sysfs)

When you flash a GSI, **system is replaced but vendor is kept**. If the GSI lacks the logic to talk to your specific hardware, shipping these HALs in the KSU module "bridges" the gap.

### Extracting from your device while running a Custom Rom with AIDL HALs

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
| APK not installed | `adb shell ls -la /system/product/overlay/` | Re-flash KSU module with Magic Mount |
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

## 📚 Additional Resources

- **[vendor_extraction_guide.md](vendor_extraction_guide.md)** — Detailed guide for extracting vendor HAL binaries
- **[config.env](config.env)** — Your device's configuration file
- **Phh-Treble documentation** — [GitHub: phhusson/treble_experimentations](https://github.com/phhusson/treble_experimentations)

---

*Built for the GSI community. Reference device: Samsung Galaxy A90 5G (SM-A908 / r3q).*
