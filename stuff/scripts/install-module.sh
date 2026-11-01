#!/usr/bin/env bash
# =============================================================================
# install-module.sh — put the built module on the phone, reboot, check it
# =============================================================================
# Building ends with a zip in out/ and four lines of instructions. This does the
# part people get wrong: copy the zip over, hand it to the root manager that is
# actually installed (ksud for KernelSU/KSU Next, magisk for Magisk), reboot,
# wait for the phone to come back, and then report whether the overlay really is
# mounted and enabled — the three things "did it work?" means.
#
#   ./build.sh install                  # the connected phone
#   ./build.sh install --no-reboot      # install, leave the reboot to you
#   ./build.sh install --device SERIAL  # more than one phone attached
#   ./build.sh install --zip PATH       # a module other than the newest build
#   ./build.sh install --zip out/wrap/x.zip --id wrap-x --package com.example.overlay
#                                       # a wrapped test module (wrap.sh passes these)
#
#   Standalone: bash stuff/scripts/install-module.sh [the same options]
#
# In Termux the zip is installed on this phone directly (root, no adb) and the
# script stops after the install: rebooting the machine the script runs on
# cannot be followed by a verification pass.
#
# Verification is read-only: /data/adb/modules/<id> must exist with no `disable`
# or `remove` file, and `cmd overlay list` must show the package as enabled.
# =============================================================================

set -uo pipefail

# adb on Windows is a Git Bash binary: /sdcard/... would be rewritten into a
# Windows path before adb saw it.
export MSYS_NO_PATHCONV=1

ROOT="${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
. "$ROOT/stuff/scripts/common.sh"
. "$ROOT/stuff/scripts/adb-device.sh"

want_serial="${DEVICE_SERIAL:-}"
zip_path=""
do_reboot=1
do_verify=1
# Set for a module that was not built from this config.env (a wrapped test
# module): the id and the packages to check are then the caller's, not the
# file's.
want_id=""
want_packages=()

usage() {
    sed -n '3,23p' "$0" | sed 's/^# \{0,1\}//'
}

die() { err "$1"; return 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --device) want_serial="${2:-}"; shift 2 ;;
        --zip) zip_path="${2:-}"; shift 2 ;;
        --id) want_id="${2:-}"; shift 2 ;;
        --package) want_packages+=("${2:-}"); shift 2 ;;
        --no-reboot) do_reboot=0; shift ;;
        --no-verify) do_verify=0; shift ;;
        -y|--yes) do_reboot=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown option: $1 (try --help)"; exit 2 ;;
    esac
done

# The module id and package name are derived, not typed: the same function the
# build uses, from the same config.env, so what is installed is what was built.
[ -f "$ROOT/config.env" ] && . "$ROOT/config.env"
derive_overlay_identity >/dev/null 2>&1 || true

module_id="${want_id:-${OVERLAY_NAME:-}}"
# A build installs one framework overlay and, sometimes, a SystemUI one. The
# packages that get checked are exactly the ones asked for, in order.
verify_pkgs=""
if [ "${#want_packages[@]}" -gt 0 ]; then
    verify_pkgs="${want_packages[*]}"
else
    verify_pkgs="${OVERLAY_PACKAGE:-}"
fi
overlay_pkg="${verify_pkgs%% *}"

# ---------------------------------------------------------------------------
# Which zip
# ---------------------------------------------------------------------------
install_find_zip() {
    if [ -n "$zip_path" ]; then
        [ -f "$zip_path" ] || { die "no such file: $zip_path"; return 1; }
        printf '%s' "$zip_path"
        return 0
    fi
    if [ -n "$module_id" ] && [ -f "$ROOT/out/${module_id}-ksu.zip" ]; then
        printf '%s' "$ROOT/out/${module_id}-ksu.zip"
        return 0
    fi
    # A clean checkout builds a different device name than the config says; the
    # newest -ksu.zip is still the thing the user just built.
    local newest
    newest="$(ls -t "$ROOT"/out/*-ksu.zip 2>/dev/null | head -n1)"
    if [ -n "$newest" ]; then
        warn "no zip for ${module_id:-this config} — using $(basename "$newest")"
        printf '%s' "$newest"
        return 0
    fi
    die "nothing to install: out/ has no -ksu.zip. Run ./build.sh build first."
    return 1
}

