#!/usr/bin/env bash
# =============================================================================
# wrap.sh — turn overlay APKs you already have into a flashable test module
# =============================================================================
# For an overlay that was built somewhere else — a repo zip, a friend's build,
# an APK you signed by hand — this compiles nothing. It puts the APK(s) in the
# module's system/product/overlay and zips them with the module files every
# root manager expects. One APK (a framework overlay) or two (framework +
# SystemUI) are both fine.
#
#   ./build.sh wrap --overlay path/to/overlay.apk
#   ./build.sh wrap --overlay overlay.apk --systemui overlay-systemui.apk
#   ./build.sh wrap --overlay overlay.apk --name my-test -y
#
#   Standalone: bash stuff/scripts/wrap.sh --overlay ... [the same options]
#
# Options
#   --overlay PATH     the overlay APK (required)
#   --systemui PATH    a second, SystemUI overlay APK (optional)
#   --name ID          module id; default wrap-<apk file name>
#   -y, --yes          no questions, do not offer to install
#   -h, --help         this help
#
# Output: out/wrap/<module-id>.zip — its own folder, so a test module never
# sits next to the release zips looking like one.
# =============================================================================

set -uo pipefail

ROOT="${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
. "$ROOT/stuff/scripts/common.sh"
# aapt2 lives in stuff/tools/ on a machine that has built once; it is used here
# only to read the APK's own package name, never to compile anything.
tools_on_path

overlay=""
systemui=""
want_name=""
assume_yes="${ASSUME_YES:-false}"

usage() { sed -n '3,25p' "$0" | sed 's/^# \{0,1\}//'; }
die() { err "$1"; return 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --overlay|--apk|--framework) overlay="${2:-}"; shift 2 ;;
        --systemui|--system-ui)      systemui="${2:-}"; shift 2 ;;
        --name|--id)                 want_name="${2:-}"; shift 2 ;;
        -y|--yes)                    assume_yes=true; shift ;;
        -h|--help)                   usage; exit 0 ;;
        -*)                          die "unknown option: $1 (try --help)"; exit 2 ;;
        *)
            # Positional: the first APK is the overlay, the second SystemUI.
            if [ -z "$overlay" ]; then
                overlay="$1"
            elif [ -z "$systemui" ]; then
                systemui="$1"
            else
                die "more than two APKs given — use --overlay and --systemui"; exit 2
            fi
            shift
            ;;
    esac
done

# A tty (the menu, or a person typing) gets asked for what was not typed.
if [ -z "$overlay" ] && [ -t 0 ]; then
    ask "  Overlay APK to pack: " ""
    overlay="$REPLY"
fi
# A path pasted from Explorer arrives as "C:\...", quotes included. Clean both
# arguments here so the CLI and the menu take the same input.
overlay="$(input_path "$overlay")"
systemui="$(input_path "$systemui")"

[ -n "$overlay" ] || { die "no APK given — ./build.sh wrap --overlay path/to/overlay.apk"; exit 2; }

# ---------------------------------------------------------------------------
# Checks — an APK that cannot be an overlay fails here, not after flashing
# ---------------------------------------------------------------------------
# An APK is a zip; two bytes are enough to catch a truncated download or a file
# renamed to .apk. od instead of grep because this is binary.
wrap_is_zip() {
    [ "$(head -c 2 "$1" 2>/dev/null | od -An -tx1 | tr -d ' \n')" = "504b" ]
}

wrap_check_apk() {
    local p="$1" label="$2"
    [ -f "$p" ] || { die "$label: no such file: $p"; return 1; }
    [ -r "$p" ] || { die "$label: cannot read: $p"; return 1; }
    [ -s "$p" ] || { die "$label: the file is empty: $p"; return 1; }
    case "$(printf '%s' "$p" | tr '[:upper:]' '[:lower:]')" in
        *.apk) ;;
        *) warn "$label: $p does not end in .apk — packing it anyway" ;;
    esac
    wrap_is_zip "$p" || { die "$label: not a zip, so not an APK: $p"; return 1; }
    return 0
}

