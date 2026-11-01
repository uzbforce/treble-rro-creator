#!/usr/bin/env bash
# =============================================================================
# match-prop.sh — which property should the submitted overlay match on?
# =============================================================================
# The overlay repo compares android:requiredSystemPropertyName/Value with plain
# string equality, and getting it wrong is silent: the overlay installs, `cmd
# overlay list` shows it enabled, and nothing changes. This reads the phone and
# ranks every property the submission could use, saying what each one is
# gambling on.
#
#   bash stuff/scripts/match-prop.sh                  # connected device, then ask
#   bash stuff/scripts/match-prop.sh --write          # take the answer it trusts
#   bash stuff/scripts/match-prop.sh --json           # for scripts
#
#   --device SERIAL   with more than one phone attached
#   --device local    read this phone directly (Termux, needs root)
#   --adb PATH        adb is looked up on PATH and in stuff/tools/platform-tools
#   --values FILE --labels FILE   rank saved `getprop` / `getprop -Z` output
#                                 instead of asking a phone (tests, offline)
#
# Two rules decide whether a candidate works, and both are readable without
# root: zygote has to be able to read the property (`getprop -Z` prints the
# SELinux area; build_odm_prop and build_bootimage_prop are the usual traps),
# and the value has to survive what is installed (vendor, odm and bootimage keep
# the OEM value under a GSI; /system, /product and /system_ext do not). When no
# property satisfies both, this says so instead of picking one — a match that
# never holds is invisible.
#
# The same ranking lives in the desktop app (gui/matchprop.go). Change one,
# change the other.
# =============================================================================

set -uo pipefail

# adb is a Windows binary under Git Bash: without this its /system/... arguments
# are rewritten into C:/Program Files/Git/system/... before adb ever sees them.
export MSYS_NO_PATHCONV=1

ROOT="${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
. "$ROOT/stuff/scripts/config-edit.sh"

adb="${ADB:-}"
serial=""
want_json=0
want_write=0
assume_yes=0
values_file=""
labels_file=""

usage() {
    sed -n '3,31p' "$0" | sed 's/^# \{0,1\}//'
}

die() { printf 'match-prop: %s\n' "$1" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --device) serial="${2:-}"; shift 2 ;;
        --adb) adb="${2:-}"; shift 2 ;;
        --values) values_file="${2:-}"; shift 2 ;;
        --labels) labels_file="${2:-}"; shift 2 ;;
        --json) want_json=1; shift ;;
        --write) want_write=1; shift ;;
        -y|--yes) assume_yes=1; want_write=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown option: $1 (try --help)" ;;
    esac
done

