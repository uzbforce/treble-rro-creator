# Configuration (`config.env`)

`config.env` is the only file you normally edit. `build.sh` reads it, generates
the overlay resources, the manifests and the module scripts, then compiles and
signs everything.

```bash
cp config.env.example config.env   # optional: Samsung A90 5G reference values
```

Values are plain shell assignments: `KEY=value` or `KEY="value"`.
`true` / `false` are lowercase.

> **Commenting a value out (`#KEY=...`) means "do not generate that resource"**,
> not "set it to zero". Booleans left out keep the GSI default; numbers left out
> keep the framework default.

The desktop app shows this file as a form — one row per setting, the switch on
the left writing exactly that `#`, and the paragraph above the key behind an ⓘ
button — so none of it has to be typed as bash. It saves only the rows you
changed; every other line stays as it was. See
[gui.md](gui.md#the-other-tabs).

---

## Checking values before a build

`build.sh` runs a preflight over `config.env` before it generates anything and
prints what it finds. `./build.sh check` runs only that preflight:

- placeholders still in place (`000`, `<codename>`) that would silently produce
  a 0 px value;
- `STATUS_BAR_CONTENT_PADDING`, `_PADDING_START` and `_PADDING_END` disagreeing,
  or a padding wider than the corner radius;
- a status bar height outside 48–400 px, or a landscape bar taller than the
  portrait one;
- brightness arrays whose lengths do not line up (`LEVELS` + 1, and
  `SCREEN_BRIGHTNESS_NITS` against `SCREEN_BRIGHTNESS_BACKLIGHT`);
- a half-filled UDFPS triple, or `UDFPS_*` set while `HAS_UDFPS=false`;
- `PEAK_REFRESH_RATE` below `DEFAULT_REFRESH_RATE`;
- a `CONFIG_*` key that no build script reads (a typo).

They are warnings, so the build continues — a value that looks odd can still be
deliberate. Values that cannot compile at all (a radius of `abc`) are errors in
[`stuff/scripts/resources.sh`](../stuff/scripts/resources.sh) and stop the build.

To see exactly what `config.env` produces without compiling anything:

```bash
./build.sh --dry-run
```

That prints every resource — type, name, value and which overlay APK it lands
in — grouped the same way the module WebUI groups them. It needs no aapt2, no
Java and no signing keys, so it is the quickest way to check a change.

---

## Identity

| Key | Example | Meaning |
|---|---|---|
| `DEVICE_CODENAME` | `r3q` | Codename from `getprop ro.product.device`. Used in names and paths. |
| `DEVICE_MANUFACTURER` | `samsung` | Manufacturer from `getprop ro.product.manufacturer`. |
| `DEVICE_MODEL` | `SM-A908N` | Display name from `getprop ro.product.model`. |
| `DEVICE_PROP_NAME` | `persist.sys.overlay.r3q` | Property the overlay matches. Empty = no condition. |
| `DEVICE_PROP_VALUE` | `true` | Required value of that property. |
| `OVERLAY_NAME` | `treble-overlay-samsung-r3q` | Output file / module id. Auto-derived when left as a placeholder. |
| `OVERLAY_PACKAGE` | `me.phh.treble.overlay.samsung.r3q` | Package name of the framework overlay. Auto-derived. |
| `OVERLAY_PACKAGE_SYSTEMUI` | `…r3q.systemui` | Package name of the SystemUI overlay. Auto-derived. |
| `OVERLAY_PRIORITY` | `628` | Framework overlay priority. Higher wins against other overlays. |
| `OVERLAY_PRIORITY_SYSTEMUI` | `9999` | SystemUI overlay priority. |

### Choosing the match property

A framework overlay (`targetPackage="android"`) is matched by **zygote**, while it
preloads the framework resources — not by Android's overlay service. That has two
consequences on GSI setups:

- Some property areas are **unreadable from the zygote domain** and come back
  empty, so the condition silently fails. The overlay still appears as enabled
  (`cmd overlay list` prints `[x]`) but its resources are never applied.
- `ro.product.device`, `ro.product.system.device` and `ro.product.product.device`
  usually hold the **ROM's** name on a GSI (`mivendor`, `phh_treble`, …), not the
  codename of the phone.

Use one of these instead:

| Setting | Behaviour | Use when |
|---|---|---|
| `DEVICE_PROP_NAME="persist.sys.overlay.<id>"` + `DEVICE_PROP_VALUE="true"` | Overlay active only on this device. `build.sh` ships a `post-fs-data.sh` that sets the property **before zygote starts**. | Recommended default. `persist.sys.*` is readable from every domain. |
| `DEVICE_PROP_NAME=""` | No condition at all — the overlay is always active. | Module will only ever be flashed on this device; or matching keeps failing. |

> **Why not the fingerprint?** AOSP's `PatternMatcher.PATTERN_SIMPLE_GLOB` does
> not match `/` in file paths, and fingerprints contain slashes.

Where the codename lives, per device type
(`adb shell getprop | grep <codename>` finds it):

| Device | Property that usually holds the codename | Matched by zygote? |
|---|---|---|
| Stock ROM, most devices | `ro.product.device`, `ro.product.vendor.device` | depends on vendor policy |
| GSI + `vendor_boot` / `odm` | `ro.product.bootimage.device`, `ro.product.odm.device` | often **no** (`build_bootimage_prop` denied) |
| Samsung | `ro.product.vendor.device`, `ro.product.omc.*` | usually |
| MediaTek / Xiaomi GSIs | `ro.product.bootimage.device`, `ro.product.odm.device` | often **no** |

Check which SELinux area a property lives in:

```bash
adb shell getprop -Z ro.product.bootimage.device
# [ro.product.bootimage.device]: [u:object_r:build_bootimage_prop:s0]  ← usually unreadable from zygote
# [ro.product.device]:           [u:object_r:build_prop:s0]            ← usually readable
```

And whether the overlay is actually in effect (not just enabled):

```bash
adb shell cmd overlay lookup <package> android:dimen/status_bar_height_default
# 200.0px   ← your value is live
# 28.0dip   ← framework default: the overlay is NOT applied
```

---

## Display

| Key | Default | Meaning |
|---|---|---|
| `ROUNDED_CORNER_RADIUS` | `100` | Screen corner radius. `100` means `100px`; `48dp` is also accepted. Generates `rounded_corner_radius` (+ top/bottom/secondary variants). |
| `STATUS_BAR_HEIGHT` | `76` | Portrait status bar height. `76` means `76px`; `88px` and `24dp` are accepted. |
| `STATUS_BAR_HEIGHT_LANDSCAPE` | `24` | Landscape status bar height. Comment out to use `24` (px). |
| `STATUS_BAR_CONTENT_PADDING` | — | Left/right inset of the status bar content → `rounded_corner_content_padding` (framework). Optional; set it together with the pair below. |
| `STATUS_BAR_PADDING_START` / `_END` / `_TOP` | — | Inner padding of the bar contents → `status_bar_padding_*` (SystemUI). This is the path that measurably works on GSI builds (see below). Optional. |
| `STATUS_BAR_ICONS_PADDING_START` / `_END` | — | Padding of the system-icons cluster (battery/signal/wifi side) → `status_bar_icons_padding_*`. Optional. |
| `STATUS_BAR_DOT_MIN_PADDING` | — | End-side reserve for the privacy dot → `ongoing_appops_dot_min_padding`. Optional. |
| `HAS_PRIVACY_DOT` | — | `false` disables `config_enablePrivacyDot`, which also removes its end-side reserve. Optional. |
| `DISPLAY_CUTOUT` | — | SVG path for the notch/punch-hole, ending in `@dp`. Leave commented out for no cutout. |

Take the values from your stock product overlay (`framework-res__auto_generated_rro_product.apk`)
or from your device tree.

### Status bar height

On Android 12L and newer (13, 14, 15, 16) the framework does **not** read
`status_bar_height` for the system bar. `SystemBarUtils.getStatusBarHeight()`
reads `status_bar_height_default` and adds the display-cutout inset:

```
status bar height = max(status_bar_height_default, cutout.safeInsetTop)
```

Earlier versions of this tool only wrote `status_bar_height`, so the value was
silently ignored on modern GSIs. The build now writes all of them:

| File | Resources |
|---|---|
| `values/generated.xml` | `status_bar_height_default`, `status_bar_height`, `status_bar_height_portrait`, `quick_qs_offset_height` |
| `values-land/generated.xml` | `status_bar_height_default`, `status_bar_height`, `quick_qs_offset_height` |

The landscape file matters because `status_bar_height_default` has no `-land`
variant in AOSP; without it the portrait value is used in landscape too.

> **Cutout wins.** If your punch-hole/notch is taller than the value you set,
the final height is the cutout height. Do not lower `STATUS_BAR_HEIGHT` below
your cutout's safe inset.

See [troubleshooting.md](troubleshooting.md#status-bar-height-does-not-change).

### Status bar content padding (start / end)

There are two resources for the left/right gap between the screen edge and the
first status bar item, and **which one is live depends on the ROM**:

| Resource | Package | Path |
|---|---|---|
| `rounded_corner_content_padding` | `android` (framework) | AOSP's own knob. SystemUI computes `left = max(this, display-cutout left inset)`, `right = max(this, privacy-dot reserve)` and applies it to the bar contents (`StatusBarContentInsetsProvider` → `PhoneStatusBarView`). |
| `status_bar_padding_start` / `_end` / `_top` | `com.android.systemui` | Plain XML padding of `@+id/status_bar_contents`, applied when the status bar layout is inflated. |
| `status_bar_icons_padding_start` / `_end` | `com.android.systemui` | Padding of the system-icons cluster (battery/signal/wifi side). |
| `ongoing_appops_dot_min_padding` | `com.android.systemui` | End-side reserve that keeps the privacy dot visible (20dp in AOSP). |

Measured on an Android 16 GSI (1080px wide, density 2.0), reading the real view
tree with `adb exec-out cmd window dump-visible-window-views`:

| Build | `status_bar_contents` padding | Result |
|---|---|---|
| framework `rounded_corner_content_padding` = 200px, no SystemUI padding | 8px / 8px (ROM default) | framework value **never applied** |
| framework 100px + `status_bar_padding_start/end` = 200 / 250 | 200px / 250px | moved 1:1: clock glyph x = 62 → 255 |
| both at 48px (a 140-150px corner) | 48px / 48px | inset applied on both sides; clock sits at 43 + 48 + 11 = 102 |

So on GSI builds the **SystemUI dimens are the ones that work**; the framework
value can be live (`cmd overlay lookup` reports it) and still change nothing.
Set both to the same value — each ROM applies one of the two, and they do not
stack, because the framework path overrides the padding instead of adding to it.

```bash
# Which values are live right now
adb shell cmd overlay lookup <package> android:dimen/rounded_corner_content_padding
adb shell cmd overlay lookup <package> com.android.systemui:dimen/status_bar_padding_start
```

`ROUNDED_CORNER_RADIUS` no longer writes `rounded_corner_content_padding` by
itself: an implicit `0px` would drag the content into the corners on ROMs that
do apply the framework value. It is written only when you set
`STATUS_BAR_CONTENT_PADDING`.

Practical guidance:

- Content hugs the corners/edges → set `STATUS_BAR_PADDING_START` / `_END`
  (and `STATUS_BAR_CONTENT_PADDING` to the same value). The module WebUI
  changes the same three values at runtime; it adds the resources to the
  overlay APK when `config.env` left them commented out, so a rebuild is only
  needed to bake a value in
  ([webui.md](webui.md#what-the-page-can-change)).
- How much: a corner of radius `R` intrudes `R - sqrt(R^2 - (R-y)^2)` at height
  `y`. For `R = 150` that is 60px at `y = 30` and 30px at `y = 60`, so 48px
  clears the icon band (`y = 30..89`). AOSP itself uses about `R/10`.
- Need asymmetric padding → the `_START` / `_END` keys are independent.
- Either path leaves the icons at the battery/signal side alone unless the ROM
  keeps XML padding on the cluster; `STATUS_BAR_ICONS_PADDING_START` / `_END`
  targets that directly.
- The right side never gets closer to the edge than the privacy-dot reserve
  (`20dp`). Lower `STATUS_BAR_DOT_MIN_PADDING`, or set `HAS_PRIVACY_DOT=false`
  to remove that reserve entirely (you also lose the camera/mic indicator dot).
- Device has a punch-hole/notch → the cutout inset is still respected on the
  framework path; the value you set is a minimum, not an override.

---

## Brightness

| Key | Example | Meaning |
|---|---|---|
| `HAS_AUTO_BRIGHTNESS` | `true` | Generates `config_automatic_brightness_available`. |
| `LIGHT_SENSOR_TYPE` | `android.sensor.light` | `config_displayLightSensorType`. Vendor sensors have names like `com.samsung.sensor.physical_light`. |
| `BRIGHTNESS_DIM` | `15` | `config_screenBrightnessDim` (0–255). |
| `BRIGHTNESS_DARK` | `3` | `config_screenBrightnessDark` (0–255). |
| `BRIGHTNESS_DOZE` | `60` | `config_screenBrightnessDoze` (0–255) + `config_screenBrightnessDozeFloat`. |
| `BRIGHTNESS_DEFAULT` | `128` | `config_screenBrightnessSettingDefault` + float mirror. |
| `BRIGHTNESS_MIN` | `0` | `config_screenBrightnessSettingMinimum` + float mirror. |
| `BRIGHTNESS_MAX` | `255` | `config_screenBrightnessSettingMaximum` + float mirror. Leave it out unless you need to cap the GSI's maximum. |
| `AUTO_BRIGHTNESS_LEVELS` | `"1 5 10 50 …"` | Lux breakpoints (space-separated, increasing). Extract from the stock overlay. |
| `AUTO_BRIGHTNESS_BACKLIGHT_VALUES` | `"5 15 30 …"` | Backlight values. Must contain **one more** value than `AUTO_BRIGHTNESS_LEVELS`. |
| `AUTO_BRIGHTNESS_DISPLAY_VALUES_NITS` | `"2 5 12 …"` | OLED/nits curve. Also **levels + 1** values. Used by modern brightness mapping. |
| `SCREEN_BRIGHTNESS_BACKLIGHT` | `"0 1 2 …"` | Backlight scale for `config_screenBrightnessBacklight` (integer, increasing). |
| `SCREEN_BRIGHTNESS_NITS` | `"2 5 12 …"` | Backlight → nits mapping for `config_screenBrightnessNits`. Same count as `SCREEN_BRIGHTNESS_BACKLIGHT`. |

Each brightness key is independent: only the keys you set are written to the
overlay, so a GSI that already raised `config_screenBrightnessSettingMaximum`
is not capped to 255 by accident.

The backlight/nits arrays are validated (integers or numbers, increasing, and
the right count). A mismatch is skipped with a warning instead of producing a
module that breaks auto-brightness. Without the arrays the GSI's own curve is
used.

> `HAS_HBM` / `BRIGHTNESS_EXTENDED_MAXIMUM` were removed. AOSP has no
> `config_screenBrightnessExtendedMaximum`; high-brightness mode is implemented
> by the panel/vendor driver, not by an RRO. Setting `HAS_HBM` is ignored.

---

## Fingerprint (UDFPS)

| Key | Example | Meaning |
|---|---|---|
| `HAS_UDFPS` | `true` | Registers fingerprint in `config_biometric_sensors` (`0:2:15` unless overridden). |
| `UDFPS_X` | `540` | Sensor center X in px. Optional. |
| `UDFPS_Y` | `2145` | Sensor center Y in px. Optional. |
| `UDFPS_RADIUS` | `114` | Sensor radius in px. Optional. |
| `CONFIG_BIOMETRIC_SENSORS` | `"0:2:15"` | Override the sensor list (`id:modality:strength`, `;`-separated). |
| `HAS_SAMSUNG_FINGERPRINT` | `false` | Samsung Goodix sensors (`persist.sys.phh.samsung_fingerprint`). |
| `HAS_SAMSUNG_FOD` | `false` | Enable Samsung FOD through `/sys/class/sec/tsp/cmd`. |
| `CONFIG_DOZE_UDFPS_LONG_PRESS_SENSOR_TYPE` | `"org.lineageos.sensor.udfps"` | Optional: sensor type for long-press while the screen is off. |

> The example values above come from a Samsung A90 5G, not from a universal
default. Using another device's geometry puts the lock-screen icon away from
the physical sensor. Measure your own device: `bash stuff/scripts/udfps-probe.sh`
(or the app's **UDFPS** tab) reads it from the phone, or from an extracted
firmware tree. See [udfps.md](udfps.md) for what each source means.

`UDFPS_X` / `UDFPS_Y` / `UDFPS_RADIUS` are **all-or-nothing**. When all three are
set, `config_udfps_sensor_props` is written as a three-item integer array. When
any is missing the array is left alone (the AIDL HAL / SystemUI reports the
sensor location), instead of writing an array with empty items — which makes
`Resources.getIntArray()` throw at runtime.

> `persist.sys.udfps.*` is **not** read by AOSP, TrebleDroid or PHH. Older
> versions of this tool wrote those properties; they are gone. The framework
> array above is the supported mechanism.

How to find X / Y / radius: [udfps.md](udfps.md).

---

## Features

| Key | Default | Effect |
|---|---|---|
| `HAS_AOD` | `false` | Always-on display resources + `doze_display_state_supported` in SystemUI. |
| `HAS_DOZE` | `false` | Doze-after-screen-off and pickup-pulse resources. |
| `DOZE_SUSPEND_UNSUPPORTED` | `false` | For panels (e.g. some Samsung) that cannot handle DOZE_SUSPEND. |
| `HAS_5G` | `false` | Enables 5G resources. |
| `HAS_VOLTE` | `false` | Enables VoLTE/VT/WFC resources. |
| `HAS_BURN_IN_PROTECTION` | `false` | `config_enableBurnInProtection` (framework). SystemUI's status/nav-bar shifting follows this value. |
| `HAS_DOUBLE_TAP_WAKE` | `false` | Double-tap-to-wake support. |
| `DEFAULT_REFRESH_RATE` | `60` | Default display refresh rate. |
| `PEAK_REFRESH_RATE` | `60` | Peak refresh rate. |

---

## Vendor HAL flags

Set these **only after** the files are in `src/vendor/`. Enabling them without
the files, or with files from another device, can bootloop the phone.

| Key | Meaning |
|---|---|
| `HAS_VENDOR_FINGERPRINT_HAL` | Include and start a fingerprint HAL from `src/vendor/`. |
| `HAS_VENDOR_VIBRATOR_HAL` | Include and start a vibrator HAL. |
| `HAS_SAMSUNG_VIBRATOR` | Start Samsung's vibrator services. |

See [device-extraction.md](device-extraction.md).

---

## Signing and build tools

| Key | Default | Meaning |
|---|---|---|
| `PLATFORM_JAR` | `/usr/share/android-framework-res/framework-res.apk` | Resource dictionary. `build.sh` falls back to `stuff/tools/framework-res.apk` automatically. |
| `PLATFORM_KEY` | `stuff/keys/platform.pk8` | Signing key (platform key is shipped). |
| `PLATFORM_CERT` | `stuff/keys/platform.x509.pem` | Certificate matching the key. |

The shipped key is the well-known AOSP test platform key. That is what makes a
platform-signed overlay work on a GSI; it is not a secret and is not trusted by
anything except builds that already use it.

---

## Advanced (do not change)

```env
COMPILE_SDK_VERSION=35
ANDROID_VERSION="15"
MIN_SDK_VERSION=33
TARGET_SDK_VERSION=34
```

They become the APK's `compileSdk` / `minSdk` / `targetSdk`. They do **not**
select the resource dictionary — that is `PLATFORM_JAR` (Android 13 by default)
— and they do not decide which GSI the overlay runs on. Raising them changes
what `aapt2 link` resolves, which is how `resource not found` errors start.

---

## Overlay repo submission (optional)

Only affects `out/<name>-hardware-overlay.zip`, the source tree you submit as a
pull request to
[Doze-off/vendor_hardware_overlay](https://github.com/Doze-off/vendor_hardware_overlay)
(base branch `pie`) so GSI builds ship the overlay themselves; upstream
[TrebleDroid/vendor_hardware_overlay](https://github.com/TrebleDroid/vendor_hardware_overlay)
takes the same tree. It does not change the flashable module.
Walkthrough: [submission.md](submission.md).

| Key | Default | Meaning |
|---|---|---|
| `HW_OVERLAY_MATCH_PROP` | `ro.product.vendor.device` | Property the preinstalled overlay matches on. Empty = always active. |
| `HW_OVERLAY_MATCH_VALUE` | `DEVICE_CODENAME` | Exact value of that property (no globs). |
| `HW_OVERLAY_PRIORITY` | a free number | `android:priority` for the framework overlay. |
| `HW_OVERLAY_PRIORITY_SYSTEMUI` | `OVERLAY_PRIORITY_SYSTEMUI` | Priority for the SystemUI overlay. |

`android:requiredSystemPropertyValue` is compared with plain string equality
(`FrameworkParsingPackageUtils#checkRequiredSystemProperties`), so `*` and `+`
are not wildcards: an overlay carrying `+*samsung/r3q*` never activates. Use the
literal value from `adb shell getprop ro.product.vendor.device`.

The repo's `tests/tests.sh` rejects a priority that another overlay already
uses, which is why the submission does not reuse `OVERLAY_PRIORITY` (628 is
taken). Nothing runs that script for you on the Doze-off fork (its Actions tab
has no runs), so run it in your clone before opening the pull request. The default is the first free number at or after a device-specific
start in `stuff/scripts/data/treble-overlay-priorities.txt` (a snapshot of the repo);
take the number the test script suggests if it differs.

---

## Optional stock values

These are **off by default**. Extract them from your stock product overlay APK
(see [device-extraction.md](device-extraction.md)) and uncomment only the ones
that differ from the vendor overlay — values present in both are already kept
when the GSI is flashed.

| Key | Type | Resource |
|---|---|---|
| `CONFIG_RADIO_ACCESS_FAMILY` | string | `config_radio_access_family` |
| `SKIP_RESTORING_NETWORK_SELECTION` | bool | `skip_restoring_network_selection` |
| `CONFIG_SWITCH_PHONE_ON_VOICE_REG_STATE_CHANGE` | bool | `config_switch_phone_on_voice_reg_state_change` |
| `CONFIG_BIOMETRIC_SENSORS` | string | `config_biometric_sensors` (`id:modality:strength`, `;`-separated) |
| `CONFIG_FILL_MAIN_BUILTIN_DISPLAY_CUTOUT` | bool | `config_fillMainBuiltInDisplayCutout` |
| `CONFIG_POWER_DECOUPLE_INTERACTIVE_MODE_FROM_DISPLAY` | bool | `config_powerDecoupleInteractiveModeFromDisplay` |
| `CONFIG_POWER_DECOUPLE_AUTO_SUSPEND_MODE_FROM_DISPLAY` | bool | `config_powerDecoupleAutoSuspendModeFromDisplay` |
| `CONFIG_DISPLAY_BLANKS_AFTER_DOZE` | bool | `config_displayBlanksAfterDoze` |
| `CONFIG_DOZE_SUPPORTS_AOD_WALLPAPER` | bool | `config_dozeSupportsAodWallpaper` |
| `CONFIG_SUPPORT_AUDIO_SOURCE_UNPROCESSED` | bool | `config_supportAudioSourceUnprocessed` |
| `CONFIG_CAMERA_SOUND_FORCED` | bool | `config_camera_sound_forced` |
| `CONFIG_USE_DEV_INPUT_EVENT_FOR_AUDIO_JACK` | bool | `config_useDevInputEventForAudioJack` |
| `CONFIG_WIFI_DISPLAY_SUPPORTS_PROTECTED_BUFFERS` | bool | `config_wifiDisplaySupportsProtectedBuffers` |
| `CONFIG_CARRIER_VOLTE_AVAILABLE` | bool | `config_carrier_volte_available` |
| `CONFIG_CARRIER_VT_AVAILABLE` | bool | `config_carrier_vt_available` |
| `CONFIG_CARRIER_WFC_IMS_AVAILABLE` | bool | `config_carrier_wfc_ims_available` |
| `CONFIG_CARRIER_VOLTE_TTY_SUPPORTED` | bool | `config_carrier_volte_tty_supported` |
| `CONFIG_CAMERA_DOUBLE_TAP_POWER_GESTURE_ENABLED` | bool | `config_cameraDoubleTapPowerGestureEnabled` |

Anything not in this list can be added to the marked section at the bottom of
`src/framework/res/values/config.xml`.

---

## Resource audit

Every build checks each generated `type/name` against the resource table in the
target dictionary (`stuff/tools/framework-res.apk`). A name the target does not have
is **not** a compile error — Android silently ignores it — so the build stops
instead of producing a module that changes nothing:

```
✓ Resource audit: 42 overrides exist in the target
⚠ 1 resource(s) are not in the target and would do nothing:
    bool/config_somethingFromAnotherRom
✗ Refusing to build a module that would silently change nothing.
```

The full list is written to `out/<name>-overrides.txt` (`APPLIES` / `IGNORED`).
If you intentionally target a resource added after the dictionary version, use:

```bash
./build.sh --allow-unknown-resources
```

A resource that exists in the dictionary but was **removed** in a later Android
release still compiles and is ignored by that release. The build only emits
resources that are present in Android 13 through 16 (for example
`config_pinnerHomeApp` was removed in Android 15 and is no longer emitted).

---

## Customizing `service.sh`

`service.sh` and `customize.sh` are generated from `config.env` and your
`src/vendor/` contents on every build. To add your own post-boot commands, copy
`stuff/templates/service.sh.example` to `src/module/service.sh` and edit it. When that
file exists the build packs it as-is instead of generating one. The same applies
to `src/module/customize.sh`. Remember to include the generated behaviour you
still want (overlay enable diagnostics, AOD property, HAL starts) when you take
over the file.

---

## Placeholder values

Any value that still contains an angle-bracketed placeholder — `<codename>`,
`<device_codename>`, `<manufacturer>`, … — is replaced with `generic` instead
of being used: identity values become `generic` (the build produces
`treble-overlay-generic-generic`) and a placeholder `DEVICE_PROP_NAME` falls
back to `ro.product.device`; an empty one still means "no condition". Useful
for testing the workflow, not for flashing on a real phone.

Numeric placeholders such as `000` are **not** detected; they are real numbers
(a 0px radius, a 0px bar). Replace them before building for a device.
