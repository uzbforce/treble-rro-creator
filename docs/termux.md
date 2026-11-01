# Termux (Android)

You can build the overlay on the phone itself. The toolchain is the same; only
the install step differs.

> Use Termux from **[F-Droid](https://f-droid.org/en/packages/com.termux/)**.
> The Google Play version is outdated and its packages are incompatible.

---

## 1. Prepare Termux

```bash
termux-setup-storage

apt update
apt upgrade -y

apt install -y git aapt aapt2 apksigner android-tools openjdk-17 \
               unzip zip curl tsu
```

If `pkg install` fails with signature or mirror errors, run
`termux-change-repo`, pick a mirror close to you, then repeat `apt update`.

> **`zipalign` comes from the `aapt` package, not from `aapt2`.** Installing
> `aapt2`, `apksigner` and `android-tools` leaves `zipalign` missing; adding
> `aapt` provides it. If it is still absent, `build.sh` continues and copies
> the APK instead of aligning it (valid, just not mmap-aligned) and tells you
> to run `pkg install aapt`.

---

## 2. Clone into the home directory

```bash
cd ~
git clone https://github.com/uzbforce/treble-rro-creator
cd treble-rro-creator
```

> ⚠️ **Do not clone into `/sdcard`.** Android's shared storage does not support
> executable permissions or the symlinks `aapt2`/`zipalign` need. Use `~`
> (`/data/data/com.termux/files/home`).

---

## 3. Build

```bash
./build.sh
```

On a terminal this opens the **menu**, which is the desktop app's toolkit in a
numbered list — the same build, the same `config.env` editor, the same phone
probes. Termux has no window, so this is the full interface on the phone:

```
     1  Build              dry run, build, check, doctor, clean
     2  config.env         browse and edit one key at a time
     3  Addons             module tweaks: settings and overlay resources
     4  Device             read manufacturer, model, codename from the phone
     5  Auto Detect        ROM answers: cutout, corners, refresh rate, VoLTE, 5G
     6  UDFPS              in-display fingerprint geometry
     7  Match property     which property the submission should match on
     8  Files              what was built, and where it is
     9  Docs               the guides in docs/
```

`1 → 2` is the build. The first run checks the toolchain: if something is
missing it installs it (aapt2/zipalign/apksigner via `pkg`,
`framework-res.apk` by download), then builds.

To skip the menu, use the verbs directly:

```bash
./build.sh build     # build, installing tools if needed
./build.sh setup     # [3] Android / Termux, then [1] Android 13 resources
./build.sh doctor    # verify
./build.sh check     # validate config.env only
```

If `build.sh` cannot install packages unattended, it prints the exact command
to run. `./build.sh setup` walks through the options interactively.

---

## 4. Edit the config

`2` in the menu lists `config.env` by section with the value next to each key,
`on`/`off` for the ones that are commented out, and writes the change in place —
the comments and the file's shape stay as they are. That is quicker on a phone
than hunting for a `#` in a 240-line file.

Use a text editor when you want to see the notes above each key:

```bash
nano config.env
```

`Ctrl+O` then `Enter` saves, `Ctrl+X` exits. Or edit the same file with
MT Manager at:

```
/data/data/com.termux/files/home/treble-rro-creator/config.env
```

Required values and every optional flag are listed in
[configuration.md](configuration.md).

With the phone in the same hand, `4` (Device) fills in `DEVICE_CODENAME`,
`DEVICE_MANUFACTURER` and `DEVICE_MODEL` from `getprop`, `5` (Auto Detect) reads
what the running ROM says about the hardware — cutout path, corner radii, status
bar height, refresh rates, the VoLTE and 5G flags, the light sensor and the OEM
switches — and `6` (UDFPS) finds the fingerprint sensor's real geometry. No PC,
no typing values between screens.

Do not forget `src/framework/res/xml/power_profile.xml` — replace it with your
device's file, see
[device-extraction.md](device-extraction.md#power-profile-power_profilexml--mandatory).

---

## 5. Install the module

```bash
cp out/*-ksu.zip /sdcard/
```

Then either:

- open your root manager (KernelSU / KSU Next / Magisk) → Modules → install the
  zip, or use MT Manager to pick it from `/sdcard/`, or
- from a PC over ADB:

```bash
adb shell su -c 'ksud module install /sdcard/treble-overlay-<device>-ksu.zip'
```

Reboot when done.

> **KernelSU / KSU Next:** install **Magic Mount** (or Hybrid Mount configured
> for magic mount) before flashing overlay modules.
> **Never use OverlayFS** — it mounts fine, but a mistake in a vendor build's
> `sepolicy.rule` or VINTF manifests then bootloops the device; magic mount
> ignores the bad file and boots.

---

## Tips

- Keep the project inside Termux home. Moving it to `/sdcard` breaks execution
  permissions.
- `./build.sh clean` frees space; `./build.sh clean --all` starts over for a
  new device. Backups go to `stuff/backups/`.
- Building needs roughly 300 MB free for the toolchain and intermediates.
- If Termux is killed during a download, just run `./build.sh` again — already
  downloaded pieces are reused.
- Logs are printed in the terminal. For a detailed trace:
  `bash -x ./build.sh 2>&1 | tee build.log`.