tmpdir="$(mktemp -d 2>/dev/null || mktemp -d -t matchprop)"
cleanup() { rm -rf "$tmpdir"; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

# ---------------------------------------------------------------------------
# The two getprop dumps, as `key<TAB>value` files
# ---------------------------------------------------------------------------
# `getprop` prints `[key]: [value]`; some ROMs mix warnings into the same
# stream, and those lines are skipped rather than parsed into nonsense.
#
# An argument is a file to read; no argument reads the pipeline it is in
# (`getprop | parse_props`), which is how the dumps come off a phone. Removing
# the `-` restores the bug this had: `$1` unset under `set -u`, so every device
# run died with "$1: unbound variable" and then blamed the phone's getprop.
parse_props() {
    awk '
        {
            sub(/\r$/, "")
            if ($0 !~ /^\[.*\]: \[.*\]$/) next
            i = index($0, "]: [")
            if (i <= 2) next
            key = substr($0, 2, i - 2)
            val = substr($0, i + 4, length($0) - i - 4)
            printf "%s\t%s\n", key, val
        }
    ' "${1:--}"
}

# prop_of <file> <key> -> the value, empty when absent.
prop_of() {
    [ -f "$1" ] || return 0
    awk -F'\t' -v k="$2" '$1 == k { print $2; exit }' "$1"
}

# adb is located by resolve_adb in stuff/scripts/adb-device.sh, which
# collect_from_device sources below: one definition, honouring --adb, for every
# probe.

# ---------------------------------------------------------------------------
# Reading the phone
# ---------------------------------------------------------------------------
# Multi-device selection is shared with the probes, so every device action asks
# the same question and accepts the same --device value.
collect_from_device() {
    . "$ROOT/stuff/scripts/adb-device.sh"
    # adb, or this phone read natively in Termux (device_connect in adb-device.sh).
    device_connect "match-prop" "$serial" || exit 1
    serial="$DEVICE_SERIAL"

    device_sh getprop | parse_props >"$tmpdir/values"
    [ -s "$tmpdir/values" ] || die "the phone did not answer getprop — is it connected and authorized?"
    # The areas are the second-best signal, never required: `getprop -Z` is
    # missing on old Android, and without it the ranking still works.
    device_sh 'getprop -Z' | parse_props >"$tmpdir/labels"
    : >"$tmpdir/labels.ok"
}

collect_from_files() {
    [ -f "$values_file" ] || die "--values: no such file: $values_file"
    parse_props "$values_file" >"$tmpdir/values"
    [ -s "$tmpdir/values" ] || die "--values: nothing that looks like getprop output in $values_file"
    if [ -n "$labels_file" ]; then
        [ -f "$labels_file" ] || die "--labels: no such file: $labels_file"
        parse_props "$labels_file" >"$tmpdir/labels"
        : >"$tmpdir/labels.ok"
    fi
}

# ---------------------------------------------------------------------------
# The rules
# ---------------------------------------------------------------------------
# prop|zone|kind — zone is which partition the value comes from (that is what
# decides GSI survival) and kind is what the property holds.
CANDIDATES='ro.product.vendor.device|vendor|device
ro.product.odm.device|odm|device
ro.product.bootimage.device|bootimage|device
ro.product.device|system|device
ro.product.product.device|product|device
ro.product.system.device|system|device
ro.product.system_ext.device|system_ext|device
ro.build.product|build|device
ro.product.vendor.name|vendor|name
ro.product.odm.name|odm|name
ro.product.bootimage.name|bootimage|name
ro.product.name|product|name
ro.product.vendor.model|vendor|model
ro.product.model|product|model'

# Where the codename is looked for, in partition order: vendor, odm and
# bootimage are the OEM's own naming and what a GSI leaves alone; /system and
# /product hold the ROM's name (on a GSI, the GSI itself).
CODENAME_ORDER='ro.product.vendor.device ro.product.odm.device ro.product.bootimage.device ro.product.device ro.product.system.device ro.product.product.device ro.product.system_ext.device ro.build.product'

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

kind_score() {
    case "$1" in
        device) echo 25 ;;
        model) echo 15 ;;
        name) echo 12 ;;
        *) echo 0 ;;
    esac
}

# What the SELinux area means for zygote reading it. The negative numbers are
# the documented traps, not guesses: build_odm_prop and build_bootimage_prop are
# refused to zygote on most GSI builds, so a condition on them never holds.
label_score() {
    case "$1" in
        build_prop|build_vendor_prop) echo 30 ;;
        vendor_default_prop) echo 25 ;;
        default_prop) echo 15 ;;
        build_system_prop|bootloader_prop) echo -20 ;;
        build_odm_prop|build_bootimage_prop) echo -35 ;;
        *) echo 0 ;;
    esac
}

readable_by_zygote() {
    case "$1" in
        build_prop|build_vendor_prop|vendor_default_prop|default_prop) return 0 ;;
    esac
    return 1
}

survives_gsi() {
    case "$1" in
        vendor|odm|bootimage) return 0 ;;
    esac
    return 1
}

# u:object_r:build_vendor_prop:s0 -> build_vendor_prop
short_label() {
    printf '%s' "$1" | awk -F: 'NF >= 3 { print $3; exit }'
}

# Values that name a build rather than a device. These are why a "looks like a
# codename" filter is not enough: mivendor is a Xiaomi vendor tree shared by a
# whole family, generic is the GSI itself.
generic_reason() {
    case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
        generic|generic_x86|generic_arm64|generic_x86_64) echo "the AOSP/GSI build name, shared by every generic image" ;;
        aosp|aosp_arm64) echo "an AOSP build name, not a device" ;;
        mainline) echo "the mainline/module build name, not a device" ;;
        treble) echo "the Treble build name, not a device" ;;
        phh_treble) echo "the GSI's own name — present on every device running that GSI" ;;
        mivendor) echo "Xiaomi's vendor build name — shared by many Xiaomi devices, not a codename" ;;
        emulator) echo "an emulator, not a phone" ;;
        unknown) echo "no value" ;;
        qcom) echo "a SoC vendor, shared by every Qualcomm device" ;;
        mediatek|mtk) echo "a SoC vendor, shared by every MediaTek device" ;;
        exynos) echo "a SoC vendor, shared by every Exynos device" ;;
        android) echo "not a device name" ;;
        '') echo "no value" ;;
        *) return 1 ;;
    esac
    return 0
}

