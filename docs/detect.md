# Automatic detection

Some of the values in `config.env` are not style choices — they are facts about
the panel. A guessed cutout path puts the status bar under the camera, a guessed
corner radius cuts icons in half, a guessed refresh rate makes the screen stutter
or drains the battery. The **Detect** tab asks the phone (or an unpacked ROM) for
those facts and shows which source answered each one.

```bash
bash stuff/scripts/device-probe.sh                # the only connected phone
bash stuff/scripts/device-probe.sh --device SER    # one of several
bash stuff/scripts/device-probe.sh --firmware DIR # an extracted ROM
bash stuff/scripts/device-probe.sh --write        # put the winners in config.env
bash stuff/scripts/device-probe.sh --power-profile # print res/xml/power_profile.xml
```

The window runs the same script (`--json`) through `POST /api/detect`, so the
command line and the tab can never disagree.

## More than one phone

With two phones attached, adb refuses to guess and so does this: running the
probe with no `--device` prints the list and stops. On a terminal it asks first,
with the model next to each serial:

```
More than one device is connected:
  RFCM90F5BBX        device        SM_A908N (lineage_r3q)
  595648cf1cdc       device        26012RN62A (zephyr_global)
Which device? [1-2] or a serial:
```

A number, a full serial or a prefix only one serial shares is accepted. Without
a terminal (the desktop app, a pipe, CI) it stops with the same list and says
`--device SERIAL`, because picking the wrong phone is how the wrong phone gets
written to.

The app has the same list as a picker on the Device, Detect and UDFPS tabs. It
is filled from `adb devices -l`, the last pick is remembered, and every command
carries that serial — one phone is still automatic, so the usual case needs no
clicks. Phones that are attached but not ready are listed with their state:
`unauthorized` needs the prompt on the phone accepted, `offline` needs a replug,
`no permissions` is a udev rule on Linux.

The logic is in `stuff/scripts/adb-device.sh`, shared by this probe and the
UDFPS one, and tested by `stuff/tests/adb-device.test.js`.

## What it reads

| Setting | Resource it feeds | Sources, best first |
|---|---|---|
| `DISPLAY_CUTOUT` | `config_mainBuiltInDisplayCutout` | the applied `DisplayCutout` from `dumpsys window displays`; an enabled overlay's APK; the OEM `framework-res.apk` |
| `ROUNDED_CORNER_RADIUS` | `rounded_corner_radius` | the HWC geometry in `dumpsys display` |
| `STATUS_BAR_HEIGHT` | `status_bar_height_default` | an enabled overlay's APK; `cmd overlay lookup` (the dimen the module writes); the status bar window's rendered height, as a check |
| `STATUS_BAR_HEIGHT_LANDSCAPE` | `status_bar_height_landscape` | the ROM's `values-land` (firmware scan only) |
| `DEFAULT_REFRESH_RATE` | `config_defaultRefreshRate` | the highest panel mode (the running rate is adaptive, so it is not usable) |
| `PEAK_REFRESH_RATE` | `config_defaultPeakRefreshRate` | the highest mode in `supportedModes` |
| `BRIGHTNESS_MAX` / `_MIN` / `_DEFAULT` / `_DIM` / `_DARK` / `_DOZE` | `config_screenBrightness*` | the framework integer resources (0–255) |
| `HAS_AOD` | `config_dozeAlwaysOnDisplayAvailable` | the framework boolean |
| `HAS_DOZE` | `config_dozeAfterScreenOffByDefault` | the framework boolean |
| `HAS_DOUBLE_TAP_WAKE` | `config_supportDoubleTapWake` | the framework boolean |
| `HAS_BURN_IN_PROTECTION` | `config_enableBurnInProtection` | the framework boolean |
| `HAS_VOLTE` | `config_device_volte_available` | the framework boolean |
| `HAS_5G` | `config_telephony5gNonStandalone` | the modem's NR bitmask in `dumpsys telephony.registry`; `ro.telephony.default_network` (both `low`: see below) |
| `LIGHT_SENSOR_TYPE` | `config_displayLightSensorType` | `cmd overlay lookup` only — the ROM's own string |
| `HAS_SAMSUNG_FOD` | — (module service) | whether `/sys/class/sec/tsp/cmd` exists |
| `HAS_SAMSUNG_VIBRATOR` | — (module service) | `init.svc.sec-vibrator-2-2` or the service in `/vendor/etc/init` |
| `HAS_SAMSUNG_FINGERPRINT` | — (PHH property) | `/dev/goodix_fp` (only reported when it is there) |

