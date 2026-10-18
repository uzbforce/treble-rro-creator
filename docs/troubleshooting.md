# Troubleshooting

Start with the two read-only checks:

```bash
./build.sh doctor     # can this machine build at all?
./build.sh check      # is config.env valid?
```

On Windows use `build.cmd doctor` / `build.cmd check`. Both return a non-zero
exit code on failure, so they are safe to use in scripts.

---

## The build stops immediately

### `Missing: aapt2` / `Missing: apksigner` / `Missing: java`

The toolchain is incomplete. Run:

```bash
./build.sh setup      # interactive
# or simply re-run the build; it installs what is missing
```

On Windows, `build.cmd` needs **Git for Windows** and **JDK 17+**:

```bat
winget install EclipseAdoptium.Temurin.17.JDK
```

Open a **new** terminal after installing Java so `PATH` is refreshed.

### `cannot execute binary file` / `Exec format error` / `not a valid win32`

A binary for the wrong platform is in `tools/`. This happens when the same
checkout was set up from both Windows and WSL/Linux. `doctor` names the exact
file.

```bat
build.cmd setup        :: replaces the toolchain with Windows binaries
build.cmd doctor
```

On Linux, `./build.sh setup` reinstalls the Linux tooling.

### `This project is on a Windows drive, but you are running inside WSL`

The checkout is on `C:` (or another Windows drive) and you are in a WSL shell —
typically because VS Code opened the folder with “WSL: …” in the bottom-left.
Building from WSL would install Linux binaries into the shared `tools/` folder.

- Use a Windows terminal / double-click `build.cmd`, **or**
- clone the project inside the Linux filesystem (`~/treble-rro-creator`) and run
  `./build.sh` there.