is_codename_shape() {
    [[ "${1:-}" =~ ^[a-z][a-z0-9_]{1,23}$ ]]
}

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# ---------------------------------------------------------------------------
# Ranking
# ---------------------------------------------------------------------------
# A function, not top-level code: the dumps it reads do not exist until a phone
# (or --values) has answered, and main collects before it ranks.
rank() {
    values="$tmpdir/values"
    labels="$tmpdir/labels"
    manuf="$(prop_of "$values" ro.product.manufacturer)"
    brand="$(lower "$(prop_of "$values" ro.product.brand)")"
    manuf_lc="$(lower "$manuf")"
    model="$(prop_of "$values" ro.product.model)"
    codename=""
    codename_prop=""
    for name in $CODENAME_ORDER; do
        v="$(prop_of "$values" "$name")"
        [ -n "$v" ] || continue
        generic_reason "$v" >/dev/null && continue
        is_codename_shape "$v" || continue
        [ "$v" = "$brand" ] && continue
        [ "$v" = "$manuf_lc" ] && continue
        codename="$v"
        codename_prop="$name"
        break
    done

    c_prop=(); c_val=(); c_score=(); c_zone=(); c_label=(); c_why=(); c_risk=(); c_trust=(); c_perfect=()
    r_prop=(); r_val=(); r_reason=()

    while IFS='|' read -r name zone kind; do
        [ -n "$name" ] || continue
        v="$(prop_of "$values" "$name")"
        [ -n "$v" ] || continue
        label="$(short_label "$(prop_of "$labels" "$name")")"

        if reason="$(generic_reason "$v")"; then
            r_prop+=("$name"); r_val+=("$v"); r_reason+=("$reason")
            continue
        fi
        if [ -n "$brand" ] && [ "$v" = "$brand" ]; then
            r_prop+=("$name"); r_val+=("$v")
            r_reason+=("the brand, not the device — it would match every phone of this make")
            continue
        fi

        score=$(( $(zone_score "$zone") + $(kind_score "$kind") + $(label_score "$label") ))
        why=""; risk=""
        case "$zone" in
            vendor|odm|bootimage) why="lives on /$zone, which a GSI leaves alone" ;;
            *) why="read from the installed /$zone partition"
               risk="a GSI replaces /$zone, so the value changes and the match stops" ;;
        esac
        case "$label" in
            build_prop|build_vendor_prop|vendor_default_prop|default_prop)
                why="$why · zygote can read $label" ;;
            '')
                risk="${risk:+$risk · }this ROM did not report its SELinux area, so readability is unchecked" ;;
            *)
                risk="${risk:+$risk · }$label is often denied to zygote — the overlay can show as enabled and do nothing" ;;
        esac
        if [ -n "$codename" ] && [ "$v" = "$codename" ]; then
            score=$((score + 30)); why="$why · holds the codename"
            [ "$name" = "$codename_prop" ] && score=$((score + 10))
        elif [ -n "$codename" ] && [[ "$v" == *"$codename"* ]]; then
            score=$((score + 10)); why="$why · contains the codename"
        else
            # The missi case: a property that names this build, not this phone, so
            # matching on it would claim a different device.
            score=$((score - 20))
            if [ "$kind" = "device" ]; then
                risk="${risk:+$risk · }holds a different name ($v) than this phone's codename (${codename:-unknown})"
            else
                risk="${risk:+$risk · }does not hold the codename, so it names this variant rather than the device"
            fi
        fi
        if is_codename_shape "$v"; then
            score=$((score + 10))
        else
            score=$((score - 5))
            case "$v" in *' '*) risk="${risk:+$risk · }contains a space — exact matching works, but it is easy to break while editing" ;; esac
        fi
        case "$(lower "$v")" in *global*) score=$((score - 10)); risk="${risk:+$risk · }has a region suffix, so another region's build would not match" ;; esac
        if [ "$zone" = "system" ] && [ "$kind" = "device" ] && [ "$v" = "$codename" ] && [ "$label" = "build_prop" ]; then
            # The normal, good answer on a stock ROM: say so instead of making the
            # /system risk read as a deal-breaker.
            risk="if a GSI is installed later this property becomes the GSI's name"
        fi

        perfect=0
        if [ -n "$codename" ] && [ "$v" = "$codename" ] && [ "$kind" = "device" ] \
            && readable_by_zygote "$label" && survives_gsi "$zone"; then
            perfect=1
        fi
        trust="low"
        if [ "$perfect" = "1" ]; then trust="high"
        elif [ -n "$codename" ] && [ "$v" = "$codename" ]; then trust="medium"
        fi

        c_prop+=("$name"); c_val+=("$v"); c_score+=("$score"); c_zone+=("$zone")
        c_label+=("$label"); c_why+=("$why"); c_risk+=("$risk"); c_trust+=("$trust")
        c_perfect+=("$perfect")
    done <<<"$CANDIDATES"

    # Best first: score, then the row that actually carries the codename, then name.
    order="$(
        for i in "${!c_prop[@]}"; do
            carry=1
            if [ -n "$codename" ] && [ "${c_val[$i]}" = "$codename" ]; then carry=0; fi
            printf '%d\t%d\t%03d\t%s\n' "${c_score[$i]}" "$carry" "$i" "${c_prop[$i]}"
        done | LC_ALL=C sort -t$'\t' -k1,1nr -k2,2n -k3,3n | cut -f4
    )"
    sorted=()
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        for i in "${!c_prop[@]}"; do
            [ "${c_prop[$i]}" = "$name" ] && { sorted+=("$i"); break; }
        done
    done <<<"$order"

    # Confidence is about the answer, not the ranking: "high" is reserved for a
    # property that satisfies every rule at once. Anything less and the honest
    # advice is to keep the match that already works, because a submitted condition
    # that does not hold is invisible.
    confidence="low"
    if [ "${#sorted[@]}" -gt 0 ]; then
        top="${sorted[0]}"
        if [ "${c_perfect[$top]}" = "1" ]; then
            confidence="high"
        elif [ -n "$codename" ] && [ "${c_val[$top]}" = "$codename" ]; then
            confidence="medium"
        fi
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
    printf '{"serial":"%s","model":"%s","codename":"%s","confidence":"%s","moduleProp":"%s","candidates":[' \
        "$(json_escape "$serial")" "$(json_escape "$model")" "$(json_escape "$codename")" \
        "$confidence" "$(json_escape "$module_prop")"
    sep=""
    for i in "${sorted[@]}"; do
        printf '%s{"prop":"%s","value":"%s","score":%d,"zone":"%s","label":"%s","trust":"%s","perfect":%s,"why":"%s","risk":"%s"}' \
            "$sep" "$(json_escape "${c_prop[$i]}")" "$(json_escape "${c_val[$i]}")" "${c_score[$i]}" \
            "${c_zone[$i]}" "${c_label[$i]}" "${c_trust[$i]}" \
            "$([ "${c_perfect[$i]}" = "1" ] && echo true || echo false)" \
            "$(json_escape "${c_why[$i]}")" "$(json_escape "${c_risk[$i]}")"
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

