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
               unzip zip curl wget tsu
```

If `pkg install` fails with signature or mirror errors, run
`termux-change-repo`, pick a mirror close to you, then repeat `apt update`.

> **Broken `curl`.** A `pkg upgrade` interrupted half way can leave `curl`
> unable to start (`CANNOT LINK EXECUTABLE "curl": cannot locate symbol ...`).
> `build.sh` then downloads with `wget` instead, which is why it is in the list
> above; `pkg upgrade -y` repairs `curl` itself.

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
     p  Profiles           saved config.env sets, one per device
```

**Profiles** are for more than one phone. A profile is a name plus a saved
`config.env`; exactly one is active, and it is the one `config.env` holds. On a
fresh clone there is none, and `p → n` names the current `config.env` as
`Profile #1`. Switch (`s`), rename (`r`) and delete (`d`) work the same way; you
can also do it from the shell:

```
./build.sh profiles                    # what is saved, which one is active
./build.sh profiles switch pixel       # by id or by name
./build.sh profiles new "Pixel 8"      # copy the active set under a new name
./build.sh profiles rename pixel "Pixel 8a"
./build.sh profiles delete old
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
no typing values between screens. Those four options need root; see
[section 5](#5-root-for-the-phone-probes).

Do not forget `src/framework/res/xml/power_profile.xml` — replace it with your
device's file, see
[device-extraction.md](device-extraction.md#power-profile-power_profilexml--mandatory).

---

## 5. Root for the phone probes

On a PC the probes ask the phone over `adb shell`. In Termux there is nothing to
plug in and no server to dial — the phone the probes want is the one the script
is already running on — so they read it directly instead: the same `getprop`,
`cmd overlay`, `wm`, `dumpsys` and `/vendor` reads, run natively.

That path needs root. Termux runs as an app UID, and `cmd`, `dumpsys` and most
of `/vendor` are closed to it. A root shell also lets `/vendor/build.prop` and
the vendor `overlay/` APKs be read for the firmware values the GSI no longer has.

Start the tool through `su` or `tsu`:

```bash
tsu ./build.sh          # recommended: root for the whole session
```

or just run `./build.sh`: it asks once, before the menu paints, and never again
for the rest of the session.

```
  Termux: root is needed to read /vendor and to install the module.
  Granting it now means no prompt lands on top of the build later.
    Give root access now? [Y/n]
```

That one question is the same `su` permission the manager would ask for anyway.
Asking for it first keeps the request off the top of a screen the tool is
mid-way through drawing. `--no-su` skips it (or `TREBLE_NO_SU=1`); the run then
escalates per command, exactly as it did before.

The first time you pick a probe in
Termux, the menu explains this once and offers to read the phone directly:

```
  This is Termux, so the phone is this one rather than a device on a cable.
  Reading it directly needs root: the same getprop, cmd overlay, wm and
  dumpsys reads a PC makes over adb.
  Read this phone as root? [Y/n]
```

`su` prompts for permission on the first read. The answer is remembered for the
session: every later probe — and `7` (Match property) — uses it without asking
again, and the options are labelled **this phone** rather than **the connected
phone**. Decline and the probes fall back to adb, which is what you want when a
second phone is on the cable (Termux's `android-tools` can reach one over
wireless debugging).

If no `su` binary exists:

```bash
pkg install tsu
tsu ./build.sh
```

Root not granted is reported, not worked around — every read would come back
empty and the report would look like a ROM that answers nothing.

Two practical notes:

- **The device wait.** On a PC a probe waits up to 120s for a cable to be
  plugged in. That wait cannot end on Termux, so when this machine is the phone
  the local source is chosen before the wait starts. `Ctrl-C` leaves a wait in
  any case and puts you back in the submenu.
- **Speed.** Each read is one root call, about the same count of round trips a
  PC makes over adb — a few seconds, not instant.

---

## 6. Install the module

```bash
./build.sh install          # push, hand it to the root manager, reboot, verify
./build.sh install --no-reboot   # install and leave the reboot to you
```

`install` picks the newest `out/*-ksu.zip` (or `--zip PATH`), copies it over,
hands it to whatever manager is really installed — `ksud` for KernelSU / KSU
Next, `magisk` for Magisk — reboots, waits for the phone to come back, and then
says whether the module is enabled and the overlay package is actually listed.
On Termux it installs on this phone directly and stops after the install,
because rebooting the machine the script is running on cannot be followed by a
check.

The menu carries the same thing: **1 Build → 8 Install**.

An overlay APK that already exists — built elsewhere, or signed by hand — can
be packed without compiling anything: **1 Build → 9 Wrap APK**, or
`./build.sh wrap --overlay overlay.apk [--systemui overlay-systemui.apk]`. The
zip lands in `out/wrap/`, separately from the release builds.

Or copy it yourself:

```bash
cp out/*-ksu.zip /sdcard/
```

Or let the menu do that: **8 Files → 1 Copy** writes the zip and its APKs to
`/sdcard/treble-rro-creator` — with `cp` on the phone, or `adb push` when a PC
ran the build. The terminal tells you how many files landed.

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
