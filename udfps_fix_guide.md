# UDFPS Sensor Position Guide

How to get your device's UDFPS sensor position coordinates (X, Y, radius/size) for use in the overlay config.

---

## Method 1: Sysfs Position File (Fastest, Xiaomi/Oppo/Realme)

Some kernels expose the sensor position via sysfs. Try:

```bash
adb shell cat /sys/class/fingerprint/fingerprint/position
```

If it returns comma-separated numbers (`bottom_mm,?,height_mm,?,?,area_size_mm`), use the included script:

```bash
# Needs ADB connection + root
python3 get_udfps_location.py
```

It reads the position, gets display properties, and outputs the XML dimen values you need **IT IS NOT GUARANTEED TO BE THE RIGHT VALUES**.

---

## Method 2: Android Properties

```bash
adb shell getprop persist.vendor.fingerprint.sensor_location
adb shell getprop | grep -iE 'udfps|fingerprint.*sensor|fod'
adb shell getprop ro.udfps.sensor_pos_x
```

---

## Method 3: dumpsys fingerprint

```bash
adb shell dumpsys fingerprint | grep -iE 'location|sensor|bounds|udfps|mSensorLocations'
```

If the AIDL fingerprint HAL is running, it may dump `SensorLocationInternal` with x, y, radius.

---

## Method 4: Search Device Trees on GitHub

Find your device codename and search for:

```
device/<manufacturer>/<codename>/overlay/frameworks/base/core/res/res/values/
```

Look for:
```xml
<dimen name="physical_fingerprint_sensor_center_screen_location_x">XXXdp</dimen>
<dimen name="physical_fingerprint_sensor_center_screen_location_y">XXXdp</dimen>
```

Also check SystemUI dimens:
```xml
<dimen name="udfps_animation_size">280dp</dimen>
<dimen name="udfps_animation_offset">0dp</dimen>
```

---

## Method 5: Extract from Vendor Overlay APK

```bash
# List overlay APKs
adb shell ls /vendor/overlay/

# Pull and search, need adb root access, turn it on in developer options > Rooted debugging
adb root
adb pull /vendor/overlay/<name>.apk
# install jre-opensdk with your package manager, then install apktool, search on google for the install command
apktool d <name>.apk
grep -ri "fingerprint_sensor_location\|udfps\|sensor_position" ./<decompiled>/
```

---

## Method 6: Dump Device Tree Blob

```bash
# Pull the DTBO from device (root) or extract from firmware
adb shell su -c 'cat /sys/firmware/fdt > /data/local/tmp/dtb.dump'
adb pull /data/local/tmp/dtb.dump

# Decompile (install device-tree-compiler first)
dtc -I dtb -O dts dtb.dump > dtb.dump.dts

# Search for fingerprint position
grep -i fingerprint dtb.dump.dts
```

---

## Method 7: Physical Estimate (Last Resort)

Most UDFPS sensors are centered horizontally and positioned near the bottom:

| Display | X | Y | Radius |
|---------|---|---|--------|
| 1080x2400 | 540 | 2200-2280 | ~130-150 |
| 1440x3120 | 720 | 2920-3000 | ~130-150 |

- **X** = `display_width / 2`
- **Y** = `display_height - (120 to 200)` (adjust based on where the sensor icon appears on the lock screen)
- **Radius** = start with `140px` and adjust until the touch area matches the physical sensor