Each row keeps its source and a confidence, and two sources with different
numbers stay as two rows — that disagreement is usually an OEM value next to the
GSI's default, and it is the thing worth looking at.

## Why the sources are not interchangeable

* **Display hardware facts** (corners, refresh modes) come from the panel driver.
  They are the same on the OEM ROM and on a GSI, so they are the strongest
  runtime evidence there is.
* **Framework resources** are what the running ROM is *serving*. On a GSI that
  can be the GSI's own default rather than the OEM's choice, and once this
  module is installed the answer can be the module's own overlay. The probe says
  so: a value that the module's overlay sets is marked `medium` with
  "not independent evidence" in its detail.
* **The OEM's own files** are the only ones that still hold the OEM's intent
  after a GSI replaced the system partition. On a device that means the enabled
  overlay APKs under `/product/overlay`; otherwise it means the ROM dump.

Refresh rates need the same care. The rate the panel is *running* at is not its
rating: adaptive refresh reported 60 Hz on one run and 120 Hz on the next on the
same phone, which is why both settings come from the `supportedModes` list. The
ROM's own `config_defaultPeakRefreshRate` is not trustworthy either — MIUI
declares 240 on a 120 Hz panel — so it is only mentioned, never copied.

A concrete example from the reference device (Xiaomi, HyperOS 3 / Android 16):
the OEM ROM reports a 144 px corner radius, a 118 px status bar, a 120 Hz panel
and a small cutout `M 0,0 H -29 V 118 H 29 V 0 H 0 Z`. The same phone on a GSI
reported **135 px** corners — the value an earlier build of this module had
written — and no cutout at all, because `config_mainBuiltInDisplayCutout` lives
in the OEM system partition the GSI replaced. That is the reason for the
confidence column: read these values on the OEM ROM, or from a ROM dump, and
treat a GSI's own answer as "what that ROM uses", not as the OEM's number.

## Scanning a ROM dump

The firmware mode reads `framework-res.apk` and every `*/overlay/*.apk` under the
folder and does not need a phone:

```bash
bash stuff/scripts/device-probe.sh --firmware ~/roms/r3q --json
```

