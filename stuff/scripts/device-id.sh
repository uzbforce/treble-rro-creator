#!/usr/bin/env bash
# =============================================================================
# device-id.sh — what is this phone, as config.env spells it
# =============================================================================
# DEVICE_MANUFACTURER, DEVICE_MODEL and DEVICE_CODENAME end up in the overlay
# package, the module name and the launcher icon, so a wrong one is not a build
# error — it is an overlay for a phone that does not exist. This asks the phone
# (or saved `getprop` output) and shows every property that answered, which
# partition it came from, and why the winner won.
#
#   bash stuff/scripts/device-id.sh                 # connected device, then ask
#   bash stuff/scripts/device-id.sh --write         # take the answer it trusts
#   bash stuff/scripts/device-id.sh --json          # for scripts
#
#   --device SERIAL   with more than one phone attached
#   --device local    read this phone directly (Termux, needs root)
#   --adb PATH        adb is looked up on PATH and in stuff/tools/platform-tools
#   --values FILE     rank saved `getprop` output instead of asking a phone
#
# The codename rule is the same one the submission needs: a codename lives on
# /vendor, /odm or /bootimage, holds a lower-case name that is not the brand,
# the manufacturer, a build name or an SoC vendor, and survives a GSI. The
# ranking here and gui/matchprop.go answer the same question; change one, change
# the other.
# =============================================================================

set -uo pipefail

export MSYS_NO_PATHCONV=1

ROOT="${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
. "$ROOT/stuff/scripts/config-edit.sh"
# The report is drawn with the shared UI layer, so it folds onto a phone the same
# way the menu does.
UI_LIB="$ROOT/stuff/scripts/ui.sh"
[ -f "$UI_LIB" ] || { printf 'device-id: stuff/scripts/ui.sh is missing\n' >&2; exit 1; }
. "$UI_LIB"

adb="${ADB:-}"
serial=""
want_json=0
want_write=0
values_file=""

usage() {
    sed -n '3,19p' "$0" | sed 's/^# \{0,1\}//'
}

die() { printf 'device-id: %s\n' "$1" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --device) serial="${2:-}"; shift 2 ;;
        --adb) adb="${2:-}"; shift 2 ;;
        --values) values_file="${2:-}"; shift 2 ;;
        --json) want_json=1; shift ;;
        --write|-y|--yes) want_write=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown option: $1 (try --help)" ;;
    esac
done

tmpdir="$(mktemp -d 2>/dev/null || mktemp -d -t device-id)"
cleanup() { rm -rf "$tmpdir"; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

# `getprop` prints `[key]: [value]`; a warning mixed into the stream is skipped
# rather than parsed into a device called "error". Reads stdin when no file is
# named, because the device path feeds it from a pipe.
parse_props() {
    awk '
        {
            sub(/\r$/, "")
            if ($0 !~ /^\[.*\]: \[.*\]$/) next
            i = index($0, "]: [")
            if (i <= 2) next
            printf "%s\t%s\n", substr($0, 2, i - 2), substr($0, i + 4, length($0) - i - 4)
        }
    ' "${1:--}"
}

prop_of() {
    [ -f "$1" ] || return 0
    awk -F'\t' -v k="$2" '$1 == k { print $2; exit }' "$1"
}

# adb is located by resolve_adb in stuff/scripts/adb-device.sh, which
# collect_from_device sources below: one definition, honouring --adb, for every
# probe.

collect_from_device() {
    . "$ROOT/stuff/scripts/adb-device.sh"
    # adb, or this phone read natively in Termux (device_connect in adb-device.sh).
    device_connect device-id "$serial" || exit 1
    serial="$DEVICE_SERIAL"
    device_sh getprop | parse_props >"$tmpdir/values"
    [ -s "$tmpdir/values" ] || die "the phone did not answer getprop — is it connected and authorized?"
}

collect_from_files() {
    [ -f "$values_file" ] || die "--values: no such file: $values_file"
    parse_props "$values_file" >"$tmpdir/values"
    [ -s "$tmpdir/values" ] || die "--values: nothing that looks like getprop output in $values_file"
}

values="$tmpdir/values"

# Partition order: the OEM's own naming first, the ROM's last. A GSI replaces
# /system and /product, so a codename read from there is the GSI's, not the
# phone's.
CODENAME_PROPS='ro.product.vendor.device ro.product.odm.device ro.product.bootimage.device ro.product.device ro.product.product.device ro.product.system.device ro.product.system_ext.device ro.build.product'
MANUFACTURER_PROPS='ro.product.vendor.manufacturer ro.product.odm.manufacturer ro.product.bootimage.manufacturer ro.product.manufacturer ro.product.product.manufacturer ro.product.system.manufacturer'
MODEL_PROPS='ro.product.vendor.model ro.product.odm.model ro.product.bootimage.model ro.product.model ro.product.product.model ro.product.system.model'    # The second segment is the partition: ro.product.<zone>.<field>. Plain
    # ro.product.device and ro.build.product are the /system ones, which is why
    # a wildcard on *.product.* would be wrong — it also matches them.
    zone_of() {
        case "$1" in
            ro.product.vendor.*) echo vendor ;;
            ro.product.odm.*) echo odm ;;
            ro.product.bootimage.*) echo bootimage ;;
            ro.product.product.*) echo product ;;
            ro.product.system_ext.*) echo system_ext ;;
            ro.product.system.*) echo system ;;
            ro.product.device|ro.build.product) echo system ;;
            *) echo system ;;
        esac
    }