emit_human() {
    local i n=0 saved_prop saved_value
    saved_prop="$(cfg_get HW_OVERLAY_MATCH_PROP)"
    saved_value="$(cfg_get HW_OVERLAY_MATCH_VALUE)"

    printf '\n  Match property — what the submitted overlay requires\n\n'
    printf '  %-12s %s\n' 'Phone' "${model:-unknown}${manuf:+ ($manuf)}"
    if [ -n "$codename" ]; then
        printf '  %-12s %s  (%s)\n' 'Codename' "$codename" "$codename_prop"
    else
        printf '  %-12s %s\n' 'Codename' 'not found — no property carries a device name'
    fi
    [ -n "$module_prop" ] && printf '  %-12s %s  (DEVICE_PROP_NAME)\n' 'Module' "$module_prop"
    if [ -n "$saved_prop" ] || [ -n "$saved_value" ]; then
        printf '  %-12s %s = %s\n' 'Current' "${saved_prop:-ro.product.vendor.device}" "$saved_value"
    fi

    if [ "${#sorted[@]}" -gt 0 ]; then
        printf '\n  Ranked properties\n\n'
        printf '    #  score  %-28s %-18s %-10s %s\n' 'property' 'value' 'zone' 'SELinux area'
        for i in "${sorted[@]}"; do
            n=$((n + 1))
            printf '  %3d %6d  %-28s %-18s %-10s %s\n' \
                "$n" "${c_score[$i]}" "${c_prop[$i]}" "${c_val[$i]}" "${c_zone[$i]}" "${c_label[$i]:-not reported}"
            printf '            · %s\n' "${c_why[$i]}"
            [ -n "${c_risk[$i]}" ] && printf '            ! %s\n' "${c_risk[$i]}"
        done
    else
        printf '\n  No property could be ranked — nothing on this phone names the device.\n'
    fi

    if [ "${#r_prop[@]}" -gt 0 ]; then
        printf '\n  Ruled out\n\n'
        for i in "${!r_prop[@]}"; do
            printf '    %-28s %-18s %s\n' "${r_prop[$i]}" "${r_val[$i]}" "${r_reason[$i]}"
        done
    fi

    printf '\n  Confidence: %s\n' "$confidence"
    case "$confidence" in
        high)
            printf '    %s carries the codename, zygote can read it, and a GSI leaves\n' "${c_prop[${sorted[0]}]}"
            printf '    its partition alone. This is the answer.\n'
            ;;
        medium)
            printf '    The best property holds the codename, but something else about it\n'
            printf '    is a gamble (readability, or a GSI replaces its partition). It works\n'
            printf '    today on this ROM; keeping the match you already have is safer.\n'
            ;;
        *)
            printf '    No property satisfies every rule. Keep the HW_OVERLAY_MATCH_* you\n'
            printf '    already have, or set the pair by hand from config.env.\n'
            ;;
    esac
    printf '\n'
}

