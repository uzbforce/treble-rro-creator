# Vendor HAL Extraction Guide (HIDL vs AIDL)

## 🏗 Why the "Resource Dictionary" (framework-res.apk) Matters

To build an overlay, `aapt2` needs to know the exact "Resource IDs" used by the Android system. This is done by linking against a reference `framework-res.apk`.

### ⚠️ The Android 13 Rule
For this tool, **Android 13's `framework-res.apk` is the gold standard**.
- **Why?** It contains the most stable set of resource IDs: the dictionary links overlays for Android 13 through 16, and every generated resource is checked against it before the build continues.
- **Avoid pulling from your phone:** Manufacturers "optimize" (strip) their `framework-res.apk` to save space. If you use a pulled file, `aapt2` will often throw "Resource not found" errors because the ID dictionary is incomplete.

**Always use the "Download Android 13" option in `./build.sh setup`.**

---

## 🔧 Build Tools

The same entry point that builds also installs the toolchain:

```bash
./build.sh            # installs what is missing, then builds
./build.sh setup      # interactive installer only
./build.sh doctor     # verify the toolchain, install nothing
```

`aapt2`, `zipalign`, `apksigner` and `framework-res.apk` are downloaded into the
local `stuff/tools/` folder — no root required. On Windows use `build.cmd` instead.

---

## 🚀 The HIDL → AIDL Shift: Why Stock HALs Don't Work on A16 GSIs

Traditionally, Treble GSIs used **HIDL (HAL Interface Definition Language)** to communicate with vendor hardware. Starting with Android 14 and **strictly enforced in Android 16**, Google has fully moved to **AIDL (Android Interface Definition Language)** for HALs.

### The Hard Truth
Most stock vendor partitions (especially on older devices) only ship **HIDL HALs**. When you flash Android 16 GSI, it expects **AIDL HALs** — and there is **no compatibility layer**. Even with perfect SELinux rules and VINTF manifests, HIDL HALs simply will not be picked up by the A16 framework.

This applies to:
- **Fingerprint (UDFPS)** — A16 biometric framework registers AIDL HALs only. HIDL fingerprint services may run but the Settings menu won't show fingerprint enrollment.
- **Vibrator** — A16 GSIs do not discover HIDL vibrator services.
- **Power/Health** — A16 requires AIDL interfaces for power management features.

### The Real Solutions (No Workarounds)
1. **Source AIDL HALs from a Custom ROM** (LineageOS, Pixel Experience, crDroid, etc.) built for your device on Android 14+. These ROMs compile native AIDL HALs that the GSI can use. Extract them from the ROM zip or from a running ROM installation.
2. **Use a full vendor from a Custom ROM** — Flash the custom ROM, then pull its entire `/vendor` partition. This gives you AIDL HALs with correct SELinux, init scripts, and VINTF manifests that already work together.
3. **Build AIDL HALs from source** if your device has an upstream device tree with AIDL HAL definitions (advanced, requires kernel source).
4. **If no custom ROM exists for your device**, you may need to stick with an older GSI (A14 or earlier) that still supports HIDL.

> ❌ **What NOT to do:** Extracting HIDL HALs from stock firmware and adding SELinux/VINTF will **not** make them work on A16 GSI. The interface mismatch is at the framework level, not a permission issue.

---

## 📋 Quick Checklist

Before extracting, determine what your device needs:

| Feature | What you need | Protocol | Recommendation |
|---------|--------------|----------|----------------|
| **Fingerprint (UDFPS)** | AIDL binary, .rc, VINTF, libs, sepolicy | AIDL (Required for A16) | Stock HIDL is incompatible with A16. Source AIDL from a Custom ROM or device tree. |
| **Vibrator** | AIDL binary, .rc, VINTF, sepolicy | AIDL (Required for A16) | Stock HIDL won't be discovered by A16. Source AIDL from a Custom ROM. |
| **Display/AOD** | .rc file for sysfs permissions | N/A | Can be extracted from stock vendor (sysfs access is not HAL-dependent). |

