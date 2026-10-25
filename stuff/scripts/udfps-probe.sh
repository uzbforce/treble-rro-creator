#!/usr/bin/env bash
# =============================================================================
# udfps-probe.sh — find a device's in-display fingerprint (UDFPS) geometry
# =============================================================================
# UDFPS_X / UDFPS_Y / UDFPS_RADIUS in config.env are the sensor's centre and
# radius in px, written to android:array/config_udfps_sensor_props. Guessing
# them puts the lock-screen icon next to the sensor instead of on it, so this
# asks the phone (or a firmware dump) the same question several ways and says
# where each answer came from.
#
#   bash stuff/scripts/udfps-probe.sh                 # connected device
#   bash stuff/scripts/udfps-probe.sh --firmware DIR  # extracted ROM dump
#   bash stuff/scripts/udfps-probe.sh --json          # for the desktop app
#   bash stuff/scripts/udfps-probe.sh --write         # put the winner in config.env
#
# Three situations, in the order the guide describes them:
#
#   1. OEM ROM on the phone. The vendor FOD properties and the preinstalled
#      device overlay are both present, so this is the strongest evidence.
#   2. GSI on the phone. The system partition is the GSI's, but /vendor and
#      /persist keep the OEM's properties, and the phh/device overlay that was
#      flashed with the GSI usually still carries the resource. Both are read
#      here; a value that came from an overlay this tool itself modified is
#      marked as such instead of being counted as independent.
#   3. Firmware files. Only useful once the images are unpacked: super.img
#      needs lpunpack before any APK or build.prop inside it can be read, so a
#      bare fastboot ROM reports what it is missing instead of guessing.
#
# Nothing here is root-only. The overlay APKs and properties it reads are
# world-readable on a normal boot.
# =============================================================================

set -uo pipefail

# adb is a Windows binary under Git Bash: without this its /system/... arguments
# are rewritten into C:/Program Files/Git/system/... before adb ever sees them.
# The local half of a pull is converted back with winpath() instead, because the
# same binary cannot open an MSYS /tmp path.
export MSYS_NO_PATHCONV=1

winpath() {
    if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s' "$1"; fi
}

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

mode="device"
serial=""
want_json=0
want_write=0
adb="${ADB:-}"
aapt2="${AAPT2:-}"
fwdir=""
scan_all_apks=0

usage() {
    sed -n '3,30p' "$0" | sed 's/^# \{0,1\}//'
}

die() { printf 'udfps-probe: %s\n' "$1" >&2; exit 1; }

# Multi-device selection is shared with the Detect probe.
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
        --adb) adb="${2:-}"; shift 2 ;;
        --aapt2) aapt2="${2:-}"; shift 2 ;;
        --all-apks) scan_all_apks=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown option: $1 (try --help)" ;;
    esac
done

tmpdir="$(mktemp -d 2>/dev/null || mktemp -d -t udfps)"
cleanup() { rm -rf "$tmpdir"; }
trap cleanup EXIT HUP INT TERM

notes=()
warnings=()

# Candidates, kept parallel so the report can be sorted after the fact.
c_kind=(); c_source=(); c_label=(); c_x=(); c_y=(); c_r=()
c_conf=(); c_score=(); c_detail=()

# ---------------------------------------------------------------------------
# aapt2
# ---------------------------------------------------------------------------
# The APK is the authority: an overlay that is enabled and maps the array is
# what the framework is actually serving. aapt2 is already downloaded for the
# build, so reuse that copy instead of asking for a second install.
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

