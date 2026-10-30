#!/usr/bin/env bash
# =============================================================================
# Treble Overlay — shared helpers
# =============================================================================
# Sourced by build.sh and by the modules in stuff/scripts/. Never run directly.
#
# The entry point sets ROOT (the project directory) and then sources this file,
# so every helper below can assume it exists and that the current directory is
# the project root.
# =============================================================================

: "${ROOT:?stuff/scripts/common.sh must be sourced by build.sh (ROOT is not set)}"

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
# Absolute paths are used for file tests and for zip destinations. Arguments
# handed to native tools (aapt2/zipalign) must stay RELATIVE: MSYS on Windows
# does not reliably convert a /c/... path for a native .exe.
# Everything that is not the thing you build lives under stuff/, so the root
# only holds the two entry points, config.env and the folders you open.
STUFF_DIR="$ROOT/stuff"
TOOLS_DIR="$STUFF_DIR/tools"
BUILD_DIR="$STUFF_DIR/build"
OUT_DIR="$ROOT/out"
KEYS_DIR="$STUFF_DIR/keys"
BACKUP_DIR="$STUFF_DIR/backups"
TEMPLATES_DIR="$STUFF_DIR/templates"
# Not "the old version of your files": the no-git fallback for
# restore_from_release(). Kept identical to the committed files by stuff/tests/run.sh.
RECOVERIES_DIR="$TEMPLATES_DIR/recoveries"

SRC_DIR="$ROOT/src"
FRAMEWORK_DIR="$SRC_DIR/framework"
FRAMEWORK_RES="$FRAMEWORK_DIR/res"
SYSTEMUI_DIR="$SRC_DIR/systemui"
SYSTEMUI_RES="$SYSTEMUI_DIR/res"
MODULE_DIR="$SRC_DIR/module"
VENDOR_DIR="$SRC_DIR/vendor"

CONFIG_FILE="$ROOT/config.env"
CONFIG_EXAMPLE="$ROOT/config.env.example"

# ---------------------------------------------------------------------------
# Restoring a tracked file to what this release ships
# ---------------------------------------------------------------------------
# "Start over" must never hand back a copy that froze at some old commit. The
# committed blob IS the template for a tracked file, so ask git for it; the
# copy in stuff/templates/recoveries/ is only the fallback for a checkout with no .git
# (a fork downloaded as a zip). stuff/tests/run.sh fails if the two ever drift.
#
#   restore_from_release <path relative to ROOT> [fallback copy]
#
# Returns 0 when the file on disk now holds the release version.
restore_from_release() {
    local rel="$1" fallback="${2:-}"

    if [ -d "$ROOT/.git" ] && command -v git >/dev/null 2>&1 \
       && git -C "$ROOT" rev-parse --verify --quiet "HEAD:${rel}" >/dev/null 2>&1; then
        if git -C "$ROOT" checkout HEAD -- "$rel" 2>/dev/null; then
            return 0
        fi
    fi

    if [ -n "$fallback" ] && [ -f "$fallback" ]; then
        mkdir -p "$(dirname "$ROOT/$rel")"
        cp "$fallback" "$ROOT/$rel" && return 0
    fi
    return 1
}

# ---------------------------------------------------------------------------
# Platform
# ---------------------------------------------------------------------------
IS_WINDOWS=false
case "$(uname -s 2>/dev/null)" in
    MINGW*|MSYS*|CYGWIN*) IS_WINDOWS=true ;;
esac

# WSL reports Linux but lives inside Windows. The build is allowed there only
# when the checkout is on the Linux filesystem (see wsl_guard).
IS_WSL=false
if ! $IS_WINDOWS && [ -r /proc/version ] && grep -qi microsoft /proc/version 2>/dev/null; then
    IS_WSL=true
fi

IS_TERMUX=false
if [ -d /data/data/com.termux ] && [ -n "${PREFIX:-}" ]; then
    IS_TERMUX=true
fi

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

