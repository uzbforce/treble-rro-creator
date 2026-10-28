# WebUI (edit values without rebuilding)

KernelSU, KSU Next and APatch can show a page for an installed module. This
module ships one in `webroot/`: open the module in the manager and tap the
WebUI button. Magisk's official app has no WebUI; use a WebUI host (WebUI X,
KsuWebUI or MMRL) and open the same module page there.

The page edits the values the module ships and applies them **on the phone**.
Dimensions are written into `resources.arsc` of the overlay APK that is already
installed — the same value a rebuild would bake in — so there is no `aapt2`, no
new APK and no reinstall. Only the doze boolean is registered as a fabricated
overlay (`cmd overlay fabricate`), because that command cannot carry a
dimension at all: it accepts data types 16–31 and rejects a dimen with
`dataType is out of range of [16, 31] (too low)`.

---

## Requirements

| | |
|---|---|
| Android | 12 or newer — the page reads live values with `cmd overlay lookup` and registers the boolean with `overlay fabricate`, neither of which exists on 11 |
| Root | the page writes the module's APKs and registers the boolean; both need uid 0 |
| Manager | KernelSU, KSU Next or APatch with their built-in WebUI; Magisk with a WebUI host (below) |

## Managers

| Manager | Install the zip | Open the page |
|---|---|---|
| KernelSU / KSU Next | Modules → Install from storage | Module → **WebUI** |
| APatch | Modules → Install from storage | Module → **WebUI** |
| Magisk | Modules → Install from storage | Use **WebUI X**, **KsuWebUI** or **MMRL** |

The zip is the same for all of them, and the module directory is
`/data/adb/modules/<id>` in all three root solutions. `customize.sh` is sourced
directly by KernelSU and APatch; Magisk's app installer reads the same
`module.prop` and `customize.sh`. The standard `META-INF` installer is included
too, so Magisk recovery installs and older Magisk installers work. All managers
end up running the same `customize.sh`, `service.sh` and `webroot/apply.sh`.

KernelSU, KSU Next, APatch and KsuWebUI expose the familiar `ksu.exec` bridge;
MMRL / WebUI X expose an equivalent root exec API. The page detects any of
them, and all managers install modules in `/data/adb/modules`, so the page and
`apply.sh` are identical everywhere. The
page only finds the helper by the module id when the host provides
`moduleInfo()` (KernelSU / KSU Next); otherwise it reads the module id from the
page URL when the host opened `/data/adb/modules/<id>/webroot/index.html`, and
finally falls back to `/data/adb/modules/*/webroot/apply.sh` (APatch and most
Magisk WebUI hosts).

Without a WebUI host, Magisk users keep the normal flow: edit `config.env`,
rebuild, reinstall. The WebUI itself is not a separate build and does not
depend on the manager's module format.

---

## What the page can change

| Field | Resource | Type |
|---|---|---|
| Corner radius | `android:dimen/rounded_corner_radius` | px |
| Status bar height | `android:dimen/status_bar_height_default` | px |
| Content padding | `android:dimen/rounded_corner_content_padding` | px |
| Padding start / end | `com.android.systemui:dimen/status_bar_padding_start` / `_end` | px |
| Blank display after doze | `android:bool/config_displayBlanksAfterDoze` | bool |

