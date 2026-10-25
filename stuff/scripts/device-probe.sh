#!/usr/bin/env bash
# =============================================================================
# device-probe.sh — read the display settings an overlay has to match
# =============================================================================
# The overlay writes a handful of numbers that are properties of the panel, not
# style choices: the cutout path, the corner radius, the status bar height, the
# refresh rates. Guessing them puts content under a camera or leaves the clock
# off the edge, so this asks the phone (or an unpacked ROM) and keeps every
# answer with the source it came from.
#
#   bash stuff/scripts/device-probe.sh                 # connected device
#   bash stuff/scripts/device-probe.sh --firmware DIR  # extracted ROM dump
#   bash stuff/scripts/device-probe.sh --json          # for the desktop app
#   bash stuff/scripts/device-probe.sh --write         # put the winners in config.env
#   bash stuff/scripts/device-probe.sh --power-profile # print res/xml/power_profile.xml
#
# --power-profile prints the compiled XML tree of the power profile (the
# desktop app turns it back into a file); everything else about the run goes to
# stderr.
#
# What answers, and how far to trust it:
#
#   runtime   dumpsys display / dumpsys window — what the panel driver and the
#             running framework report. Survives a GSI for anything the display
#             hardware tells Android (corners, refresh rates), but says nothing
#             about the OEM ROM once the OEM system partition is gone.
#   resource  cmd overlay lookup android:... — the value the framework is
#             serving right now. On a GSI that can be the GSI's own default, so
#             it is evidence of "what Android uses", not of "what the OEM chose".
#   firmware  aapt2 over framework-res.apk and the overlay APKs of an unpacked
#             ROM. The only source that still has the OEM's cutout path when a
#             GSI has replaced the system partition.
#
# Nothing here is root-only.
# =============================================================================

set -uo pipefail

# adb is a Windows binary under Git Bash: without this its /system/... arguments
# are rewritten into C:/Program Files/Git/system/... before adb ever sees them.
export MSYS_NO_PATHCONV=1

winpath() {
    if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s' "$1"; fi
}

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

mode="device"
serial=""
want_json=0
want_write=0
power_mode=0
check_profile=0
adb="${ADB:-}"
aapt2="${AAPT2:-}"
fwdir=""

usage() {
    sed -n '3,39p' "$0" | sed 's/^# \{0,1\}//'
}

die() { printf 'device-probe: %s\n' "$1" >&2; exit 1; }

# Multi-device selection lives next to this script and is shared with the UDFPS
# probe, so both ask the same question and accept the same --device value.
ADB_DEVICE_LIB="$(cd "$(dirname "$0")" && pwd)/adb-device.sh"
[ -f "$ADB_DEVICE_LIB" ] || die "stuff/scripts/adb-device.sh is missing — the checkout is incomplete"
. "$ADB_DEVICE_LIB"

note() { notes+=("$1"); }
warn() { warnings+=("$1"); }

while [ $# -gt 0 ]; do
    case "$1" in
        --device)
            mode="device"
            shift
            if [ $# -gt 0 ] && [ "${1#--}" = "$1" ]; then serial="$1"; shift; fi
            ;;
        --firmware)
            mode="firmware"
            [ $# -ge 2 ] || die "--firmware needs a folder"
            fwdir="$2"
            shift 2
            ;;
        --json) want_json=1; shift ;;
        --write) want_write=1; shift ;;
        --power-profile) power_mode=1; shift ;;
        --check-profile) check_profile=1; shift ;;
        --adb) adb="${2:-}"; shift 2 ;;
        --aapt2) aapt2="${2:-}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown option: $1 (try --help)" ;;
    esac
done

tmpdir="$(mktemp -d 2>/dev/null || mktemp -d -t deviceprobe)"
cleanup() { rm -rf "$tmpdir"; }
trap cleanup EXIT HUP INT TERM

notes=()
warnings=()
files=()

# Facts, kept parallel: one row per (setting, value) pair. Two sources that
# disagree both stay, because the disagreement is the useful part.
f_key=(); f_label=(); f_unit=(); f_value=(); f_src=()
f_conf=(); f_kind=(); f_detail=()

W=""; H=""; DENS=""; DENS_PHYS=""; MODEL=""; CODENAME=""; rom=""; IS_GSI=0

# ---------------------------------------------------------------------------
# Bookkeeping
# ---------------------------------------------------------------------------
int_of() {
    case "${1:-}" in ''|*[!0-9.]*) return 1 ;; esac
    awk -v v="$1" 'BEGIN { if (v ~ /[0-9]/) { printf "%d", v + 0.5; } else { exit 1 } }'
}

# add_fact key label unit value source confidence kind detail
#
# The same value from a second source is not a second answer, so it is dropped;
# a different value is kept and the page shows both.
add_fact() {
    local key="$1" label="$2" unit="$3" value="$4" source="$5"
    local conf="$6" kind="$7" detail="${8:-}"
    [ -n "$value" ] || return 1
    local i
    for i in "${!f_key[@]}"; do
        [ "${f_key[$i]}" = "$key" ] || continue
        if [ "${f_value[$i]}" = "$value" ]; then
            # Same answer from another source: one row, but the provenance is
            # kept — it is where "and this overlay is the module's own" lands.
            f_detail[$i]="${f_detail[$i]}; also ${source}: ${detail}"
            return 1
        fi
    done
    f_key+=("$key"); f_label+=("$label"); f_unit+=("$unit"); f_value+=("$value")
    f_src+=("$source"); f_conf+=("$conf"); f_kind+=("$kind"); f_detail+=("$detail")
    return 0
}

# demote key value note — when this module's own overlay turns out to hold a
# value that a framework lookup already reported, that answer stops being
# independent evidence. The row stays (it is still what Android uses), but its
# confidence drops and the detail says why.
demote() {
    local key="$1" value="$2" extra="$3" i found=1
    for i in "${!f_key[@]}"; do
        [ "${f_key[$i]}" = "$key" ] || continue
        [ "${f_value[$i]}" = "$value" ] || continue
        [ "${f_kind[$i]}" = "resource" ] || continue
        f_conf[$i]="medium"
        f_detail[$i]="${f_detail[$i]}; $extra"
        found=0
    done
    return $found
}

# first_fact key — the highest-priority answer recorded for a key. Facts are
# added best-source-first, so the first one is the winner.
first_fact() {
    local i
    for i in "${!f_key[@]}"; do
        [ "${f_key[$i]}" = "$1" ] && { printf '%s' "$i"; return 0; }
    done
    return 1
}

# ---------------------------------------------------------------------------
# Tools
# ---------------------------------------------------------------------------
resolve_adb() {
    [ -n "$adb" ] && return 0
    adb="$(command -v adb 2>/dev/null || true)"
    [ -n "$adb" ] && return 0
    for adb in "$ROOT/stuff/tools/platform-tools/adb" "$ROOT/stuff/tools/platform-tools/adb.exe"; do
        [ -x "$adb" ] && return 0
    done
    adb=""
    return 1
}

resolve_aapt2() {
    [ -n "$aapt2" ] && return 0
    local candidate
    for candidate in "$ROOT/stuff/tools/aapt2" "$ROOT/stuff/tools/aapt2.exe"; do
        [ -x "$candidate" ] && { aapt2="$candidate"; return 0; }
    done
    candidate="$(command -v aapt2 2>/dev/null || true)"
    [ -n "$candidate" ] && { aapt2="$candidate"; return 0; }
    return 1
}

# apk_string_res APK RESNAME — the default-config value of a string resource.
apk_string_res() {
    "$aapt2" dump resources "$(winpath "$1")" 2>/dev/null | awk -v res="string/$2" '
        $1 == "resource" && $3 == res { want = 1; next }
        want && $1 == "resource" { want = 0 }
        want && /^[[:space:]]*\(\) / {
            line = $0
            sub(/^[[:space:]]*\(\) /, "", line)
            gsub(/^"|"$/, "", line)
            print line
            exit
        }'
}

