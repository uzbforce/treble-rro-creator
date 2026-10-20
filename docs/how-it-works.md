# How it works

## Runtime Resource Overlay (RRO)

A GSI ships a generic `framework-res.apk`. An RRO is a small APK that overrides
individual resources in another package — the framework (`android`) or
SystemUI (`com.android.systemui`) — without modifying it.

```
GSI framework-res.apk   ←  idmap2  ←  your overlay APK
(original values)                      (overridden values)
```

At boot, `idmap2` maps the resources in the overlay to resources in the target.
Android then uses the overlay values when the overlay is enabled **and** its
match condition is satisfied.

### Why a module is needed

GSIs use dynamic partitions. `/system/product/overlay/` does not persist across
reboots, and a manually copied APK does not get the SELinux context the package
manager expects.

A KernelSU / KSU Next / APatch / Magisk module solves both:

1. The module lives in `/data/adb/modules/<id>/`.
2. At boot the root manager bind-mounts its `system/` tree over `/system/`, so
   the overlay APK appears in `/system/product/overlay/` with the right context.
3. The package manager picks it up and `idmap2` links it. Because the overlays
   are **static**, Android enables them during boot, before `service.sh` runs.
   `service.sh` re-runs `cmd overlay enable` as a harmless fallback and then
   reports whether each APK was accepted — that report is the fastest way to
   spot a wrong match property or a broken mount.

This is also why **Magic Mount** is required on KernelSU: without a mount
mechanism the files never reach `/system`. OverlayFS is discouraged because it
interacts badly with SELinux policies and VINTF manifests for modules like this.

---

## Properties vs settings

A common source of confusion. They are different namespaces:

| Mechanism | Example | Used by | Persists |
|---|---|---|---|
| System property | `setprop persist.sys.overlay.aod true` | Phh-Treble features (AOD, 5G, IMS) | Yes (`persist.*`) |
| Overlay resource | `config_udfps_sensor_props` | UDFPS sensor geometry | Part of the APK |
| Global setting | `settings put global ...` | Android framework settings | Yes |

Phh-based GSIs read a small set of `persist.sys.phh.*` / `persist.sys.overlay.*`
properties. Use `setprop` for those. UDFPS is **not** configured with properties:
AOSP reads `config_udfps_sensor_props` and `config_biometric_sensors` from the
framework overlay. `persist.sys.udfps.*` does not exist in AOSP, TrebleDroid or
PHH and is no longer written by this tool.

---

## What the build does

1. **Read `config.env`** — device identity, display values, feature flags.
2. **Back up** the current config, module scripts and `src/vendor/` to
   `backups/`.
3. **Generate** `build/AndroidManifest.xml`, `build/systemui/AndroidManifest.xml`,
   `build/module.prop`, `build/Android.mk`, and the resource XML:
   - `src/framework/res/values/generated.xml`
   - `src/framework/res/values-land/generated.xml` (status bar, landscape)
   - `src/systemui/res/values/generated.xml`
4. **Audit** every generated `type/name` against `framework-res.apk`. A name the
   target does not have is silently ignored by Android, so the build stops and
   writes `out/<name>-overrides.txt` instead of shipping a no-op.
5. **Compile** a staged copy of the resources with `aapt2 compile` → `.flat`
   files. An empty `power_profile.xml` template is left out of the staging copy
   so it cannot erase the GSI's battery/CPU data.
6. **Link** with `aapt2 link` against `framework-res.apk` → unsigned APKs.
7. **Align** with `zipalign`, **sign** and **verify** with `apksigner`.
8. **Package** the flashable module: APKs + `module.prop` + generated
   `customize.sh` + generated `service.sh` (+ `sepolicy.rule` and vendor files
   when requested).
9. **Generate the Hardware Overlay Repo sources** and a test module from them.

Nothing in the output depends on the machine that built it: the scripts and
zips use LF endings and `/` paths because they run on Android.

---

## Overlay priority and matching

Each overlay declares:

```xml
<overlay
    android:targetPackage="android"
    android:priority="628"
    android:isStatic="true"
    android:requiredSystemPropertyName="persist.sys.overlay.r3q"
    android:requiredSystemPropertyValue="true" />
```