# The package name, and the package the APK overrides. Both are read from the
# APK itself: it is what the summary prints and what the on-phone check greps
# for, and a typo in a name typed by hand would send the user looking at the
# wrong line of `cmd overlay list`.
WRAP_PKG=""
WRAP_TARGET=""
WRAP_STATIC=""
wrap_meta() {
    local apk="$1" dump
    WRAP_PKG=""; WRAP_TARGET=""; WRAP_STATIC=""
    command -v aapt2 >/dev/null 2>&1 || return 0
    dump="$(aapt2 dump badging "$apk" 2>/dev/null || true)"
    WRAP_PKG="$(printf '%s\n' "$dump" | sed -n "s/^package: name='\([^']*\)'.*/\1/p" | head -n 1)"
    dump="$(aapt2 dump xmltree --file AndroidManifest.xml "$apk" 2>/dev/null || true)"
    WRAP_TARGET="$(printf '%s\n' "$dump" | sed -n 's/.*:targetPackage([^)]*)="\([^"]*\)".*/\1/p' | head -n 1)"
    if printf '%s\n' "$dump" | grep -Eq ':isStatic\([^)]*\)=true'; then
        WRAP_STATIC=true
    fi
    return 0
}

step "Checking the APKs"
wrap_check_apk "$overlay" "overlay" || exit 1
[ -n "$systemui" ] && { wrap_check_apk "$systemui" "SystemUI" || exit 1; }

fw_name="$(basename "$overlay")"
su_name=""
if [ -n "$systemui" ]; then
    su_name="$(basename "$systemui")"
    # Both APKs land in one folder; a shared name would silently pack one and
    # drop the other.
    if [ "$su_name" = "$fw_name" ]; then
        die "both APKs are named ${fw_name} — rename one of them"; exit 1
    fi
    if [ "$(cd "$(dirname "$overlay")" && pwd)/$fw_name" = "$(cd "$(dirname "$systemui")" && pwd)/$su_name" ]; then
        die "the same file was given twice"; exit 1
    fi
fi

wrap_meta "$overlay"
fw_pkg="$WRAP_PKG"; fw_target="$WRAP_TARGET"; fw_static="$WRAP_STATIC"
su_pkg=""; su_target=""; su_static=""
if [ -n "$systemui" ]; then
    wrap_meta "$systemui"
    su_pkg="$WRAP_PKG"; su_target="$WRAP_TARGET"; su_static="$WRAP_STATIC"
    ok "${su_name}: ${su_pkg:-package not readable}${su_target:+ → ${su_target}}"
fi

ok "${fw_name}: ${fw_pkg:-package not readable}${fw_target:+ → ${fw_target}}"

if [ -z "$fw_pkg" ] && [ -z "$su_pkg" ]; then
    warn "aapt2 is not installed, so the package names could not be read — the"
    warn "module is still built, but the on-phone check cannot name the overlay."
    info "Read them yourself with: aapt2 dump badging \"$overlay\" | head -n1"
fi
if [ -n "$fw_pkg" ] && [ -z "$fw_target" ]; then
    warn "${fw_pkg} has no <overlay> element in its manifest — it may not be an overlay at all"
fi
if [ "$fw_static" != true ] && [ -n "$fw_pkg" ]; then
    warn "${fw_pkg} is not a static overlay — it is enabled by the module's service.sh, not by the framework"
fi

# ---------------------------------------------------------------------------
# Module id and output path
# ---------------------------------------------------------------------------
wrap_slug() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]' \
        | sed 's/[^a-z0-9._-]/-/g; s/--*/-/g; s/^[._-]*//; s/[._-]*$//'
}

wrap_module_id() {
    local base slug
    if [ -n "$want_name" ]; then
        # The three managers share this namespace: ^[a-zA-Z][a-zA-Z0-9._-]+$
        if printf '%s' "$want_name" | grep -Eq '^[A-Za-z][A-Za-z0-9._-]+$'; then
            printf '%s' "$want_name"
            return 0
        fi
        die "--name must start with a letter; letters, digits, dots, dashes and underscores only"
        return 1
    fi
    base="$(basename "$overlay")"
    base="${base%.*}"
    slug="$(wrap_slug "$base")"
    [ -n "$slug" ] || slug="overlay"
    printf 'wrap-%s' "$slug"
}

module_id="$(wrap_module_id)" || exit 1
out_dir="$OUT_DIR/wrap"
dest="$out_dir/${module_id}.zip"

# ---------------------------------------------------------------------------
# Author, from config.env when there is one
# ---------------------------------------------------------------------------
author="overlay test"
if [ -f "$ROOT/config.env" ]; then
    # shellcheck disable=SC1090
    . "$ROOT/config.env" 2>/dev/null || true
    if [ -n "${MODULE_AUTHOR:-}" ] && [[ "$MODULE_AUTHOR" != *"<"* ]]; then
        author="$MODULE_AUTHOR"
    fi
fi

# ---------------------------------------------------------------------------
# Stage the module
# ---------------------------------------------------------------------------
step "Packing ${module_id}"
mkdir -p "$BUILD_DIR" "$out_dir"
tmp="$(mktemp -d "$BUILD_DIR/wrap.XXXXXX" 2>/dev/null || mktemp -d)"
mod="$tmp/module"
cleanup_wrap() { rm -rf "$tmp"; }
trap cleanup_wrap EXIT INT TERM