# Prints "x y r" for array/config_udfps_sensor_props, or nothing.
apk_udfps() {
    [ -n "$aapt2" ] || return 1
    "$aapt2" dump resources "$(winpath "$1")" 2>/dev/null | awk '
        /array\/config_udfps_sensor_props/ { found = 1; next }
        found && /\[/ {
            gsub(/[^0-9, ]/, "")
            n = split($0, a, ",")
            if (n >= 3) { gsub(/ /, "", a[1]); gsub(/ /, "", a[2]); gsub(/ /, "", a[3]); print a[1], a[2], a[3] }
            exit
        }'
}

# Prints the sensor-list entry ("0:2:15") for array/config_biometric_sensors.
apk_biometric() {
    [ -n "$aapt2" ] || return 1
    "$aapt2" dump resources "$(winpath "$1")" 2>/dev/null | awk '
        /array\/config_biometric_sensors/ { found = 1; next }
        found && /\[/ { gsub(/[^0-9:;]/, ""); print; exit }'
}

# ---------------------------------------------------------------------------
# Candidate bookkeeping
# ---------------------------------------------------------------------------
is_uint() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

# add_candidate kind source label x y radius confidence score detail
#
# Anything that does not survive the range checks is dropped with a warning: a
# value that puts the icon off the panel is worse than no value at all, because
# the module would then override a sensor the HAL could have located itself.
add_candidate() {
    local kind="$1" source="$2" label="$3" x="$4" y="$5" r="$6"
    local conf="$7" score="$8" detail="${9:-}"

    if ! is_uint "$x" || ! is_uint "$y" || ! is_uint "$r" \
        || [ "$x" -le 0 ] || [ "$y" -le 0 ] || [ "$r" -le 0 ]; then
        warn "ignored $label: not a usable triple ($x, $y, $r)"
        return 1
    fi
    if [ -n "${W:-}" ] && [ -n "${H:-}" ]; then
        if [ "$x" -ge "$W" ] || [ "$y" -ge "$H" ]; then
            warn "ignored $label: $x,$y is outside the ${W}x${H} panel"
            return 1
        fi
        if [ "$r" -gt "$((W / 6))" ] || [ "$r" -lt 20 ]; then
            warn "ignored $label: radius $r is not a fingerprint sensor ($W px wide)"
            return 1
        fi
    fi

    # A sensor sits on the panel's centre line on every UDFPS phone made so
    # far; an answer that is not close to it is more likely a misparse.
    local bonus=0
    if [ -n "${W:-}" ] && [ $((x - W / 2)) -le 8 ] && [ $((W / 2 - x)) -le 8 ]; then
        bonus=5
    fi

    c_kind+=("$kind"); c_source+=("$source"); c_label+=("$label")
    c_x+=("$x"); c_y+=("$y"); c_r+=("$r")
    c_conf+=("$conf"); c_score+=($((score + bonus))); c_detail+=("$detail")
    return 0
}

# True when a candidate with these coordinates is already recorded; used to stop
# "cmd overlay lookup" from adding a second copy of the overlay's own answer.
have_values() {
    local i
    for i in "${!c_x[@]}"; do
        [ "${c_x[$i]}" = "$1" ] && [ "${c_y[$i]}" = "$2" ] && [ "${c_r[$i]}" = "$3" ] && return 0
    done
    return 1
}

chosen_index() {
    local best="" i
    for i in "${!c_score[@]}"; do
        if [ -z "$best" ] || [ "${c_score[$i]}" -gt "${c_score[$best]}" ]; then best="$i"; fi
    done
    printf '%s' "$best"
}

# fod_rect LOCATION SIZE prints "cx cy r" for the Xiaomi FOD rectangle, or
# nothing when the pair is not usable. location.X_Y is the rectangle's top-left
# corner and size is width,height, so reading the first pair as a centre would
# put X at 451 instead of 540 on a 1080-wide panel: this arithmetic is the whole
# reason the values line up, and both modes go through it.
fod_rect() {
    local loc="$1" siz="$2" left top w h
    left="$(printf '%s' "$loc" | cut -d, -f1 | tr -cd '0-9')"
    top="$(printf '%s' "$loc" | cut -d, -f2 | tr -cd '0-9')"
    w="$(printf '%s' "$siz" | cut -d, -f1 | tr -cd '0-9')"
    h="$(printf '%s' "$siz" | cut -d, -f2 | tr -cd '0-9')"
    [ -n "$left" ] && [ -n "$top" ] && [ -n "$w" ] && [ -n "$h" ] || return 1
    [ "$w" -gt 0 ] && [ "$h" -gt 0 ] || return 1
    printf '%s %s %s\n' "$((left + w / 2))" "$((top + h / 2))" "$(( (w < h ? w : h) / 2 ))"
}

# ---------------------------------------------------------------------------
# Device mode
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

adb_dev() { "$adb" ${serial:+-s "$serial"} "$@"; }
shel() { adb_dev shell "$1" 2>/dev/null | tr -d '\r'; }

probe_device() {
    resolve_adb || die "adb not found — install platform-tools, or pass --adb PATH"
    adb_pick_device "$adb" "$serial" "udfps-probe" || exit 1
    serial="$DEVICE_SERIAL"

    local props size dens_out
    props="$(shel getprop)"
    prop() { printf '%s\n' "$props" | sed -n "s/^\[$1\]: \[\(.*\)\]$/\1/p" | head -n1; }

    size="$(shel 'wm size')"
    W="$(printf '%s\n' "$size" | sed -n 's/.*Physical size: \([0-9]*\)x[0-9]*.*/\1/p' | head -n1)"
    H="$(printf '%s\n' "$size" | sed -n 's/.*Physical size: [0-9]*x\([0-9]*\).*/\1/p' | head -n1)"
    dens_out="$(shel 'wm density')"
    DENS="$(printf '%s\n' "$dens_out" | sed -n 's/.*Physical density: \([0-9]*\).*/\1/p' | head -n1)"
    [ -n "$W" ] && [ -n "$H" ] || die "could not read the display size (wm size)"

    # The ODM partition keeps the real name on HyperOS, where the vendor one is
    # "mivendor" and the model is "Xiaomi for arm64" (measured on a Redmi Note
    # 17). Same order as device-probe.sh.
    MODEL="$(prop ro.product.odm.model)"
    [ -n "$MODEL" ] || MODEL="$(prop ro.product.model)"
    CODENAME="$(prop ro.product.odm.device)"
    [ -n "$CODENAME" ] || CODENAME="$(prop ro.product.vendor.device)"
    [ -n "$CODENAME" ] || CODENAME="$(prop ro.product.device)"

    local flavor miui hyperos
    flavor="$(prop ro.build.flavor)"
    hyperos="$(prop ro.mi.os.version.name)"
    miui="$(prop ro.miui.ui.version.name)"
    IS_GSI=0
    case "$flavor" in *gsi*|*GSI*) IS_GSI=1 ;; esac
    if [ "$IS_GSI" -eq 1 ]; then
        rom="GSI (${flavor:-unknown})"
    elif [ -n "$hyperos" ]; then
        rom="HyperOS $hyperos"
    elif [ -n "$miui" ]; then
        rom="MIUI $miui"
    else
        rom="${flavor:-unknown ROM}"
    fi

    resolve_aapt2 || warn "aapt2 not found — overlay APKs cannot be read, only the properties"

    # ---- 1. overlays that are actually enabled and map the array ----------
    # `cmd overlay dump` lists every installed overlay, enabled or not, so the
    # enabled set has to come from `cmd overlay list` ([x]/[ ]). Without that
    # filter a disabled OEM overlay's numbers are reported as what the ROM uses.
    # Anonymous overlays (fabricated RROs) have no path and are skipped.
    local dump pairs enabled pkg path
    dump="$(shel 'cmd overlay dump')"
    enabled="$(shel 'cmd overlay list' | sed -n 's/^\[x\] //p' | sed 's/[[:space:]]*$//')"
    pairs="$(printf '%s\n' "$dump" | awk -v en="$enabled" '
        BEGIN {
            n = split(en, E, "\n")
            for (i = 1; i <= n; i++) if (E[i] != "") on[E[i]] = 1
        }
        /^IDMAP OF / { pkg = $3; path = ""; keep = (pkg in on) }
        /overlay path *:/ { path = $NF }
        /\(array\/config_udfps_sensor_props / {
            if (keep && path != "" && !seen[path]++) print pkg "|" path
        }')"

    if [ -n "$pairs" ]; then
        while IFS='|' read -r pkg path; do
            [ -n "$path" ] || continue
            local local_apk="$tmpdir/$(basename "$path")"
            if ! adb_dev pull "$path" "$(winpath "$local_apk")" >/dev/null 2>&1; then
                warn "could not pull $path"
                continue
            fi
            local vals bio
            vals="$(apk_udfps "$local_apk")"
            if [ -z "$vals" ]; then
                warn "$pkg maps the array but its APK has no readable value"
                continue
            fi
            bio="$(apk_biometric "$local_apk")"
            local x y r origin conf score
            read -r x y r <<<"$vals"
            # When the module has patched this APK before, it leaves the OEM copy
            # next to it as <name>.webui-orig. The enabled file then contains
            # whatever this tool wrote last time, so it is not evidence that
            # agrees with the properties — it must not outrank them.
            if [ -n "$(shel "ls $path.webui-orig")" ]; then
                origin="patched by this module earlier (.webui-orig next to it)"
                conf="medium"; score=60
            else
                origin="preinstalled overlay"
                conf="high"; score=90
            fi
            add_candidate "overlay" "overlay:$pkg" "overlay $pkg" "$x" "$y" "$r" \
                "$conf" "$score" "$origin, from $path${bio:+, sensors $bio}" || true
            files+=("$path|enabled overlay mapping config_udfps_sensor_props")
        done <<<"$pairs"
    else
        note "no enabled overlay maps config_udfps_sensor_props"
    fi

    # ---- 2. the effective value the framework is serving -------------------
    # This is the same array the framework reads, but it says nothing about
    # where the value came from — an overlay this tool patched earlier answers
    # here too. It is still worth recording: it is what Android is using now.
    local lookup lx ly lr in_config=""
    lookup="$(shel 'cmd overlay lookup android android:array/config_udfps_sensor_props' \
        | tr -s ' \n' ' ')"
    if [ -n "$lookup" ] && [ "${lookup#Error}" = "$lookup" ]; then
        set -- $lookup
        lx="${1:-}"; ly="${2:-}"; lr="${3:-}"
        # The array can be answering with the numbers config.env already sets —
        # that is this tool's own work, not a second opinion from the device.
        if [ -f "$ROOT/config.env" ] \
            && grep -qE "^UDFPS_X=$lx$" "$ROOT/config.env" \
            && grep -qE "^UDFPS_Y=$ly$" "$ROOT/config.env" \
            && grep -qE "^UDFPS_RADIUS=$lr$" "$ROOT/config.env"; then
            in_config=" — matches what config.env already sets, so it may be this tool's own overlay"
        fi
        if ! have_values "$lx" "$ly" "$lr"; then
            add_candidate "framework" "framework-array" "live framework value" \
                "$lx" "$ly" "$lr" "medium" 70 \
                "cmd overlay lookup, source not attributed$in_config" || true
        fi
    fi

    # ---- 3. Xiaomi's FOD rectangle ---------------------------------------
    # A property pair, not an overlay resource; fod_rect turns it into a centre
    # and both modes share that arithmetic.
    local loc siz rect loc_key siz_key cx cy cr
    for loc_key in persist.vendor.sys.fp.fod.location.X_Y persist.sys.fp.fod.location.X_Y; do
        siz_key="${loc_key/location.X_Y/size.width_height}"
        loc="$(prop "$loc_key")"
        siz="$(prop "$siz_key")"
        [ -n "$loc" ] && [ -n "$siz" ] || continue
        rect="$(fod_rect "$loc" "$siz")" || continue
        read -r cx cy cr <<<"$rect"
        add_candidate "props" "xiaomi-fod-props" "Xiaomi FOD rectangle" "$cx" "$cy" "$cr" \
            "high" 92 "$loc_key=$loc  $siz_key=$siz → left+width/2, top+height/2" || true
        break
    done

    # ---- 4. kernels that export the sensor position -----------------------
    local pos_file="/sys/class/fingerprint/fingerprint/position" pos
    pos="$(shel "cat $pos_file")"
    if [ -n "$pos" ] && [ "${pos#cat:}" = "$pos" ]; then
        local bottom_mm area_mm height_mm bottom_px area_px
        bottom_mm="$(printf '%s' "$pos" | cut -d, -f1)"
        height_mm="$(printf '%s' "$pos" | cut -d, -f3)"
        area_mm="$(printf '%s' "$pos" | cut -d, -f6)"
        if is_uint "${bottom_mm%%.*}" && is_uint "${area_mm%%.*}" && [ -n "$DENS" ]; then
            # mm -> px has to use the panel's physical density, not the user's
            # display-size override: the kernel numbers are panel millimetres.
            bottom_px="$(awk -v mm="$bottom_mm" -v dpi="$DENS" 'BEGIN { printf "%d", mm / 25.4 * dpi }')"
            area_px="$(awk -v mm="$area_mm" -v dpi="$DENS" 'BEGIN { printf "%d", mm / 25.4 * dpi }')"
            add_candidate "sysfs" "sysfs-position" "kernel position file" \
                "$((W / 2))" "$((H - bottom_px - area_px / 2))" "$((area_px / 2))" \
                "medium" 75 "$pos_file=$pos (bottom ${bottom_mm}mm, area ${area_mm}mm)" || true
        else
            warn "unexpected $pos_file contents: $pos"
        fi
    fi

    # ---- 5. HAL-reported sensor location ---------------------------------
    local fp
    fp="$(shel 'dumpsys fingerprint')"
    if printf '%s' "$fp" | grep -qi 'sensorLocation'; then
        local hx hy hr
        hx="$(printf '%s' "$fp" | grep -oiE 'x *[:=] *[0-9]+' | head -n1 | tr -cd '0-9')"
        hy="$(printf '%s' "$fp" | grep -oiE 'y *[:=] *[0-9]+' | head -n1 | tr -cd '0-9')"
        hr="$(printf '%s' "$fp" | grep -oiE 'radius *[:=] *[0-9]+' | head -n1 | tr -cd '0-9')"
        [ -n "$hx" ] && [ -n "$hy" ] && [ -n "$hr" ] && \
            add_candidate "dumpsys" "dumpsys-fingerprint" "HAL sensor location" \
                "$hx" "$hy" "$hr" "medium" 72 "dumpsys fingerprint" || true
    fi

    # ---- 6. last resort: the panel's own geometry -------------------------
    if [ "${#c_x[@]}" -eq 0 ]; then
        local guess_r guess_y
        guess_r=$((W * 89 / 1080))
        guess_y=$((H - H * 198 / 2396))
        add_candidate "estimate" "display-estimate" "estimate from the panel" \
            "$((W / 2))" "$guess_y" "$guess_r" "guess" 10 \
            "no source answered; scaled from a 1080x2396 panel" || true
        warn "these are estimates — check the lock-screen icon before trusting them"
    fi
}

# ---------------------------------------------------------------------------
# Firmware mode
# ---------------------------------------------------------------------------
# A fastboot ROM keeps everything worth reading inside super.img, and reading an
# ext4/erofs image needs lpunpack and a mount. So this walks a directory that is
# already unpacked (an extracted product/vendor tree, a custom ROM zip's files,
# or a folder of pulled APKs) and reports the images it would have needed when
# it finds only a raw super.img.
probe_firmware() {
    [ -n "$fwdir" ] || die "--firmware needs a folder"
    [ -d "$fwdir" ] || die "not a folder: $fwdir"
    local apks apk rel vals bio x y r count=0

    resolve_aapt2 || warn "aapt2 not found — APK resources cannot be read"

    if [ -n "$aapt2" ]; then
        if [ "$scan_all_apks" -eq 1 ]; then
            apks="$(find "$fwdir" -maxdepth 7 -type f -iname '*.apk' 2>/dev/null | head -n 400)"
        else
            apks="$(find "$fwdir" -maxdepth 7 -type f -iname '*.apk' 2>/dev/null \
                | grep -iE 'overlay|udfps|finger|fod' | head -n 200)"
            [ -n "$apks" ] || apks="$(find "$fwdir" -maxdepth 7 -type f -iname '*.apk' 2>/dev/null | head -n 120)"
        fi
        while IFS= read -r apk; do
            [ -n "$apk" ] || continue
            count=$((count + 1))
            vals="$(apk_udfps "$apk")"
            [ -n "$vals" ] || continue
            bio="$(apk_biometric "$apk")"
            read -r x y r <<<"$vals"
            rel="${apk#"$fwdir"/}"
            # A vendor/product overlay in a ROM is the OEM's own answer; it is
            # scored below the live device (which cannot be stale) but above
            # anything inferred.
            add_candidate "overlay" "firmware:$rel" "overlay $rel" "$x" "$y" "$r" \
                "high" 88 "${fwdir#$PWD/}/$rel${bio:+, sensors $bio}" || true
            files+=("$apk|overlay with config_udfps_sensor_props")
        done <<<"$apks"
    fi

    # Properties shipped as text (vendor/build.prop, odm/etc/build.prop, …).
    # build.prop comes first: on a Xiaomi ROM the vendor one carries the FOD
    # rectangle, and a tree has hundreds of per-app *.prop files (system_ext's
    # cust/*) that would otherwise fill the cap long before it is reached.
    local pfile key val loc siz rect cx cy cr hit n
    while IFS= read -r pfile; do
        [ -n "$pfile" ] || continue
        # One pass with the shell's own parser: grep plus two seds per file is
        # three forks over two hundred files, which is a minute on Windows.
        loc=""; siz=""; hit=""; n=0
        while IFS='=' read -r key val; do
            key="${key%$'\r'}"; val="${val%$'\r'}"
            case "$key" in
                persist.vendor.sys.fp.fod.location.X_Y|persist.sys.fp.fod.location.X_Y) loc="$val" ;;
                persist.vendor.sys.fp.fod.size.width_height|persist.sys.fp.fod.size.width_height) siz="$val" ;;
            esac
            case "$key" in
                *sys.fp.fod*|ro.hardware.fp.fod*)
                    if [ "$n" -lt 4 ]; then hit="$hit $key=$val"; n=$((n + 1)); fi
                    ;;
            esac
        done < "$pfile" 2>/dev/null
        [ -n "$hit" ] && files+=("$pfile|FOD properties:$hit")

        # The rectangle is the answer for a phone whose overlay does not set
        # config_udfps_sensor_props, which is most Xiaomi ROMs: the property is
        # the vendor client's own definition of the sensor, shipped as the
        # factory default, and the live phone reports the same numbers.
        [ -n "$loc" ] && [ -n "$siz" ] || continue
        rect="$(fod_rect "$loc" "$siz")" || continue
        read -r cx cy cr <<<"$rect"
        # Two partitions can carry the same default; the same triple is one
        # answer, while a differing one stays visible as its own row.
        have_values "$cx" "$cy" "$cr" && continue
        add_candidate "props" "firmware-fod-props" "Xiaomi FOD rectangle" "$cx" "$cy" "$cr" \
            "high" 90 "$pfile: location.X_Y=$loc size.width_height=$siz → left+width/2, top+height/2" || true
    done <<EOF