Most devices only **need the overlay APK** (corner radius, cutout, brightness, etc.). Vendor HALs are only needed for features that don't work on the GSI's default implementation.

---

## 🛠 Step 1: Source AIDL HALs (Do NOT Use Stock HIDL)

Before you begin: **Stock vendor HIDL HALs will not work on A16 GSI.** You must source AIDL HALs. Here are the options, in order of preference:

### Option A: Custom ROM has AIDL HALs (Best — No extra work needed)

If your device has a custom ROM (LineageOS 21+, Pixel Experience, crDroid, etc.) based on Android 14+:
1. Flash the custom ROM on your device
2. Boot it up — if fingerprint and vibrator work, the AIDL HALs are built-in
3. Either pull the entire vendor (see "Option: Use full vendor from custom ROM" section at the end), or extract individual HALs from the running ROM (see Step 2)

### Option B: Find AIDL HALs in a Custom ROM device tree

Most custom ROM device trees on GitHub ship AIDL HAL source under:
```
device/<manufacturer>/<codename>/aidl/
hardware/<manufacturer>/<codename>/aidl/
```
Look for directories like:
```
android.hardware.biometrics.fingerprint/
android.hardware.vibrator/
```

These are compiled into AIDL HAL binaries. You can build them yourself or find pre-built ones in the ROM's `vendor/` partition.

### Option C: Check if your device already has AIDL HALs (rare but possible)

Boot a custom ROM or even stock (if on A14+) and check:

```bash
# Check for AIDL fingerprint/vibrator services
adb shell service list | grep -iE 'finger|vibrat|biometric'

# List HAL binaries — AIDL binaries look like:
#   android.hardware.biometrics.fingerprint-service.<device>
#   android.hardware.vibrator-service.<device>
adb shell ls /vendor/bin/hw/*finger* /vendor/bin/hw/*vibrat* 2>/dev/null
```

> 💡 **AIDL vs HIDL naming:** AIDL HAL binaries follow the pattern `android.hardware.<feature>-service.<device>` (e.g., `android.hardware.biometrics.fingerprint-service.r3q`). HIDL binaries look like `android.hardware.biometrics.fingerprint@2.3-service.<device>`. The `@<version>` pattern is HIDL.

### What if no custom ROM exists for your device?

If your device has no custom ROM support at all, you have three paths:
1. **Stick with A14 or earlier GSI** that still supports HIDL HALs
2. **Port AIDL HALs yourself** — find a device with similar hardware and adapt their AIDL HAL source (advanced)
3. **Use the overlay-only module** (without vendor HALs) — fingerprint and vibrator won't work, but display, brightness, and cutout overrides will

### Reference: Stock HIDL layout (for comparison only)

If you're curious what stock HIDL HALs look like (for reference, NOT for extraction):

```
# Fingerprint HIDL (Won't work on A16 GSI)
/vendor/bin/hw/android.hardware.biometrics.fingerprint@2.3-service.samsung
/vendor/etc/init/android.hardware.biometrics.fingerprint@2.3-service.samsung.rc
/vendor/etc/vintf/manifest/android.hardware.biometrics.fingerprint@2.3-service.samsung.xml
/vendor/lib64/android.hardware.biometrics.fingerprint@2.1.so
/vendor/lib64/android.hardware.biometrics.fingerprint@2.2.so
/vendor/lib64/android.hardware.biometrics.fingerprint@2.3.so

# Vibrator HIDL (Won't work on A16 GSI)
/vendor/bin/hw/vendor.samsung.hardware.vibrator@2.2-service
/vendor/etc/init/vendor.samsung.hardware.vibrator@2.2-service.rc
/vendor/etc/vintf/manifest/vendor.samsung.hardware.vibrator@2.2-service.xml
```

> Notice the `@2.3` and `@2.2` version suffixes — that's the HIDL versioning pattern. AIDL HALs don't have version suffixes in the binary name.

---

## 📦 Step 2: Extract the AIDL HAL Files

Once you've found a source of AIDL HALs (from a custom ROM zip, running custom ROM, or device tree build), use one of these methods to extract them.