ok()   { echo -e "  ${GREEN}✓${NC} $*"; }
info() { echo -e "  ${YELLOW}→${NC} $*"; }
warn() { echo -e "  ${YELLOW}⚠${NC} $*"; }
err()  { echo -e "  ${RED}✗${NC} $*" >&2; }
step() { echo -e "\n${BOLD}━━━ $* ━━━${NC}"; }

banner() {
    echo ""
    echo -e "  ${BOLD}$*${NC}"
    echo -e "  ${BOLD}──────────────────────────────────────────────────────────${NC}"
    echo ""
}

# ---------------------------------------------------------------------------
# Prompts
# ---------------------------------------------------------------------------
# ask <question> <default>   -> answer in $REPLY
#
# `read` returns 1 at EOF (stdin redirected, CI, IDE task, no console). Under
# `set -e` that used to kill the scripts silently right after a menu had been
# printed. Falling back to a stated default keeps everything runnable
# unattended, and pressing Enter also takes the default.
ask() {
    local question="$1" default="${2:-}" answer=""
    printf '%s' "$question"
    if ! read -r answer; then
        echo ""
        info "No terminal input available — using '${default}'."
        answer="$default"
    fi
    [ -z "$answer" ] && answer="$default"
    REPLY="$answer"
}

# confirm <question> <y|n>   -> returns 0 for yes
confirm() {
    local question="$1" default="${2:-n}" answer
    ask "$question" "$default"
    answer="$REPLY"
    case "$answer" in
        [Yy]|[Yy][Ee][Ss]) return 0 ;;
        *) return 1 ;;
    esac
}