# ---------------------------------------------------------------------------
# Talking to the phone
# ---------------------------------------------------------------------------
# Root on the phone: local mode is already root, adb goes through su. One place,
# because every install and every check needs it.
install_root() {
    local cmd="$1"
    if [ "${DEVICE_LOCAL:-0}" = 1 ]; then
        device_local_run "$cmd" </dev/null 2>/dev/null | tr -d '\r'
    else
        "$adb" ${serial:+-s "$serial"} shell "su -c $(sh_quote "$cmd")" </dev/null 2>/dev/null | tr -d '\r'
    fi
}

# The manager that will take the zip. KernelSU and KSU Next ship ksud; APatch's
# apd takes the same `module install` arguments; Magisk uses --install-module.
# Asked in one root call so the su prompt happens once.
install_manager() {
    local have
    have="$(install_root 'for b in ksud magisk apd; do command -v $b >/dev/null 2>&1 && echo "have:$b"; done')"
    case "$have" in
        *have:ksud*) printf 'ksud' ;;
        *have:apd*)  printf 'apd' ;;
        *have:magisk*) printf 'magisk' ;;
        *) printf '' ;;
    esac
}

# Where the zip lives on the phone. /sdcard/Download is the folder every manager
# app browses, and the one the manual instructions in the build summary use.
install_remote_path() {
    printf '/sdcard/Download/%s' "$(basename "$1")"
}

# adb push, but bounded: adb has no timeout and a wedged server would hang the
# script with nothing on screen.
install_push() {
    local local_zip="$1" remote="$2" dir status
    dir="$(mktemp -d 2>/dev/null || printf '%s' "${TMPDIR:-/tmp}/install.$$")"
    mkdir -p "$dir" 2>/dev/null
    "$adb" ${serial:+-s "$serial"} shell "mkdir -p /sdcard/Download" >/dev/null 2>&1 || true
    adb_device_exec 1200 "$dir/push" "$adb" ${serial:+-s "$serial"} push "$local_zip" "$remote"
    status=$?
    cat "$dir/push.err" >&2 2>/dev/null || true
    rm -rf "$dir"
    return "$status"
}

# ---------------------------------------------------------------------------
# Reboot, then wait for the phone to be up again
# ---------------------------------------------------------------------------
# Waiting on sys.boot_completed rather than on `adb wait-for-device`: the device
# node comes back long before the framework is ready, and the checks below read
# the overlay service, which only answers after boot_completed.
install_wait_boot() {
    local limit="${1:-240}" waited=0 state
    while [ "$waited" -lt "$limit" ]; do
        sleep 2
        waited=$((waited + 2))
        state="$("$adb" ${serial:+-s "$serial"} shell getprop sys.boot_completed 2>/dev/null | tr -d '\r\n')"
        if [ "$state" = 1 ]; then
            return 0
        fi
        if [ $((waited % 20)) -eq 0 ]; then
            info "still booting — ${waited}s of ${limit}s"
        fi
    done
    return 1
}