Content padding is AOSP's own knob for the same gap, but a GSI was measured
ignoring it while the two SystemUI paddings moved the clock 1:1 — set all three
when you move the content
([configuration.md](configuration.md#status-bar-content-padding-start--end)).

The page loads the module's build-time values from `webui-defaults.conf` into
the sliders and separately reads what the device currently resolves
(`cmd overlay lookup`) for the `active …` label under each field. Values you
change are stored in `webui.conf`; **Apply** sends the whole visible set, so
pressing it without moving a slider simply re-applies the current values
instead of doing nothing.

That second read is in whatever unit the resource declares: the module writes
px, so its own values come back as `113.0px`, while a ROM whose framework value
is 28dp answers `28.0dip`. `apply.sh` scales a dp answer with the display
density (`wm density`, an override first) and reports px, because the sliders
and the APK are px. Before that, `28.0dip` was read as `28` and an Apply that
only touched the content padding also wrote a 28px status bar — the bar
collapsed and the clock and icons jumped to the top. Without a readable
density a dp answer is reported as `—`, not as a number.

A value that the build does not carry — the optional padding resources
(`rounded_corner_content_padding`, `status_bar_padding_start/_end`) are only in
the APK when `STATUS_BAR_CONTENT_PADDING`, `STATUS_BAR_PADDING_START` or
`STATUS_BAR_PADDING_END` is set in `config.env` — is **added** by the page
instead of being refused. `config.env` decides what a build ships; it no longer
decides what the page can write:

- the entry is appended to the `dimen` type of the APK's `resources.arsc`
  (the type, its spec and the key string are written too, and a table without a
  `dimen` type gets one);
- the zip is written again with the bigger table, entries realigned to four
  bytes and the APK signing block copied over. A static overlay is not
  signature-checked, so a stale block is fine;
- an existing value is still patched in place, which keeps the APK the same
  size and only refreshes the two CRCs.

The framework maps overlay resources by **name**, so the entry needs no
particular id; `idmap2` maps it to the target resource when zygote starts. The
mapping lives in `PATCH_TARGETS` in `webroot/index.html` and mirrors the names
`stuff/scripts/resources.sh` emits. The one thing that still needs a rebuild is a name
this page cannot express: a resource *array* (auto-brightness), or a build whose
`resources.arsc` holds more than one package. Then Apply says
`x PAD_START: dimen/status_bar_padding_start could not be added to this build`
and names the reason.

**Not editable in the five fields above:** resource *arrays* (auto-brightness
levels/backlight, `config_udfps_sensor_props`), `power_profile.xml`, vendor HAL
files. They are all listed under **All resources** below, marked *rebuild* where
the page cannot write them.

A rebuild from a `config.env` that leaves the padding keys commented out does
revert them until the page adds the entries again on the next Apply.

---

## Addons

The **Addons** card is the other half of the module. **Live** addons are
Settings values written with `settings put`: the volume panel side, the screen
timeout, hiding the status-bar clock and the captive-portal probe. **Overlay**
addons are resources: upside-down rotation, the navigation-bar padding, a
transparent status-bar background and the masked-out notch.

A live control is not part of **Apply**: it applies the moment it changes,
because changing a Setting needs no framework restart and no APK is touched. The
choice is written to `addons.conf` in the module, and `service.sh` applies that
file on every boot — so a value set here sticks.

An overlay control is part of **Apply**, because its value is a resource in the
overlay APK. The row shows what is in the installed APK (**in this APK**, or
**ROM default** when it is not applied); changing it turns the line into **apply
to write**, and Apply writes the entry into `resources.arsc` with the same
writer the sliders use — a boolean, a dimension, or a colour for the status-bar
drawable. The density-qualified `status_background` is written once per density,
for the same reason the build writes it that way. Nothing is visible until the
framework reloads, exactly like a slider.

**Use default** is the per-row way out: the control goes back to the default,
Apply removes the entry from the APK (so the ROM's own resource is used again)
and the line leaves `addons.conf`. On a live addon it applies at once. The addon
can be chosen and saved again later — Apply writes it back.

Only the addons that differ from the default are kept in the file; picking one
back to its default removes the line and hands that setting back to the ROM.
**Reset addons** restores the live defaults; overlay lines stay, because the
installed APK still carries them — use **Use default** on the row, then Apply, to
take one out. The line under each live control is what the phone resolves right
now, and it turns into `saved left · phone right` when a saved value did not
take.

The catalog is `webroot/addons.sh` — one script that the page, the desktop app
and `service.sh` all run — so the addon list here and in the app cannot drift.
The full list, what each one writes, and how to add one:
[addons.md](addons.md).

---

## All resources

Below the five fields, **All resources** lists everything else the build emits.
It is rendered from `webroot/webui-manifest.json`, which `build.sh` writes from
the same resource XML it compiles — there is no second list to fall out of sync
with `stuff/scripts/resources.sh`.

| Type | Control | Stored as |
|---|---|---|
| `dimen` | number + `px`/`dp` | complex dimension, unit 0 = px, 1 = dip |
| `bool` | switch | `Res_value` type `0x12` (`true` is `0xFFFFFFFF`, the value aapt2 writes) |
| `integer` | number | type `0x10` |
| `string` | text | type `0x03`, an index into the APK's global value pool |

A string is the only value that can need room: if it is already in the APK's
value pool it is rewritten in place, otherwise it is appended to the pool and
the table is rebuilt (indices of existing strings do not change). Everything is
read back before the APK is written.

Apply patches only what differs from the build value, so opening the section and
pressing Apply does not rewrite thirty untouched resources.

Read-only rows, marked *rebuild*:

- resource arrays — one overlay resource holds one `Res_value`, an array is
  many (auto-brightness curves, `config_udfps_sensor_props`);
- `values-land` entries — a different configuration than the one the page
  patches, so the landscape value keeps coming from the build;
- values that reference another resource (`@string/…`);
- `power_profile.xml` and vendor HAL files, which are not in the table at all.

---

## Applying

- **Apply & reload** — writes the values into the module's overlay APKs, then
  restarts the framework (`setprop ctl.restart zygote`). A static overlay is
  read when the framework starts, so this restart is what makes a new value
  visible. The screen goes black for about 20 s, every app process restarts, and
  the manager showing this page dies with them — that is expected, reopen it.
- **Apply** — same patching, without the restart. The values are on disk and
  load at the next reload; the chip shows `N pending · reload` until then.
- **Reset** — asks for confirmation, restores the APKs the build produced
  (`<apk>.webui-orig`), disables the fabricated boolean and deletes the saved
  values. It reloads the framework only when something had been applied.

Sliders only change what the page would write; nothing reaches the device until
**Apply** or **Apply & reload** is pressed.

When Apply fails, the reason is shown in three places so it cannot be missed or
scrolled away: the snackbar, a banner in the header, and a pinned block at the
top of **Diagnostics**. Pressing **Refresh status** no longer replaces it — the
pinned block stays until the next Apply. The first failing line is what matters
(`x not running as root`, `x cannot write …/webui.conf`, or the overlay
manager's own message).

Values are stored in `webui.conf` next to the module. Before the first patch,
`apply.sh backup` keeps the APK the build produced as `<apk>.webui-orig`; that
copy is what **Reset** puts back. The values therefore live in the APK until you
reset or reinstall the module — nothing has to be re-applied at boot, and
`service.sh` only re-registers the fabricated boolean (its output still goes to
`webui-boot.log`).

### What Apply writes

`resources.arsc` is stored uncompressed in an aapt2 APK, so a `dimen` value sits
at a fixed offset and is just four bytes: `(px << 8) | unit`, with unit 0 = px.
The page finds the entry by name in the default configuration, rewrites those
four bytes and refreshes the CRC of `resources.arsc` in both zip headers. It then
parses the result again and refuses to write the APK unless every value reads
back — a broken resource table would not be noticed until the next boot.

The same file is mounted at `/product/overlay`, so a patched APK only becomes
visible when the overlay manager scans it again; that is what the zygote restart
does. `cmd overlay lookup` reports what the framework is actually using, which
is what the `active …` labels and the chip compare against.

A value the build already ships is patched in place (same APK size, only the two
CRCs change); one it does not ship is added to the table as described above. What
still needs a rebuild is a name the page cannot express — a resource array such
as the auto-brightness curves, `power_profile.xml`, a vendor HAL file, or a
`resources.arsc` with more than one package.

---

## The boot guard

A patched APK is read by zygote before anything else can react to it, so a value
the framework rejects cannot be fixed from the page. The page therefore arms a
counter every time it writes an APK (`apply.sh arm`):

1. `webui-gen` goes up by one.
2. The next boot's `post-fs-data.sh` runs `apply.sh boot-guard`. The first boot
   after a patch records `webui-try = webui-gen` and lets the boot continue.
3. `service.sh` reaches `boot_completed` and runs `apply.sh boot-confirm`, which
   writes `webui-gen-ok = webui-gen`.
4. If a boot never gets there, the *next* boot sees `webui-try == webui-gen`,
   restores `<apk>.webui-orig` before zygote starts, moves the rejected values
   to `webui.conf.failed` and appends `guard=restored` to `webui-boot.log`.

The page then shows **Your last Apply was rolled back**; `webui.conf.failed`
holds exactly what to try again, one value at a time. **Reset** clears the
counters, so a deliberate Reset is never undone by the guard.

---

## After a rebuild or reinstall

The module directory is replaced by the new zip, so the saved values are kept
outside it: every `set` mirrors `webui.conf` to
`/data/adb/treble-webui/<module-id>/webui.conf`, and `customize.sh` copies it
back into the fresh install. The new APKs carry the build-time values, and the
page notices that nothing is patched (`patched=0`) and re-applies the saved
values on its next start — once per session, without a reload.

So after an update: install the zip, open the WebUI once. **Reset** removes
`webui.conf`, the mirror and the guard counters.

---

## Reading the page

- **Android 14** — from `getprop ro.build.version.sdk`. Fabricated overlays
  need Android 12 (API 31) or newer.
- **Overrides live / 2 pending · reload** — compares the saved values in
  `webui.conf` with what `cmd overlay lookup` returns right now. *No overrides
  applied* means nothing has been saved yet (the APK still has the build's
  values). `pending` means the APK was patched but the framework has not scanned
  it yet, so a reload (or a reboot) is still outstanding.

**Diagnostics** prints the Android release/SDK, the uid the bridge runs as,
whether `su` and the module directory are usable, the saved values, a live check
of every resource, the last 20 `OverlayManager` log lines (where the rejection
reason is logged) and the last boot run.

If the bridge runs without root, the page says so instead of pretending Apply
worked, and retries everything through `su -c` when `su` is available. The
module also ships `webroot/config.json` with
`"permissions": ["kernelsu.permission.SHELL"]` so WebUI X grants its shell
interface without a prompt; its own non-root working mode still has to be
switched to root mode by the user.
- **active 96px** under a field — the value `cmd overlay lookup` returns right
  now, not the saved value. If it differs from the slider, the label turns red:
  the patched APK has not been scanned yet, so run **Apply & reload**.
- The hero shows the radius with a live device preview (corners, status bar
  height and content padding), so you can judge the shape before applying.

Every command the page runs is echoed to **Diagnostics** together with stdout,
stderr and the exit code. If the page was opened outside a manager that injects
the root bridge, it says so instead of showing empty values.

KernelSU, KSU Next and APatch's native bridge does not accept a JavaScript
function: their `ksu.exec` takes the **name** of a global callback and
evaluates it later, exactly like the official `js/kernelsu` library. Other
hosts take a function, return a promise, accept two arguments, or return the
result directly. The page probes those conventions once with `echo` and then
uses the one that answers; the chosen mode is printed in diagnostics as
`protocol: name`, `protocol: name2`, `protocol: callback`,
`protocol: twoArg` or `protocol: oneArg`. Without that probe the native bridge receives a function
where it expects a name and never calls back — the page then shows “bridge did
not answer”.

## How it works

`webroot/index.html` does the patching and `webroot/apply.sh` keeps the values,
handles the APK paths, the backup and the reload. For a 96 px corner:

```bash
# 1. the APKs that belong to this module
sh apply.sh apks                 # fw=/…/overlay/<id>.apk  sui=/…/<id>-systemui.apk
sh apply.sh backup               # <apk>.webui-orig, once

# 2. the page rewrites dimen/rounded_corner_radius in the default config:
#    TypedValue complex dimension (96 << 8) | px(0) = 0x6000, then the
#    CRC of resources.arsc in the local header and the central directory

# 3. make the framework scan the APK again
sh apply.sh reload               # setprop ctl.restart zygote
```

The boolean is still a fabricated overlay (type `0x12`); its name is sanitised
to `treble_webui_bool_config_displayBlanksAfterDoze` because an overlay name may
only contain alphanumerics, `_` and `.`. `apply.sh apply` registers it, and
`service.sh` does so again at boot.

The helper can be run by hand for debugging:

```bash
su -c 'sh /data/adb/modules/treble-overlay-*/webroot/apply.sh get'
su -c 'sh /data/adb/modules/treble-overlay-*/webroot/apply.sh conf'
su -c 'sh /data/adb/modules/treble-overlay-*/webroot/apply.sh manifest'
su -c 'sh /data/adb/modules/treble-overlay-*/webroot/apply.sh status'
su -c 'sh /data/adb/modules/treble-overlay-*/webroot/apply.sh diag'
su -c 'sh /data/adb/modules/treble-overlay-*/webroot/apply.sh verify'
su -c 'sh /data/adb/modules/treble-overlay-*/webroot/apply.sh apks'
su -c 'sh /data/adb/modules/treble-overlay-*/webroot/apply.sh backup'
su -c 'sh /data/adb/modules/treble-overlay-*/webroot/apply.sh restore'
su -c 'sh /data/adb/modules/treble-overlay-*/webroot/apply.sh arm'
su -c 'sh /data/adb/modules/treble-overlay-*/webroot/apply.sh boot-guard'
su -c 'sh /data/adb/modules/treble-overlay-*/webroot/apply.sh boot-confirm'
su -c 'sh /data/adb/modules/treble-overlay-*/webroot/apply.sh reload'
```

`get` prints the effective values (saved first, then the build defaults); `conf`
prints only what was saved; `manifest` prints `webroot/webui-manifest.json`.
`arm` / `boot-guard` / `boot-confirm` are the boot guard described above —
`boot-guard` and `boot-confirm` are what `post-fs-data.sh` and `service.sh`
call, so running them by hand is only useful for diagnosis.

---

## Limitations

- The page appears only in managers / hosts that support a module WebUI
  (KernelSU, KSU Next, APatch, WebUI X, KsuWebUI, MMRL). A normal browser cannot
  run root commands.
- Multi-user devices: overlays are enabled for user 0.
- A patched APK no longer matches its APK signature. Preinstalled overlay APKs
  are not signature-verified when PackageManager scans them, which is why this
  works — do not use the same trick on a user-installed app.
- A reload (or reboot) is required: restarting SystemUI is not enough, because
  the overlay table is built during the package scan.
- A value the page cannot express (an array, a landscape-only resource, a
  `@string/…` reference) is shown read-only; set it in `config.env` and rebuild.
- Reinstalling the module replaces the APKs (and reverts the patch); the saved
  values are kept in `/data/adb/treble-webui/<module-id>/` and re-applied when
  the page is opened again.
- The page patches the **default** configuration only, so values in
  `values-land/` keep coming from the build.