A fastboot ROM keeps those APKs inside `super.img`. The desktop app unpacks it
itself: **Scan firmware** takes the `super.img`, a Samsung `AP_*.tar.md5`, the
ROM folder or an extracted tree, and needs no `lpunpack` (see
[gui.md](gui.md#unpacking-a-rom)).

On the command line, unpack with the same code and point the probe at the
result:

```bash
./treble-rro-creator.sh -unpack super.img
# unpacked to /tmp/treble-rro-firmware/super
bash stuff/scripts/device-probe.sh --firmware /tmp/treble-rro-firmware/super
```

If you already have the partitions as separate images (mounting them with
`lpunpack` + loop mounts works too), point `--firmware` straight at that tree.

The scan also reads the `build.prop` files for `ro.sf.lcd_density`, because a
dimen written in `dp` cannot become `px` without it.

## Brightness and feature flags

The six `BRIGHTNESS_*` values are the framework's 0–255 setting scale, not the
panel's raw scale: on the reference device the backlight goes to 4095, and the
probe prints that in the notes so the two numbers are not confused. The float
twins AOSP also defines (`config_screenBrightnessSettingMaximumFloat`, …) are
derived by the build as `value / 255`; an OEM's own floats can use the raw scale
instead (the reference device has `MinimumFloat = 0.0017` next to a minimum of
10), so only the integers are written.

The `HAS_*` rows are mostly framework booleans. Two of them need care:

- `HAS_DOUBLE_TAP_WAKE` reads `config_supportDoubleTapWake`, AOSP's own switch.
  MIUI leaves it `false` while its touch driver provides double-tap-to-wake, so
  a `false` row does not mean the phone lacks the gesture. Copy the value only
  if you want the AOSP path.
- `HAS_5G` is **evidence only, never written**. Two phones show why: the Galaxy
  A90 5G reports `PhoneCapability.mDeviceNrCapability [1]` and
  `ro.telephony.default_network=26`, and a Redmi Note 17 **4G** reports `[1, 2]`
  and `33`. Both are AOSP NR values (`1` = non-standalone, `2` = standalone,
  `23`–`33` = the NR network modes), so the telephony config cannot tell a 4G
  modem from a 5G one — Xiaomi shares it with the 5G sibling model. The probe
  shows both rows with `low` confidence and a note; neither is preselected and
  `--write` skips them. Set `HAS_5G` from the phone's specifications.

`config_telephony5gNonStandalone` is still not used: it says the telephony
stack supports NSA and is `true` on 4G ROMs as well.

The distinction that does hold is hardware vs registration. A ROM whose IMS does
not come up — Samsung's vendor IMS on a GSI is the common case — can sit on LTE
with no 5G icon while the phone's specs say 5G. That is why the row is a setting
to confirm, not a fact to read.

`LIGHT_SENSOR_TYPE` is the opposite lesson: only the ROM's own string is
copied. It either names a vendor type (Samsung: `com.samsung.sensor.physical_light`)
or is empty, and an empty `config_displayLightSensorType` means the ROM registers
no display light sensor — adding one would change its behaviour. The sensor HAL's
list is printed as a note, not used as a source: picking a name from it by shape
produced `xiaomi.sensor.light_raw` on a HyperOS phone whose resource is empty,
which is a raw ADC sensor, not the display one.

Three more switches are read from the vendor partition, because the module acts
on a specific node or init service: `HAS_SAMSUNG_FOD` (the Samsung touch driver's
`/sys/class/sec/tsp/cmd`), `HAS_SAMSUNG_VIBRATOR` (`sec-vibrator-2-2` in
`/vendor/etc/init`), and `HAS_SAMSUNG_FINGERPRINT` (a `/dev/goodix_fp` node; it is
only reported when present, since the absence of that node does not prove the
sensor is not Goodix).

What cannot be read from a phone at all:

- `HAS_VENDOR_FINGERPRINT_HAL` and `HAS_VENDOR_VIBRATOR_HAL` describe which files
  you extracted into `src/vendor/`, not the device — set them after the files are
  there ([device-extraction.md](device-extraction.md)).
- `DOZE_SUSPEND_UNSUPPORTED` is a workaround for a panel that hangs on
  DOZE_SUSPEND. No flag reports that; you set it when AOD breaks on your panel.

## The power profile

`--power-profile` (the **Power profile** card in the tab) is the one setting that
is a file rather than a number. The probe finds `res/xml/power_profile.xml` in
the enabled overlay that maps it, or in `framework-res.apk`, and prints what
`aapt2 dump xmltree` gives: an indented tree, not XML. The desktop app converts
that tree back into a document, checks that it is well-formed with a `<device>`
root and at least one entry, and shows it before **Save** writes
`src/framework/res/xml/power_profile.xml`. The build compiles exactly that file
into the overlay.

The source matters more than it looks. The copy inside `framework-res.apk` is
often the **AOSP placeholder** — every value `0.1`, a single 400 MHz CPU speed
and a 1000 mAh battery — and shipping that over the ROM's real profile is worse
than shipping nothing. The probe therefore reads every enabled overlay that maps
`xml/power_profile` first, skips any profile that does not look like a device
(CPU speeds in the GHz range, screen currents in mA, a battery in the thousands),
and fails with a named candidate instead of saving the placeholder. On the
reference device the real file is in `/vendor/overlay/FrameworksResTarget_Vendor.apk`
(38 entries: 149.73 mA screen-on, 621.14 mA full brightness, CPU clusters from
300 MHz to 1.9 GHz, 7700 mAh) — a root-only file, which is why the probe falls
back to `su 0 cat` when `adb pull` cannot read it.

On HyperOS `cmd overlay dump` also needs root; without that fallback the probe
saw no overlays and read the generic `framework-res` copy, which is exactly how
the placeholder ended up in the first report.

A `@0x…` resource reference inside the compiled XML is refused with the
attribute named: aapt2 cannot resolve it without the resource table, and writing
the raw id would not compile.

## Writing the values

In the tab, untick anything you do not want and press **Write the ticked values**.
Only the settings in the table above are accepted; a typo in a key or a value
outside the panel's range is refused instead of written. The lines keep their
place and their comments, and a commented-out `DISPLAY_CUTOUT` is switched on
rather than duplicated — the same edit path the `config.env` form uses.

The cutout path is written quoted, because it contains spaces:

```
DISPLAY_CUTOUT="M 0,0 L 120,0 L 120,80 L 0,80 Z @dp"
```

MIUI's own path has neither spaces nor a unit suffix
(`M 0,0 H -29 V 118 H 29 V 0 H 0 Z`) and is written exactly as the framework
stores it; the path is centred by `DisplayCutout`, so the negative X is correct.

## Adding another setting

The script is deliberately plain: a setting is one `add_fact` call with its key,
label, unit, value, source, confidence and detail. A new source for an existing
setting is another call with the same key and a different `source`; the page
shows both and the user picks. `gui/detect.go` needs the key in `detectKeys` with
a range check, and that is all the window needs to offer it.
