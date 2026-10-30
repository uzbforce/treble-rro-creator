# Module addons

An addon is a tweak the **module** owns, chosen in the app's **Addons** tab (or
the module's page on the phone). It is not a `config.env` key: it lives in
`src/module/addons.conf`, so the addon list and the overlay resource list stay
two different things.

There are two kinds, and the catalog says which is which:

- **Live** addons are Settings values. The module writes them with
  `settings put`, so a change is true the moment it is saved, on a running
  phone, with no APK and no reboot. `service.sh` re-applies them at every boot.
  The overlay APK alone cannot do one.
- **Overlay** addons are resources, framework or SystemUI. The build reads the
  choice and emits the resource into the matching overlay APK, so from the app
  they take effect after a **Build** and a flash — a resource is fixed once the
  process that reads it is running. The phone's page can also write the same
  entries into the APK that is already installed (see
  [the WebUI](webui.md#addons)), which needs a framework reload but no rebuild;
  the next reinstall replaces those APKs with the build's choices again.

Where they are set:

- **Desktop app → Addons** — pick the values, **Save addons**. The choices go
  into `src/module/addons.conf`; live ones apply when the module is installed,
  overlay ones are baked by the next **Build**.
- **On the phone → module WebUI → Addons** — the same catalog. A live choice is
  applied as soon as you change it. An overlay choice is part of the APK, so it
  is written by **Apply** (the page patches `resources.arsc` with the value the
  build would emit) and needs the reload to be seen. **Use default** is the way
  out of either kind: it removes the line and, for an overlay, the resource.
- **Every boot** — `service.sh` applies the live values in the file, so a choice
  set once survives a reboot, a Settings reset by another app, and a GSI update.

## The addons

| Id | Kind | Values | Effect |
|---|---|---|---|
| `volume_panel` | live | `right` (default), `left` | `secure volume_panel_on_left` — which edge the volume slider slides in from |
| `captive_portal` | live | `on` (default), `off` | `global captive_portal_mode` — Android's "sign in to this network" probe; off stops the false no-internet warnings a GSI shows on some networks |
| `stay_awake` | live | `on`, `off` (default) | `system screen_off_timeout` — `on` writes the largest value an int Setting holds (2147483647 ms, about 24 days), so the display never sleeps, on battery too. The power button still turns it off; nothing else does. `off` restores the AOSP default of 60 s |
| `status_clock` | live | `on` (default), `off` | `secure icon_blacklist` — `off` adds `clock` to the list of icons SystemUI hides, so the time leaves the status bar and the notification icons get its room. Whatever else is in that list is kept. The lock-screen clock is a different view and stays |
| `any_rotation` | overlay | `on`, `off` (default) | `config_allowAllRotations=true` — allows the 180° rotation Android normally refuses, so an app (and a launcher that rotates) can turn upside down |
| `nav_bar_padding` | overlay | `on` (default), `off` | `navigation_bar_height` and `_landscape` become `0dp` while `navigation_bar_frame_height` stays `48dp` — content reaches the bottom edge and the gesture pill is still drawn and swipeable |
| `status_bar_background` | overlay | `on` (default), `off` | `status_background` (SystemUI) becomes transparent — the fading shade SystemUI draws behind the collapsed status bar is gone, and the bar sits on the wallpaper or the app |
| `hide_notch` | overlay | `on`, `off` (default) | `config_maskMainBuiltInDisplayCutout=true` — the display is masked to the area below the cutout, so the notch strip is black and outside every window: apps, games and the status bar all start below it |

**Battery percentage and clock seconds are not addons.** They are Android's
own Settings toggles (Settings → Battery, and the clock's seconds switch next
to *Use 24-hour format* on the GSIs that expose it), so the module does not pin
a value the ROM already lets you change.

`volume_panel` is the one that used to mean a One UI setting: AOSP SystemUI
reads `volume_panel_on_left` on every show, so switching it is live — no reboot,
no SystemUI restart.

The default is what the addon does when it is **not** chosen. It is not written
anywhere; it is only what the form shows.

### The navigation bar trick

The gesture bar is two different heights:

- `navigation_bar_height` is the **inset** apps lay out inside. Reducing it is
  what removes the empty strip at the bottom.
- `navigation_bar_frame_height` is the bar's **own window** — the surface that
  draws the pill and catches the swipe from the bottom.

Setting only the inset to `0dp` gives apps the full screen while the pill still
floats over the content and the swipe still works. Removing padding the other
way — hiding the bar — loses the pill, which is why this addon keeps the frame
explicitly instead of shrinking everything. The landscape values move with the
portrait ones so turning the phone does not bring the strip back.

### The hidden notch

`hide_notch` does not paint a black rectangle over the camera. It sets
`config_maskMainBuiltInDisplayCutout`, and the framework reacts by **shrinking
the display** to the area below the cutout (`LogicalDisplay.getMaskingInsets`,
`DisplayDeviceInfo.FLAG_MASK_DISPLAY_CUTOUT`):

- the strip the notch lives in is no longer part of the display, so it is black
  and no window — app, game, status bar — can draw there or receive a touch
there;
- every window's insets are computed against the smaller display, so the status
  bar and app content start just below the notch and nothing can be laid out
  under the camera;
- `DisplayCutout` is reported as `null` to apps, because inside the display
  there is no cutout left to avoid.

The cost is real and is the point: the top strip stops being screen. A game or
a video is letterboxed at the top instead of running under the notch, and the
status bar moves down with everything else.

It needs a cutout to mask. The build defines one from `DISPLAY_CUTOUT`, so an
addon chosen on a `config.env` that leaves the cutout commented out has nothing
to work with — the build says so on the console. It is a resource: from the app
it takes a **Build**, a flash and a reboot, because the overlay is a static RRO
that Android reads during boot. From the phone's page, **Apply** writes the same
boolean into the installed APK and a reload makes the framework see it.

If you want the black strip *without* giving up the screen area, that is the
other half of the pair: `CONFIG_FILL_MAIN_BUILTIN_DISPLAY_CUTOUT=true` in
`config.env` makes the framework paint the cutout region black, while apps that
ask for full-screen layout can still draw behind it. `hide_notch` is the one
that takes the area away.

### The status bar background

`status_bar_background=off` replaces SystemUI's `status_background` drawable —
the 9-patch black-to-transparent gradient under the collapsed bar — with
`@android:color/transparent`. The bar keeps its layout, its height, its swipe
area and the icons; only the shade is gone, so a wallpaper or an app reaches the
top of the screen behind them.

The replacement is written once per density (`values-mdpi`, `values-hdpi`, …)
and not only as a default value. `status_background` is a set of density-qualified
9-patches, and Android only accepts an overlay entry whose configuration is at
least as specific as the entry it found in the ROM (`AssetManager2::FindEntry`);
a lone default value loses to the ROM's `xxhdpi` patch and the shade stays.
That is also why the build links with `--no-resource-deduping`: aapt2 would
otherwise collapse those identical per-density items back into one default
entry.

SystemUI only draws that shade when it wants the bar to stay readable over an
app (its "opaque" bar mode). Apps that already draw edge to edge have a
transparent bar to begin with, so on Android 15 and 16 the difference shows in
the apps that still ask for an opaque status bar, not in every app.

The notification shade and the quick-settings panel have their own background
and are not affected. From the app it needs a rebuild and a flash; from the
phone's page, Apply writes the same per-density entries into the installed APK
and a reload loads them.

### The upside-down rotation

`config_allowAllRotations=false` is why a phone stops at landscape: the
framework refuses a 180° (reverse-portrait) rotation even when auto-rotate is
on. The addon flips that resource. Apps that support rotation will then also
turn upside down.

A launcher can still pin its own home screen to portrait — that is the
launcher's choice, not the framework's. If yours does, look for **Allow home
screen rotation** in the launcher's settings; the addon is what makes the 180°
case available once it rotates.

## Only what you chose is enforced

`addons.conf` holds the addons that differ from the default:

```sh
# Module addons — Treble Overlay
#volume_panel=left        ← a note, not applied
stay_awake=on              ← applied at every boot
any_rotation=on            ← baked into the next build
```

Choosing an addon back to its default **removes** the line (and restores the
default now), which hands that setting back to the ROM. That is why an untouched
install changes nothing at all, and why a value you later change in Android's own
Settings stays changed unless the addon is listed here.

**Use default** is the per-row way out: it sets the control back to the default,
applies it (a live value at once, an overlay entry on the next **Apply**) and
drops the line. The addon can be chosen and saved again whenever it is wanted.

**Reset addons** applies every live default and empties those lines. On the
phone it keeps the overlay lines, because the APK that is installed still has
them; use **Use default** on an overlay row, then Apply, to take one out. On the
desktop there is no APK to leave alone, so **Clear all** removes every line,
overlay ones included.

The file is kept in the module directory, and mirrored to
`/data/adb/treble-webui/<module-id>/addons.conf` because a module update replaces
the directory. `customize.sh` copies it back on install and applies the live
values straight away, so an update takes effect without waiting for the next
boot.

## Using it

**Desktop app.** The **Addons** tab shows the catalog the module ships. Once a
row is changed, **Save addons** writes `src/module/addons.conf`. Live rows show
the phone's own value next to the control; overlay rows say **next build**
because that is when they happen. The app does not need a phone for this — the
same file is what a hand edit would produce.

**On the phone.** Open the module → **WebUI** → the **Addons** card. A live
switch or picker applies immediately (`settings put` through the module's own
script) and saves the choice, so there is no Apply button to forget. The line
under each control is what the phone resolves right now, and it turns into
`saved left · phone right` when a saved value did not take — the one case worth
looking at.

An overlay row reads the choice the installed APK was built with, and can be
changed. Its line says **in this APK**; a change turns it into **apply to write**
because there is nothing to do until **Apply**, which patches the APK together
with the sliders (a reload, or reboot, is what makes the framework read it).
Picking **Use default** and pressing Apply drops the entry, so the ROM's own
resource is what the device resolves again.

Addons are independent of the overlay *except* for the overlay kind: a live
change does not patch an APK and is not undone by **Reset** (that button is
about the overlay APKs). An overlay change is part of the APK, so it is written
by Apply and reverted by installing the module again.

## Adding an addon

Everything starts in `src/webui/addons.sh`, which the build packs as
`webroot/addons.sh`:

1. add a line to `catalog()` — `id|choices|default|label|summary|kind`, with
   `kind` either `setting` or `overlay`, and a summary without `|`;
2. for a **live** addon, add a case to `apply_one()` that maps the choice to
   `settings put`, and the reverse mapping to `live_value()` so the page can
   show what the phone resolved;
3. for an **overlay** addon, add the resource emission to
   `generate_resource_xml()` (framework) or `generate_systemui_resource_xml()`
   (SystemUI) in `stuff/scripts/resources.sh`, reading the choice with
   `addon_choice <id>`; it must emit nothing for the default. Then add the same
   names to `ADDON_RESOURCES` in `src/webui/index.html`, so the page can write
   the entry on the phone and **Use default** can remove it (a test checks the
   names still appear in `resources.sh`);
4. add a commented example line to `src/module/addons.conf` (the test checks
   that every catalog id appears there).

`stuff/tests/addons-sh.test.js` runs the script against a fake `settings`, so a
live mapping can be tested without a phone; it also runs the resource generators
and checks what an overlay choice emits. Whether the target framework actually
has the name is checked by a build: `out/apks/*-overrides.txt` lists every
resource it accepted.

## Limits

- A `settings` key is only as real as the ROM behind it. A value the ROM's
  Settings app does not use is still written, and reported as `saved` — it just
  does not change anything.
- The namespaces are Android's own (`secure`, `global`, `system`) and the keys
  are AOSP's. An OEM setting (a Samsung or Xiaomi private key) works the same
  way if the OEM SystemUI still reads it, which is not something this tool can
  promise.
- An overlay addon is a resource, so the process that reads it has to reload:
  from the app that is a rebuild, a flash and a reboot; from the phone's page it
  is Apply and a reload. A new install (or an update) replaces the APK, so the
  choice made only on the phone has to be made again.
- Keep the screen on and the battery drains — that is the addon doing its job,
  not a bug.
