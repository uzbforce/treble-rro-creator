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

The page loads the module's build-time values from `webui-defaults.conf` into
the sliders and separately reads what the device currently resolves
(`cmd overlay lookup`) for the `active …` label under each field. Values you
change are stored in `webui.conf`; **Apply** sends the whole visible set, so
pressing it without moving a slider simply re-applies the current values
instead of doing nothing.

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
`scripts/resources.sh` emits. The one thing that still needs a rebuild is a name
this page cannot express: a resource *array* (auto-brightness), or a build whose
`resources.arsc` holds more than one package. Then Apply says
`x PAD_START: dimen/status_bar_padding_start could not be added to this build`
and names the reason.

**Not editable here:** resource *arrays* (auto-brightness levels/backlight,
`config_udfps_sensor_props`), `power_profile.xml`, vendor HAL files. Fabricated
overlays carry one value per resource, and a value is a single `Res_value`, so
those still need a rebuild.

A rebuild from a `config.env` that leaves the padding keys commented out does
revert them: the new APK replaces the patched one, and the page has to add the
entries again on the next Apply.

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

Apply only overwrites values the build already ships. A resource that is not in
the APK needs a rebuild, and so does anything an overlay cannot express
(resource arrays such as the auto-brightness curves, `power_profile.xml`, vendor
HALs).

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
su -c 'sh /data/adb/modules/treble-overlay-*/webroot/apply.sh status'
su -c 'sh /data/adb/modules/treble-overlay-*/webroot/apply.sh diag'
su -c 'sh /data/adb/modules/treble-overlay-*/webroot/apply.sh verify'
su -c 'sh /data/adb/modules/treble-overlay-*/webroot/apply.sh apks'
su -c 'sh /data/adb/modules/treble-overlay-*/webroot/apply.sh backup'
su -c 'sh /data/adb/modules/treble-overlay-*/webroot/apply.sh restore'
su -c 'sh /data/adb/modules/treble-overlay-*/webroot/apply.sh reload'
```

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
- A dimension that is not in the APK cannot be written; the page names the
  `config.env` key that would add it.
- Reinstalling the module replaces `webui.conf` and the APKs; the saved values
  are not migrated (the reinstall also reverts any patch).
