# UDFPS Sensor Position Guide

How to get your device's in-display fingerprint (UDFPS) geometry —
`UDFPS_X`, `UDFPS_Y`, `UDFPS_RADIUS` — and how the tool asks for it.

The three values go into `android:array/config_udfps_sensor_props`, which tells
SystemUI where to draw the lock-screen icon and how big the touch target is.
They are physical facts about the panel, not a style choice: another device's
numbers put the icon next to the sensor, where no finger can reach it.

The geometry is only half of the job. On Xiaomi optical sensors the module also
has to put the touch panel into FOD mode and restore the display node the
vendor HAL opens; both are described in
[touch-panel FOD mode](#hbm-and-the-touch-panel-fod-mode) below.

---

## The probe

`stuff/scripts/udfps-probe.sh` asks the question every way that is known to
work, keeps the source of each answer, and ignores anything that does not fit
the panel. It prints a table and the `config.env` lines:

```bash
bash stuff/scripts/udfps-probe.sh                 # the only connected phone
bash stuff/scripts/udfps-probe.sh --device SERIAL # one of several
bash stuff/scripts/udfps-probe.sh --json          # machine-readable
bash stuff/scripts/udfps-probe.sh --write         # put the winner in config.env
bash stuff/scripts/udfps-probe.sh --firmware DIR  # unpacked OEM firmware
```

Both probes pick the phone the same way, through `stuff/scripts/adb-device.sh`:
one attached is used automatically, several means `--device` or a question on the
terminal, and a phone that is attached but not ready is named with its state and
its fix. That shared rule is described in
[detect.md](detect.md#more-than-one-phone).

The desktop app has the same thing in its **UDFPS** tab: *Read from the
connected phone*, or *Scan firmware* for a `super.img`, a Samsung AP, a ROM
folder or an extracted tree. Every row keeps its source visible, and **Use the
selected values** writes the three lines plus `HAS_UDFPS=true`.

There are three situations, and the probe says which one it is in.

### 1. OEM ROM on the phone

The strongest case. Everything the vendor ships is present and readable:

| Source | What it reads |
|---|---|
| Xiaomi FOD properties | `persist.vendor.sys.fp.fod.location.X_Y`, `…size.width_height` |
| Enabled overlays | `cmd overlay dump` → the APK that maps `config_udfps_sensor_props`, pulled and read with `aapt2` |
| The live array | `cmd overlay lookup android android:array/config_udfps_sensor_props` |
| HAL | `dumpsys fingerprint` when it prints a sensor location |
| Kernel | `/sys/class/fingerprint/fingerprint/position` on some vendors |

The overlay is the answer the framework itself is serving, so it outranks
everything inferred. The properties matter too: they are what the vendor's FOD
client uses to dim the screen and enable the sensor.

### 2. GSI on the phone

A GSI replaces `/system`, not `/vendor` or `/persist`, so the vendor FOD
properties usually survive and the device overlay that came with the GSI still
sits in `/product/overlay`. Both are read exactly as above.

Two traps the probe handles:

- An overlay the **module has patched before** leaves the OEM file next to it as
  `<name>.webui-orig`. The enabled APK then contains whatever was written last
  time, so it is not independent evidence and is demoted in the report.
- `cmd overlay lookup` returns the effective value, which may be this tool's own
  overlays. It is listed, but attributed as "source not attributed".

If a GSI has no overlay and no properties, the probe says so instead of
inventing numbers. The previous Python helper
(`stuff/scripts/udfps-location.py`) is still there for the sysfs-only kernels,
but it only understands that one source.

### 3. OEM firmware files

Point `--firmware` at an **already extracted** tree — a mounted or unpacked
`product/`, `vendor/`, `system_ext/`, a custom ROM's files, or a folder of pulled
APKs. It reads:

- every overlay APK it finds for `config_udfps_sensor_props` and
  `config_biometric_sensors` (with `aapt2`),
- `build.prop` / `prop.default` for the `ro.hardware.fp.fod*` flags **and** for
  the `persist.vendor.sys.fp.fod.*` rectangle,
- VINTF manifests and `.rc` files that mention the fingerprint HAL or
  `vendor.xiaomi.hardware.fingerprintextension`.

The rectangle is the one that usually answers. Most Xiaomi ROMs ship
`config_udfps_sensor_props` empty in `framework-res.apk` and no overlay that
fills it in: the sensor geometry lives only in `vendor/build.prop`, as the
factory default the vendor FOD client reads. The probe converts that pair with
the same arithmetic as the live phone (see
[Xiaomi FOD properties](#xiaomi-fod-properties-miui--hyperos--poco) below), so
`--firmware` and `--device` report the same numbers for the same build — for
example `540, 2198, 89` on `zephyr`.

A stock **fastboot ROM is not enough by itself**: on a dynamic-partition device
the APKs and props live inside `super.img`. Rather than extracting it by hand,
let the app do it — **Scan firmware** accepts the `super.img` itself, a Samsung
`AP_*.tar.md5`, the ROM folder or an extracted tree, and unpacks the partitions
first (see [gui.md](gui.md#unpacking-a-rom)). From a terminal the same unpacker
is the `-unpack` flag:

```bash
./treble-rro-creator.sh -unpack super.img             # prints the folder it wrote
bash stuff/scripts/udfps-probe.sh --firmware /tmp/treble-rro-firmware/super
```

Recovery-zip ROMs can be scanned after `unzip`, because their files are already
in the archive. Scanning every APK in a large dump is slow; the default looks at
overlay-looking names first, `--all-apks` opens everything.

---

## Reading the values by hand

### Xiaomi FOD properties (MIUI / HyperOS / POCO)

```bash
adb shell getprop persist.vendor.sys.fp.fod.location.X_Y
adb shell getprop persist.vendor.sys.fp.fod.size.width_height
```

Android 8 used the same names without `vendor` (`persist.sys.fp.fod.*`).

These are **not** a centre point and a radius. The first pair is the **top-left
corner** of the sensor rectangle, the second its **width and height**:

```
location.X_Y      = left,top
size.width_height = width,height

UDFPS_X      = left + width / 2
UDFPS_Y      = top + height / 2
UDFPS_RADIUS = min(width, height) / 2
```

Worked example — Redmi Note 17 4G (`zephyr`, 1080×2396):

```
persist.vendor.sys.fp.fod.location.X_Y      = 451,2109
persist.vendor.sys.fp.fod.size.width_height = 178,178

→ UDFPS_X=540  UDFPS_Y=2198  UDFPS_RADIUS=89
```

`451 + 89 = 540`, which is exactly `1080 / 2` — the arithmetic is what confirms
the corner reading. A centre reading would have produced 451, off-centre.

### The overlay that is actually enabled

```bash
# Only enabled overlays print an IDMAP block, and the mapping names the resource.
adb shell cmd overlay dump | grep -B12 'array/config_udfps_sensor_props'
```

Pull the `overlay path` from that block (world-readable, no root) and read the
array:

```bash
adb pull /system/product/overlay/<name>.apk
stuff/tools/aapt2 dump resources <name>.apk | grep -A3 config_udfps_sensor_props
```

```
resource 0x7f010001 array/config_udfps_sensor_props
  () (array) size=3
    [540, 2198, 89]
```

### Other sources

```bash
# Android properties some vendors use
adb shell getprop | grep -iE 'udfps|fingerprint.*sensor|fod'

# AIDL HALs may dump SensorLocationInternal
adb shell dumpsys fingerprint | grep -iE 'sensorLocation|location'

# Kernels that export the position as millimetres from the bottom
adb shell cat /sys/class/fingerprint/fingerprint/position

# Device tree / firmware: the OEM's own overlay
device/<manufacturer>/<codename>/overlay/frameworks/base/core/res/res/values/
<dimen name="physical_fingerprint_sensor_center_screen_location_x">XXXdp</dimen>
```

`physical_fingerprint_sensor_center_screen_location_*` is in **dp**, not px, and
only older devices use it — convert with the panel density before putting it in
`config.env`. The `UDFPS_*` values here are px.

The device-tree blob (`dtbo.img`) sometimes contains the touch-panel FOD region:

```bash
dtc -I dtb -O dts dtb.dump > dtb.dump.dts && grep -i -A2 fod dtb.dump.dts
```

### Physical estimate (last resort)

When nothing answers, the probe prints a scaled guess and refuses to write it
with `--write`. Most UDFPS sensors are centred horizontally and sit near the
bottom:

- **X** = `display_width / 2`
- **Y** = roughly `display_height - (0.07 … 0.09 × display_height)`
- **Radius** = roughly `0.08 × display_width` (89 px on a 1080-wide panel)

These are starting points only. Adjust until the lock-screen icon sits on the
sensor; a radius that is too small makes the touch target hard to hit, a too
large one makes the bright spot look wrong.

---

## HBM and the touch-panel FOD mode

Three separate things have to be true before the sensor can see a finger on a
Xiaomi optical device: the touch panel must be in FOD mode, the vendor FOD
engine must be able to open the display node it monitors, and something must
switch local HBM on around the capture. None of them is a resource, so no
overlay can supply them.

### The display node the HAL opens

The FOD engine lives in the vendor fingerprint HAL (`libmifpext.so`) and
hardcodes `/dev/mi_display/disp_feature`. It opens that path once, while it
initialises, and then registers for display events and sets local HBM through
it:

```text
D vendor.xiaomi.hardware.fingerprintextension@1.0: XiaomiFingerprint init
D android.hardware.biometrics.fingerprint@2.1-service-lx: FodEngineCore enable!
D android.hardware.biometrics.fingerprint@2.1-service-lx: open /dev/mi_display/disp_feature success
```

MIUI's system image creates that path. A GSI replaces `/system` and does not,
and the kernel only publishes `/dev/disp_feature`, so the same boot reads:

```text
E android.hardware.biometrics.fingerprint@2.1-service-lx: could not open /dev/mi_display/disp_feature
E android.hardware.biometrics.fingerprint@2.1-service-lx: open /dev/mi_display/disp_feature failed
```

The FOD engine then stays half-initialised, which is exactly the failure the
geometry check does not catch: the icon sits in the right place, the spot
behind it is grey and dim instead of a bright white circle, touches never
arrive, and the sensor looks dead even at full brightness.

The module re-creates the missing path in `post-fs-data.sh`, before the HAL's
`late_start` service, from the node the kernel did create:

```sh
DEV=$(cat /sys/class/mi_display/disp_feature/dev)   # e.g. 480:0
mkdir -p /dev/mi_display
mknod /dev/mi_display/disp_feature c ${DEV%%:*} ${DEV##*:}
chown system system /dev/mi_display/disp_feature
chmod 0660 /dev/mi_display/disp_feature
restorecon /dev/mi_display/disp_feature            # vendor_displayfeature_device
```

Both details matter. The node must be owned by `system` because the HAL runs as
that user (`user system` in its `.rc`), and it must carry the
`vendor_displayfeature_device` label so SELinux lets the fingerprint domain
open it. A root-owned `0600` node, or a symlink to the `device`-labelled
`/dev/disp_feature`, produces the same unhelpful `could not open …` message
with no denial in dmesg — check the label, not only the path.

```bash
su -c 'ls -lZ /dev/mi_display/disp_feature'
su -c 'logcat -d -b all | grep -E "disp_feature|FodEngine|XiaomiFingerprint" | tail'
```

### The touch-panel FOD mode

There is no AOSP overlay resource for HBM. The bright spot behind the
fingerprint icon is controlled by the fingerprint HAL and the panel driver, not
by the RRO. On Xiaomi devices the stock properties are
`ro.hardware.fp.fod=true`, `ro.hardware.fp.fod.location=low` and the
`ro.hardware.fp.fod.lowlight.*` thresholds; leave them alone.

`config_udfps_sensor_props` only tells SystemUI where to draw the icon and how
large the touch target is. It does **not** put the touch panel into fingerprint
mode, and on Xiaomi optical sensors that is a separate step:

- HyperOS: `FingerprintService` calls the vendor extension
  `vendor.xiaomi.hardware.fingerprintextension.extCmd(4, 3)`, which calls
  `vendor.xiaomi.hardware.touchfeature.setModeValue(10, 3)`.
- `setModeValue` is `ioctl(0x5400, {10, 3})` on `/dev/xiaomi-touch`; the driver
  logs it as `Mode:FOD fod_status = 3`, and a released mode as `0`.
- With the panel in that mode the touch controller reports presses in the
  sensor area (`/sys/devices/virtual/touch/touch_dev/fod_press_status`), and
  the vendor Goodix HAL wakes the sensor and captures an image.
- Local HBM is a separate ioctl (`0x400c440e` on
  `/dev/mi_display/disp_feature`; 2 = on, 1 = off). On HyperOS the HAL turns it
  on around the capture; on a GSI it refuses, with
  `skip enable lhbm as fingerprint is idle` — that check expects the MIUI
  fingerprint client, which is the thing a GSI does not have.

A GSI has no HyperOS fingerprint client, so the first call never happens: the
panel stays in normal touch mode, the HAL never sees the finger, and the sensor
looks dead even though the icon is in the right place. Even with the panel
armed, the sensor only gets ambient light and the HBM step is skipped.

The module ships `fod/xiaomi-fod`, a small arm64 helper that issues the same
ioctls. `service.sh` starts it when `/dev/xiaomi-touch` exists and
`ro.hardware.fp.fod=true`. The daemon copies the state machine the stock touch
driver logs: mode 10 is armed with value 3 (FOD plus the AOD wake bit) when the
screen turns off, stays armed while the keyguard is showing (lock screen and
AOD) or a fingerprint client is running (settings enrollment, in-app prompts),
and is released with 0 otherwise. It reads the panel backlight,
`dumpsys window policy` and `dumpsys fingerprint` for that, so it needs no MIUI
service.

Because the vendor HAL will not light the panel on a GSI, the same daemon
drives local HBM. While the panel is armed it watches `fod_press_status` every
50 ms and turns HBM on when the finger lands, and off as soon as the finger is
up and no prompt is left (a 150 ms hold covers the capture, and the prompt
disappearing ends it early). That is
the stock behaviour — the spot stays dark until the sensor is touched — and it
keeps the bright circle out of the lock screen and the AOD.

A press with the display asleep works the same way, with one extra step. The
touch controller reports it in suspend, the daemon lights HBM (about 10 ms) and
wakes the screen with `input keyevent 224`. The wake is not cosmetic: with the
panel asleep the vendor HAL starts an auth, waits 1500 ms for the fingerprint
UI to answer and aborts with
`GF_ERROR_UI_READY_TIMEOUT`, because the GSI's SystemUI has no UDFPS view up in
doze. Waking brings the keyguard's prompt up inside that window, so the same
press goes on to unlock the phone. The `screen_off_udfps_enabled` Secure setting
is not consulted: this GSI's SystemUI does not act on it, and MIUI wakes the
display on that press anyway.

The prompt itself is noticed from SystemUI's own logs: `logcat` is filtered to
`UdfpsController` and `UdfpsControllerOverlay`, and `showUdfpsOverlay` arms the
panel the moment the window appears (opening enrollment, an in-app biometric
prompt), while `hideUdfpsControllerOverlay` releases it. That costs nothing
while no line arrives. A `dumpsys fingerprint` check every 5 s is kept as a
fallback for GSIs whose SystemUI uses different tags, and the keyguard is
refreshed with `dumpsys window policy` every 2 s.

Manual checks, useful when the icon is right but the sensor is silent. Run them
through `su -c`; a plain adb shell process is not allowed to open the touch
node.

```bash
# Arm the touch panel's FOD mode (3 = FOD + AOD, 0 = release)
su -c '/data/adb/modules/<module>/fod/xiaomi-fod touch 10 3'
su -c 'dmesg | grep "Mode:FOD"'       # fod_status = 3 while armed, 0 after release

# Local HBM: 2 = on, 1 = off. The daemon does this on press; use it to test
# the panel and the ioctl by hand.
su -c '/data/adb/modules/<module>/fod/xiaomi-fod hbm 2'
su -c '/data/adb/modules/<module>/fod/xiaomi-fod hbm 1'

# What the daemon did
su -c 'cat /data/adb/modules/<module>/fod.log'
```

---

## The UDFPS icon colour

`UDFPS_COLOR` in `config.env` sets SystemUI's `config_udfpsColor`, the colour
the icon and the light behind it are painted with:

```bash
UDFPS_COLOR="#ffffff"   # #rrggbb or #aarrggbb; the leading # is optional
```

It is written into the SystemUI overlay, so it needs `HAS_UDFPS=true` and a
rebuild ([configuration](configuration.md#fingerprint-udfps)). AOSP's default
is already opaque white, though: if the spot looks grey rather than white, the
colour is not the problem — local HBM is not on. Check `fod.log` for the
`local hbm` lines and the node first (see
[the display node](#the-display-node-the-hal-opens)).

A device without the vendor fingerprint HAL or without `/dev/xiaomi-touch`
still gets the overlay values only; there is nothing for the helper to drive.