> ⚠️ **Important:** If you're pulling the **entire vendor** from a custom ROM (recommended for simplicity), skip to the "Option: Use full vendor from custom ROM" section at the end. These methods are for extracting individual AIDL HALs.

### Method A: Extract from Custom ROM zip file (No root needed)

Download your device's custom ROM zip and extract the vendor directly:

```bash
# Create extraction directories
mkdir -p src/vendor/bin/hw
mkdir -p src/vendor/etc/init
mkdir -p src/vendor/etc/vintf/manifest
mkdir -p src/vendor/lib64

# Extract from ROM zip (adjust ROM zip path)
unzip -j <rom_name>.zip "vendor/bin/hw/*finger*" -d src/vendor/bin/hw/
unzip -j <rom_name>.zip "vendor/bin/hw/*vibrat*" -d src/vendor/bin/hw/
unzip -j <rom_name>.zip "vendor/etc/init/*finger*" -d src/vendor/etc/init/
unzip -j <rom_name>.zip "vendor/etc/init/*vibrat*" -d src/vendor/etc/init/
unzip -j <rom_name>.zip "vendor/etc/vintf/manifest/*" -d src/vendor/etc/vintf/manifest/
unzip -j <rom_name>.zip "vendor/lib64/*finger*" -d src/vendor/lib64/
unzip -j <rom_name>.zip "vendor/lib64/*vibrat*" -d src/vendor/lib64/

# Make binaries executable
chmod +x src/vendor/bin/hw/*
```

> Some ROM zips use `payload.bin` (Pixel-style) or `dat.br` (LineageOS-style). For `payload.bin`, use `payload-dumper-go`. For `dat.br`, use `sdat2img` then mount.

### Method B: Pull from running Custom ROM (requires root)

Boot your device into the **custom ROM** (not stock firmware) and pull:

```bash
# Create extraction directories
mkdir -p src/vendor/bin/hw
mkdir -p src/vendor/etc/init
mkdir -p src/vendor/etc/vintf/manifest
mkdir -p src/vendor/lib64

# --- Pull individual files ---
# Binary file (HAL executable) — AIDL names won't have @version:
adb shell su -c 'cat /vendor/bin/hw/<your_aidl_hal_binary>' > src/vendor/bin/hw/<your_aidl_hal_binary>

# Init script:
adb shell su -c 'cat /vendor/etc/init/<your_aidl_init.rc>' > src/vendor/etc/init/<your_aidl_init.rc>

# VINTF manifest:
adb shell su -c 'cat /vendor/etc/vintf/manifest/<your_aidl_manifest.xml>' > src/vendor/etc/vintf/manifest/<your_aidl_manifest.xml>

# Shared library:
adb shell su -c 'cat /vendor/lib64/<your_aidl_library.so>' > src/vendor/lib64/<your_aidl_library.so>

# Make binaries executable
chmod +x src/vendor/bin/hw/*

# --- Pull via tar (faster for many files) ---
adb shell su -c 'tar -czf /data/local/tmp/vendor_aidl.tar.gz -C / vendor/bin/hw/*finger* vendor/etc/init/*finger* vendor/etc/vintf/manifest/*finger* vendor/lib64/*finger*'
adb pull /data/local/tmp/vendor_aidl.tar.gz /tmp/

# The archive stores paths as vendor/bin/hw/…, so extract one level ABOVE
# src/vendor. Extracting inside src/vendor gives src/vendor/vendor/… and the
# build then finds no HALs at all.
cd src && tar -xzf /tmp/vendor_aidl.tar.gz
```

### Method C: Extract from custom ROM vendor.img

If you have a `vendor.img` from a custom ROM:

```bash
sudo mount -o loop vendor.img /mnt/vendor

# Copy files — AIDL HALs won't have @version in names
sudo cp /mnt/vendor/bin/hw/*finger* src/vendor/bin/hw/
sudo cp /mnt/vendor/etc/init/*finger* src/vendor/etc/init/
sudo cp /mnt/vendor/etc/vintf/manifest/*.xml src/vendor/etc/vintf/manifest/
sudo cp /mnt/vendor/lib64/*finger* src/vendor/lib64/
sudo cp /mnt/vendor/bin/hw/*vibrat* src/vendor/bin/hw/ 2>/dev/null
sudo cp /mnt/vendor/etc/init/*vibrat* src/vendor/etc/init/ 2>/dev/null
sudo cp /mnt/vendor/lib64/*vibrat* src/vendor/lib64/ 2>/dev/null
sudo cp /mnt/vendor/etc/init/*display* src/vendor/etc/init/ 2>/dev/null

sudo chown -R $USER:$USER src/vendor/
chmod +x src/vendor/bin/hw/*
sudo umount /mnt/vendor
```

> 💡 **Tip:** You can copy **all** vendor init scripts and manifests at once, then remove what you don't need:
> ```bash
> sudo cp -r /mnt/vendor/etc/init/ src/vendor/etc/
> sudo cp -r /mnt/vendor/etc/vintf/ src/vendor/etc/
> # Then delete files you don't want or select all the necessary files
> ```

---

## 📦 Option: Use Full Vendor from Custom ROM (Simplest Path)

If your device has a custom ROM (LineageOS 21+, crDroid, Pixel Experience, etc.) based on Android 14+, this is the **easiest and most reliable** approach:

1. **Flash the custom ROM** on your device
2. **Boot it up** and verify everything works (fingerprint, vibrator, etc.)
3. **Pull the entire vendor partition** while booted into the custom ROM:

```bash
# Create the src/vendor directory structure
mkdir -p src/vendor

# Pull entire vendor (requires root)
adb shell su -c 'tar -czf /data/local/tmp/vendor_full.tar.gz -C / vendor'
adb pull /data/local/tmp/vendor_full.tar.gz
cd system && tar -xzf ../vendor_full.tar.gz vendor
cd ..
```

This gives you everything: AIDL HALs, correct SELinux contexts, proper init .rc files, working VINTF manifests, and all required libraries — all guaranteed to work together because they were already running on your hardware.

### What to do after extracting full vendor

1. **Trim unused HALs** — remove binaries/init scripts for features you don't need (NFC, radio, etc.)
2. **Check service.sh** — the build script auto-generates this, but verify it starts the services you want
3. **Run `./build.sh`** — it will package everything automatically

> ✅ **This is the recommended approach.** Individual HAL extraction is only needed if you want to cherry-pick specific features from a full vendor dump.

---

## 🔧 Step 3: Init .rc File

### AIDL HALs: Already correct, just extract

AIDL HALs from custom ROMs ship with their correct `.rc` files already in `/vendor/etc/init/`. In most cases, you can drop the extracted `.rc` file into `src/vendor/etc/init/` without modification. Just make sure the binary path matches.

### AIDL .rc example

```rc
service vendor.fingerprint_aidl /vendor/bin/hw/android.hardware.biometrics.fingerprint-service.r3q
    class late_start
    user system
    group system input uhid
    capabilities SYS_NICE
    file /dev/goodix_fp 0660 system system
    file /dev/esfp0 0660 system system
```

Notice the binary name: no `@2.3` version suffix — AIDL HALs use the pattern `android.hardware.<feature>-service.<device>`.

### Common .rc directives

| Directive | Common values | Notes |
|-----------|--------------|-------|
| `class` | `late_start`, `hal`, `main` | Most HALs use `late_start` or `hal` |
| `user` | `system`, `root`, `bluetooth` | Usually `system` for HALs |
| `group` | `system`, `input`, `uhid` | Varies by HAL type |
| `capabilities` | `SYS_NICE`, `SYS_RESOURCE` | Only if the HAL needs elevated caps |
| `file` | `/dev/...` | Device node permissions |

> **⚠️ IMPORTANT:** If the stock vendor already has a service with the same name, use a **different service name** to avoid conflict. Both can coexist!

### Reference: HIDL .rc format (for comparison only)