# ---------------------------------------------------------------------------
# WSL safety
# ---------------------------------------------------------------------------
# A checkout on a Windows drive that is built from inside WSL would put Linux
# binaries into the same stuff/tools/ folder the Windows build reads, and would hand
# Windows a build tree it cannot use. Refuse with instructions instead of
# producing a half-broken toolchain. (This is the "VS Code opened the folder
# with WSL" case.)
wsl_guard() {
    $IS_WSL || return 0
    case "$ROOT" in
        /mnt/[a-z]/*) ;;
        *) return 0 ;;
    esac

    echo ""
    err "This project is on a Windows drive, but you are running inside WSL."
    echo ""
    echo "    Project:  $ROOT"
    echo "    Shell:    WSL (Linux)"
    echo ""
    echo "  The Linux toolchain would be installed into the same stuff/tools/ folder the"
    echo "  Windows build uses, so both platforms would then see the wrong binaries."
    echo ""
    echo -e "  ${BOLD}Use one of these instead:${NC}"
    echo "    • Windows (cmd, PowerShell, VS Code):   build.cmd"
    echo "    • Linux / Termux:                       clone the project inside Linux"
    echo "                                            (e.g. ~/treble-rro-creator)"
    echo "                                            and run ./build.sh there"
    echo ""
    echo "  In VS Code, check the bottom-left corner: if it says \"WSL: ...\","
    echo "  close the remote window (or open a Windows terminal) and run build.cmd."
    echo ""
    exit 1
}

# ---------------------------------------------------------------------------
# Legacy layout
# ---------------------------------------------------------------------------
# Older versions of this project kept res/, systemui_overlay/, customize.sh,
# service.sh, sepolicy.rule and system/vendor/ at the top level. Users who
# upgrade by pulling can still have personal (untracked) copies there. Move
# them into src/ instead of silently ignoring them.
migrate_layout() {
    local moved=false f

    # res/ -> src/framework/res
    if [ -d "$ROOT/res" ]; then
        if [ ! -d "$FRAMEWORK_RES" ]; then
            mkdir -p "$FRAMEWORK_DIR"
            cp -R "$ROOT/res" "$FRAMEWORK_DIR/res"
            rm -rf "$ROOT/res"
            info "Moved legacy ./res → src/framework/res"
            moved=true
        else
            warn "Legacy ./res exists but is no longer used — the build reads src/framework/res"
        fi
    fi

    # systemui_overlay/ -> src/systemui/res
    if [ -d "$ROOT/systemui_overlay/res" ]; then
        if [ ! -d "$SYSTEMUI_RES" ]; then
            mkdir -p "$SYSTEMUI_DIR"
            cp -R "$ROOT/systemui_overlay/res" "$SYSTEMUI_DIR/res"
            rm -rf "$ROOT/systemui_overlay"
            info "Moved legacy ./systemui_overlay → src/systemui"
            moved=true
        else
            warn "Legacy ./systemui_overlay exists but is no longer used — the build reads src/systemui/res"
        fi
    fi

    # system/vendor -> src/vendor
    if [ -d "$ROOT/system/vendor" ]; then
        mkdir -p "$VENDOR_DIR"
        cp -R "$ROOT/system/vendor/." "$VENDOR_DIR/" 2>/dev/null || true
        rm -rf "$ROOT/system"
        info "Moved legacy ./system/vendor → src/vendor"
        moved=true
    fi

    # Root module scripts -> src/module
    mkdir -p "$MODULE_DIR"
    for f in customize.sh service.sh sepolicy.rule; do
        [ -f "$ROOT/$f" ] || continue
        if [ -f "$MODULE_DIR/$f" ] && cmp -s "$ROOT/$f" "$MODULE_DIR/$f"; then
            rm -f "$ROOT/$f"
        else
            mv -f "$ROOT/$f" "$MODULE_DIR/$f"
            info "Moved legacy ./$f → src/module/$f (now the copy that gets built)"
        fi
        moved=true
    done

    # YOUR BACKUPS -> stuff/backups
    if [ -d "$ROOT/YOUR BACKUPS" ] && [ ! -d "$BACKUP_DIR" ]; then
        mv "$ROOT/YOUR BACKUPS" "$BACKUP_DIR"
        info "Moved legacy ./YOUR BACKUPS → stuff/backups"
        moved=true
    fi

    # Everything that is not src/, docs/ or an entry point now lives in stuff/.
    # A git pull moves these itself; this covers an upgrade from a zip, which
    # would otherwise leave a second copy in the way at the root.
    mkdir -p "$STUFF_DIR"
    for f in keys templates windows tests scripts tools build backups; do
        [ -d "$ROOT/$f" ] || continue
        if [ -d "$STUFF_DIR/$f" ]; then
            warn "Legacy ./$f exists but stuff/$f is the one in use — remove the old copy"
            continue
        fi
        mv "$ROOT/$f" "$STUFF_DIR/$f"
        info "Moved legacy ./$f → stuff/$f"
        moved=true
    done

    $moved && info "Layout upgraded — internals live in stuff/, the entry points stay at the root"
    return 0
}

# ---------------------------------------------------------------------------
# Binary inspection
# ---------------------------------------------------------------------------
# Windows cannot execute Linux binaries. If this checkout is also opened from
# WSL/Kali (a copy on the same drive), a Linux `aapt2` can land in the same
# stuff/tools/ folder the Windows build puts on PATH, shadow `aapt2.exe`, and fail
# much later with "Exec format error". Classify by magic bytes so it is caught
# up front.
classify_binary() {
    local f="$1"
    if [ ! -e "$f" ]; then echo "missing"; return 0; fi
    if [ -d "$f" ]; then echo "directory"; return 0; fi
    local magic
    magic=$(head -c 4 "$f" 2>/dev/null | od -An -tx1 2>/dev/null | tr -d ' \n')
    case "$magic" in
        4d5a*)     echo "windows-pe" ;;   # MZ  -> .exe
        7f454c46)  echo "linux-elf" ;;    # \x7fELF -> WSL/Linux build
        2321*)     echo "script" ;;       # #!
        504b0304)  echo "zip" ;;          # PK.. -> apk / jar
        "")        echo "unreadable" ;;
        *)         echo "unknown" ;;
    esac
}

kind_label() {
    case "$1" in
        windows-pe) echo "Windows executable" ;;
        linux-elf)  echo "Linux binary (ELF)" ;;
        script)     echo "shell script" ;;
        zip)        echo "archive" ;;
        missing)    echo "missing" ;;
        *)          echo "$1" ;;
    esac
}

# A native binary built for the OTHER platform. This is the real contamination
# signal: scripts, jars and apks are fine to share between Windows and WSL.
kind_foreign() {
    if $IS_WINDOWS; then
        [ "$1" = "linux-elf" ]
    else
        [ "$1" = "windows-pe" ]
    fi
}

# Can a binary of this kind run on the machine we are on right now?
kind_usable() {
    if $IS_WINDOWS; then
        case "$1" in
            windows-pe|script|zip) return 0 ;;
            *) return 1 ;;
        esac
    fi
    case "$1" in
        linux-elf|script|zip) return 0 ;;
        *) return 1 ;;
    esac
}

# Every path a tool could be picked up from, in the order build.sh resolves it.
tool_candidates() {
    local name="$1" c
    for c in "$(command -v "$name" 2>/dev/null)" \
             "${TOOLS_DIR}/${name}" \
             "${TOOLS_DIR}/${name}.exe" \
             "${TOOLS_DIR}/${name}.bat"; do
        [ -n "$c" ] && [ -f "$c" ] && printf '%s\n' "$c"
    done
    return 0
}

# Is this tool usable HERE (PATH, stuff/tools/, .exe/.bat on Windows)?
tool_ready() {
    local name="$1" cand
    while IFS= read -r cand; do
        [ -n "$cand" ] || continue
        kind_usable "$(classify_binary "$cand")" && return 0
    done <<< "$(tool_candidates "$name")"
    return 1
}

# First usable copy of a tool (prints the path, returns 1 when there is none).
tool_path() {
    local name="$1" cand
    while IFS= read -r cand; do
        [ -n "$cand" ] || continue
        if kind_usable "$(classify_binary "$cand")"; then
            printf '%s\n' "$cand"
            return 0
        fi
    done <<< "$(tool_candidates "$name")"
    return 1
}

# Where the aapt2 resource dictionary lives, if it is installed.
framework_res_path() {
    local c
    for c in "$TOOLS_DIR/framework-res.apk" \
             "/usr/share/android-framework-res/framework-res.apk"; do
        [ -f "$c" ] && { printf '%s\n' "$c"; return 0; }
    done
    # Optional local Android SDK (Arch Linux layout)
    if [ -d "/opt/android-sdk/platforms" ]; then
        c=$(find /opt/android-sdk/platforms -name "framework-res.apk" 2>/dev/null | head -n 1)
        [ -n "$c" ] && { printf '%s\n' "$c"; return 0; }
    fi
    return 1
}

# Everything the build needs, as a space-separated list (empty = ready).
# zipalign is not in the Termux package repository (pkg cannot install it) and
# an unaligned RRO still loads, so it is optional there instead of blocking the
# build forever. Everything else still requires it.
zipalign_optional() {
    $IS_TERMUX && ! tool_ready zipalign
}

# align_apk <unsigned> <aligned> — zipalign when available, plain copy if not.
# An unaligned APK is valid and installs; it just cannot be mmap'ed as
# efficiently, so this is a warning, not a failure.
ALIGN_WARNED=false
align_apk() {
    if tool_ready zipalign; then
        zipalign -f 4 "$1" "$2"
        return $?
    fi
    if ! $ALIGN_WARNED; then
        warn "zipalign not available — APKs stay unaligned (valid, slightly slower to map)"
        $IS_TERMUX && warn "  Termux: pkg install aapt  (that package ships zipalign)"
        ALIGN_WARNED=true
    fi
    cp -f "$1" "$2"
}

toolchain_missing() {
    local missing="" t
    for t in aapt2 zipalign apksigner; do
        [ "$t" = "zipalign" ] && zipalign_optional && continue
        tool_ready "$t" || missing="$missing $t"
    done
    command -v java >/dev/null 2>&1 || missing="$missing java"
    framework_res_path >/dev/null 2>&1 || missing="$missing framework-res.apk"
    printf '%s' "${missing# }"
}

# ---------------------------------------------------------------------------
# Device identity
# ---------------------------------------------------------------------------
# Turns the raw DEVICE_* values from config.env into the module id, the overlay
# package names and the match condition. Called by build.sh right after
# config.env is sourced, and by the standalone scripts (manifest.sh,
# hardware-overlay.sh) so they agree with the build.
#
# Users only need to set DEVICE_CODENAME and DEVICE_MANUFACTURER; everything
# else is derived. A value containing "<" is a template placeholder.
derive_overlay_identity() {
    [ -z "${DEVICE_MANUFACTURER:-}" ] || [[ "$DEVICE_MANUFACTURER" == *"<"* ]] && DEVICE_MANUFACTURER="generic"
    [ -z "${DEVICE_CODENAME:-}" ]     || [[ "$DEVICE_CODENAME" == *"<"* ]]     && DEVICE_CODENAME="generic"

    # Clean manufacturer for Java package names (lowercase alphanumeric only)
    SAFE_MANUFACTURER=$(printf '%s' "${DEVICE_MANUFACTURER}" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]//g')

    # Clean codename for package name: replace non-alphanumeric with dots
    # e.g. "Infinix-X6852" → "infinix.x6852" (dots are valid Java package separators)
    PACKAGE_SEGMENT=$(printf '%s' "${DEVICE_CODENAME}" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/./g' | sed 's/\.\.*/./g' | sed 's/^\.//;s/\.$//')

    # Module ids are shared by Magisk, KernelSU and APatch: they must match
    # ^[a-zA-Z][a-zA-Z0-9._-]+$ (no spaces or slashes). Use the already-cleaned
    # manufacturer/codename pieces for the generated default; an explicit
    # OVERLAY_NAME in config.env is kept as-is.
    DEFAULT_MANUFACTURER="${SAFE_MANUFACTURER:-generic}"
    DEFAULT_CODENAME="${PACKAGE_SEGMENT:-generic}"
    [ -z "${OVERLAY_NAME:-}" ]        || [[ "$OVERLAY_NAME" == *"<"* ]]        && OVERLAY_NAME="treble-overlay-${DEFAULT_MANUFACTURER}-${DEFAULT_CODENAME}"
    [ -z "${OVERLAY_PACKAGE:-}" ]     || [[ "$OVERLAY_PACKAGE" == *"<"* ]]     && OVERLAY_PACKAGE="me.phh.treble.overlay.${SAFE_MANUFACTURER}.${PACKAGE_SEGMENT}"
    [ -z "${OVERLAY_PACKAGE_SYSTEMUI:-}" ] || [[ "$OVERLAY_PACKAGE_SYSTEMUI" == *"<"* ]] && OVERLAY_PACKAGE_SYSTEMUI="${OVERLAY_PACKAGE}.systemui"
    [[ "${DEVICE_PROP_VALUE:-}" == *"<"* ]] && DEVICE_PROP_VALUE="${DEVICE_CODENAME}"
    # Only placeholders are replaced. An EMPTY DEVICE_PROP_NAME is meaningful: it
    # builds an overlay with no match condition (always active), which is the safe
    # default for framework overlays — see the Overlay Activation section of
    # config.env for why ro.product.* conditions fail on GSI setups.
    [[ "${DEVICE_PROP_NAME:-}" == *"<"* ]] && DEVICE_PROP_NAME="ro.product.device"

    if [ -n "${DEVICE_PROP_NAME:-}" ]; then
        OVERLAY_CONDITION="        android:requiredSystemPropertyName=\"${DEVICE_PROP_NAME}\"
        android:requiredSystemPropertyValue=\"${DEVICE_PROP_VALUE}\" />"
        CONDITION_DESC="${DEVICE_PROP_NAME} == \"${DEVICE_PROP_VALUE}\""
    else
        OVERLAY_CONDITION="        />"
        CONDITION_DESC="none (always active)"
    fi

    [ -z "${ANDROID_VERSION:-}" ]     && ANDROID_VERSION="14"
    [ -z "${COMPILE_SDK_VERSION:-}" ] && COMPILE_SDK_VERSION="34"
    [ -z "${MIN_SDK_VERSION:-}" ]     && MIN_SDK_VERSION="34"
    [ -z "${TARGET_SDK_VERSION:-}" ]  && TARGET_SDK_VERSION="34"

    # Module metadata: module.prop, both manifests and the hardware overlay
    # read these. Empty or still a <placeholder> falls back to the release
    # values, so a config.env written before these keys existed still builds.
    [[ -z "${OVERLAY_VERSION:-}" || "${OVERLAY_VERSION}" == *"<"* ]] && OVERLAY_VERSION="1.0"
    [[ -z "${OVERLAY_VERSION_CODE:-}" || "${OVERLAY_VERSION_CODE}" == *"<"* ]] && OVERLAY_VERSION_CODE="1"
    # Author is free text; only an empty or placeholder one is replaced.
    [[ -z "${MODULE_AUTHOR:-}" || "${MODULE_AUTHOR}" == *"<"* ]] && MODULE_AUTHOR="${DEVICE_MANUFACTURER}"

    [[ "${LIGHT_SENSOR_TYPE:-}" == *"<"* ]] && LIGHT_SENSOR_TYPE="android.sensor.light"
    [[ "${DEVICE_MODEL:-}" == *"<"* ]] && DEVICE_MODEL="Generic Device"
    # Status bar landscape height: only set fallback if explicitly a placeholder
    # (otherwise leave empty so the status bar section skips it)
    [[ "${STATUS_BAR_HEIGHT_LANDSCAPE:-}" == *"<"* ]] && STATUS_BAR_HEIGHT_LANDSCAPE=24

    return 0
}