# apk_dimen_res APK RESNAME WANT_CONFIG — "unit value" as aapt2 prints it, e.g.
# "px 113.0". WANT_CONFIG is "land" for the landscape qualifier, "" otherwise.
apk_dimen_res() {
    "$aapt2" dump resources "$(winpath "$1")" 2>/dev/null | awk -v res="dimen/$2" -v want_cfg="${3:-}" '
        $1 == "resource" && $3 == res { want = 1; next }
        want && $1 == "resource" { want = 0 }
        want && /^[[:space:]]*\(/ {
            line = $0
            sub(/^[[:space:]]*\(/, "", line)
            cfg = line; sub(/\).*/, "", cfg)
            val = line; sub(/^[^(]*\)[[:space:]]*/, "", val)
            if (cfg != want_cfg) next
            if (val ~ /^@/) next
            if (val ~ /px$/) { n = val; sub(/px$/, "", n); print "px " n; exit }
            if (val ~ /dp$/) { n = val; sub(/dp$/, "", n); print "dp " n; exit }
        }'
}

# ---------------------------------------------------------------------------
# Device mode
# ---------------------------------------------------------------------------
# </dev/null matters: adb inherits stdin, and a call made inside a `while read`
# loop would otherwise eat the rest of the loop's input after the first pass.
shel() { "$adb" ${serial:+-s "$serial"} shell "$1" </dev/null 2>/dev/null | tr -d '\r'; }

# Overlay state needs root on some ROMs (HyperOS is one): the plain call returns
# an error, which read as "no overlays" and silently fell back to the GSI's own
# values. Every overlay query goes through these two.
ovl_list() {
    local out
    out="$(shel 'cmd overlay list')"
    [ -n "$out" ] || out="$(shel 'su 0 cmd overlay list')"
    printf '%s' "$out"
}
ovl_dump() {
    local out
    out="$(shel 'cmd overlay dump')"
    [ -n "$out" ] || out="$(shel 'su 0 cmd overlay dump')"
    printf '%s' "$out"
}

# pull that also works for a root-only file (/vendor/overlay is one): adb pull
# runs as the shell user, `su 0 cat` does not.
pull_file() {
    local remote="$1" local_path="$2"
    "$adb" ${serial:+-s "$serial"} pull "$remote" "$(winpath "$local_path")" >/dev/null 2>&1 \
        && [ -s "$local_path" ] && return 0
    "$adb" ${serial:+-s "$serial"} exec-out "su 0 cat '$remote'" >"$local_path" 2>/dev/null \
        && [ -s "$local_path" ] && return 0
    return 1
}

# cmd overlay lookup needs the shell permission; fall back to su when a build
# only allows root. An error string is a miss, not a value.
lookup() {
    local out
    out="$(shel "cmd overlay lookup android $1")"
    case "$out" in
        ""|Error*|error*) out="$(shel "su 0 cmd overlay lookup android $1")" ;;
    esac
    case "$out" in
        Error*|error*) out="" ;;
    esac
    printf '%s' "$out"
}

# 113.0px / 24.0dp — the module wants px. dp is converted with the panel density
# when it is known, and left alone (with a note) when it is not.
dimen_to_px() {
    local raw="$1" unit n
    # `cmd overlay lookup` can answer with the reference it followed:
    # "@17105807 -> 118.0px". The number after the arrow is the value.
    case "$raw" in *"-> "*) raw="${raw##*-> }" ;; esac
    # `cmd overlay lookup` spells the density unit "dip" (28.0dip), so both
    # spellings have to be caught — reading "28.0dip" as px turned a 28dp bar
    # into a 28px answer.
    case "$raw" in
        *dip) unit="dp"; n="${raw%dip}" ;;
        *px) unit="px"; n="${raw%px}" ;;
        *dp) unit="dp"; n="${raw%dp}" ;;
        *) unit="px"; n="$raw" ;;
    esac
    if [ "$unit" = "dp" ]; then
        [ -n "$DENS" ] || return 1
        awk -v n="$n" -v d="$DENS" 'BEGIN { printf "%d", n * d / 160 + 0.5 }'
    else
        awk -v n="$n" 'BEGIN { printf "%d", n + 0.5 }'
    fi
}

pick_serial() {
    # One phone: use it. Several: ask, or stop with the list and the --device
    # spelling. See stuff/scripts/adb-device.sh for the states it understands.
    adb_pick_device "$adb" "$serial" "device-probe" || exit 1
    serial="$DEVICE_SERIAL"
}

