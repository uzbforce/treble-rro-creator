#!/usr/bin/env bash
# =============================================================================
# Overlay-repo submission tree (Doze-off/vendor_hardware_overlay)
# =============================================================================
# Writes what Doze-off/vendor_hardware_overlay expects, from the same resources
# this project compiles into a module. TrebleDroid/vendor_hardware_overlay is
# the upstream it continues; the tree is identical, so a PR there works too.
#
#   <brand>/<model>/AndroidManifest.xml
#   <brand>/<model>/Android.mk
#   <brand>/<model>/res/values/*, res/values-land/*, res/xml/*
#   <brand>/<model>-SystemUI/…            (when src/systemui has resources)
#   _submission/HOW-TO-SUBMIT.md          (steps, checklist, what changed)
#   _submission/overlay.mk.lines          (the PRODUCT_PACKAGES lines to add)
#
# That tree is packed into out/<overlay>-hardware-overlay.zip by build.sh; a
# maintainer merges it into the repo, the GSI builds it, and the device gets the
# values without installing a module.
#
# Differences from the module build, on purpose:
#
#   * The match condition targets a property that exists on a stock device.
#     A module is matched by persist.sys.overlay.<codename>, which this project
#     sets itself at boot — a preinstalled overlay never sees it. So the
#     submission gates on ro.product.vendor.device (exact) by default.
#
#   * Resource names on the repo's blacklist (tests/blacklist) are dropped.
#     Those are user-preference resources the repo refuses to let an overlay
#     force; keeping them fails the repo's own test script.
#
#   * android:requiredSystemPropertyValue is compared with plain string
#     equality (AOSP FrameworkParsingPackageUtils#checkRequiredSystemProperties),
#     so no "*" or "+" globs: the value must be what the device reports.
#
# Sourced by build.sh (common.sh loaded, config.env sourced, identity derived).
# Standalone, with an optional config file (default: ./config.env):
#
#   ./stuff/scripts/hardware-overlay.sh plan [config.env]  what would be written
#   ./stuff/scripts/hardware-overlay.sh write <dir> [config.env] write the tree
# =============================================================================

# Sourced by build.sh, or run directly for the standalone commands below.
if [ "${BASH_SOURCE[0]}" != "$0" ] && [ -z "${ROOT:-}" ]; then
    echo "This is an internal build module — run ./build.sh instead." >&2
    return 1 2>/dev/null || exit 1
fi

# ---------------------------------------------------------------------------
# The overlay repo's rules
# ---------------------------------------------------------------------------
# tests/blacklist of Doze-off/vendor_hardware_overlay (identical to upstream
# TrebleDroid's): resources an overlay may not define (they are user preferences
# or would break the device). A submission that defines one fails tests/tests.sh.
HW_BLACKLIST_ARGS=(
    config_useRoundIcon
    config_swipe_up_gesture_setting_available
    config_cameraDoubleTapPowerGestureEnabled
    config_cellBroadcastAppLinks
    config_doublePressOnPowerBehavior
    config_dozeComponent
    config_enableAutoPowerModes
    config_enableMultiUserUI
    config_mainBuiltInDisplayIsRound
    config_multiuserMaximumUsers
    config_screen_magnification_multi_tap_adjustment
    config_swipe_up_gesture_default
    config_allowAllRotations
    config_volumeAdjustmentForRemoteGroupSessions
    config_unplugTurnsOnScreen
)

hw_blacklist_re() {
    local re="" n
    for n in "${HW_BLACKLIST_ARGS[@]}"; do
        re="${re:+$re|}${n}"
    done
    printf '^(%s)$' "$re"
}

# Priorities already used by static framework overlays in the repo, so the
# submission does not pick one that tests/tests.sh rejects as a duplicate.
hw_priority_file() {
    printf '%s' "${ROOT}/stuff/scripts/data/treble-overlay-priorities.txt"
}

hw_priority_uses() { # <priority> -> how many repo overlays use it
    local file count
    file=$(hw_priority_file)
    [ -f "$file" ] || { printf '0'; return 0; }
    count=$(grep -cx "$1" "$file" 2>/dev/null || true)
    printf '%s' "${count:-0}"
}