# Does this power_profile.xml contain actual data, or is it the empty template?
power_profile_is_placeholder() {
    local f="$1"
    [ -f "$f" ] || return 0
    ! grep -qE '<item[[:space:]>]' "$f"
}

# ---------------------------------------------------------------------------
# Portable helpers
# ---------------------------------------------------------------------------
# Convert an MSYS path to a native Windows path (no-op elsewhere).
to_win_path() {
    if $IS_WINDOWS && command -v cygpath >/dev/null 2>&1; then
        cygpath -w "$1"
    else
        printf '%s' "$1"
    fi
}

# Create <dest> from the contents of <src>, using whichever zip tool exists:
# Info-ZIP (Linux/Termux), 7-Zip, or PowerShell's ZipArchive API (Windows).
create_zip() {
    local src="$1" dest="$2"
    rm -f "$dest"
    if command -v zip >/dev/null 2>&1; then
        ( cd "$src" && zip -r "$dest" . >/dev/null ) || return 1
    elif command -v 7z >/dev/null 2>&1; then
        ( cd "$src" && 7z a -tzip "$dest" . >/dev/null ) || return 1
    elif command -v powershell >/dev/null 2>&1 && [ -f "$STUFF_DIR/windows/zipdir.ps1" ]; then
        powershell -NoProfile -ExecutionPolicy Bypass \
            -File "$(to_win_path "$STUFF_DIR/windows/zipdir.ps1")" \
            -Source "$(to_win_path "$(cd "$src" && pwd)")" \
            -Dest "$(to_win_path "$dest")" >/dev/null || return 1
    else
        err "No zip tool available (install zip, 7-Zip, or re-run the build on Windows)"
        return 1
    fi
}

# Make the local toolchain visible. Windows tools are .exe files in stuff/tools/;
# on Linux the build-tools zipalign needs the bundled libc++ from lib64/.
tools_on_path() {
    case ":$PATH:" in
        *":$TOOLS_DIR:"*) ;;
        *) export PATH="$TOOLS_DIR:$PATH" ;;
    esac

    [ -d "$TOOLS_DIR" ] || return 0
    if ! $IS_WINDOWS; then
        local lib
        for lib in "$TOOLS_DIR"/android-sdk/build-tools/*/lib64; do
            [ -d "$lib" ] && [ -f "$lib/libc++.so" ] || continue
            export LD_LIBRARY_PATH="$lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
            break
        done
    fi
    return 0
}