probe_device() {
    resolve_adb || die "adb not found — install platform-tools, or pass --adb PATH"
    pick_serial

    local props size dens_out
    props="$(shel getprop)"
    prop() { printf '%s\n' "$props" | sed -n "s/^\[$1\]: \[\(.*\)\]$/\1/p" | head -n1; }

    size="$(shel 'wm size')"
    W="$(printf '%s\n' "$size" | sed -n 's/.*Physical size: \([0-9]*\)x[0-9]*.*/\1/p' | head -n1)"
    H="$(printf '%s\n' "$size" | sed -n 's/.*Physical size: [0-9]*x\([0-9]*\).*/\1/p' | head -n1)"
    [ -n "$W" ] && [ -n "$H" ] || die "could not read the display size (wm size)"

    # `wm size` / `wm density` print an override only when one is set. The
    # override is what the framework resolves dp with, so the conversion below
    # has to use it; the physical number is kept for the note.
    dens_out="$(shel 'wm density')"
    DENS="$(printf '%s\n' "$dens_out" | sed -n 's/.*Physical density: \([0-9]*\).*/\1/p' | head -n1)"
    local dens_ovr size_ovr
    dens_ovr="$(printf '%s\n' "$dens_out" | sed -n 's/.*Override density: \([0-9]*\).*/\1/p' | head -n1)"
    if [ -n "$dens_ovr" ]; then
        DENS_PHYS="$DENS"
        DENS="$dens_ovr"
        note "the display density is overridden: physical ${DENS_PHYS}dpi, effective ${DENS}dpi. dp values are converted with the effective one, because that is what the framework resolved them with"
    fi
    size_ovr="$(printf '%s\n' "$size" | sed -n 's/.*Override size: \([0-9]*x[0-9]*\).*/\1/p' | head -n1)"
    [ -z "$size_ovr" ] || note "the display size is overridden to ${size_ovr} (panel is ${W}x${H}); the px values below are what this ROM reports in that mode"

    # Some properties answer with a placeholder rather than the phone's name.
    # Measured on a Redmi Note 17 (HyperOS 3): ro.product.vendor.model was
    # "Xiaomi for arm64" and ro.product.vendor.device was "mivendor", while the
    # ODM property had the real ones. A generic value is never used when a real
    # one exists, and the order puts the partitions most likely to keep the
    # stock name first.
    generic_name() {
        local v lc
        v="${1:-}"
        lc="$(printf '%s' "$v" | tr '[:upper:]' '[:lower:]')"
        case "$lc" in
            ''|unknown|aosp*|*gsi*|*treble*|*arm64*|generic*|emulator*|mivendor|qssi*|sdk_*) return 0 ;;
        esac
        return 1
    }
    pick_prop() {
        local p v
        for p in "$@"; do
            v="$(prop "$p")"
            [ -n "$v" ] || continue
            generic_name "$v" && continue
            printf '%s' "$v"
            return 0
        done
        return 1
    }
    MODEL="$(pick_prop ro.product.odm.model ro.product.vendor.model ro.product.model || true)"
    [ -n "$MODEL" ] || MODEL="$(prop ro.product.model)"
    CODENAME="$(pick_prop ro.product.odm.device ro.product.vendor.device ro.product.bootimage.device ro.product.device || true)"
    [ -n "$CODENAME" ] || CODENAME="$(prop ro.product.device)"
    [ -n "$CODENAME" ] || CODENAME="$(prop ro.build.product)"

    local flavor
    flavor="$(prop ro.build.flavor)"
    IS_GSI=0
    case "$flavor" in *gsi*|*GSI*) IS_GSI=1 ;; esac
    rom="$(prop ro.build.display.id)"
    [ -n "$rom" ] || rom="${flavor:-unknown ROM}"

    resolve_aapt2 || warn "aapt2 not found — overlay APKs cannot be read, only the runtime values"

    # This module patches the phh device overlay in place, so an enabled overlay
    # APK can be this tool's own output. Knowing which files those are is the
    # difference between "the ROM says 113px" and "we said 113px last build".
    local module_apks=""
    module_apks="$(shel 'ls /data/adb/modules/*/system/product/overlay/*.apk 2>/dev/null' | sed 's#.*/##' | sort -u)"
    # The glob has to be expanded by root's shell, not by the shell user's.
    [ -n "$module_apks" ] || module_apks="$(shel "su 0 sh -c 'ls /data/adb/modules/*/system/product/overlay/*.apk 2>/dev/null'" | sed 's#.*/##' | sort -u)"
    [ -z "$module_apks" ] || note "this module's own overlays are installed; a framework resource answer can be the module reading back its own value (those rows say so)"

    # ---- runtime: what the panel driver and the framework report -----------
    # dumpsys display is the only place that has the refresh modes and the
    # rounded-corner geometry. Both come from the display hardware, so they are
    # still right on a GSI.
    local display window
    display="$(shel 'dumpsys display')"
    window="$(shel 'dumpsys window displays')"

    # The DisplayDeviceInfo block is one long line per display. A Samsung with a
    # DeX monitor, a TV over HDMI or a casting sink adds more of them, and none
    # of those describe the panel the overlay has to match. Prefer the one named
    # "Built-in Screen" and say so when there was more than one to choose from.
    local ddi ddi_all ddi_count ddi_name
    ddi_all="$(printf '%s\n' "$display" | grep 'DisplayDeviceInfo{' || true)"
    ddi_count="$(printf '%s\n' "$ddi_all" | grep -c . || true)"
    ddi="$(printf '%s\n' "$ddi_all" | grep -i -m1 'DisplayDeviceInfo{"[^"]*\(built-in\|internal\)' || true)"
    [ -n "$ddi" ] || ddi="$(printf '%s\n' "$ddi_all" | head -n1)"
    if [ -z "$ddi" ]; then
        warn "dumpsys display printed no DisplayDeviceInfo — refresh rates and corners unknown"
    elif [ "${ddi_count:-0}" -gt 1 ]; then
        ddi_name="$(printf '%s' "$ddi" | sed 's/.*DisplayDeviceInfo{"\([^"]*\)".*/\1/')"
        warn "dumpsys display lists ${ddi_count} displays — the built-in panel (\"${ddi_name}\") was used; the others (a monitor, a cast sink) are not what the overlay matches"
    fi

    # ---- corner radius ----------------------------------------------------
    # The panel geometry is what Android is drawing, so it is reported first and
    # preselected. The dimen is what the ROM asks for; the two agreed on the
    # reference Xiaomi (144px) and disagreed on a Samsung custom ROM (panel
    # 100px, dimen 50px), which is why both stay as rows.
    local corners radius_line radius
    corners="$(printf '%s\n' "$ddi" | grep -o 'roundedCorners RoundedCorners{.*' || true)"
    [ -n "$corners" ] || corners="$(printf '%s\n' "$window" | grep -m1 -o 'mRoundedCorners=RoundedCorners{.*' || true)"
    if [ -n "$corners" ]; then
        # Every corner usually has the same radius; the largest is the one the
        # overlay's single value has to match, and a phone with different top
        # and bottom corners keeps the top one visible in the status bar.
        radius="$(printf '%s\n' "$corners" | grep -o 'radius=[0-9.]*' | sed 's/radius=//' \
            | awk 'BEGIN { m = 0 } { v = $1 + 0; if (v > m) m = v } END { if (m > 0) printf "%d", m + 0.5 }')"
        radius_line="$(printf '%s\n' "$corners" | grep -o 'position=[A-Za-z]*' | sed 's/position=//' | tr '\n' ' ')"
        if [ -n "$radius" ] && [ "$radius" -gt 0 ] 2>/dev/null; then
            add_fact ROUNDED_CORNER_RADIUS "Corner radius" "px" "$radius" \
                "display hardware" "high" "runtime" \
                "dumpsys display: RoundedCorners radius ${radius}px (${radius_line% }); this is the panel geometry the framework is drawing" || true
        fi
    else
        note "the display reports no rounded corners — 0 is a real answer on a flat-cornered panel, but this ROM did not say so either"
    fi

    local corner_lookup corner_res
    corner_lookup="$(lookup 'android:dimen/rounded_corner_radius')"
    if [ -n "$corner_lookup" ]; then
        corner_res="$(dimen_to_px "$corner_lookup" || true)"
        [ -n "$corner_res" ] && add_fact ROUNDED_CORNER_RADIUS "Corner radius" "px" "$corner_res" \
            "framework resource" "medium" "resource" \
            "cmd overlay lookup android:dimen/rounded_corner_radius returned ${corner_lookup} — the ROM's own value, which can be smaller than the panel's" || true
    fi

    # ---- refresh rates -----------------------------------------------------
    # The rate in use is not the panel's rating: adaptive refresh sits at 60
    # while the screen is idle (measured 60 on one run and 120 on the next, on
    # the same phone). The supportedModes list is what the panel can do.
    local modes peak rates cur cur_i
    modes="$(printf '%s\n' "$ddi" | grep -o 'fps=[0-9.]*' | sed 's/fps=//')"
    peak="$(printf '%s\n' "$modes" | awk 'BEGIN { m = 0 } { v = $1 + 0; if (v > m) m = v } END { if (m > 0) printf "%d", m + 0.5 }')"
    rates="$(printf '%s\n' "$modes" | awk '!seen[$0]++' | awk '{ printf "%d ", $1 + 0.5 }' | sed 's/ $//')"
    cur="$(printf '%s\n' "$ddi" | grep -o 'renderFrameRate [0-9.]*' | head -n1 | sed 's/renderFrameRate //')"
    cur_i="$(int_of "$cur" 2>/dev/null || true)"

    if [ -n "$peak" ]; then
        add_fact PEAK_REFRESH_RATE "Peak refresh rate" "Hz" "$peak" \
            "display hardware" "high" "runtime" \
            "dumpsys display: supportedModes ${rates}Hz; ${peak} is the highest the panel offers" || true
        add_fact DEFAULT_REFRESH_RATE "Default refresh rate" "Hz" "$peak" \
            "display hardware" "medium" "runtime" \
            "the panel's highest mode. What the ROM picks on its own is a user/ROM setting; it is at ${cur_i:-unknown}Hz now" || true
        if [ -n "$cur_i" ] && [ "$cur_i" -lt "$peak" ]; then
            note "the panel is at ${cur_i}Hz right now and can do ${peak}Hz — adaptive refresh, not a missing mode"
        fi
    else
        local setting_peak
        setting_peak="$(shel 'settings get system peak_refresh_rate')"
        case "$setting_peak" in
            ""|null|*[!0-9.]*) ;;
            *)
                local sp
                sp="$(int_of "$setting_peak" || true)"
                [ -n "$sp" ] && add_fact PEAK_REFRESH_RATE "Peak refresh rate" "Hz" "$sp" \
                    "settings override" "medium" "settings" \
                    "settings get system peak_refresh_rate — a user setting, not the panel's maximum" || true
                ;;
        esac
    fi
    # ---- status bar height -------------------------------------------------
    # The dimen is what the module writes, so it is the answer: Android 12L+
    # computes the bar from status_bar_height_default plus the cutout inset, and
    # writing the *rendered* height instead would add that inset twice. The
    # window's reserved height is reported after it as a check — when the two
    # differ, the difference is usually exactly the cutout.
    local sb_lookup sb_px sb_inset
    sb_lookup="$(lookup 'android:dimen/status_bar_height_default')"
    if [ -n "$sb_lookup" ] && [ "${sb_lookup#Error}" = "$sb_lookup" ]; then
        sb_px="$(dimen_to_px "$sb_lookup" || true)"
        if [ -n "$sb_px" ]; then
            add_fact STATUS_BAR_HEIGHT "Status bar height" "px" "$sb_px" \
                "framework resource" "high" "resource" \
                "cmd overlay lookup android:dimen/status_bar_height_default returned ${sb_lookup} — the resource the module writes" || true
        fi
    fi
    # What the status bar window is actually reserving. On a GSI this is the
    # GSI's idea of a bar, which is the number the overlay has to replace.
    # Read the inset out of insetsSize instead of taking the first top= on the
    # line: a window line also carries frame coordinates, and "top" there is not
    # the bar height.
    local sb_line
    sb_line="$(shel 'dumpsys window windows | grep -m1 "type=statusBars"')"
    sb_inset="$(printf '%s' "$sb_line" | sed -n 's/.*insetsSize=Insets{\([^}]*\)}.*/\1/p' | grep -o 'top=[0-9]*' | head -n1 | sed 's/top=//')"
    [ -n "$sb_inset" ] || sb_inset="$(printf '%s' "$sb_line" | grep -o 'top=[0-9]*' | head -n1 | sed 's/top=//')"
    if [ -n "$sb_inset" ] && [ "$sb_inset" -gt 0 ] 2>/dev/null; then
        add_fact STATUS_BAR_HEIGHT "Status bar height" "px" "$sb_inset" \
            "status bar window" "medium" "runtime" \
            "dumpsys window windows: the StatusBar window reserves ${sb_inset}px at the top — the rendered result, which includes the cutout inset the dimen above does not" || true
    fi

    # ---- brightness -------------------------------------------------------
    # The integer resources are the scale config.env takes (0-255). The float
    # twins AOSP also has are derived by the build as value/255, while an OEM's
    # own floats use the panel's raw scale (measured: min 0.0017 next to a 10/255
    # resource), so they are reported as a note instead of being written.
    local bkey bres bval bright_note=""
    while IFS='|' read -r bkey bres; do
        [ -n "$bkey" ] || continue
        bval="$(lookup "android:integer/$bres")"
        case "$bval" in ''|*[!0-9]*) continue ;; esac
        add_fact "$bkey" "$(printf '%s' "$bkey" | sed 's/BRIGHTNESS_/Brightness /')" "" "$bval" \
            "framework resource" "high" "resource" \
            "cmd overlay lookup android:integer/$bres returned $bval" || true
        bright_note="${bright_note}${bres}=${bval} "
    done <<'BRIGHTEOF'
