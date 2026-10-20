# Submitting to the overlay repo

A module has to be installed on every device, and re-installed after every
module update. The alternative is to get the overlay **built in**: overlays in a
vendor overlay repo are compiled by the ROM's GSI build, and the framework picks
the one overlay whose match condition fits the device. No module, nothing to
update.

**Target: [Doze-off/vendor_hardware_overlay](https://github.com/Doze-off/vendor_hardware_overlay).**
That is the repo this project submits to. It is the actively maintained one, still receiving new device overlays and fixes. It
is a continuation of
[TrebleDroid/vendor_hardware_overlay](https://github.com/TrebleDroid/vendor_hardware_overlay):
The zip this project builds works in both, so
open one PR where you want the overlay to land; only open a second one if you
also want it upstream.

This project already builds that source tree:

| File | What it is |
|---|---|
| `out/<name>-hardware-overlay.zip` | The exact folders to copy into the repo |
| `out/<name>-hardware-overlay-test.zip` | A flashable module with the APKs that tree builds |
| `_submission/HOW-TO-SUBMIT.md` (inside the zip) | The same steps, with this device's values filled in |

Preview without building:

```bash
./scripts/hardware-overlay.sh plan
```

The [How to create an overlay?](https://github.com/TrebleDroid/treble_experimentations/wiki/How-to-create-an-overlay%3F)
wiki page is still the reference for *extracting* the stock values. It is out of
date about *matching* them — see [step 1](#1-the-match-condition-is-exact--the-wiki-is-wrong-here).

---

## What the repo expects

```
overlay.mk                            # every module listed
Brand/Model/AndroidManifest.xml       # target android, static, priority, match
Brand/Model/Android.mk                # LOCAL_PACKAGE_NAME, product/overlay
Brand/Model/res/values/*.xml          # the resources (config.xml, bools.xml, …)
Brand/Model/res/xml/power_profile.xml
Brand/Model-SystemUI/…                # optional, target com.android.systemui
```

Other files in the repo, for orientation: `build/` (the repo's own `aapt`,
`signapk` and `build.sh`), `tests/tests.sh` (the submission checker),
`tests/blacklist` and `tests/knownKeys` (its data), `.github/workflows/Build.yml`
(the `Overlay` workflow) and `azure-pipelines.yml` (older CI, still present).

`tests/tests.sh` is the rulebook, whether or not anything runs it for you:

- a priority that another static `android` overlay already uses is a **failure**
- a resource name in `tests/blacklist` is a **failure**
- a resource name that AOSP does not have is a **failure**
- `overlay.mk` must list every module, sorted, each line ending with `\`
- `config_automatic_brightness_available = true` without a brightness curve is a
  **failure**
- `power_profile.xml` may only contain known element names, and a
  `battery.capacity` of 1000 is rejected
- `public.xml` and `color_extraction.xml` are rejected

`./build.sh` already avoids all of this, with one exception: a
`power_profile.xml` you extracted yourself is copied verbatim, so its element
names are not checked here. The last two are about files this project does not
generate at all.

---

## How a submission actually goes through

Watching the merged pull requests in the Doze-off repo — new device folders
(#105, #116, #117), fixes to existing ones (#107, #109, #110, #111, #112) — the
flow is:

1. **A pull request against `pie`.** That is the repo's only active branch (and
   its default), so the PR form fills it in for you. Every merged overlay PR in
   the repo has `pie` as the base.
2. **Only two kinds of change:** the new `Brand/Model/` (and optional
   `Brand/Model-SystemUI/`) folders, plus the matching lines in `overlay.mk`.
   No APKs, no `build/` output, no notes folder, no `tests/` edits.
3. **Nothing runs the checks for you on this fork.** The repo carries the
   `Overlay` workflow, but GitHub leaves Actions off on forks and the Doze-off
   repo's Actions tab has zero runs — the PRs merged there never had a CI
   result. So `bash tests/tests.sh` in your clone is the only gate before the
   maintainer looks at the PR. (Upstream TrebleDroid does run that workflow on
   PRs to `pie`.)
4. **The maintainer reviews and merges by hand**, usually within days, with a
   merge commit ("Merge pull request #116 from …"). PR #113 was closed instead,
   with the whole review being "Wrong format" — that is what the naming section
   below is for.
5. **Issues are disabled on the repo.** The PR thread is the only feedback
   channel; the maintainer also links a Telegram group
   (<https://t.me/dozeoff_treble>) from his profile.

Nothing in the flow is automated, so a tidy PR that passes the test script and
matches the repo's naming is what gets merged.

---

## Naming: the part a reviewer rejects first

The repo's folders and modules follow the existing tree, not a formula. Real
examples: `Asus/Rog5_5s`, `Infinix/Hot30I-X669C`, `Xiaomi/RedmiA5`,
`Samsung/A54x`, `Moto/G8Power`.

| What | Rule | Example |
|---|---|---|
| Folder | `Brand/Model`, brand once, capitalised, no spaces | `Xiaomi/RedmiA5` |
| SystemUI folder | `Brand/Model-SystemUI` | `Xiaomi/RedmiA5-SystemUI` |
| `LOCAL_PACKAGE_NAME` | `treble-overlay-<brand>-<model>`, lowercase | `treble-overlay-xiaomi-redmia5` |
| SystemUI module | same, `-systemui` suffix | `treble-overlay-xiaomi-redmia5-systemui` |
| Manifest package | `me.phh.treble.overlay.<brand>.<model>` | `me.phh.treble.overlay.xiaomi.redmia5` |

The first two come from `DEVICE_MANUFACTURER` and `DEVICE_CODENAME` in
`config.env` — set them to the folder names (`DEVICE_MANUFACTURER="Xiaomi"`,
`DEVICE_CODENAME="RedmiA5"`), not to `Xiaomi/RedmiA5` or `xiaomi-redmia5`.
The module name is derived from them and lowercased, with anything that is not a
letter or digit turned into a dot (`Rog5_5s` → `treble-overlay-asus-rog5.5s`); if
yours does not read like the table, set `OVERLAY_NAME` explicitly. PR #113 was closed because the tree
was `ITEL/itel-P11002L` with a `treble-overlay-ITEL-itel-P11002L` module and no
`overlay.mk` change.

---

## Before you submit

### 1. The match condition is exact — the wiki is wrong here

The wiki (and many older manifests in the repo, which never activate) tells you
to write:

```xml
android:requiredSystemPropertyValue="+*samsung/r3q*"
```

`*` and `+` are **not** wildcards. The framework compares the property with
plain string equality — `FrameworkParsingPackageUtils#checkRequiredSystemProperties`
— so a value with a `+` or `*` never matches, and the overlay is simply never
enabled. It looks installed, it does nothing. (This is not a theory: the repo's
own `Asus/Rog5_5s/AndroidManifest.xml` documents the same finding after the
property mismatch was reproduced in PackageManager logs, and the overlay was
switched to an exact value in PR #107.)

This project writes an exact match instead:

```xml
android:requiredSystemPropertyName="ro.product.vendor.device"
android:requiredSystemPropertyValue="r3q"
```

Check yours:

```bash
adb shell getprop ro.product.vendor.device
```

`ro.product.vendor.device` lives on the vendor partition: it survives a GSI
flash and does not change with an OTA. Override the pair in `config.env` if your
device reports something else:

```bash
HW_OVERLAY_MATCH_PROP="ro.product.vendor.device"
HW_OVERLAY_MATCH_VALUE="what getprop printed"
```

`ro.vendor.build.fingerprint` also works, but it contains the build number, so
every OTA makes the overlay stop matching. An empty `HW_OVERLAY_MATCH_PROP`
submits an always-active overlay — only sensible for a property-less device.

### 2. Only values the product overlay actually differs on

The GSI already has the vendor overlay; an overlay in this repo only has to
carry what the **product** overlay changes. Copying every value from the stock
overlays is the most common reason a PR is sent back. See
[device-extraction.md](device-extraction.md) for pulling the stock values out.

### 3. A real `power_profile.xml`

The file is only included once you replace the template in
`src/framework/res/xml/power_profile.xml` with your device's own profile
([how to extract it](device-extraction.md)). An empty template is skipped, and
the GSI falls back to its own profile.

### 4. A priority nobody uses

`android:priority` decides which static overlay wins when two set the same
resource, and the repo rejects duplicates. `OVERLAY_PRIORITY` (used by the
module) is not reused for the submission: its default, 628, is already taken by
four overlays in the repo.

The build picks a free number from a snapshot of the repo's priorities
(`scripts/data/treble-overlay-priorities.txt`), starting at a value derived from
the device name. Override it with `HW_OVERLAY_PRIORITY` in `config.env` — or take
the number `tests/tests.sh` prints for you, which is authoritatively up to date.

### 5. Resource names the repo forbids

`tests/blacklist` names resources an overlay may not force (user preferences,
mostly). This project drops them from the submission and reports which ones:

```
→ Dropped config_cellBroadcastAppLinks config_dozeComponent config_enableMultiUserUI
  config_multiuserMaximumUsers config_unplugTurnsOnScreen (the overlay repo
  blacklists these; the module still sets them)
```

The module keeps them, so the device looks the same either way.

---

## Step by step

### 1. Test it first

Flash `out/<name>-hardware-overlay-test.zip`, reboot:

```bash
adb shell cmd overlay list --user 0 | grep me.phh.treble.overlay
adb shell cmd overlay lookup me.phh.treble.overlay.<brand>.<model> android:dimen/rounded_corner_radius
```

Both commands take the **package** name from the manifest
(`me.phh.treble.overlay.<brand>.<model>`), not the module name
(`treble-overlay-<brand>-<model>`) — that only exists in the build.
`lookup` printing your value means the match condition and the resources are
both right. Nothing changed? Compare `adb shell getprop
ro.product.vendor.device` with `android:requiredSystemPropertyValue` in the test
APK's manifest; a mismatch silently disables it.

### 2. Fork, clone, branch

Fork <https://github.com/Doze-off/vendor_hardware_overlay> on GitHub (keep
"Copy the `pie` branch only", that is the only one that matters), then:

```bash
git clone https://github.com/<your-user>/vendor_hardware_overlay.git
cd vendor_hardware_overlay
git checkout -b pie origin/pie     # merged PRs use this branch name
```

### 3. Copy the folders

Unzip `out/<name>-hardware-overlay.zip` into the clone root: `Brand/Model/`,
`Brand/Model-SystemUI/`. Keep the names exactly as they are in the zip — they
came from `DEVICE_MANUFACTURER`/`DEVICE_CODENAME`. Do not copy any other file,
and delete `_submission/`: it is notes, not overlay source.

```bash
git status --short    # only Brand/… entries should appear
```

### 4. Add the modules to `overlay.mk`

Insert the lines from `_submission/overlay.mk.lines` into the
`PRODUCT_PACKAGES` list, each ending with a backslash, tabs included. The
`treble-overlay-*` lines are sorted with `LC_ALL=C` (uppercase before lowercase,
`-` before `_`), which is why `Hisense`, `NavBar`, `Redmi` come first. Keep the
empty line at the end of the file.

### 5. Run the repo's tests

```bash
sudo apt install xmlstarlet       # Debian/Ubuntu; brew install xmlstarlet on macOS
bash tests/tests.sh
```

Anything it prints as `Fatal:` and exits non-zero on (it also leaves a `fail`
file) has to be fixed before the PR. It checks the blacklist, duplicate
priorities, resource names against AOSP, the power profile and `overlay.mk`, and
it prints the free priority it suggests.

Two known snags, neither caused by your overlay:

- On the current `pie` tree the `overlay.mk` ordering check fails on a
  pre-existing line: `treble-overlay-moto-malmo` sits after the `motorola-*`
  block. Leave that line alone (or fix it in its own PR) and make sure your own
  lines are in order.
- If it reports that a resource does not exist in AOSP, `tests/knownKeys` is
  missing an entry rather than the value being wrong. Either leave the key out
  of the submission or keep it and add the comment the script prints ("I swear
  it makes sense to set <key>, and I can completely explain why.") to that
  values file. Several overlays in the repo do the same.

### 6. Build it the way the repo does (optional)

```bash
cd build && bash build.sh          # writes build/*.apk; needs aapt + java
cd build && bash build.sh --local-aapt   # use the aapt bundled in build/
```

The repo signs with its own platform keys in `build/keys`, so the APKs are only
for testing.

### 7. Commit, push, open the pull request

```bash
git add overlay.mk Brand/Model Brand/Model-SystemUI
git commit -m "overlay: add <brand>/<model>"
git push -u origin pie
```

Open the PR against `Doze-off/vendor_hardware_overlay`, base branch `pie`. Write
what the reviewers in this repo ask for — the merged PRs all state the getprop
values the overlay matches on, plus what it fixes:

```markdown
Adds the overlay for <marketing name> (<codename>).

- `ro.product.vendor.device`: `<value from getprop>`
- `ro.vendor.build.fingerprint`: `<value from getprop>`
- Build: Android <version>, vendor <build id>

What it fixes: <e.g. status bar height, rounded corners, AOD support>.

Values come from the stock product overlay (`product/overlay/…apk`), diffed
against the GSI defaults, so only the resources that actually differ are
included.

Verified with the test module from out/…-hardware-overlay-test.zip:
`adb shell cmd overlay lookup me.phh.treble.overlay.<brand>.<model> android:dimen/rounded_corner_radius`
→ `<value>`
```

Keep it to one device per PR unless the models really share the firmware and the
match property (that is why `Asus/Rog5_5s` is a single folder for the ROG 5 and
5s).

---

## After it is merged

- The overlay ships with the next build of the GSIs that use this repo, and on a
  matching device the values are applied on a clean install with no module.
- Your own module and the built-in overlay can coexist — the module wins while
  it is installed (it patches the APK), and uninstalling it leaves the repo's
  copy in place.
- If the values change, pull `pie` first, edit `config.env`, rebuild, and send a
  PR that updates the same folder. Do not open a second overlay for the same
  device, and do not rewrite another device's folder in the same PR.
- Watch the device's forum for GSI regressions after a release: a value that
  was right for one build can break a newer one.

---

## Limits

- The submission is source, not an APK: the ROM builds it with its own AOSP
  tree. A resource name that only exists on your Android version fails their
  test against AOSP, so it has to be dropped from the submission (the module can
  keep it).
- `scripts/data/treble-overlay-priorities.txt` is a snapshot. The repo adds
  overlays continuously; run their `tests/tests.sh` before opening the PR.
- The repo's resource-name check (`tests/knownKeys`) is maintained by hand and
  is not complete — Doze-off's copy is ahead of upstream's but still missing
  newer names (e.g. `config_radio_access_family`). A `Fatal:` about a resource
  that demonstrably exists in AOSP is that, not a broken value.
- Nothing checks a PR automatically on the Doze-off fork (no Actions runs), and
  there is no issue tracker to ask in: if the maintainer disagrees with the
  format or the values, the PR is closed. Pull requests are reviewed by hand,
  and nothing here guarantees a merge.