# ---------------------------------------------------------------------------
# Did it work?
# ---------------------------------------------------------------------------
# Three separate answers, because they fail independently: the module may be
# missing (wrong manager), present but disabled (manager's "enabled" switch), or
# present and enabled while the overlay itself did not attach (a bad resource,
# a mount system that did not mount it).
install_verify() {
    local fails=0 mod_dir disable_line overlay_line

    mod_dir="$(install_root "ls -d /data/adb/modules/${module_id} 2>/dev/null | head -n1")"
    if [ -n "$mod_dir" ]; then
        ok "module /data/adb/modules/${module_id} is present"
        disable_line="$(install_root "ls /data/adb/modules/${module_id}/disable 2>/dev/null")"
        if [ -n "$disable_line" ]; then
            warn "the module is disabled in the manager — enable it and reboot"
            fails=$((fails + 1))
        else
            ok "it is enabled (no disable or remove flag)"
        fi
    else
        err "no /data/adb/modules/${module_id} — the install did not land"
        info "Open your root manager and install out/$(basename "$1") by hand, or check that the manager is supported."
        fails=$((fails + 1))
    fi

    # Word-splitting on purpose: this is a list of package names, and neither
    # a package nor an overlay id can contain a space.
    local pkg
    for pkg in $verify_pkgs; do
        overlay_line="$(device_sh "cmd overlay list | grep -F ${pkg} | head -n1")"
        case "$overlay_line" in
            \[x\]*)
                ok "overlay ${pkg} is registered and enabled"
                ;;
            \[*\]*)
                warn "overlay ${pkg} is registered but not enabled:"
                printf '      %s\n' "$overlay_line"
                info "Enable it: adb shell su -c 'cmd overlay enable ${pkg}'"
                fails=$((fails + 1))
                ;;
            *)
                err "overlay ${pkg} is not in the overlay list"
                info "The module is installed but did not mount. KernelSU/KSU Next needs Magic Mount (not OverlayFS) — see docs/how-it-works.md."
                fails=$((fails + 1))
                ;;
        esac
    done

    if [ "$fails" -eq 0 ]; then
        ok "the overlay is live — reboot once more after changing values, then hard-reboot if a value sticks at the old one"
        return 0
    fi
    warn "${fails} check(s) did not pass — details above"
    return 1
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
install_main() {
    local zip local_zip remote manager confirm_reboot

    zip="$(install_find_zip)" || return 1
    [ -f "$zip" ] || return 1
    local_zip="$(cd "$(dirname "$zip")" && pwd)/$(basename "$zip")"

    step "Install the module"
    ui_kv "Module" "$(basename "$local_zip")" 10
    ui_kv "Device" "${module_id:-unknown}" 10
    printf '\n'

    # Termux, not adb: this phone is the machine, so nothing is pushed.
    if device_is_termux && [ -z "$want_serial" ] && ! adb_device_ready_now "${adb:-adb}" 2>/dev/null; then
        if ! device_local_begin "install-module.sh"; then
            die "root is needed to install a module on this phone"
            return 1
        fi
        manager="$(install_manager)"
        if [ -z "$manager" ]; then
            die "no ksud, apd or magisk on this phone — install the zip from your root manager's Modules screen"
            return 1
        fi
        # Root can read Termux's home, so the zip is installed where it sits.
        info "installing with ${manager} (no adb involved)"
        case "$manager" in
            magisk) install_root "magisk --install-module $(sh_quote "$local_zip")" ;;
            *)      install_root "${manager} module install $(sh_quote "$local_zip")" ;;
        esac
        ok "installed — reboot this phone, then open the WebUI or run ./build.sh doctor to check it"
        return 0
    fi

    resolve_adb || { die "adb was not found — install platform-tools (./build.sh doctor says where)"; return 1; }
    adb_pick_device "$adb" "$want_serial" "install-module.sh" || return 1
    # device_sh and install_root read the globals adb-device.sh uses.
    serial="$DEVICE_SERIAL"
    info "using ${serial}"

    remote="$(install_remote_path "$local_zip")"
    info "copying to ${remote}"
    if ! install_push "$local_zip" "$remote"; then
        die "the copy failed — is the phone still connected? (adb devices)"
        return 1
    fi

    manager="$(install_manager)"
    case "$manager" in
        ksud|apd)
            info "installing with ${manager}"
            if ! install_root "${manager} module install ${remote}" | sed 's/^/    /'; then
                die "${manager} refused the zip"
                return 1
            fi
            ;;
        magisk)
            info "installing with magisk"
            if ! install_root "magisk --install-module ${remote}" | sed 's/^/    /'; then
                die "magisk refused the zip"
                return 1
            fi
            ;;
        *)
            warn "no ksud, apd or magisk on the phone — the zip is at ${remote}"
            info "Open your root manager → Modules → Install from storage and pick it."
            return 1
            ;;
    esac
    ok "installed"

    if [ "$do_reboot" = 0 ]; then
        info "reboot when you are ready, then check: adb shell cmd overlay list | grep ${overlay_pkg}"
        return 0
    fi
    if [ -t 0 ] && [ -t 1 ]; then
        confirm "Reboot now and check the overlay when it comes back? [Y/n] " y || {
            info "not rebooting — reboot yourself, then verify with: adb shell cmd overlay list | grep ${overlay_pkg}"
            return 0
        }
    fi

    info "rebooting"
    "$adb" ${serial:+-s "$serial"} reboot >/dev/null 2>&1 || true
    # The phone drops off adb for a few seconds; asking it to come back first
    # keeps the boot wait from reading an empty shell.
    "$adb" ${serial:+-s "$serial"} wait-for-device >/dev/null 2>&1 || true
    if ! install_wait_boot 240; then
        die "the phone did not finish booting within 240s — plug it in and watch it, then check by hand"
        return 1
    fi
    ok "booted"

    [ "$do_verify" = 1 ] || return 0
    install_verify "$local_zip"
}
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    install_main
fi