BRIGHTNESS_MAX|config_screenBrightnessSettingMaximum
BRIGHTNESS_MIN|config_screenBrightnessSettingMinimum
BRIGHTNESS_DEFAULT|config_screenBrightnessSettingDefault
BRIGHTNESS_DIM|config_screenBrightnessDim
BRIGHTNESS_DARK|config_screenBrightnessDark
BRIGHTNESS_DOZE|config_screenBrightnessDoze
BRIGHTEOF

    if [ -n "$bright_note" ]; then
        local panel_max
        panel_max="$(shel 'cat /sys/class/backlight/*/max_brightness 2>/dev/null' | head -n1)"
        [ -n "$panel_max" ] || panel_max="$(shel "su 0 sh -c 'cat /sys/class/backlight/*/max_brightness 2>/dev/null'" | head -n1)"
        # No apostrophes inside ${var:+…}: bash still parses quotes in the
        # expansion word, and a lone ' would open a string that never closes.
        case "$panel_max" in ''|0|*[!0-9]*) panel_max="" ;; esac
        note "brightness resources: ${bright_note% }; the framework scale is 0-255${panel_max:+ while the raw backlight goes to $panel_max}${panel_max:+ (the float twins are not value/255 on an OEM ROM, so only the integers are written)}"
    fi

    # ---- feature flags -----------------------------------------------------
    # The booleans the module can set, read from the same framework the rest of
    # this probe reads. On an OEM ROM these are the OEM's answers; on a GSI they
    # are the GSI's, which is why the framework note above applies here too.
    # These are the ROM's AOSP switches, not a list of hardware features. Two
    # traps worth keeping in mind: config_telephony5gNonStandalone says the
    # telephony stack supports NSA 5G and is true on 4G ROMs too, so 5G is read
    # from the modem below instead of from it; and MIUI leaves
    # config_supportDoubleTapWake false while its own touch driver provides
    # double-tap-to-wake, so "false" here does not mean the phone lacks the
    # gesture.
    local fkey fres fval f_on=0
    while IFS='|' read -r fkey fres; do
        [ -n "$fkey" ] || continue
        fval="$(lookup "android:bool/$fres")"
        case "$fval" in true|false) ;; *) continue ;; esac
        add_fact "$fkey" "$(printf '%s' "$fkey" | sed 's/^HAS_//; s/_/ /g')" "" "$fval" \
            "framework resource" "high" "resource" \
            "cmd overlay lookup android:bool/$fres returned $fval" || true
        f_on=$((f_on + 1))
    done <<'FLAGEOF'