zone_score() {
    case "$1" in
        vendor) echo 40 ;;
        odm|bootimage) echo 35 ;;
        product) echo 25 ;;
        system) echo 22 ;;
        system_ext) echo 18 ;;
        build) echo 10 ;;
        *) echo 0 ;;
    esac
}

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# Values that name a build, a vendor or a family rather than one phone.
generic_reason() {
    case "$(lower "$1")" in
        ''|unknown|generic|generic_x86|generic_arm64|generic_x86_64) echo "not a device name" ;;
        aosp|aosp_arm64|aosp_x86_64) echo "an AOSP build name, not a device" ;;
        mainline|treble|phh_treble) echo "the GSI's own build name, present on every phone running it" ;;
        mivendor) echo "Xiaomi's vendor build name — shared by many devices" ;;
        qcom|mediatek|mtk|exynos|unisoc|sprd|qualcomm) echo "a SoC vendor, shared by every phone with that chip" ;;
        emulator|goldfish|ranchu) echo "an emulator, not a phone" ;;
        *) return 1 ;;
    esac
    return 0
}

is_codename_shape() { [[ "${1:-}" =~ ^[a-z][a-z0-9_]{1,23}$ ]]; }

# ---------------------------------------------------------------------------
# What the phone says
# ---------------------------------------------------------------------------
# A function, not top-level code: the dump does not exist until a phone (or
# --values) has answered, and main collects before it reads.
detect() {
    first_of() { # <props...> -> `value<TAB>prop`, empty when nothing answered
        local name v
        for name in $1; do
            v="$(prop_of "$values" "$name")"
            [ -n "$v" ] || continue
            printf '%s\t%s' "$v" "$name"
            return 0
        done
    }

    manufacturer=""
    manufacturer_prop=""
    model=""
    model_prop=""

    row="$(first_of "$MANUFACTURER_PROPS")"
    if [ -n "$row" ]; then
        manufacturer="${row%%$'\t'*}"
        manufacturer_prop="${row#*$'\t'}"
    fi
    row="$(first_of "$MODEL_PROPS")"
    if [ -n "$row" ]; then
        model="${row%%$'\t'*}"
        model_prop="${row#*$'\t'}"
    fi

    brand="$(lower "$(prop_of "$values" ro.product.brand)")"
    manufacturer_lc="$(lower "$manufacturer")"

    # ---------------------------------------------------------------------------
    # Codename candidates
    # ---------------------------------------------------------------------------
    c_prop=(); c_val=(); c_zone=(); c_score=(); c_why=(); c_risk=()
    r_prop=(); r_val=(); r_reason=()

    for name in $CODENAME_PROPS; do
        v="$(prop_of "$values" "$name")"
        [ -n "$v" ] || continue
        zone="$(zone_of "$name")"
        label="$(lower "$v")"

        if reason="$(generic_reason "$v")"; then
            r_prop+=("$name"); r_val+=("$v"); r_reason+=("$reason")
            continue
        fi
        if [ "$label" = "$brand" ]; then
            r_prop+=("$name"); r_val+=("$v")
            r_reason+=("the brand, not the device — it would match every phone of this make")
            continue
        fi
        if [ "$label" = "$manufacturer_lc" ]; then
            r_prop+=("$name"); r_val+=("$v")
            r_reason+=("the manufacturer, not the device")
            continue
        fi
        if ! is_codename_shape "$v"; then
            r_prop+=("$name"); r_val+=("$v")
            r_reason+=("not a codename shape (lower-case letters, digits, underscore)")
            continue
        fi

        score="$(zone_score "$zone")"
        case "$zone" in
            vendor|odm|bootimage) why="lives on /$zone, which a GSI leaves alone" ;;
            *) why="read from /$zone, which a GSI replaces — the codename becomes the GSI's" ;;
        esac
        c_prop+=("$name"); c_val+=("$v"); c_zone+=("$zone"); c_score+=("$score")
        c_why+=("$why"); c_risk+=("")
    done

    # Best first, then by property name so the output is stable.
    order="$(
        for i in "${!c_prop[@]}"; do
            printf '%d\t%03d\t%s\n' "${c_score[$i]}" "$i" "${c_prop[$i]}"
        done | LC_ALL=C sort -t$'\t' -k1,1nr -k3,3 | cut -f2
    )"
    sorted=()
    while IFS= read -r i; do
        [ -n "$i" ] && sorted+=("$i")
    done <<<"$order"

    codename=""
    codename_prop=""
    confidence="low"
    if [ "${#sorted[@]}" -gt 0 ]; then
        top="${sorted[0]}"
        codename="${c_val[$top]}"
        codename_prop="${c_prop[$top]}"
        case "${c_zone[$top]}" in
            vendor|odm|bootimage) confidence="high" ;;
            *) confidence="medium" ;;
        esac
    fi

    module_prop=""
    [ -n "$codename" ] && module_prop="persist.sys.overlay.$(lower "$codename")"
}

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------
json_escape() { printf '%s' "$1" | tr -d '\000-\037' | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }

