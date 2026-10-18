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

The first run checks the toolchain. If something is missing it installs it
(aapt2/zipalign/apksigner via `pkg`, `framework-res.apk` by download), then
builds. To choose things yourself:

```bash
./build.sh setup     # [3] Android / Termux, then [1] Android 13 resources
./build.sh doctor    # verify
./build.sh check     # validate config.env only
```

If `build.sh` cannot install packages unattended, it prints the exact command
to run. `./build.sh setup` walks through the options interactively.

---

## 4. Edit the config

Use a text editor in Termux:

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
> **Never use OverlayFS** — it can bootloop the device.

---

## Tips

- Keep the project inside Termux home. Moving it to `/sdcard` breaks execution
  permissions.
- `./build.sh clean` frees space; `./build.sh clean --all` starts over for a
  new device. Backups go to `backups/`.
- Building needs roughly 300 MB free for the toolchain and intermediates.
- If Termux is killed during a download, just run `./build.sh` again — already
  downloaded pieces are reused.
- Logs are printed in the terminal. For a detailed trace:
  `bash -x ./build.sh 2>&1 | tee build.log`.