HAS_AOD|config_dozeAlwaysOnDisplayAvailable
HAS_DOZE|config_dozeAfterScreenOffByDefault
HAS_DOUBLE_TAP_WAKE|config_supportDoubleTapWake
HAS_BURN_IN_PROTECTION|config_enableBurnInProtection
HAS_VOLTE|config_device_volte_available
FLAGEOF
    [ "$f_on" -gt 0 ] && note "feature flags are the ROM's AOSP switches: MIUI keeps config_supportDoubleTapWake=false while its touch driver still provides double-tap-to-wake, so treat them as settings to copy, not as a hardware capability list"

    # ---- 5G ----------------------------------------------------------------
    # Both signals a phone offers are shown, and neither is preselected, because
    # both were measured lying on a 4G phone: a Redmi Note 17 4G (HyperOS 3)
    # reports PhoneCapability NR bits [1, 2] (non-standalone + standalone) and
    # ro.telephony.default_network=33, an AOSP NR network mode, while shipping a
    # 4G modem. Xiaomi's telephony config is shared with the 5G sibling model.
    #
    # They stay on the page because on a phone that really is 5G they are the
    # only device-side evidence there is, and a low-confidence row is shown but
    # never written — the user can tick one. What is not offered at all is
    # config_telephony5gNonStandalone, which only says the stack supports NSA
    # and is true on 4G ROMs as well.
    local nr_cap nr_bits nr_default nr_mode nr_any=0
    nr_cap="$(shel 'dumpsys telephony.registry | grep -m1 -o "mDeviceNrCapabilit[a-z]* \[[0-9, ]*\]"' | grep -o '\[[0-9, ]*\]' | head -n1)"
    if [ -n "$nr_cap" ]; then
        nr_any=1
        nr_bits="$(printf '%s' "$nr_cap" | tr -cd '0-9')"
        local nr_value=false
        printf '%s' "$nr_bits" | grep -q '[1-9]' && nr_value=true
        add_fact HAS_5G "5G" "" "$nr_value" \
            "modem capability" "low" "runtime" \
            "dumpsys telephony.registry: PhoneCapability.mDeviceNrCapability ${nr_cap} (1 = non-standalone, 2 = standalone). Measured wrong on a Redmi Note 17 4G, which reports NR bits with a 4G modem, so this alone is not proof" || true
    fi
    nr_default="$(prop ro.telephony.default_network)"
    nr_mode="${nr_default%%,*}"
    case "$nr_mode" in
        2[3-9]|3[0-3])
            nr_any=1
            add_fact HAS_5G "5G" "" "true" \
                "vendor default network mode" "low" "prop" \
                "ro.telephony.default_network=${nr_mode} is an AOSP NR network mode (23-33), but that is per-model vendor config: the Redmi Note 17 4G also ships 33" || true
            ;;
    esac
    if [ "$nr_any" -eq 1 ]; then
        note "HAS_5G is not written automatically: the device-side evidence is unreliable (a 4G Redmi Note 17 reports NR capability and an NR default mode). Confirm the value from the phone's specs. On a real 5G phone, a ROM without working IMS can still show no 5G icon — that is registration, not the hardware bit this row carries"
    else
        note "5G could not be read: this Android version publishes no modem NR bitmap and ro.telephony.default_network is unset — set HAS_5G from the phone's specs"
    fi

    # ---- light sensor ------------------------------------------------------
    # LIGHT_SENSOR_TYPE is config_displayLightSensorType, a sensor *string*. Only
    # the running ROM's own answer is copied: it either names a vendor type
    # (Samsung: com.samsung.sensor.physical_light) or is empty, which means the
    # ROM registers no display light sensor and adding one would change its
    # behaviour. The sensor HAL's list is a note, not a source — picking a name
    # from it by shape produced xiaomi.sensor.light_raw on a HyperOS phone whose
    # resource is empty, and that is a raw ADC sensor, not the display one.
    local ls_res ls_types ls_rc
    ls_res="$(lookup 'android:string/config_displayLightSensorType')"
    ls_types="$(shel 'dumpsys sensorservice' | sed -n 's/.*type: \([^()]*\)(.*/\1/p' | grep -i light | awk '!seen[$0]++' | tr '\n' ' ')"
    ls_types="${ls_types% }"
    if [ -n "$ls_res" ]; then
        local ls_why="this ROM's config_displayLightSensorType"
        [ "$IS_GSI" -eq 1 ] && ls_why="this ROM's config_displayLightSensorType — on a GSI that is the GSI default, not the OEM's name"
        add_fact LIGHT_SENSOR_TYPE "Light sensor type" "" "$ls_res" \
            "framework resource" "high" "resource" \
            "cmd overlay lookup android:string/config_displayLightSensorType returned ${ls_res} (${ls_why})" || true
    else
        # An empty answer and a refused lookup are different facts: one means the
        # ROM chose no sensor, the other that the answer is missing.
        ls_rc="$(shel 'cmd overlay lookup android android:string/config_displayLightSensorType >/dev/null 2>&1; echo $?')"
        if [ "$ls_rc" = 0 ]; then
            note "this ROM sets config_displayLightSensorType to an empty string — no display light sensor is registered${ls_types:+, and the sensor HAL lists ${ls_types}}. LIGHT_SENSOR_TYPE is left as config.env has it, because writing a name here would add a sensor the ROM does not use"
        else
            note "config_displayLightSensorType could not be read (rc=${ls_rc:-unknown}), so LIGHT_SENSOR_TYPE is left unchanged${ls_types:+; the sensor HAL lists ${ls_types}}"
        fi
    fi

    # ---- OEM switches a live phone can answer ------------------------------
    # These flags are about nodes and init services the vendor partition
    # provides, so they are read rather than guessed. The three flags that are
    # not here describe your extracted files, not the phone (see the note below).
    local tsp_node goodix_node vib_prop vib_rc
    tsp_node="$(shel '[ -e /sys/class/sec/tsp/cmd ] && echo yes')"
    # A shell user can be denied by SELinux on a stock ROM; the module's own
    # check runs as root, so ask root before reporting the node as absent.
    [ -n "$tsp_node" ] || tsp_node="$(shel "su 0 sh -c '[ -e /sys/class/sec/tsp/cmd ] && echo yes'" | head -n1)"
    if [ "$tsp_node" = yes ]; then
        add_fact HAS_SAMSUNG_FOD "Samsung FOD" "" "true" \
            "touch panel node" "high" "runtime" \
            "/sys/class/sec/tsp/cmd exists — the Samsung touch driver's FOD switch, which the module writes fod_enable,1 to" || true
    else
        add_fact HAS_SAMSUNG_FOD "Samsung FOD" "" "false" \
            "touch panel node" "high" "runtime" \
            "no /sys/class/sec/tsp/cmd — this touch driver has no Samsung FOD switch, so the module would have nothing to write" || true
    fi

    goodix_node="$(shel '[ -e /dev/goodix_fp ] && echo yes')"
    [ -n "$goodix_node" ] || goodix_node="$(shel "su 0 sh -c '[ -e /dev/goodix_fp ] && echo yes'" | head -n1)"
    if [ "$goodix_node" = yes ]; then
        add_fact HAS_SAMSUNG_FINGERPRINT "Samsung fingerprint (Goodix)" "" "true" \
            "fingerprint driver" "medium" "runtime" \
            "/dev/goodix_fp exists — a Goodix sensor behind Samsung's vendor HAL, which is what persist.sys.phh.samsung_fingerprint is for" || true
    fi

    vib_prop="$(shel 'getprop init.svc.sec-vibrator-2-2')"
    vib_rc="$(shel 'grep -h "^service " /vendor/etc/init/*.rc 2>/dev/null' | grep -i vibrat | awk '{print $2}' | tr '\n' ' ')"
    vib_rc="${vib_rc% }"
    case "$vib_prop" in
        "")
            if printf '%s' "$vib_rc" | grep -qw 'sec-vibrator-2-2'; then
                add_fact HAS_SAMSUNG_VIBRATOR "Samsung vibrator" "" "true" \
                    "vendor init" "high" "runtime" \
                    "/vendor/etc/init defines the sec-vibrator-2-2 service${vib_prop:+, currently $vib_prop} — this is what the module starts" || true
            else
                add_fact HAS_SAMSUNG_VIBRATOR "Samsung vibrator" "" "false" \
                    "vendor init" "high" "runtime" \
                    "no sec-vibrator-2-2 service in /vendor/etc/init (vibrator services present: ${vib_rc:-none}), so the module has no service to start" || true
            fi
            ;;
        *)
            add_fact HAS_SAMSUNG_VIBRATOR "Samsung vibrator" "" "true" \
                "vendor init" "high" "runtime" \
                "init.svc.sec-vibrator-2-2 is ${vib_prop} — the vendor defines the service the module starts" || true
            ;;
    esac

    note "not read from the phone: HAS_VENDOR_FINGERPRINT_HAL and HAS_VENDOR_VIBRATOR_HAL describe which files you extracted into src/vendor (docs/device-extraction.md), and DOZE_SUSPEND_UNSUPPORTED is a workaround for a panel that hangs on DOZE_SUSPEND — nothing reports that, you set it when AOD breaks"

    # ---- display cutout ----------------------------------------------------
    # The applied path is the truth for the running ROM: DisplayCutout carries
    # the spec string it was built from. An empty spec means no cutout is
    # configured, which on a GSI is often the GSI's fault rather than the
    # phone's.
    # mDisplayCutout appears once per display, so take it from the built-in
    # display's block (mDisplayId=0) instead of whichever line comes first.
    local cutline spec inset_rect
    cutline="$(printf '%s\n' "$window" | awk '
        /Display: mDisplayId=0([^0-9]|$)/ { inblock = 1; next }
        /Display: mDisplayId=[0-9]/ { inblock = 0 }
        inblock && /mDisplayCutout=DisplayCutout\{/ { print; exit }')"
    [ -n "$cutline" ] || cutline="$(printf '%s\n' "$window" | grep -m1 -o 'mDisplayCutout=DisplayCutout{.*' || true)"
    spec="$(printf '%s\n' "$cutline" | sed -n 's/.*cutoutSpec=\(.*\) rotation=.*/\1/p')"
    spec="${spec#\{}"; spec="${spec%\}}"
    case "$spec" in
        ""|"null"|"{}") spec="" ;;
    esac
    if [ -n "$spec" ]; then
        add_fact DISPLAY_CUTOUT "Display cutout path" "" "$spec" \
            "applied cutout" "high" "runtime" \
            "dumpsys window displays: the DisplayCutout was built from this spec" || true
    else
        inset_rect="$(printf '%s\n' "$cutline" | grep -o 'insets=Rect([^)]*)' | head -n1)"
        note "this ROM applies no display cutout (dumpsys window displays: ${inset_rect:-mDisplayCutout empty})"
    fi

    # The resource the framework is serving. It is the same value the module
    # writes, so on a device that already runs the overlay this is the module
    # reading back its own work — the detail says so when config.env agrees.
    local cut_res in_config=""
    cut_res="$(lookup 'android:string/config_mainBuiltInDisplayCutout')"
    if [ -n "$cut_res" ]; then
        if [ -f "$ROOT/config.env" ] && grep -qF "DISPLAY_CUTOUT=\"$cut_res\"" "$ROOT/config.env" 2>/dev/null; then
            in_config=" — matches what config.env already sets, so this may be this tool's own overlay"
        fi
        add_fact DISPLAY_CUTOUT "Display cutout path" "" "$cut_res" \
            "framework resource" "medium" "resource" \
            "cmd overlay lookup android:string/config_mainBuiltInDisplayCutout${in_config}" || true
    fi

    if [ "$IS_GSI" -eq 1 ] && [ -z "$cut_res" ] && [ -z "$spec" ]; then
        warn "no cutout is configured on this GSI. The OEM's path lives in the OEM system partition, which the GSI replaced — boot the OEM ROM or pass --firmware DIR to read it"
    fi
    note "on a GSI the framework resource can be the GSI's default rather than the OEM's value; the firmware scan is the only source that still has the OEM number"

    # ---- stock overlay APKs that are enabled -------------------------------
    # On an OEM ROM the framework-res overlay in /product/overlay is where these
    # values actually come from, and reading it is the strongest device-side
    # evidence there is. On this GSI /product belongs to the GSI, so it usually
    # finds nothing — the note above says why.
    #
    # `cmd overlay dump` lists every installed overlay, enabled or not, so the
    # enabled set has to come from `cmd overlay list` ([x]/[ ]). Skipping that
    # is how a disabled overlay's numbers get reported as "what the ROM uses".
    if [ -n "$aapt2" ]; then
        local on_list pair_lines pkg path
        on_list="$(ovl_list | sed -n 's/^\[x\] //p' | sed 's/[[:space:]]*$//')"
        # AOSP ships cutout emulation overlays that pretend to be a notch. If one
        # is switched on, the applied cutout is that emulation, not the phone's
        # real geometry, so those packages never count as evidence.
        local emu_on
        emu_on="$(printf '%s\n' "$on_list" | grep -c 'display\.cutout\.emulation' || true)"
        [ "${emu_on:-0}" -gt 0 ] && note "a display-cutout emulation overlay is enabled — the applied cutout is an emulation, not this phone's notch"

        pair_lines="$(ovl_dump | awk -v en="$on_list" '
            BEGIN {
                n = split(en, E, "\n")
                for (i = 1; i <= n; i++) if (E[i] != "") on[E[i]] = 1
            }
            /^IDMAP OF / { pkg = $3; path = ""; keep = (pkg in on) && pkg !~ /display\\.cutout\\.emulation/ }
            /overlay path *:/ { path = $NF }
            /(string\/config_mainBuiltInDisplayCutout|dimen\/status_bar_height_default) / {
                if (keep && path != "" && !seen[path]++) print pkg "|" path
            }')"

        while IFS='|' read -r pkg path; do
            [ -n "$pkg" ] || continue
            local local_apk="$tmpdir/$(basename "$path")"
            pull_file "$path" "$local_apk" || {
                warn "could not read $path"
                continue
            }
            files+=("$path|enabled overlay ($pkg)")
            local owned="no" conf="high" who="the enabled overlay"
            if [ -n "$module_apks" ] && printf '%s\n' "$module_apks" | grep -qxF "$(basename "$path")"; then
                owned="yes"; conf="medium"
                who="this module's overlay (the same APK lives under /data/adb/modules)"
            fi
            local v
            v="$(apk_string_res "$local_apk" config_mainBuiltInDisplayCutout)"
            if [ -n "$v" ]; then
                if [ "$owned" = yes ]; then
                    # Do not add a second row: mark the framework answer that
                    # already has this value as this module's own work.
                    demote DISPLAY_CUTOUT "$v" "$who sets it, so that value is not independent evidence" \
                        || add_fact DISPLAY_CUTOUT "Display cutout path" "" "$v" \
                            "overlay: $pkg" "$conf" "overlay" "$who sets config_mainBuiltInDisplayCutout" || true
                else
                    add_fact DISPLAY_CUTOUT "Display cutout path" "" "$v" \
                        "overlay: $pkg" "$conf" "overlay" \
                        "$who $path sets config_mainBuiltInDisplayCutout" || true
                fi
            fi
            v="$(apk_dimen_res "$local_apk" status_bar_height_default "")"
            if [ -n "$v" ]; then
                local px
                px="$(dimen_to_px "${v#* }" || true)"
                if [ -n "$px" ]; then
                    if [ "$owned" = yes ]; then
                        demote STATUS_BAR_HEIGHT "$px" "$who sets status_bar_height_default, so that value is not independent evidence" \
                            || add_fact STATUS_BAR_HEIGHT "Status bar height" "px" "$px" \
                                "overlay: $pkg" "$conf" "overlay" "$who sets ${v#* }" || true
                    else
                        add_fact STATUS_BAR_HEIGHT "Status bar height" "px" "$px" \
                            "overlay: $pkg" "$conf" "overlay" \
                            "$who $path sets status_bar_height_default = ${v#* }${W:+ on a ${W}px-wide panel}" || true
                    fi
                fi
            fi
        done <<<"$pair_lines"
    fi

    if [ "$IS_GSI" -eq 1 ]; then
        note "landscape status bar height comes from values-land, which no runtime lookup exposes — pass --firmware DIR to read it from the OEM overlays"
    fi
    if [ -z "${CODENAME:-}" ]; then
        warn "no vendor codename — on a GSI prefer ro.product.vendor.device"
    fi
}