These are HIDL-style init files — shown here for reference so you can recognize them:

**Fingerprint (HIDL):**
```rc
service vendor.fps_hal /vendor/bin/hw/android.hardware.biometrics.fingerprint@2.3-service.samsung
    class late_start
    user system
    group system input uhid
    capabilities SYS_NICE
    file /dev/goodix_fp 0660 system system
    file /dev/esfp0 0660 system system
```

**Vibrator (HIDL):**
```rc
on early-boot
    chown system system /sys/class/timed_output/vibrator/intensity
    chmod 660 /sys/class/timed_output/vibrator/intensity

service sec-vibrator-2-2 /vendor/bin/hw/vendor.samsung.hardware.vibrator@2.2-service
    class hal
    user system
    group system
```

---

## 📄 Step 4: VINTF Manifest Fragment

The VINTF manifest tells the framework what HAL interfaces your service implements. Extract this from your custom ROM's `/vendor/etc/vintf/manifest/`. An incorrect manifest can cause bootloops or HAL manager crashes.

### AIDL VINTF format (what you need)

AIDL VINTF manifests use `format="aidl"` and specify the interface FQN directly — no version suffix:

```xml
<manifest version="1.0" type="device">
    <hal format="aidl">
        <name>android.hardware.biometrics.fingerprint</name>
        <version>2</version>              <!-- AIDL version (just the major) -->
        <interface>
            <name>IFingerprint</name>
            <instance>default</instance>
        </interface>
    </hal>
</manifest>
```

```xml
<manifest version="1.0" type="device">
    <hal format="aidl">
        <name>android.hardware.vibrator</name>
        <version>1</version>
        <interface>
            <name>IVibrator</name>
            <instance>default</instance>
        </interface>
    </hal>
</manifest>
```

> 💡 **Just extract it!** The VINTF manifest from your custom ROM already has the correct format — there's no need to write one from scratch.

### Reference: HIDL VINTF format (for comparison only)

HIDL manifests use `format="hidl"` with `@major.minor` versioning:

```xml
<manifest version="1.0" type="device">
    <hal format="hidl">
        <name>android.hardware.biometrics.fingerprint</name>
        <transport>hwbinder</transport>
        <version>2.3</version>
        <interface>
            <name>IBiometricsFingerprint</name>
            <instance>default</instance>
        </interface>
        <fqname>@2.3::IBiometricsFingerprint/default</fqname>
    </hal>
</manifest>
```

```xml
<manifest version="1.0" type="device">
    <hal format="hidl">
        <name>vendor.samsung.hardware.vibrator</name>
        <transport>hwbinder</transport>
        <version>2.2</version>
        <interface>
            <name>ISehVibrator</name>
            <instance>default</instance>
        </interface>
    </hal>
</manifest>
```

---

## 🔒 Step 5: Add SELinux Policy Rules

SELinux rules are equally needed for AIDL and HIDL HALs. Add them to `src/module/sepolicy.rule`. A reference example is in `stuff/templates/sepolicy.rule.example`.

> 💡 **AIDL SELinux context:** AIDL HALs from custom ROMs use the same SELinux domain names as HIDL ones (e.g., `hal_fingerprint_default`, `hal_vibrator_default`). The rules are identical — the SELinux policy doesn't distinguish between AIDL and HIDL at the domain level.

### Generic SELinux rules pattern

```
# Allow init to execute the HAL binary (domain transition)
allow init <hal_type>_exec:file { execute execute_no_trans };

# Allow HAL to load shared libraries
allow <hal_type> vendor_file:file { read execute getattr open map };

# Allow HAL to access its device node
allow <hal_type> <device_type>:chr_file rw_file_perms;

# Allow HAL to read sysfs attributes
allow <hal_type> <sysfs_type>:dir r_dir_perms;
allow <hal_type> <sysfs_type>:file r_file_perms;

# Allow HAL to create data files
allow <hal_type> <data_type>:dir create_dir_perms;
allow <hal_type> <data_type>:file create_file_perms;
```