# A free priority for the submission. Start at a number derived from the device
# name so two people building different devices rarely pick the same one, then
# probe upwards (1000-2999 stays below the repo's high-priority Misc overlays).
hw_suggest_priority() {
    local file seed p tries=0
    file=$(hw_priority_file)
    seed=$(printf '%s/%s' "${DEVICE_MANUFACTURER:-device}" "${DEVICE_CODENAME:-name}" | cksum 2>/dev/null | awk '{ print $1 }')
    [ -n "$seed" ] || seed=0
    p=$((1000 + (seed % 2000)))
    [ -f "$file" ] || { printf '%s' "$p"; return 0; }
    while [ "$tries" -lt 2000 ]; do
        if ! grep -qx "$p" "$file" 2>/dev/null; then
            printf '%s' "$p"
            return 0
        fi
        p=$((p + 1))
        [ "$p" -gt 2999 ] && p=1000
        tries=$((tries + 1))
    done
    printf '1000'
}

# The property a stock device can match the submission with.
hw_match_prop() {
    if [ -n "${HW_OVERLAY_MATCH_PROP+set}" ]; then
        printf '%s' "${HW_OVERLAY_MATCH_PROP}"
    else
        printf 'ro.product.vendor.device'
    fi
}

# Exact value — no globs, because the framework compares with String.equals().
hw_match_value() {
    if [ -n "${HW_OVERLAY_MATCH_VALUE+set}" ]; then
        printf '%s' "${HW_OVERLAY_MATCH_VALUE}"
    else
        printf '%s' "${DEVICE_CODENAME}"
    fi
}

hw_priority() {
    if [ -n "${HW_OVERLAY_PRIORITY:-}" ]; then
        printf '%s' "$HW_OVERLAY_PRIORITY"
    else
        hw_suggest_priority
    fi
}