emit_json() {
    local i sep
    printf '{"serial":"%s","manufacturer":"%s","manufacturerProp":"%s","model":"%s","modelProp":"%s","codename":"%s","codenameProp":"%s","moduleProp":"%s","confidence":"%s","candidates":[' \
        "$(json_escape "$serial")" "$(json_escape "$manufacturer")" "$(json_escape "$manufacturer_prop")" \
        "$(json_escape "$model")" "$(json_escape "$model_prop")" \
        "$(json_escape "$codename")" "$(json_escape "$codename_prop")" \
        "$(json_escape "$module_prop")" "$confidence"
    sep=""
    for i in "${sorted[@]}"; do
        printf '%s{"prop":"%s","value":"%s","zone":"%s","score":%d,"why":"%s"}' \
            "$sep" "$(json_escape "${c_prop[$i]}")" "$(json_escape "${c_val[$i]}")" \
            "${c_zone[$i]}" "${c_score[$i]}" "$(json_escape "${c_why[$i]}")"
        sep=","
    done
    printf '],"rejected":['
    sep=""
    for i in "${!r_prop[@]}"; do
        printf '%s{"prop":"%s","value":"%s","reason":"%s"}' \
            "$sep" "$(json_escape "${r_prop[$i]}")" "$(json_escape "${r_val[$i]}")" \
            "$(json_escape "${r_reason[$i]}")"
        sep=","
    done
    printf ']}\n'
}