$(
    {
        find "$fwdir" -maxdepth 7 -type f \( -name 'build.prop' -o -name 'prop.default' \) 2>/dev/null
        find "$fwdir" -maxdepth 7 -type f -name '*.prop' 2>/dev/null | head -n 195
    } | head -n 200
)
EOF

    # What the ROM's HAL stack looks like — the part an overlay cannot replace.
    local vintf
    vintf="$(grep -rlE 'android\.hardware\.biometrics\.fingerprint|vendor\.xiaomi\.hardware\.fingerprintextension' \
        --include='*.xml' --include='*.rc' "$fwdir" 2>/dev/null | head -n 10)"
    while IFS= read -r vintf; do
        [ -n "$vintf" ] || continue
        files+=("$vintf|mentions the fingerprint HAL or the Xiaomi extension")
    done <<<"$vintf"

    # Raw images: say what is missing instead of pretending the scan was complete.
    local img
    img="$(find "$fwdir" -maxdepth 3 -type f \( -name 'super.img' -o -name 'product.img' -o -name 'vendor.img' -o -name 'system_ext.img' \) 2>/dev/null | head -n 8)"
    if [ -n "$img" ]; then
        while IFS= read -r one; do
            [ -n "$one" ] || continue
            warnings+=("$one is a raw image — unpack it first (lpunpack), then point --firmware at the extracted tree")
        done <<<"$img"
        notes+=("lpunpack usage: lpunpack super.img out/ && sudo mount -o loop,ro out/product.img /mnt")
    fi
    if [ "$count" -eq 0 ]; then
        warn "no APK found under $fwdir"
    else
        notes+=("scanned $count APK(s); pass --all-apks to look inside every APK")
    fi

    # Say which question was asked and unanswered, instead of leaving the reader
    # with an empty table. On a phone whose geometry only the running vendor
    # client knows, the connected-phone mode is the answer.
    if [ "${#c_x[@]}" -eq 0 ]; then
        note "no overlay in this ROM maps config_udfps_sensor_props and no FOD rectangle property was found; if the phone has the sensor, Read from the connected phone"
    fi
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
    local chosen idx="${1:-}" i first=1
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
    printf '"candidates":['
    for i in "${!c_x[@]}"; do
        [ "$first" -eq 1 ] || printf ','
        first=0
        printf '{"kind":"%s","source":"%s","label":"%s","x":%s,"y":%s,"radius":%s,"confidence":"%s","score":%s,"detail":"%s"}' \
            "$(json_escape "${c_kind[$i]}")" "$(json_escape "${c_source[$i]}")" \
            "$(json_escape "${c_label[$i]}")" "${c_x[$i]}" "${c_y[$i]}" "${c_r[$i]}" \
            "${c_conf[$i]}" "${c_score[$i]}" "$(json_escape "${c_detail[$i]}")"
    done
    printf '],'
    if [ -n "$idx" ]; then
        printf '"chosen":{"kind":"%s","source":"%s","x":%s,"y":%s,"radius":%s,"confidence":"%s"},' \
            "${c_kind[$idx]}" "$(json_escape "${c_source[$idx]}")" \
            "${c_x[$idx]}" "${c_y[$idx]}" "${c_r[$idx]}" "${c_conf[$idx]}"
    else
        printf '"chosen":null,'
    fi
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
    local idx="$1" i
    printf '\n'
    if [ "$mode" = "device" ]; then
        printf 'Device   %s (%s)  %sx%s @%s dpi\n' \
            "${MODEL:-unknown}" "${CODENAME:-unknown}" "${W:-?}" "${H:-?}" "${DENS:-?}"
        printf 'ROM      %s\n' "${rom:-unknown}"
    else
        printf 'Firmware %s\n' "$fwdir"
    fi
    printf '\n'

    if [ "${#c_x[@]}" -eq 0 ]; then
        printf 'No UDFPS geometry found.\n'
        for i in "${warnings[@]+"${warnings[@]}"}"; do printf '  ! %s\n' "$i"; done
        return
    fi

    printf '%-6s  %-36s %6s %6s %6s  %s\n' "CONF" "SOURCE" "X" "Y" "RADIUS" "DETAIL"
    for i in "${!c_x[@]}"; do
        printf '%-6s  %-36s %6s %6s %6s  %s\n' \
            "${c_conf[$i]}" "${c_source[$i]}" "${c_x[$i]}" "${c_y[$i]}" "${c_r[$i]}" "${c_detail[$i]}"
    done

    if [ -n "$idx" ]; then
        printf '\nChosen: %s, %s, r=%s  (%s, %s)\n' \
            "${c_x[$idx]}" "${c_y[$idx]}" "${c_r[$idx]}" "${c_conf[$idx]}" "${c_source[$idx]}"
        # Disagreement is the interesting case: it usually means one source is a
        # leftover from another device, and the user should see both numbers.
        for i in "${!c_x[@]}"; do
            [ "$i" = "$idx" ] && continue
            if [ "${c_x[$i]}" -ne "${c_x[$idx]}" ] || [ "${c_y[$i]}" -ne "${c_y[$idx]}" ]; then
                printf '  differs: %s says %s, %s\n' "${c_source[$i]}" "${c_x[$i]}" "${c_y[$i]}"
            fi
        done
        printf '\nconfig.env:\n'
        printf '  HAS_UDFPS=true\n  UDFPS_X=%s\n  UDFPS_Y=%s\n  UDFPS_RADIUS=%s\n' \
            "${c_x[$idx]}" "${c_y[$idx]}" "${c_r[$idx]}"
    fi

    if [ "${#files[@]}" -gt 0 ]; then
        printf '\nRead from:\n'
        for i in "${files[@]}"; do printf '  %s\n' "${i%%|*}"; done
    fi
    for i in "${notes[@]+"${notes[@]}"}"; do printf '\nnote: %s\n' "$i"; done
    for i in "${warnings[@]+"${warnings[@]}"}"; do printf 'warning: %s\n' "$i"; done
}