# Standalone use has no aapt2 output to look at; decide from the XML.
hw_has_systemui_resources() {
    local dir="${SYSUI_RES_DIR:-src/systemui/res}" f
    [ -d "$dir" ] || return 1
    for f in "$dir"/values*/*.xml; do
        [ -f "$f" ] || continue
        grep -qE '<(bool|dimen|integer|string|array|integer-array|string-array)[[:space:]]+name=' "$f" && return 0
    done
    return 1
}

# ---------------------------------------------------------------------------
# Resource copy — minus what the repo forbids
# ---------------------------------------------------------------------------
# _hw_strip_file <in> <out> <dropped-list>
# Drops a <bool|integer|string|dimen|item> whose name is on the blacklist,
# including values that span several lines, and leaves comments untouched.
_hw_strip_file() {
    local in="$1" out="$2" dropped="$3"
    awk -v re="$(hw_blacklist_re)" -v dropped="$dropped" '
        BEGIN { skip = 0; incomment = 0 }
        {
            line = $0
            sub(/\r$/, "", line)

            if (incomment) {
                if (line ~ /-->/) incomment = 0
                print line
                next
            }
            if (line ~ /<!--/ && line !~ /-->/) {
                incomment = 1
                print line
                next
            }

            if (skip) {
                if (line ~ /<\//) skip = 0
                next
            }

            if (match(line, /name="[^"]+"/)) {
                nm = substr(line, RSTART + 6, RLENGTH - 7)
                if (nm ~ re) {
                    print nm >> dropped
                    # One value per line, or an empty tag: done. Otherwise the
                    # value continues until the closing tag.
                    if (line ~ /\/>[ 	]*$/ || line ~ /<\/[A-Za-z-]+>/) next
                    skip = 1
                    next
                }
            }
            print line
        }
    ' "$in" > "$out"
}

# _hw_copy_resources <src-res-dir> <dst-res-dir> <dropped-list>
_hw_copy_resources() {
    local src="$1" dst="$2" dropped="$3" entry base f
    rm -rf "$dst"
    mkdir -p "$dst"
    for entry in "$src"/*; do
        [ -e "$entry" ] || continue
        base=$(basename "$entry")
        if [ -f "$entry" ]; then
            _hw_strip_file "$entry" "$dst/$base" "$dropped"
            continue
        fi
        case "$base" in
            values*)
                mkdir -p "$dst/$base"
                for f in "$entry"/*.xml; do
                    [ -f "$f" ] || continue
                    _hw_strip_file "$f" "$dst/$base/$(basename "$f")" "$dropped"
                done
                ;;
            xml)
                mkdir -p "$dst/xml"
                for f in "$entry"/*; do
                    [ -f "$f" ] || continue
                    if [ "$(basename "$f")" = "power_profile.xml" ] \
                       && power_profile_is_placeholder "$f"; then
                        continue
                    fi
                    cp "$f" "$dst/xml/"
                done
                ;;
            *)
                cp -R "$entry" "$dst/$base"
                ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# Files the repo expects
# ---------------------------------------------------------------------------
_hw_write_android_mk() { # <dir> <module-name>
    cat > "$1/Android.mk" << ANDROIDMK
LOCAL_PATH := \$(call my-dir)
include \$(CLEAR_VARS)
LOCAL_MODULE_TAGS := optional
LOCAL_PACKAGE_NAME := $2
LOCAL_MODULE_PATH := \$(TARGET_OUT_PRODUCT)/overlay
LOCAL_IS_RUNTIME_RESOURCE_OVERLAY := true
LOCAL_PRIVATE_PLATFORM_APIS := true
include \$(BUILD_PACKAGE)
ANDROIDMK
}

# _hw_write_manifest <file> <package> <target-package> <priority>
_hw_write_manifest() {
    local file="$1" package="$2" target="$3" priority="$4" prop value
    prop=$(hw_match_prop)
    value=$(hw_match_value)

    {
        printf '%s\n' '<?xml version="1.0" encoding="utf-8"?>'
        printf '%s\n' '<manifest xmlns:android="http://schemas.android.com/apk/res/android"'
        printf '    package="%s"\n' "$package"
        printf '    android:versionCode="%s"\n' "${OVERLAY_VERSION_CODE:-1}"
        printf '    android:versionName="%s">\n' "${OVERLAY_VERSION:-1.0}"
        if [ -n "$prop" ] && [ -n "$value" ]; then
            printf '    <overlay android:targetPackage="%s"\n' "$target"
            printf '        android:requiredSystemPropertyName="%s"\n' "$prop"
            printf '        android:requiredSystemPropertyValue="%s"\n' "$value"
            printf '        android:priority="%s"\n' "$priority"
            printf '        android:isStatic="true" />\n'
        else
            printf '    <overlay android:targetPackage="%s"\n' "$target"
            printf '        android:priority="%s"\n' "$priority"
            printf '        android:isStatic="true" />\n'
        fi
        printf '%s\n' '</manifest>'
    } > "$file"
}

# ---------------------------------------------------------------------------
# Submission notes
# ---------------------------------------------------------------------------
_hw_write_notes() { # <outdir> <brand> <model> <dropped-list-file> <modules-file> <folders>
    local out="$1" brand="$2" model="$3" dropped="$4" modules="$5" folders="$6"
    local prop value priority dropped_count dropped_text
    prop=$(hw_match_prop)
    value=$(hw_match_value)
    priority=$(hw_priority)
    mkdir -p "$out/_submission"

    [ -n "$folders" ] || folders="\`${brand}/${model}\`"
    dropped_count=0
    dropped_text=""
    if [ -f "$dropped" ]; then
        dropped_text=$(sort -u "$dropped" | sed 's/^/  - `/; s/$/`/')
        dropped_count=$(sort -u "$dropped" | grep -c . || true)
    fi

    cp "$modules" "$out/_submission/overlay.mk.lines"

    cat > "$out/_submission/HOW-TO-SUBMIT.md" << SUBMITEOF
# Submitting this overlay to Doze-off/vendor_hardware_overlay

This folder is the source tree the overlay repo compiles for
\`${DEVICE_MANUFACTURER} ${DEVICE_CODENAME}\`. Once it is merged, every build of
the GSIs that use the repo includes it — the device gets the values without
installing a module.

Target: <https://github.com/Doze-off/vendor_hardware_overlay>, base branch
\`pie\`. <https://github.com/TrebleDroid/vendor_hardware_overlay> is the upstream
it continues and takes the same tree, but the Doze-off repo is the active one.

## 1. Test it first (no fork needed)

Flash \`${OVERLAY_NAME}-hardware-overlay-test.zip\` from \`out/\`. It installs
exactly the APKs this source tree builds, into \`/system/product/overlay\`, so a
broken value shows up before the pull request. Reboot, then check:

\`\`\`bash
adb shell cmd overlay lookup ${OVERLAY_PACKAGE} android:dimen/rounded_corner_radius
\`\`\`

Nothing changed? Read the match condition below before you edit anything.

## 2. Fork, clone, branch

1. Fork <https://github.com/Doze-off/vendor_hardware_overlay> and clone it.
2. \`git checkout -b pie origin/pie\` — the repo's only active branch is \`pie\`.
3. Copy ${folders} into the clone root, keeping the names.
4. Delete this \`_submission/\` folder — it is notes, not overlay source.

The folder names follow the repo's naming rule: \`Brand/Model\`, brand capitalised
once, model without the brand repeated and without spaces
(\`Xiaomi/RedmiA5\`, \`Infinix/Hot30I-X669C\`, \`Asus/Rog5_5s\`). They come from
\`DEVICE_MANUFACTURER\`/\`DEVICE_CODENAME\`; if yours do not read like that, change
those in \`config.env\`, rebuild, and use the new zip — a PR with a
\`treble-overlay-BRAND-brand-model\` module gets closed as "Wrong format".

## 3. Add the modules to overlay.mk

Insert the lines from \`_submission/overlay.mk.lines\` into the
\`PRODUCT_PACKAGES\` list in \`overlay.mk\`, tab indent included, each line ending
with a backslash. The \`treble-overlay-*\` lines are sorted with \`LC_ALL=C\`
(uppercase before lowercase) and the file keeps an empty line at the end. The
repo's test script checks the order, the trailing backslashes and that every
module is listed.

\`\`\`
$(cat "$modules")
\`\`\`

## 4. Run the repo's tests — nothing runs them for you

\`\`\`bash
sudo apt install xmlstarlet        # once
bash tests/tests.sh
\`\`\`

Fix anything it reports before opening the pull request. It checks the
blacklist, duplicate priorities, resource names against AOSP, the power profile
and \`overlay.mk\`.

The Doze-off fork's Actions tab has no runs (GitHub leaves Actions off on forks),
so this script is the only check before a human reads the PR. One failure is
already in the tree and is not yours: the ordering check reports
\`treble-overlay-moto-malmo\`, which sits after the \`motorola-*\` block. Leave that
line alone and keep your own lines sorted.

If it says a resource does not exist while AOSP has it, its \`tests/knownKeys\`
lacks the entry; the script prints the comment to add in that case.

## 5. Build the APK the way the repo does (optional)

\`\`\`bash
cd build && bash build.sh               # needs aapt and java
cd build && bash build.sh --local-aapt  # uses the aapt bundled in build/
\`\`\`

## 6. Commit, push, open the pull request

\`\`\`bash
git add overlay.mk          # plus the new folders listed by git status --short
git commit -m "overlay: add ${brand}/${model}"
git push -u origin pie
\`\`\`

Open the PR against \`Doze-off/vendor_hardware_overlay\` with base branch
\`pie\`, and state what the merged PRs there state: marketing name, codename, the
getprop values the overlay matches on, what it fixes, and how you verified it
(\`cmd overlay lookup\` printing your value from the test build). Issues are
disabled on the repo, so the PR thread is the only place to discuss it.

---

## The match condition — read this

\`\`\`xml
android:requiredSystemPropertyName="${prop}"
android:requiredSystemPropertyValue="${value}"
\`\`\`

\`android:requiredSystemPropertyValue\` is compared with **plain string
equality** (\`FrameworkParsingPackageUtils#checkRequiredSystemProperties\` in
AOSP), so \`*\` and \`+\` are not wildcards: an overlay carrying
\`+*${brand}/${model}*\` never activates. Many older overlays in the repo still
use that form; they are inert.

Therefore the value above must be **exactly** what the device reports:

\`\`\`bash
adb shell getprop ${prop}
\`\`\`

- If that prints something else, set \`HW_OVERLAY_MATCH_VALUE\` (or
  \`HW_OVERLAY_MATCH_PROP\`) in \`config.env\` and rebuild.
- Prefer \`ro.product.vendor.device\`: it comes from the vendor partition, so it
  survives a GSI flash and does not change between OTA builds. The full
  \`ro.vendor.build.fingerprint\` also works, but breaks on every OTA.
- Set \`HW_OVERLAY_MATCH_PROP=""\` to submit an overlay that is always active.

## Priority

The framework overlay uses \`android:priority="${priority}"\`, which no overlay
in the repo used when this build was made. The repo's \`tests/tests.sh\` rejects a
duplicate and prints a free number when it runs; if it suggests another one,
change \`HW_OVERLAY_PRIORITY\` in \`config.env\` and rebuild.

$(if [ "$dropped_count" -gt 0 ]; then
cat << EOF2
## Resource names that were dropped

The repo's \`tests/blacklist\` forbids these, so the submission leaves them to the
GSI (the module you build yourself still sets them):

$dropped_text

EOF2
fi)

## What is in here

- \`${brand}/${model}/res/\` — framework overlay resources (\`android\`)
- \`${brand}/${model}-SystemUI/res/\` — SystemUI overlay resources, if any
- \`res/xml/power_profile.xml\` is only included once you replace the placeholder
  in \`src/framework/res/xml/\` with your device's profile

Everything is generated: edit \`config.env\` and \`src/\` in ${ROOT##*/}, then run
\`./build.sh\` and use the new zip.
SUBMITEOF
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
write_hardware_overlay() { # <outdir>
    local out="$1"
    local brand model dropped modules prop value priority

    [ -n "$out" ] || { err "write_hardware_overlay needs an output directory"; return 2; }

    brand="${DEVICE_MANUFACTURER}"
    model="${DEVICE_CODENAME}"
    prop=$(hw_match_prop)
    value=$(hw_match_value)
    priority=$(hw_priority)

    # The repo compares exact strings: a glob (or a "±" prefix) can never match
    # and the overlay would silently stay inert.
    case "$value" in
        +*|-*|*\**)
            warn "HW_OVERLAY_MATCH_VALUE=\"${value}\" looks like a glob, but android:requiredSystemPropertyValue is exact-matched."
            warn "  An overlay with a wildcard never activates. Use the literal value: adb shell getprop ${prop}"
            ;;
    esac
    case "$prop" in
        ro.vendor.product.*)
            warn "HW_OVERLAY_MATCH_PROP=\"${prop}\" is deprecated in the overlay repo; ro.product.vendor.device is preferred."
            ;;
    esac
    if [ -n "$prop" ] && [ -n "$value" ]; then
        info "Submission match: ${prop} == \"${value}\" (exact)"
    else
        info "Submission match: none (always active)"
    fi
    local uses
    uses=$(hw_priority_uses "$priority")
    if [ "${uses:-0}" -gt 0 ]; then
        warn "Priority ${priority} is already used by ${uses} overlay(s) in the overlay repo — tests/tests.sh rejects duplicates."
        warn "  Unset HW_OVERLAY_PRIORITY to let the build pick a free one, or take the number tests/tests.sh prints."
    else
        info "Submission priority: ${priority} (free in the repo snapshot)"
    fi

    rm -rf "$out"
    mkdir -p "$out"
    dropped="$out/.dropped"
    modules="$out/.modules"
    : > "$dropped"
    : > "$modules"

    # 1. Framework overlay (targets android)
    HW_FW_DIR="$out/${brand}/${model}"
    mkdir -p "$HW_FW_DIR"
    _hw_copy_resources "$RES_DIR" "$HW_FW_DIR/res" "$dropped"
    _hw_write_android_mk "$HW_FW_DIR" "$OVERLAY_NAME"
    _hw_write_manifest "$HW_FW_DIR/AndroidManifest.xml" \
        "$OVERLAY_PACKAGE" android "$priority"
    printf '\t%s \\\n' "$OVERLAY_NAME" >> "$modules"
    ok "Submission: ${brand}/${model} (${OVERLAY_NAME}, priority ${priority})"

    # 2. SystemUI overlay (targets com.android.systemui), when there is one
    HW_SYSUI_DIR=""
    if [ "${LINKED_SYSTEMUI:-false}" = "true" ] || { [ -z "${LINKED_SYSTEMUI:-}" ] && hw_has_systemui_resources; }; then
        HW_SYSUI_DIR="$out/${brand}/${model}-SystemUI"
        mkdir -p "$HW_SYSUI_DIR"
        _hw_copy_resources "$SYSUI_RES_DIR" "$HW_SYSUI_DIR/res" "$dropped"
        _hw_write_android_mk "$HW_SYSUI_DIR" "${OVERLAY_NAME}-systemui"
        _hw_write_manifest "$HW_SYSUI_DIR/AndroidManifest.xml" \
            "$OVERLAY_PACKAGE_SYSTEMUI" com.android.systemui \
            "${HW_OVERLAY_PRIORITY_SYSTEMUI:-${OVERLAY_PRIORITY_SYSTEMUI:-9999}}"
        printf '\t%s-systemui \\\n' "$OVERLAY_NAME" >> "$modules"
        ok "Submission: ${brand}/${model}-SystemUI (${OVERLAY_NAME}-systemui)"
    fi

    # 3. Notes + overlay.mk lines
    local folders="\`${brand}/${model}\`"
    [ -n "$HW_SYSUI_DIR" ] && folders="${folders} and \`${brand}/${model}-SystemUI\`"
    _hw_write_notes "$out" "$brand" "$model" "$dropped" "$modules" "$folders"

    if [ -s "$dropped" ]; then
        local names
        names=$(sort -u "$dropped" | tr '\n' ' ' | sed 's/ *$//')
        info "Dropped ${names} (the overlay repo blacklists these; the module still sets them)"
    fi
    rm -f "$dropped" "$modules"
    return 0
}

print_hardware_overlay_plan() {
    printf '\n  %bSubmission tree (Doze-off/vendor_hardware_overlay, branch pie)%b\n' "${BOLD:-}" "${NC:-}"
    printf '    %-34s %s\n' "$DEVICE_MANUFACTURER/$DEVICE_CODENAME" "$OVERLAY_NAME (android)"
    if [ "${LINKED_SYSTEMUI:-false}" = "true" ] || { [ -z "${LINKED_SYSTEMUI:-}" ] && hw_has_systemui_resources; }; then
        printf '    %-34s %s\n' "$DEVICE_MANUFACTURER/$DEVICE_CODENAME-SystemUI" "${OVERLAY_NAME}-systemui (com.android.systemui)"
    fi
    printf '    match:    %s == "%s"\n' "$(hw_match_prop)" "$(hw_match_value)"
    printf '    priority: %s\n' "$(hw_priority)"
    printf '\n'
}

# ---------------------------------------------------------------------------
# Standalone use: ./stuff/scripts/hardware-overlay.sh plan  (or "write <dir>")
# ---------------------------------------------------------------------------
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    set -e
    ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
    export ROOT
    cd "$ROOT"
    source "$ROOT/stuff/scripts/common.sh"
    case "${1:-plan}" in
        plan|write)
            ;;
        *)
            echo "usage: $0 [plan|write <dir>] [config.env]" >&2
            exit 2
            ;;
    esac
    if [ "$1" = "write" ]; then
        [ -n "${2:-}" ] || { echo "usage: $0 write <dir> [config.env]" >&2; exit 2; }
        CONF="${3:-$ROOT/config.env}"
    else
        CONF="${2:-$ROOT/config.env}"
    fi
    if [ -f "$CONF" ]; then
        # shellcheck source=/dev/null
        source "$CONF"
    else
        echo "No config file at $CONF" >&2
        exit 2
    fi
    derive_overlay_identity
    RES_DIR="${RES_DIR:-src/framework/res}"
    SYSUI_RES_DIR="${SYSUI_RES_DIR:-src/systemui/res}"
    if [ "$1" = "plan" ]; then
        print_hardware_overlay_plan
    else
        write_hardware_overlay "$2"
    fi
fi