# ---------------------------------------------------------------------------
# Firmware mode
# ---------------------------------------------------------------------------
probe_firmware() {
    [ -d "$fwdir" ] || die "not a folder: $fwdir"
    fwdir="$(cd "$fwdir" && pwd)"
    resolve_aapt2 || die "aapt2 not found — it is needed to read the APKs"

    local images
    images="$(find "$fwdir" -maxdepth 3 -type f \( -name 'super.img' -o -name 'product.img' -o -name 'system.img' \) 2>/dev/null | head -n 5)"
    if [ -n "$images" ]; then
        while IFS= read -r one; do
            [ -n "$one" ] || continue
            warn "$one is a raw image — unpack it first (lpunpack super.img out/), then point --firmware at the extracted tree"
        done <<<"$images"
    fi

    # build.prop gives the density needed to turn dp dimen values into px.
    local props
    props="$(find "$fwdir" -maxdepth 4 -name 'build.prop' 2>/dev/null | head -n 20 | xargs cat 2>/dev/null || true)"
    DENS="$(printf '%s\n' "$props" | sed -n 's/^ro\.sf\.lcd_density=\([0-9]*\).*/\1/p' | head -n1)"
    [ -n "$DENS" ] || DENS="$(printf '%s\n' "$props" | sed -n 's/^ro\.vendor\.display[a-z.]*density=\([0-9]*\).*/\1/p' | head -n1)"
    MODEL="$(printf '%s\n' "$props" | sed -n 's/^ro\.product\.vendor\.model=//p' | head -n1)"
    CODENAME="$(printf '%s\n' "$props" | sed -n 's/^ro\.product\.vendor\.device=//p' | head -n1)"
    [ -n "$CODENAME" ] || CODENAME="$(printf '%s\n' "$props" | sed -n 's/^ro\.product\.device=//p' | head -n1)"

    # framework-res.apk first: it holds the AOSP defaults every overlay starts
    # from. Then the overlay APKs, which are where the OEM values live.
    local apks
    apks="$(find "$fwdir" -type f \( -name 'framework-res.apk' -o -path '*/overlay/*.apk' \) 2>/dev/null | head -n 400)"
    if [ -z "$apks" ]; then
        warn "no framework-res.apk or overlay APK under $fwdir — is this an unpacked ROM?"
        return
    fi

    local apk cut sb sb_land scanned=0
    while IFS= read -r apk; do
        [ -n "$apk" ] || continue
        scanned=$((scanned + 1))

        cut="$(apk_string_res "$apk" config_mainBuiltInDisplayCutout)"
        if [ -n "$cut" ]; then
            add_fact DISPLAY_CUTOUT "Display cutout path" "" "$cut" \
                "firmware: $(basename "$apk")" "high" "firmware" \
                "$apk sets config_mainBuiltInDisplayCutout" || true
            files+=("$apk|cutout path")
        fi

        sb="$(apk_dimen_res "$apk" status_bar_height_default "")"
        if [ -n "$sb" ]; then
            local px
            px="$(dimen_to_px "${sb#* }" || true)"
            if [ -n "$px" ]; then
                add_fact STATUS_BAR_HEIGHT "Status bar height" "px" "$px" \
                    "firmware: $(basename "$apk")" "high" "firmware" \
                    "$apk sets status_bar_height_default = ${sb#* }${DENS:+ @ ${DENS}dpi}" || true
                files+=("$apk|status bar height")
            else
                note "$apk sets status_bar_height_default = ${sb#* } but the ROM's density is not in a build.prop, so it was not converted to px"
            fi
        fi

        # Overlays usually set status_bar_height_landscape in the default
        # config; a ROM that keeps values-land instead has it as the (land)
        # variant of status_bar_height_default. Both mean the same thing.
        sb_land="$(apk_dimen_res "$apk" status_bar_height_landscape "")"
        [ -n "$sb_land" ] || sb_land="$(apk_dimen_res "$apk" status_bar_height_default "land")"
        if [ -n "$sb_land" ]; then
            local lpx
            lpx="$(dimen_to_px "${sb_land#* }" || true)"
            [ -n "$lpx" ] && add_fact STATUS_BAR_HEIGHT_LANDSCAPE "Status bar height (landscape)" "px" "$lpx" \
                "firmware: $(basename "$apk")" "high" "firmware" \                    "$apk sets the landscape status bar height to ${sb_land#* }" || true
            files+=("$apk|landscape status bar height")
        fi
    done <<<"$apks"

    note "scanned $scanned APK(s); corners and refresh rates are display-hardware facts, so they only come from a device"
}

# ---------------------------------------------------------------------------
# Power profile
# ---------------------------------------------------------------------------
# aapt2 prints a compiled XML file as an indented tree, and that is what the
# desktop app converts back to <device>...</device>. Nothing here tries to write
# XML: the tree is faithful, and a converter that is tested can be changed.
dump_power() {
    "$aapt2" dump xmltree "$(winpath "$1")" --file res/xml/power_profile.xml 2>/dev/null
}

# A device profile has numbers only a device would: CPU frequencies in the
# hundreds of MHz to GHz, screen currents in mA, a battery in thousands of mAh.
# AOSP's fallback — and the copy many ROMs leave in framework-res — is 0.1 for
# everything, one 400 MHz speed and a 1000 mAh battery. Shipping that over the
# ROM's real profile is worse than shipping nothing, so it is refused.
profile_looks_real() {
    # The quotes come off first so awk can be a plain, portable program: the
    # tree prints values as T: '0.1', and a single quote cannot appear inside a
    # single-quoted shell string.
    local clean
    clean="$(printf '%s\n' "$1" | tr -d "'")"
    printf '%s\n' "$clean" | awk '
        /A: name="/ { n = $0; sub(/.*A: name="/, "", n); sub(/".*/, "", n) }
        /T: / {
            v = $0; sub(/.*T: /, "", v); sub(/ .*/, "", v); v += 0
            if (n == "battery.capacity" && v >= 1500) real = 1
            if ((n == "screen.on" || n == "screen.full" || \
                 n == "screen.on.display0" || n == "screen.full.display0") && v >= 10) real = 1
            if (n ~ /cpu\..*speeds/ && v >= 1000000) real = 1
        }
        END { exit !real }'
}

power_profile_device() {
    resolve_adb || die "adb not found — install platform-tools, or pass --adb PATH"
    pick_serial
    resolve_aapt2 || die "aapt2 not found — it is needed to read the APK"

    # The applied profile can come from an enabled RRO (MIUI ships one), and
    # that file is the one Android is using. It is tried first; the framework's
    # own copy is the fallback.
    local on_list overlays="" overlay apk tree
    on_list="$(ovl_list | sed -n 's/^\[x\] //p' | sed 's/[[:space:]]*$//')"
    overlays="$(ovl_dump | awk -v en="$on_list" '
        BEGIN {
            n = split(en, E, "\n")
            for (i = 1; i <= n; i++) if (E[i] != "") on[E[i]] = 1
        }
        /^IDMAP OF / { pkg = $3; p = ""; keep = (pkg in on) }
        /overlay path *:/ { p = $NF }
        /xml\/power_profile/ { if (keep && p != "") print p }' | awk '!seen[$0]++')"

    # The enabled overlay wins because it is what Android is using; the
    # framework's own copy is the fallback. Both are tried against the same
    # "is this a device profile or the AOSP placeholder" test below.
    local candidates=()
    while IFS= read -r overlay; do
        [ -n "$overlay" ] && candidates+=("$overlay")
    done <<<"$overlays"
    candidates+=("/system/framework/framework-res.apk")

    local generic=""
    for apk in "${candidates[@]}"; do
        [ -n "$(shel "ls $apk")" ] || continue
        local local_apk="$tmpdir/power.apk"
        pull_file "$apk" "$local_apk" || {
            warn "could not read $apk"
            continue
        }
        tree="$(dump_power "$local_apk")"
        [ -n "$tree" ] || continue
        if profile_looks_real "$tree"; then
            printf '# source: %s\n' "$apk"
            printf '%s\n' "$tree"
            return 0
        fi
        [ -n "$generic" ] || generic="$apk"
        note "$apk carries a generic profile (0.1 for everything, a 1 GHz-less CPU list), so it was skipped"
    done
    die "no real power profile found — ${generic:+$generic holds the AOSP placeholder; }the OEM's own is usually in an enabled overlay APK (e.g. /vendor/overlay/FrameworksResTarget_Vendor.apk) or in the ROM dump"
}

power_profile_firmware() {
    [ -d "$fwdir" ] || die "not a folder: $fwdir"
    fwdir="$(cd "$fwdir" && pwd)"
    resolve_aapt2 || die "aapt2 not found — it is needed to read the APKs"

    # Overlay APKs first (an OEM's own profile usually lives there), then the
    # framework's copy. The first one that looks like a device wins; a generic
    # AOSP profile is remembered only to explain the failure.
    local apk tree generic=""
    while IFS= read -r apk; do
        [ -n "$apk" ] || continue
        tree="$(dump_power "$apk")"
        [ -n "$tree" ] || continue
        if profile_looks_real "$tree"; then
            printf '# source: %s\n' "$apk"
            printf '%s\n' "$tree"
            return 0
        fi
        [ -n "$generic" ] || generic="$apk"
        note "$apk carries a generic profile (0.1 for everything, a 1 GHz-less CPU list), so it was skipped"
    done <<<"$(find "$fwdir" -type f -path '*/overlay/*.apk' 2>/dev/null | head -n 300; find "$fwdir" -type f -name 'framework-res.apk' 2>/dev/null | head -n 10)"

    die "no real power profile found under $fwdir${generic:+ — $generic holds the AOSP placeholder}"
}

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
json_escape() { printf '%s' "$1" | tr -d '\000-\037' | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }
json_list() {
    local first=1 v
    printf '['
    for v in "$@"; do
        [ "$first" -eq 1 ] || printf ','
        first=0
        printf '"%s"' "$(json_escape "$v")"
    done
    printf ']'
}

emit_json() {
    local i first=1
    printf '{'
    printf '"mode":"%s",' "$mode"
    if [ "$mode" = "device" ]; then
        printf '"device":{"serial":"%s","model":"%s","codename":"%s","rom":"%s","isGsi":%s,"width":%s,"height":%s,"density":%s},' \
            "$(json_escape "${serial:-}")" "$(json_escape "${MODEL:-}")" \
            "$(json_escape "${CODENAME:-}")" "$(json_escape "${rom:-}")" \
            "$([ "${IS_GSI:-0}" -eq 1 ] && echo true || echo false)" "${W:-0}" "${H:-0}" "${DENS:-0}"
    else
        printf '"firmware":"%s",' "$(json_escape "$fwdir")"
    fi
    printf '"aapt2":"%s",' "$(json_escape "${aapt2:-}")"
    printf '"facts":['
    for i in "${!f_key[@]}"; do
        [ "$first" -eq 1 ] || printf ','
        first=0
        printf '{"key":"%s","label":"%s","unit":"%s","value":"%s","source":"%s","confidence":"%s","kind":"%s","detail":"%s"}' \
            "$(json_escape "${f_key[$i]}")" "$(json_escape "${f_label[$i]}")" \
            "$(json_escape "${f_unit[$i]}")" "$(json_escape "${f_value[$i]}")" \
            "$(json_escape "${f_src[$i]}")" "$(json_escape "${f_conf[$i]}")" \
            "$(json_escape "${f_kind[$i]}")" "$(json_escape "${f_detail[$i]}")"
    done
    printf '],'
    printf '"warnings":%s,' "$(json_list "${warnings[@]+"${warnings[@]}"}")"
    printf '"notes":%s,' "$(json_list "${notes[@]+"${notes[@]}"}")"
    local fpaths=() froles=()
    for i in "${files[@]+"${files[@]}"}"; do
        fpaths+=("${i%%|*}")
        froles+=("${i#*|}")
    done
    printf '"files":['
    for i in "${!fpaths[@]}"; do
        [ "$i" -eq 0 ] || printf ','
        printf '{"path":"%s","role":"%s"}' "$(json_escape "${fpaths[$i]}")" "$(json_escape "${froles[$i]}")"
    done
    printf ']'
    [ "$want_write" -eq 1 ] && printf ',"written":"config.env"'
    printf '}\n'
}

emit_human() {
    local i
    printf '\n'
    if [ "$mode" = "device" ]; then
        printf 'Device   %s (%s)  %sx%s @%s dpi\n' \
            "${MODEL:-unknown}" "${CODENAME:-unknown}" "${W:-?}" "${H:-?}" "${DENS:-?}"
        printf 'ROM      %s\n' "${rom:-unknown}"
    else
        printf 'Firmware %s\n' "$fwdir"
    fi
    printf '\n'

    if [ "${#f_key[@]}" -eq 0 ]; then
        printf 'Nothing found.\n'
        for i in "${warnings[@]+"${warnings[@]}"}"; do printf '  ! %s\n' "$i"; done
        return
    fi

    # A cutout path is a hundred characters of SVG; the table is a summary, so
    # it is cut to a readable length here and printed in full further down.
    short_value() {
        local v="$1"
        if [ "${#v}" -gt 44 ]; then printf '%s…' "${v:0:43}"; else printf '%s' "$v"; fi
    }

    printf '%-26s %-46s %-20s %s\n' "SETTING" "VALUE" "SOURCE" "CONFIDENCE"
    for i in "${!f_key[@]}"; do
        printf '%-26s %-46s %-20s %s\n' \
            "${f_key[$i]}" "$(short_value "${f_value[$i]}${f_unit[$i]:+ ${f_unit[$i]}}")" \
            "${f_src[$i]}" "${f_conf[$i]}"
    done

    # Disagreement is the interesting case: the same setting with two values
    # means two sources, and the user has to pick which one to believe.
    local key i j distinct first second
    for key in $(printf '%s\n' "${f_key[@]}" | awk '!seen[$0]++'); do
        distinct="$(for i in "${!f_key[@]}"; do
            [ "${f_key[$i]}" = "$key" ] && printf '%s\n' "${f_value[$i]}"
        done | awk '!seen[$0]++' | grep -c . || true)"
        [ "${distinct:-0}" -gt 1 ] || continue
        if [ "$distinct" -eq 2 ]; then
            first=""; second=""
            for i in "${!f_key[@]}"; do
                [ "${f_key[$i]}" = "$key" ] || continue
                if [ -z "$first" ]; then first="$i"
                elif [ "${f_value[$i]}" != "${f_value[$first]}" ] && [ -z "$second" ]; then second="$i"; fi
            done
            printf '\n%s differs: %s says %s, %s says %s\n' \
                "$key" "${f_src[$first]}" "$(short_value "${f_value[$first]}")" \
                "${f_src[$second]}" "$(short_value "${f_value[$second]}")"
        else
            printf '\n%s: %s different answers — pick one from the table\n' "$key" "$distinct"
        fi
    done

    printf '\nvalues for config.env:\n'
    for i in "${!f_key[@]}"; do
        local seen=""
        local j
        for j in "${!f_key[@]}"; do
            [ "$i" -gt "$j" ] && [ "${f_key[$i]}" = "${f_key[$j]}" ] && { seen="1"; break; }
        done
        [ -n "$seen" ] && continue
        case "${f_key[$i]}" in
            DISPLAY_CUTOUT|LIGHT_SENSOR_TYPE) printf '  %s="%s"\n' "${f_key[$i]}" "${f_value[$i]}" ;;
            *) printf '  %s=%s\n' "${f_key[$i]}" "${f_value[$i]}" ;;
        esac
    done

    for i in "${notes[@]+"${notes[@]}"}"; do printf '\nnote: %s\n' "$i"; done
    for i in "${warnings[@]+"${warnings[@]}"}"; do printf '\nwarning: %s\n' "$i"; done
}