# did_candidate NUM PROP VALUE ZONE SCORE WHY DETAIL — one ranked property.
#
# Same shape as the match-property report: the score is the thing being compared
# down the page, so it keeps its meter and its own line; the property follows.
# WHY is printed only for the ones that could still win (DETAIL=1).
did_candidate() {
    local num="$1" prop="$2" value="$3" zone="$4" score="$5" why="$6" detail="$7"
    local line w
    w=$(ui_cols)
    printf '\n  %s%2d%s  %s %s%3d%s\n' "$UI_BOLD" "$num" "$UI_OFF" \
        "$(ui_meter "$score" 120 10)" "$UI_BOLD" "$score" "$UI_OFF"
    line="$prop = $value"
    if [ $(( ${#line} + 4 )) -le "$w" ]; then
        printf '    %s%s%s = %s\n' "$UI_BOLD" "$prop" "$UI_OFF" "$value"
    else
        printf '    %s%s%s\n' "$UI_BOLD" "$prop" "$UI_OFF"
        ui_wrap "$value" 6 | while IFS= read -r line; do
            printf '      %s\n' "$line"
        done
    fi
    printf '    %s%s%s\n' "$UI_DIM" "$zone" "$UI_OFF"
    [ "$detail" = "1" ] || return 0
    ui_mark note "$why" 6
}

emit_human() {
    local i n=0
    ui_title 'Device' 'what the overlay will claim, and which property said so'
    ui_panel 'Identity' \
        "Manufacturer|${manufacturer:-not found}" \
        "Model|${model:-not found}" \
        "Codename|${codename:-not found}"
    ui_heading 'Read from'
    ui_kv Manufacturer "${manufacturer_prop:-not found}" 14
    ui_kv Model "${model_prop:-not found}" 14
    ui_kv Codename "${codename_prop:-not found}" 14
    if [ -n "$module_prop" ]; then
        ui_heading 'Module condition'
        ui_wrap 'The overlay only loads on a phone where this is true.' 2
        ui_kv DEVICE_PROP_NAME "$module_prop" 18
        ui_kv DEVICE_PROP_VALUE true 18
    fi

    # The three that could win keep their explanation; the rest are one compact
    # line each, so a phone that answers twelve properties is still a list you
    # can read down instead of a wall of paragraphs.
    if [ "${#sorted[@]}" -gt 0 ]; then
        ui_heading "Codename candidates (${#sorted[@]})"
        for i in "${sorted[@]}"; do
            n=$((n + 1))
            if [ "$n" -le 3 ]; then
                did_candidate "$n" "${c_prop[$i]}" "${c_val[$i]}" \
                    "${c_zone[$i]}" "${c_score[$i]}" "${c_why[$i]}" 1
            else
                did_candidate "$n" "${c_prop[$i]}" "${c_val[$i]}" \
                    "${c_zone[$i]}" "${c_score[$i]}" "" 0
            fi
        done
    else
        ui_mark warn 'No property on this phone names the device.'
    fi

    if [ "${#r_prop[@]}" -gt 0 ]; then
        ui_heading "Ruled out (${#r_prop[@]})"
        for i in "${!r_prop[@]}"; do
            printf '\n  %s%s%s\n' "$UI_BOLD" "${r_prop[$i]}" "$UI_OFF"
            ui_kv value "${r_val[$i]}" 6
            ui_mark bad "${r_reason[$i]}" 4
        done
        printf '\n'
    fi

    ui_panel 'Verdict' "Confidence|$confidence"
    case "$confidence" in
        high)
            ui_mark ok "$codename_prop reads the codename from the partition a GSI leaves alone." 2
            ;;
        medium)
            ui_mark note 'The codename came from a partition a GSI replaces, so it is right for the ROM on the phone now, not necessarily for the GSI.' 2
            ;;
        *)
            ui_mark bad 'Nothing usable was found — set DEVICE_CODENAME by hand in config.env, or point this at a different phone.' 2
            ;;
    esac
    printf '\n'
}

# ---------------------------------------------------------------------------
# Writing it
# ---------------------------------------------------------------------------
# DEVICE_PROP_NAME is only touched when it is empty or already in the shape this
# writes: a hand-written condition is a decision, not a leftover.
write_device() {
    local current_prop current_value
    cfg_set DEVICE_MANUFACTURER "$manufacturer" || return 1
    cfg_set DEVICE_MODEL "$model" || return 1
    cfg_set DEVICE_CODENAME "$codename" || return 1
    current_prop="$(cfg_get DEVICE_PROP_NAME)"
    current_value="$(cfg_get DEVICE_PROP_VALUE)"
    case "$current_prop" in
        ''|persist.sys.overlay.*|\<*)
            cfg_set DEVICE_PROP_NAME "$module_prop" || return 1
            ;;
        *)
            ui_mark note "Left DEVICE_PROP_NAME alone: it is set to $current_prop, not the default shape."
            ;;
    esac
    [ -n "$current_value" ] || cfg_set DEVICE_PROP_VALUE "true"
    ui_heading 'Written to config.env'
    ui_kv DEVICE_MANUFACTURER "$manufacturer" 21
    ui_kv DEVICE_MODEL "$model" 21
    ui_kv DEVICE_CODENAME "$codename" 21
    printf '\n'
    ui_mark ok 'Build now (./build.sh, or 1 in the menu) to pick it up.'
    printf '\n'
}

main() {
    if [ -n "$values_file" ]; then
        collect_from_files
    else
        collect_from_device
    fi
    detect

    if [ "$want_json" = "1" ]; then
        emit_json
        return 0
    fi
    emit_human

    if [ -z "$codename" ]; then
        return 1
    fi

    if [ "$want_write" = "1" ]; then
        write_device || return 1
        return 0
    fi

    [ -t 0 ] || return 0
    printf '  Write these to config.env? [Y/n] '
    local reply=""
    read -r reply || reply=""
    case "$reply" in
        ''|y|Y|yes|YES) write_device || return 1 ;;
        *) printf '  Left config.env alone.\n\n' ;;
    esac
    return 0
}

main