More context: [windows.md](windows.md#wsl-why-it-is-refused).

### `aapt2 ... resource not found` during link

The resource dictionary does not match the resources you are referencing, or the
resource genuinely does not exist in the GSI.

1. Use `framework-res.apk` from **Android 13**:
   `./build.sh setup --force` → option `[1]`.
2. Remove the offending resource from `src/framework/res/values/*.xml`.
3. Check whether the GSI has the resource:

   ```bash
   adb shell cmd overlay lookup <your-package> <type>/<name>
   ```

If the lookup fails on the GSI, the resource does not exist there and must be
removed from the overlay.

### `Refusing to build a module that would silently change nothing`

The resource audit found a `type/name` that is not in the target dictionary.
Android accepts such a resource at compile time and then ignores it at runtime,
which is how an overlay can look correct and change nothing.

Read `out/<name>-overrides.txt`: every `IGNORED` line is a resource the target
does not have. Fix the spelling, remove it from
`src/framework/res/values/*.xml`, or — only when you intentionally target a
newer framework — run `./build.sh --allow-unknown-resources`.

### `<item> must have a 'type' attribute` / `xml parser error: mismatched tag`

```
build/hardware_overlay/<vendor>/<device>/res/values/config.xml:154: error: <item> must have a 'type' attribute.
build/hardware_overlay/<vendor>/<device>/res/values/config.xml:0: error: xml parser error: mismatched tag.
```

The hardware-overlay copy of `config.xml` is malformed: array items ended up
outside their array because the opening tag was dropped. In the old build the
AOSP-source tree was made by merging every `values/*.xml` into a single
`config.xml` and removing duplicate `name="…"` lines — which also removed the
opening tags of arrays whose names appear in the commented reference lists in
`src/framework/res/values/integers.xml`.

The current build copies the values tree 1:1 instead
(`generated.xml` stays its own file), so the merge no longer happens. If you see
this, you are on an old clone:

```bash
cd ~/treble-rro-creator
git pull
./build.sh clean
./build.sh
```

If it still fails, the file was edited by hand: each `<item>` must sit inside its
`<integer-array>`/`<array>` block, and every opening tag needs a matching close.

### Termux: `Toolchain is still incomplete — missing: zipalign`

`zipalign` is **not** in `aapt2`, `apksigner` or `android-tools` — it ships in
the `aapt` package. That is why reinstalling the tools hinted by the build loop
never fixes it:

```bash
pkg install aapt
command -v zipalign     # /data/data/com.termux/files/usr/bin/zipalign
```

Current builds also install `aapt` automatically and, if `zipalign` is still
missing, continue with unaligned APKs (one warning) instead of stopping — an
unaligned RRO loads fine, it just misses the 4-byte mmap alignment.

### `cp: -r not specified; omitting directory …/etc/init/hw`

Something in `src/vendor/etc/init/` is a **directory**, usually `hw/` from a
dumped vendor tree. Older builds copied that folder with a plain glob, which can
only copy files, so the build aborted (or skipped the init scripts).

Current builds copy the tree recursively and set SELinux contexts recursively,
so `etc/init/hw/*.rc` is preserved:

```bash
cd ~/treble-rro-creator && git pull
```

If you prefer a flat tree, remove the subdirectory instead:

```bash
mv src/vendor/etc/init/hw/*.rc src/vendor/etc/init/ && rmdir src/vendor/etc/init/hw
```

Related: if the build says **no vendor HAL files found** right after extracting
a tarball, check for `src/vendor/vendor/`. The archive stores paths as
`vendor/bin/hw/…`, so it must be extracted from `src/`, not from `src/vendor/`.

### The build stops with `Unexpected failure at line …`

That is the safety net printing the exact command that failed. Get a trace:

```bash
bash -x ./build.sh 2>&1 | tee build.log
```

Attach the last ~50 lines when asking for help.

---

## The module installs but the overlay does nothing

Check, in this order:

1. **Is it installed and enabled?**

   ```bash
   adb shell cmd overlay list | grep <your-package>
   ```

   `[x]` = enabled, `[ ]` = installed but disabled, missing = not installed.

   Both overlay APKs are **static** RROs. Android enables a matching static
   overlay during boot; `cmd overlay enable` cannot change it afterwards. If the
   package is missing, the APK was not mounted at boot (check the mount mode).

   > `[x]` only means the **system server** accepted the overlay. It does **not**
   > mean the framework is using your values — see step 2.

2. **Does the overlay actually supply the value?**

   ```bash
   adb shell cmd overlay lookup <your-package> android:dimen/status_bar_height_default
   ```

   This must print **your** value (`200.0px`). If it prints the framework
   default (`28.0dip`), the overlay is enabled but not applied — almost always a
   match-property problem (next step).

3. **Does the match property really match — from zygote?**

   Framework overlays (`targetPackage="android"`) are matched by **zygote** at
   boot, where several property areas are unreadable and therefore read **empty**:

   ```
   avc: denied { read } scontext=u:r:zygote:s0 tcontext=u:object_r:build_bootimage_prop:s0
   avc: denied { read } scontext=u:r:zygote:s0 tcontext=u:object_r:vendor_default_prop:s0
   adb shell su -c 'logcat -d -b all | grep "avc: *denied" | grep zygote'
   ```

   So `ro.product.bootimage.device`, `ro.product.odm.device` and most `ro.vendor.*`
   can be correct for `adb shell getprop` and still fail at boot. And on a GSI,
   `ro.product.device` / `ro.product.system.device` hold the ROM's name
   (`mivendor`, `phh_treble`, …), not your codename.

   Use the property that is readable everywhere, and let the module set it before
   zygote starts:

   ```bash
   DEVICE_PROP_NAME="persist.sys.overlay.<your-codename>"
   DEVICE_PROP_VALUE="true"
   ```

   `build.sh` then ships a `post-fs-data.sh` that runs `setprop` before zygote.
   Or set `DEVICE_PROP_NAME=""` for an overlay with no condition at all.

   ```bash
   adb shell getprop -Z ro.product.bootimage.device   # which SELinux area it lives in
   ```

4. **Is the APK in the right place?**

   ```bash
   adb shell ls -l /system/product/overlay/ | grep <name>
   ```

   If it is missing, the module was not mounted. On KernelSU / KSU Next install
   **Magic Mount** (or Hybrid Mount set to magic mount). Do **not** use
   OverlayFS.

5. **Did idmap fail?**

   ```bash
   adb logcat -d | grep -iE "overlay|idmap"
   ```

   `service 'idmap' died` means a resource in the overlay does not exist in the
   target framework. See the resource-not-found section above.

6. **Is another overlay overriding you?**

   ```bash
   adb shell dumpsys overlay | grep -A20 <your-package>
   ```

   A higher-priority overlay wins. Raise `OVERLAY_PRIORITY`, or remove the other
   overlay.

### Overlay enabled but values do not change

Look up the specific resource:

```bash
adb shell cmd overlay lookup <your-package> android:dimen/rounded_corner_radius
```

If it returns an error, the resource name is not in this GSI's framework. If it
returns the GSI value, your overlay is **not applied at all** (match property —
see step 3 above) or it lost against a higher-priority overlay.

`out/<name>-overrides.txt` lists exactly what the module carries and whether it
was found in the dictionary.

### Status bar height does not change

Android 12L+ (13/14/15/16) ignores `status_bar_height` when it lays out the
system bar. It reads `status_bar_height_default` and adds the cutout:

```
height = max(status_bar_height_default, displayCutout.safeInsetTop)
```

Check what the overlay actually contains and what the device resolved:

```bash
# In the built APK (on the PC; Windows: tools/aapt2.exe or build.cmd-style path)
aapt2 dump resources out/apks/<name>.apk | grep -A1 status_bar_height_default

# On the device: the value the overlay supplies
adb shell cmd overlay lookup <your-package> android:dimen/status_bar_height_default

# On the device: the size the framework is using (run after a reboot)
adb shell dumpsys window displays | grep -i "statusBar"
```

Common causes:

- The module was built before this fix and only has `status_bar_height`.
- The cutout safe inset is larger than the configured height.
- The overlay is listed but not enabled (property match / mount mode).
- Another higher-priority overlay sets `status_bar_height_default`.

`values-land/generated.xml` supplies the landscape value. Without it, the
portrait value would be used in landscape as well.

### Status bar content is glued to the screen edge / sits under the corner

Two resources can carry this inset and ROMs disagree about which one they use:

```
rounded_corner_content_padding   (framework)   left = max(value, cutout inset)
                                              right = max(value, privacy-dot reserve)
status_bar_padding_start/_end    (SystemUI)   plain XML padding of status_bar_contents
```

A framework value can be live (`cmd overlay lookup` shows it) and still do nothing:
measured on an Android 16 GSI, `rounded_corner_content_padding=200px` changed no
layout at all, while `status_bar_padding_start/end` moved the content 1:1. Set
both — `STATUS_BAR_CONTENT_PADDING` **and** `STATUS_BAR_PADDING_START` / `_END`
in `config.env` (see
[configuration.md](configuration.md#status-bar-content-padding-start--end)).

Check the real result instead of guessing, without root:

```bash
# what the overlay maps
adb shell cmd overlay lookup <your-package> android:dimen/rounded_corner_content_padding
adb shell cmd overlay lookup <your-package> com.android.systemui:dimen/status_bar_padding_start

# what the status bar actually laid out (unzip, then read the StatusBar entry)
adb exec-out cmd window dump-visible-window-views > views.zip
```

The status bar content view is `id/status_bar_contents`; its `padding:paddingLeft`
and `padding:paddingRight` are the live inset. If they equal your value, the
padding is applied and the remaining gap comes from something else (window insets
on `PhoneStatusBarView`, or the icons' own padding).

For the right side remember the privacy dot reserves `20dp` unless you lower
`STATUS_BAR_DOT_MIN_PADDING` or set `HAS_PRIVACY_DOT=false`.

---

## A feature is not working

| Feature | Check | Common fix |
|---|---|---|
| Corner radius | `cmd overlay lookup <pkg> android:dimen/rounded_corner_radius` | Overlay not enabled / matched |
| UDFPS | `adb shell cmd overlay lookup <pkg> android:array/config_udfps_sensor_props` and `adb shell dumpsys fingerprint` | Coordinates wrong/absent, or `config_biometric_sensors` missing; see [udfps.md](udfps.md) |
| AOD / doze | `adb shell dumpsys power \| grep -i doze` | `HAS_AOD` / `HAS_DOZE`, `config_displayBlanksAfterDoze` |
| Brightness | `adb shell getprop persist.sys.samsung.full_brightness` | Brightness values or light sensor type |
| 5G / VoLTE | `adb shell dumpsys ims` | `HAS_5G` / `HAS_VOLTE`, carrier resources |
| Fingerprint HAL | `adb logcat -d \| grep -i finger` | SELinux denials, missing libs, wrong HAL protocol (see [device-extraction.md](device-extraction.md)) |
| Vibrator | `adb shell dumpsys vibrator_manager` | HAL flag/files, SELinux |

---

## Bootloop after flashing

1. Boot into recovery (or use `adb reboot recovery`).
2. Mount `/data` and remove the module:

   ```bash
   adb shell mount /data
   adb shell rm -rf /data/adb/modules/<module-id>
   adb shell reboot
   ```

   `<module-id>` is `id=` from `module.prop` — usually
   `treble-overlay-<manufacturer>-<codename>`.

3. Rebuild without vendor HALs (answer **overlay-only**), confirm it boots, then
   add **one** HAL at a time.

Most bootloops come from vendor HAL files, VINTF manifests or SELinux rules —
not from a plain overlay build.

---

## SELinux denials

Denials are silent on many kernels: the phone boots, the feature fails.

```bash
adb logcat -b all -d | grep "avc: denied"
```

Typical lines:

```
avc: denied { read write } for ... scontext=u:r:hal_fingerprint_default:s0
avc: denied { execute } for ... scontext=u:r:init:s0 tcontext=...:hal_fingerprint_default_exec:s0
avc: denied { rw_file_perms } for ... tcontext=...:fingerprint_sensor_device:s0
```

Translate to `src/module/sepolicy.rule`:

```
allow init <hal_type>_exec:file { execute execute_no_trans };
allow <hal_type> vendor_file:file { read execute getattr open map };
allow <hal_type> <device_type>:chr_file rw_file_perms;
allow <hal_type> <sysfs_type>:file r_file_perms;
```

Reference rules: `templates/sepolicy.rule.example`.

> `sepolicy.rule` is only included in the module when you choose **Include
> vendor HALs**. Overlay-only builds skip it.

---

## Cleaning up

```bash
./build.sh clean            # build/ and out/
./build.sh clean --all      # also config.env and device files; restores templates
```

`clean --all` backs everything up to `backups/` first. The downloaded toolchain
is kept; delete `tools/` to remove it.