# ---------------------------------------------------------------------------
# Writing config.env
# ---------------------------------------------------------------------------
set_config_key() {
    local key="$1" value="$2" file="$ROOT/config.env" tmp
    [ -f "$file" ] || die "no config.env in $ROOT"
    tmp="$tmpdir/config.env"
    awk -v k="$key" -v v="$value" '
        BEGIN { done = 0 }
        {
            line = $0
            sub(/\r$/, "", line)
            if (!done && line ~ "^[[:space:]]*#?[[:space:]]*" k "=") {
                match(line, /^[[:space:]]*/)
                printf "%s%s=%s\n", substr(line, 1, RLENGTH), k, v
                done = 1
                next
            }
            print
        }
        END { if (!done) printf "%s=%s\n", k, v }
    ' "$file" >"$tmp" || return 1
    cp "$tmp" "$file"
}

write_config() {
    local i value
    for i in "${!f_key[@]}"; do
        [ "${f_conf[$i]}" = "low" ] && continue
        # One write per setting: the first fact is the highest-priority source.
        local key="${f_key[$i]}"
        local earlier=""
        local j
        for j in "${!f_key[@]}"; do
            [ "$j" -lt "$i" ] && [ "${f_key[$j]}" = "$key" ] && { earlier="1"; break; }
        done
        [ -n "$earlier" ] && continue

        value="${f_value[$i]}"
        case "$key" in
            # String settings keep the quotes every line of config.env uses.
            DISPLAY_CUTOUT|LIGHT_SENSOR_TYPE) set_config_key "$key" "\"$value\"" ;;
            *) set_config_key "$key" "$value" ;;
        esac
    done
}

# ---------------------------------------------------------------------------
main() {
    # Hidden helper for the tests: decide whether a tree on stdin is a device
    # profile or the AOSP placeholder, without needing adb or aapt2.
    if [ "$check_profile" -eq 1 ]; then
        local tree
        tree="$(cat)"
        if profile_looks_real "$tree"; then
            printf 'real\n'
            exit 0
        fi
        printf 'generic\n'
        exit 1
    fi
    if [ "$power_mode" -eq 1 ]; then
        if [ "$mode" = "firmware" ]; then power_profile_firmware; else power_profile_device; fi
        exit 0
    fi
    if [ "$mode" = "firmware" ]; then probe_firmware; else probe_device; fi
    if [ "$want_write" -eq 1 ]; then
        if [ "${#f_key[@]}" -eq 0 ]; then
            die "nothing to write — no setting was found"
        fi
        write_config
    fi
    if [ "$want_json" -eq 1 ]; then emit_json; else emit_human; fi
}

main "$@"