# ---------------------------------------------------------------------------
# Writing it into config.env
# ---------------------------------------------------------------------------
write_pair() {
    local prop="$1" value="$2"
    cfg_set HW_OVERLAY_MATCH_PROP "$prop" || { printf 'match-prop: could not write config.env\n' >&2; return 1; }
    cfg_set HW_OVERLAY_MATCH_VALUE "$value" || { printf 'match-prop: could not write config.env\n' >&2; return 1; }
    printf '\n  Written to config.env:\n    HW_OVERLAY_MATCH_PROP="%s"\n    HW_OVERLAY_MATCH_VALUE="%s"\n' "$prop" "$value"
    printf '  Rebuild to pick it up: ./build.sh (or 8 in the menu)\n\n'
    return 0
}

main() {
    if [ -n "$values_file" ]; then
        collect_from_files
    else
        collect_from_device
    fi
    rank

    if [ "$want_json" = "1" ]; then
        emit_json
        # The exit code is part of the answer: a script that reads the JSON must
        # not have to count the candidates to find out there were none.
        [ "${#sorted[@]}" -gt 0 ] && return 0
        return 1
    fi
    emit_human

    if [ "${#sorted[@]}" -eq 0 ]; then
        return 1
    fi

    if [ "$want_write" = "1" ]; then
        # --write takes the trusted answer only. A guess written silently is
        # worse than the pair that is already there.
        if [ "$confidence" != "high" ]; then
            printf '  Not writing: the best candidate is not trusted enough (%s).\n' "$confidence"
            printf '  Pick one by hand with: bash stuff/scripts/match-prop.sh\n\n'
            return 1
        fi
        write_pair "${c_prop[${sorted[0]}]}" "${c_val[${sorted[0]}]}"
        return 0
    fi

    # Interactive: a number writes that row, Enter (or anything else) keeps the
    # pair that is already in config.env.
    [ -t 0 ] || return 0
    printf '  Which one? [1-%d, Enter keeps the current match] ' "${#sorted[@]}"
    local reply=""
    read -r reply || reply=""
    case "$reply" in
        ''|*[!0-9]*) printf '  Left config.env alone.\n\n'; return 0 ;;
    esac
    if [ "$reply" -lt 1 ] || [ "$reply" -gt "${#sorted[@]}" ]; then
        printf '  Not one of them — left config.env alone.\n\n'
        return 0
    fi
    local pick="${sorted[$((reply - 1))]}"
    if [ "${c_perfect[$pick]}" != "1" ]; then
        printf '\n  Note: %s is not the property this tool would trust on its own\n' "${c_prop[$pick]}"
        printf '  (see the warning under it). It only holds while the value stays %s.\n' "${c_val[$pick]}"
    fi
    write_pair "${c_prop[$pick]}" "${c_val[$pick]}"
}

main