- **Static** overlays are enabled automatically when they match.
- The **match** prevents the overlay from applying to a different device.
  Leave `DEVICE_PROP_NAME` empty for no condition at all.
- **Priority** decides between overlays that override the same resource.

### Why the match property is not a `ro.product.*` value

A static overlay that targets `android` is matched by **zygote** while it
preloads framework resources. From the zygote domain several property areas are
unreadable on GSI setups (`build_bootimage_prop`, `vendor_default_prop`, …), so
the value reads as **empty** and the condition never matches — the overlay is
still listed as enabled by the system server, but no process ever applies it.

On top of that, a GSI usually puts its own name in `ro.product.device`
(`mivendor`, `phh_treble`, …), not your device codename.

`persist.sys.*` is readable from every domain, so the generated overlay matches
on a property the module itself sets in `post-fs-data.sh`, before zygote starts.
That is the same pattern PHH's own overlays use (`persist.sys.overlay.aod`).

If your overlay is listed but not active, check the match property first —
`cmd overlay lookup <pkg> android:dimen/status_bar_height_default` tells you
whether the values are really live.

---

## The flashable module

The module zip contains:

```
module.prop                              module metadata (id, name, version)
customize.sh                             install-time permissions/SELinux contexts
service.sh                               runs after boot: reports overlay state, sets props
post-fs-data.sh                          match property + WebUI boot guard, before zygote
webroot/index.html, apply.sh              shared WebUI (KSU/APatch/Magisk hosts)
webroot/webui-manifest.json              the resources the page can edit
webui-defaults.conf                      build-time values shown by the WebUI
META-INF/com/google/android/             Magisk installer entry point
system/product/overlay/<name>.apk        the framework overlay
system/product/overlay/<name>-systemui.apk
[system/vendor/...]                      only with vendor HALs
[sepolicy.rule]                          only with vendor HALs
```

At runtime the module also keeps a few small files next to itself:
`webui.conf` (values saved from the page), `<apk>.webui-orig` (the APK the build
produced, for Reset and the boot guard), `webui-gen` / `webui-gen-ok` /
`webui-try` (the guard counter) and `webui-boot.log`. A second copy of
`webui.conf` lives in `/data/adb/treble-webui/<module-id>/`, because the module
directory itself is replaced on update — see
[webui.md](webui.md#after-a-rebuild-or-reinstall).

`webui-manifest.json` is generated by `scripts/manifest.sh` from the resource XML
the build compiles, so the page cannot offer a resource this APK does not have.

KernelSU, KSU Next and APatch source `customize.sh` directly. Magisk's app does
the same internally; the `META-INF` pair is the standard entry point used by
recovery and older Magisk installers. `customize.sh`, `service.sh` and
`webroot/` are generated or copied on every build. `sepolicy.rule` is copied
only when vendor HALs are included and the file contains real `allow` rules.

To customize the post-boot script, copy `templates/service.sh.example` to
`src/module/service.sh`; the build then packs your file instead of generating
one. The same applies to `src/module/customize.sh`.

---

## Hardware Overlay Repo output

`out/<name>-hardware-overlay.zip` is not flashable. It contains AOSP-style
sources:

```
<manufacturer>/<codename>/
├── Android.mk
├── AndroidManifest.xml
└── res/...
```

Extract it and copy the manufacturer folder into a clone of the
[Treble Hardware Overlay Repo](https://github.com/Doze-off/vendor_hardware_overlay)
to submit a pull request. That makes the overlay part of GSIs by default instead
of requiring a module.

`out/<name>-hardware-overlay-test.zip` builds the same sources into a module so
you can verify the repo version works before submitting it.

---

## The toolchain

Everything is local to the project:

| Platform | `tools/` contents |
|---|---|
| Windows | `aapt2.exe`, `zipalign.exe`, `apksigner` (wrapper) + `apksigner.jar` |
| Linux | `aapt2`, `zipalign`, `apksigner` (system or SDK build-tools) |
| Termux | `aapt2`, `apksigner`, `zipalign` (the last one comes from the `aapt` package) |
| All | `framework-res.apk` (Android 13 resource dictionary) |

`build.sh` prefers a usable tool on `PATH`, then `tools/`. It refuses binaries
for the other platform, so a mixed setup is caught before the build starts.
`./build.sh doctor` prints exactly what it would use.