Replace `<hal_type>`, `<device_type>`, `<sysfs_type>`, and `<data_type>` with your device's actual SELinux types. Determine the right types by checking logcat denials after flashing.

### Finding SELinux denials on your device

```bash
# Check for denials after flashing the module
adb logcat -b all -d | grep "avc: denied"

# Each line shows:
# avc: denied { <permission> } for pid=... scontext=u:r:<source_context>:s0
#   tcontext=u:object_r:<target_type>:s0 tclass=<class>
#
# Translate to sepolicy rule:
#   allow <source_context> <target_type>:<class> { <permission> };
```

### Reference Example: Fingerprint HAL sepolicy

```allow init hal_fingerprint_default_exec:file { execute execute_no_trans };
allow hal_fingerprint_default vendor_file:file { read execute getattr open map };
allow hal_fingerprint_default fingerprint_sensor_device:chr_file rw_file_perms;
allow hal_fingerprint_default sysfs_fingerprint:dir r_dir_perms;
allow hal_fingerprint_default sysfs_fingerprint:file r_file_perms;
allow hal_fingerprint_default tee_device:chr_file rw_file_perms;
allow hal_fingerprint_default vendor_biometrics_data_file:dir create_dir_perms;
allow hal_fingerprint_default vendor_biometrics_data_file:file create_file_perms;
```

### Reference Example: Vibrator HAL sepolicy

```allow init hal_vibrator_default_exec:file { execute execute_no_trans };
allow hal_vibrator_default sysfs:file rw_file_perms;
allow hal_vibrator_default sysfs:dir r_dir_perms;
allow hal_vibrator_default sysfs_leds:file rw_file_perms;
allow hal_vibrator_default sysfs_leds:dir r_dir_perms;
allow hal_vibrator_default timed_output_device:chr_file rw_file_perms;
```

---

## 🧪 Step 6: Test

1. Run `./build.sh` to build the module with your extracted files
2. Flash the module on your device
3. Check logcat for SELinux denials: `adb logcat -b all -d | grep "avc: denied"`
4. Check if the service started:
   ```bash
   adb shell dumpsys fingerprint        # For fingerprint
   adb shell dumpsys vibrator           # For vibrator
   adb shell dumpsys -l | grep <hal>    # For any other HAL
   ```

### Debugging checklist

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| Service not found / not registered | HIDL HAL used instead of AIDL | Replace with AIDL HAL from a custom ROM |
| Service not found | Missing VINTF manifest | Add `.xml` to `src/vendor/etc/vintf/manifest/` |
| Service not found | Wrong VINTF format (HIDL vs AIDL) | Ensure `format="aidl"` in the manifest |
| Service won't start | SELinux denial | Check logcat, add rules to `sepolicy.rule` |
| Service starts but fails | Wrong HAL binary for this Android version | Extract from a custom ROM built for A14+ |
| "No such file" in logcat | Missing shared library | Check `src/vendor/lib64/` for missing `.so` files |
| Device bootloops | Incompatible sepolicy or VINTF | Remove the vendor files and re-test |

---

## 📁 Where the files go

Vendor files live in `src/vendor/`, using the same shape they have on the device
but without the leading `/system`:

```
project_root/
├── src/
│   ├── vendor/
│   │   ├── bin/hw/                  # HAL binaries
│   │   ├── etc/init/                # init .rc files for those HALs
│   │   ├── etc/vintf/manifest/      # VINTF fragments (format="aidl")
│   │   └── lib64/                   # shared libraries used by the HALs
│   └── module/
│       ├── customize.sh             # optional override (generated by default)
│       ├── service.sh               # optional override (generated by default)
│       └── sepolicy.rule            # your SELinux rules
├── stuff/templates/
│   ├── sepolicy.rule.example        # Samsung A90 5G reference rules
│   ├── customize.sh.example
│   └── service.sh.example
├── config.env                       # device settings
└── build.sh
```

Drop the files in the matching folder and `build.sh` picks them up. Each
subfolder has its own purpose:

> - `src/vendor/bin/hw/` — fingerprint, vibrator, display HAL binaries
> - `src/vendor/etc/init/` — init scripts for those HALs
> - `src/vendor/etc/vintf/manifest/` — VINTF manifest fragment
> - `src/vendor/lib64/` — shared libraries
> - `src/vendor/vendor_overlay_ref/` — stock vendor overlay APKs (useful for
>   extracting values like corner radius, UDFPS coordinates and brightness curves)
> - `src/vendor/build.prop` — vendor build properties
>
> Everything under `src/vendor/` is ignored by git: these files are
> device-specific and usually proprietary.

---

## Power Profile (`power_profile.xml`) — mandatory

The `src/framework/res/xml/power_profile.xml` file is important for your device's health and performance on a GSI. It tells Android how much power each hardware component uses and defines the CPU cluster architecture.

> The file shipped in `src/framework/res/xml/` is an **empty template**. The
> build detects that and leaves it out of the APK, so the GSI keeps its own
> default profile. It will not override the GSI with an empty/broken profile.
> Add your device's entries to make battery statistics and CPU power mapping
> accurate.

### ⚠️ Why you should replace the template
While your phone might boot without it, using a generic or missing `power_profile.xml` causes:
- **Poor Battery Life:** The system cannot accurately calculate power-efficient task placement.
- **CPU Mismatch:** Modern "Big.Little" or "1+3+4" CPU cluster layouts need correct frequency/power maps to scale correctly.
- **Fake Stats:** Your battery usage graph will be completely wrong.
- **Overheating:** Incorrect power maps can lead to aggressive boosting on the wrong clusters.

### What power_profile.xml contains

- **CPU clusters** — core speeds and power draw per frequency step (Essential for schedutil/schedtune)
- **Screen** — power drain when on, at full brightness, and in ambient/doze mode
- **Radio** — cellular modem power in active/idle/scanning states
- **Wi-Fi/Bluetooth** — power drain for each radio
- **Battery capacity** — nominal and typical mAh

### 🛠️ How to get YOUR device's power_profile

**YOU MUST EXTRACT THIS FROM YOUR STOCK FIRMWARE.** Do not guess.

#### Method A: Extract from framework-res.apk (Recommended)

1. Pull the framework-res APK from your stock device (via ADB or from a firmware dump):
   ```bash
   adb pull /system/framework/framework-res.apk
   ```
2. Unzip and extract the power profile:
   ```bash
   unzip -p framework-res.apk res/xml/power_profile.xml > src/framework/res/xml/power_profile.xml
   ```
3. Rebuild. The build now sees real `<item>` entries and compiles the file
   into the overlay.

#### Method B: Get from device tree source (for custom ROMs)

If your device has a high-quality custom ROM (like LineageOS), find the `power_profile.xml` in their device tree on GitHub. It's usually located at:
`device/<manufacturer>/<codename>/overlay/frameworks/base/core/res/res/xml/power_profile.xml`

---

## ⚠️ Safety Notes

1. **HIDL HALs will NOT work on A16 GSI.** Save yourself the debugging time — source AIDL HALs from a custom ROM or device tree from the start.
2. **Always keep a backup** of your working module before adding vendor HALs
3. **Test one HAL at a time** — add fingerprint first, get it working, then add vibrator
4. **If the device bootloops**, boot to recovery and remove the module:
   ```bash
   adb reboot recovery
   adb shell mount /data
   adb shell rm -rf /data/adb/modules/treble-overlay-<device_manufacturer>-<device_codename>
   adb shell reboot
   ```
5. **VINTF manifest fragments from the wrong device can cause HAL manager crashes** — only use fragments from your exact device model.
6. **Don't blindly copy ALL vendor files** — only copy the HALs you actually need. Each extra file is another potential source of conflicts.
7. **If no custom ROM exists for your device**, consider using an A14 or earlier GSI that still supports HIDL HALs for full hardware compatibility.

---

*Reference examples in this guide use the Samsung Galaxy A90 5G (SM-A908N / r3q) — your device will have different file names and paths.*