# ---------------------------------------------------------------------------
# Writing config.env
# ---------------------------------------------------------------------------
# Only the four lines are touched, and a commented-out one is switched back on:
# copying the block out of the file by hand is exactly where "UDFPS_X is set but
# HAS_UDFPS=false" comes from.
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
    local idx="$1"
    set_config_key HAS_UDFPS true
    set_config_key UDFPS_X "${c_x[$idx]}"
    set_config_key UDFPS_Y "${c_y[$idx]}"
    set_config_key UDFPS_RADIUS "${c_r[$idx]}"
}

# ---------------------------------------------------------------------------
main() {
    files=()
    if [ "$mode" = "firmware" ]; then probe_firmware; else probe_device; fi
    local idx
    idx="$(chosen_index)"
    if [ "$want_write" -eq 1 ]; then
        if [ -z "$idx" ]; then
            die "nothing to write — no usable geometry found"
        fi
        # An estimate is not good enough to write behind the user's back: it is
        # the one answer that is not evidence.
        if [ "${c_kind[$idx]}" = "estimate" ]; then
            die "only an estimate was found — set the values by hand from --help"
        fi
        write_config "$idx"
    fi
    if [ "$want_json" -eq 1 ]; then emit_json "$idx"; else emit_human "$idx"; fi
}

main "$@"