mkdir -p "$mod/system/product/overlay"
cp "$overlay" "$mod/system/product/overlay/$fw_name" || { die "could not copy $overlay"; exit 1; }
ok "framework overlay: $fw_name"
if [ -n "$systemui" ]; then
    cp "$systemui" "$mod/system/product/overlay/$su_name" || { die "could not copy $systemui"; exit 1; }
    ok "SystemUI overlay:  $su_name"
fi

pkg_label="${fw_pkg:-$fw_name}"
[ -n "$su_pkg" ] && pkg_label="$pkg_label + $su_pkg"

cat > "$mod/module.prop" << PROP
id=${module_id}
name=Overlay test - ${pkg_label}
version=$(date +%Y.%m.%d)
versionCode=$(date +%Y%m%d)
author=${author}
description=Packs overlay APKs you already have (${pkg_label}). Nothing was compiled: for testing only, not a submission.
PROP

cat > "$mod/customize.sh" << 'CUSTOMIZE_EOF'
#!/sbin/sh
# Test module: the APKs were packed as-is, so this only sets their permissions.
MODPATH=${MODPATH:-${0%/*}}
ui_print "  Installing overlay test module..."
set_perm_recursive $MODPATH/system/product/overlay 0 0 0755 0644 u:object_r:system_file:s0
ui_print "  Installed. Reboot, then check: cmd overlay list | grep overlay"
CUSTOMIZE_EOF
chmod 0755 "$mod/customize.sh"

# A static overlay is already enabled by the time this runs, so the loop below
# only reports. A non-static one is enabled here, which is the one case where a
# test module has to do something at boot.
cat > "$mod/service.sh" << SERVICE_EOF
#!/sbin/sh
# Reports whether the packed overlay(s) were accepted by the framework. This is
# what tells "the module is mounted" from "the framework refused the overlay".
PACKAGES="${fw_pkg} ${su_pkg}"
while [ "\$(getprop sys.boot_completed)" != "1" ]; do
    sleep 5
done
for pkg in \$PACKAGES; do
    [ -n "\$pkg" ] || continue
    cmd overlay enable "\$pkg" >/dev/null 2>&1 || true
    if cmd overlay list 2>/dev/null | grep -q "\[x\] \$pkg"; then
        log -t wrap-overlay "enabled: \$pkg" 2>/dev/null || true
    else
        log -t wrap-overlay "NOT enabled: \$pkg (wrong target package or priority, or the mount system did not mount the module)" 2>/dev/null || true
    fi
done
SERVICE_EOF
chmod 0755 "$mod/service.sh"

# Magisk's recovery installer bootstraps through META-INF; KernelSU, KSU Next
# and APatch ignore it. Generated by the same function the real build uses, so a
# test module and a release module install through identical code.
. "$ROOT/stuff/scripts/module.sh"
generate_magisk_meta "$mod"

create_zip "$mod" "$dest" || { die "could not write ${dest}"; exit 1; }
zip_size="$(du -sh "$dest" 2>/dev/null | cut -f1)"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
rewrap_rel="out/wrap/$(basename "$dest")"
ui_panel "Test module ready" \
    "Module|${module_id}" \
    "Overlay|${fw_pkg:-$fw_name}" \
    ${systemui:+"SystemUI|${su_pkg:-$su_name}"} \
    "Zip|${rewrap_rel} (${zip_size:-?})"

echo ""
info "Install it with your root manager, then reboot."
info "Verify:  adb shell cmd overlay list | grep -F ${fw_pkg:-${fw_name%.apk}}"
if [ -n "$fw_target" ]; then
    info "Lookup:  adb shell cmd overlay lookup ${fw_pkg} ${fw_target}:dimen/rounded_corner_radius"
fi
echo ""
echo -e "  ${UI_DIM}This module is a wrapper, not a build: deleting it removes nothing else,"
echo -e "  and rebuilding the device's real overlay does not replace it.${UI_OFF}"

# ---------------------------------------------------------------------------
# Offer to finish the job
# ---------------------------------------------------------------------------
# Same shape as a build: with a terminal, ask. -y and a piped run are left
# alone, so nothing waits for an answer that will not come.
if [ "$assume_yes" != true ] && [ -t 0 ] && [ -t 1 ]; then
    if confirm "  Install it on the phone now? [y/N] " n; then
        # The module id and the packages are known here, so the install's own
        # verification checks this zip instead of whatever config.env describes.
        wrap_install_args=(--zip "$dest" --id "$module_id")
        [ -n "$fw_pkg" ] && wrap_install_args+=(--package "$fw_pkg")
        [ -n "$su_pkg" ] && wrap_install_args+=(--package "$su_pkg")
        bash "$ROOT/stuff/scripts/install-module.sh" "${wrap_install_args[@]}" \
            || warn "the install did not finish — the zip is in out/wrap/"
    fi
fi
exit 0