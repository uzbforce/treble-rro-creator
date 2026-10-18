#!/bin/bash
# =============================================================================
# Treble Overlay Creator — Build Tools Setup
# =============================================================================
# Installs aapt2, zipalign, apksigner, and framework-res.apk so you can
# build overlays. Supports multiple methods:
#
#   Method 1 — Package manager (recommended):
#     Debian/Ubuntu: sudo apt install aapt android-sdk-build-tools apksigner
#                                 android-framework-res
#
#   Method 2 — Manual download into tools/ (no root needed):
#     Script downloads aapt2 from Google Maven and guides you for the rest.
#
# Usage:
#   ./setup.sh
#
# =============================================================================

set -e

# ── Platform detection ─────────────────────────────────────────────────────
# Git Bash / MSYS2 on Windows: tools are .exe binaries, apksigner is a Java
# .bat, and there is no sudo/apt/pacman. The Windows branch downloads the
# official build-tools zip instead.
IS_WINDOWS=false
case "$(uname -s 2>/dev/null)" in
    MINGW*|MSYS*|CYGWIN*) IS_WINDOWS=true ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Launched from cmd.exe, PWD can be "C:/..." instead of "/c/..." (see build.sh)
if $IS_WINDOWS && command -v cygpath >/dev/null 2>&1; then
    SCRIPT_DIR=$(cygpath -u "$SCRIPT_DIR")
fi
cd "$SCRIPT_DIR"

TOOLS_DIR="${SCRIPT_DIR}/tools"

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'
ok()   { echo -e "  ${GREEN}✓${NC} $*"; }
info() { echo -e "  ${YELLOW}→${NC} $*"; }
warn() { echo -e "  ${YELLOW}⚠${NC} $*"; }
err()  { echo -e "  ${RED}✗${NC} $*"; }

# prompt <question> <default>  → answer in $REPLY
#
# `read` returns 1 at EOF (stdin redirected, CI, IDE task, no console). With
# `set -e` that used to kill this script silently right after the menu had
# been printed. Fall back to a default and say which one was used, so an
# unattended `setup.cmd < /dev/null` still installs the normal toolchain.
prompt() {
    local default="$2" answer=""
    printf '%s' "$1"
    if ! read -r answer; then
        echo ""
        echo -e "  ${YELLOW}→${NC} No terminal input available — using '${default}'."
        answer="$default"
    fi
    REPLY="$answer"
}

echo ""
echo -e "${BOLD}  ╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}  ║      Treble Overlay — Build Tools Setup             ║${NC}"
echo -e "${BOLD}  ╚══════════════════════════════════════════════════════╝${NC}"
echo ""

# ---------------------------------------------------------------------------
# Windows toolchain
# ---------------------------------------------------------------------------
# Git for Windows ships bash and coreutils, but no aapt2/zipalign/apksigner.
# Google's Windows build-tools zip contains all three, so one download covers
# the whole toolchain.
install_windows_tools() {
    mkdir -p "$TOOLS_DIR"

    if ! command -v unzip &>/dev/null; then
        err "unzip not found — reinstall Git for Windows (it bundles unzip)"
        return 1
    fi
    if ! command -v java &>/dev/null; then
        warn "Java not found — apksigner needs a JDK (17 or newer)."
        echo "      Install one: https://adoptium.net/"
        echo "      or:          winget install EclipseAdoptium.Temurin.17.JDK"
        echo "      Then re-run setup.cmd."
        return 1
    fi

    local tmp_zip="${TOOLS_DIR}/build-tools-win.zip"
    local api=""
    local url=""

    info "Downloading Android build-tools for Windows..."
    for api in 36 35 34; do
        # Google names these build-tools_r<API>_windows.zip
        url="https://dl.google.com/android/repository/build-tools_r${api}_windows.zip"
        info "  Trying build-tools r${api}..."
        if curl --fail -L --retry 2 "$url" -o "$tmp_zip" 2>/dev/null; then
            break
        fi
        api=""
    done

    if [ -z "$api" ]; then
        err "Could not download the Windows build-tools."
        info "Install Android SDK build-tools and add its folder to PATH, or copy"
        info "aapt2.exe and zipalign.exe into tools/ and re-run ./setup.sh."
        rm -f "$tmp_zip"
        return 1
    fi

    rm -rf "${TOOLS_DIR}/build-tools-win"
    mkdir -p "${TOOLS_DIR}/build-tools-win"
    if ! unzip -q -o "$tmp_zip" -d "${TOOLS_DIR}/build-tools-win"; then
        err "Failed to extract the build-tools archive"
        rm -f "$tmp_zip"
        return 1
    fi
    rm -f "$tmp_zip"

    local bt_dir
    bt_dir=$(ls -d "${TOOLS_DIR}/build-tools-win/"* 2>/dev/null | head -1)
    if [ -z "$bt_dir" ]; then
        err "Unexpected build-tools archive layout"
        return 1
    fi
    ok "build-tools r${api} downloaded"

    local installed=false
    for exe in aapt2.exe zipalign.exe; do
        if [ -f "${bt_dir}/${exe}" ]; then
            cp "${bt_dir}/${exe}" "${TOOLS_DIR}/${exe}"
            ok "Installed ${exe}"
            installed=true
        else
            warn "${exe} not found in the build-tools package"
        fi
    done

    # A Linux aapt2/zipalign left in tools/ by a WSL/Kali run of this script
    # would shadow the .exe installed above (same name, higher priority) and
    # break the build with "cannot execute binary file".
    local stale
    for stale in "${TOOLS_DIR}/aapt2" "${TOOLS_DIR}/zipalign"; do
        if [ -f "$stale" ] && [ "$(classify_binary "$stale")" = "linux-elf" ]; then
            rm -f "$stale"
            warn "Removed stale Linux binary ${stale#"${TOOLS_DIR}"/} (it shadowed the Windows one)"
        fi
    done

    # apksigner: bash does not resolve .bat files, so wrap the jar in a small
    # shell script — `apksigner ...` then behaves exactly like on Linux.
    if [ -f "${bt_dir}/lib/apksigner.jar" ]; then
        cp "${bt_dir}/lib/apksigner.jar" "${TOOLS_DIR}/apksigner.jar"
        cat > "${TOOLS_DIR}/apksigner" << 'APKSIGNER_EOF'
#!/bin/sh
# Generated by setup.sh — runs the build-tools apksigner jar.
here=$(cd "$(dirname "$0")" && pwd)
case "$(uname -s 2>/dev/null)" in
    MINGW*|MSYS*|CYGWIN*) here=$(cygpath -w "$here") ;;
esac
exec java -jar "$here/apksigner.jar" "$@"
APKSIGNER_EOF
        chmod +x "${TOOLS_DIR}/apksigner"
        ok "Installed apksigner (java -jar tools/apksigner.jar)"
        installed=true
    else
        warn "apksigner.jar not found in the build-tools package"
    fi

    # Everything we need is copied into tools/; drop the ~120 MB extraction.
    rm -rf "${TOOLS_DIR}/build-tools-win"

    if ! $installed; then
        return 1
    fi
    return 0
}

acquire_framework_res() {
    local force="$1"
    if [ "$force" != "force" ] && ([ -f "/usr/share/android-framework-res/framework-res.apk" ] || [ -f "${TOOLS_DIR}/framework-res.apk" ]); then
        return 0
    fi

    echo ""
    info "Almost ready! We just need framework-res.apk (the resource dictionary)."
    echo "  This file acts as a 'translator' for aapt2. Using the wrong version"
    echo "  will cause 'resource not found' errors during build."
    echo ""
    echo -e "  ${BOLD}Options to get it:${NC}"
    echo -e "    ${BOLD}[1]${NC} Download Android 13 Resources (${GREEN}STRONGLY RECOMMENDED${NC})"
    echo -e "        • Most stable for aapt2. Works for A13, A14, A15, and A16 overlays."
    echo ""
    echo -e "    ${BOLD}[2]${NC} Download Android 14"
    echo -e "    ${BOLD}[3]${NC} Download Android 15"
    echo -e "    ${BOLD}[4]${NC} Download Android 16 (Preview)"
    echo ""
    echo -e "    ${BOLD}[5]${NC} Pull from your device (${RED}NOT RECOMMENDED${NC})"
    echo -e "        • Pulled files are often 'optimized' (odex/vdex) by manufacturers"
    echo -e "        • Missing critical resource IDs — ${RED}aapt2 WILL fail${NC}."
    echo ""
    echo -e "    ${BOLD}[n]${NC} Skip for now"
    echo ""
    prompt "  Choose [1/2/3/4/5]: " "1"
    res_choice="$REPLY"

    case "$res_choice" in
        5)
            mkdir -p "${TOOLS_DIR}"
            info "Attempting to pull..."
            if cp /system/framework/framework-res.apk "${TOOLS_DIR}/framework-res.apk" 2>/dev/null; then
                ok "framework-res.apk pulled successfully"
            elif command -v su &>/dev/null && su -c "cp /system/framework/framework-res.apk \"${TOOLS_DIR}/framework-res.apk\"" 2>/dev/null; then
                ok "framework-res.apk pulled successfully (via su)"
            else
                err "Failed to pull framework-res.apk (Permission denied)"
                info "Please use one of the Download options instead."
            fi
            ;;
        1|2|3|4)
            mkdir -p "${TOOLS_DIR}"
            local sdk_ver="33" # Default 13
            [ "$res_choice" == "2" ] && sdk_ver="34"
            [ "$res_choice" == "3" ] && sdk_ver="35"
            [ "$res_choice" == "4" ] && sdk_ver="36"
            
            local tmp_zip="${TOOLS_DIR}/platform_tmp.zip"
            
            info "Downloading Android ${sdk_ver} platform resources from Google..."
            # Try different revisions until one works
            local success=false
            for rev in r08 r07 r06 r05 r04 r03 r02 r01 ""; do
                local url="https://dl.google.com/android/repository/platform-${sdk_ver}_${rev}.zip"
                url="${url%_}" # strip trailing underscore if rev is empty
                info "  Trying ${url}..."
                if curl --fail -L "$url" -o "$tmp_zip" 2>/dev/null; then
                    success=true
                    break
                fi
            done

            if [ "$success" = "true" ]; then
                info "Extracting android.jar from platform zip..."
                unzip -j -o "$tmp_zip" "*/android.jar" -d "${TOOLS_DIR}/" 2>/dev/null || { err "Extraction failed"; rm -f "$tmp_zip"; return 1; }
                
                if [ ! -f "${TOOLS_DIR}/android.jar" ]; then
                    err "unzip succeeded but android.jar was not found in the zip!"
                    rm -f "$tmp_zip"
                    return 1
                fi

                info "Renaming and cleaning up..."
                mv "${TOOLS_DIR}/android.jar" "${TOOLS_DIR}/framework-res.apk"
                rm -f "$tmp_zip"
                ok "Android ${sdk_ver} resources installed to tools/framework-res.apk ($(du -sh "${TOOLS_DIR}/framework-res.apk" | cut -f1))"
            else
                err "Download failed for all revisions! Google might have moved the files."
                info "Try pulling from your device or manual download."
                return 1
            fi
            ;;
    esac
}

# ─────────────────────────────────────────────────────────────────────────
# Binary platform detection
# ─────────────────────────────────────────────────────────────────────────
# Windows cannot run Linux binaries. If this checkout is also opened from
# WSL/Kali (the repo lives on C:, so tools/ is shared), a Linux `aapt2` lands in
# the same folder the Windows build puts on PATH, shadows `aapt2.exe`, and the
# build dies later with "cannot execute binary file: Exec format error".
# Everything below classifies files by magic bytes so that is caught up front.
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
        *)          echo "$1" ;;
    esac
}

# A native binary built for the OTHER platform. This is the real contamination
# signal: scripts, jars and apks are fine to share between Windows and WSL,
# executables are not.
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

# ─────────────────────────────────────────────────────────────────────────
# Doctor — verify the toolchain actually works on THIS platform
# ─────────────────────────────────────────────────────────────────────────
# Run: setup.sh --doctor  (or setup.cmd --doctor on Windows)
# Read-only: never installs anything, exits 0 when a build should work.
check_runs() {
    local label="$1"; shift
    local out rc=0
    out=$("$@" 2>&1) || rc=$?
    if printf '%s' "$out" | grep -qiE 'cannot execute binary file|exec format error|not a valid win32|bad cpu type';
    then
        printf '    %-22s ✗ %s\n' "$label" "$(printf '%s' "$out" | head -1 | cut -c1-70)"
        return 1
    fi
    printf '    %-22s ✓ ran\n' "$label"
    if [ "$rc" -ne 0 ]; then
        printf '    %-22s   (exit %s — normal for tools without arguments)\n' "" "$rc"
    fi
    return 0
}

run_doctor() {
    local problems=0 t cand kind usable bad

    echo ""
    echo -e "${BOLD}  ╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}  ║         Toolchain check (setup.sh --doctor)          ║${NC}"
    echo -e "${BOLD}  ╚══════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${BOLD}Environment${NC}"
    printf '    %-12s %s\n' "Shell:" "$(uname -s 2>/dev/null || echo unknown)  (MSYSTEM=${MSYSTEM:-unset})"
    if $IS_WINDOWS; then printf '    %-12s %s\n' "Platform:" "Windows (Git Bash / MSYS2)"
    else printf '    %-12s %s\n' "Platform:" "Linux / Termux"; fi
    printf '    %-12s %s\n' "Project:" "${SCRIPT_DIR}"
    printf '    %-12s %s\n' "Tools dir:" "${TOOLS_DIR}"
    echo ""
    echo -e "  ${BOLD}Tools${NC}"

    for t in aapt2 zipalign apksigner; do
        usable=""; bad=""
        while IFS= read -r cand; do
            [ -n "$cand" ] || continue
            kind=$(classify_binary "$cand")
            if kind_usable "$kind"; then
                [ -z "$usable" ] && usable="$cand"
            else
                bad="${bad}${cand} [$(kind_label "$kind")] "
            fi
        done <<< "$(tool_candidates "$t")"

        if [ -n "$usable" ]; then
            printf '    %-12s ✓ %s  [%s]\n' "$t" "$usable" "$(kind_label "$(classify_binary "$usable")")"
            if [ -n "$bad" ]; then
                printf '    %-12s   ⚠ shadows it, cannot run here: %s\n' "" "$bad"
                problems=$((problems + 1))
            fi
        elif [ -n "$bad" ]; then
            printf '    %-12s ✗ only unusable copies: %s\n' "$t" "$bad"
            problems=$((problems + 1))
        else
            printf '    %-12s ✗ not found\n' "$t"
            problems=$((problems + 1))
        fi
    done

    # Resource dictionary
    local res=""
    for cand in "${TOOLS_DIR}/framework-res.apk" "/usr/share/android-framework-res/framework-res.apk"; do
        [ -f "$cand" ] && { res="$cand"; break; }
    done
    if [ -n "$res" ]; then
        printf '    %-12s ✓ %s  [%s]\n' "framework" "$res" "$(kind_label "$(classify_binary "$res")")"
    else
        printf '    %-12s ✗ not found — run setup to download it\n' "framework"
        problems=$((problems + 1))
    fi

    # java (apksigner needs it)
    local jpath
    jpath=$(command -v java 2>/dev/null || true)
    if [ -n "$jpath" ]; then
        printf '    %-12s ✓ %s  [%s]\n' "java" "$jpath" "$(kind_label "$(classify_binary "$jpath")")"
    else
        printf '    %-12s ✗ not found — apksigner will fail\n' "java"
        problems=$((problems + 1))
    fi

    echo ""
    echo -e "  ${BOLD}Do they actually run here?${NC}"
    local rbin
    for t in aapt2 zipalign apksigner; do
        rbin=""
        while IFS= read -r cand; do
            [ -n "$cand" ] || continue
            kind_usable "$(classify_binary "$cand")" && { rbin="$cand"; break; }
        done <<< "$(tool_candidates "$t")"
        [ -n "$rbin" ] || continue
        case "$t" in
            aapt2)     check_runs "$t version" "$rbin" version || problems=$((problems + 1)) ;;
            zipalign)  check_runs "$t" "$rbin" || problems=$((problems + 1)) ;;
            apksigner) check_runs "$t --version" "$rbin" --version || problems=$((problems + 1)) ;;
        esac
    done

    echo ""
    echo -e "  ${BOLD}Contamination check${NC}"
    local found_foreign=false f fkind
    # Binaries for the other platform sitting in tools/ (typical of a
    # WSL/Kali setup.sh run on this same checkout). Only native executables
    # matter here — scripts, jars and the apk are shared safely.
    for f in "${TOOLS_DIR}"/*; do
        [ -f "$f" ] || continue
        fkind=$(classify_binary "$f")
        if kind_foreign "$fkind"; then
            printf '    ⚠ %s is a %s — cannot run here\n' "${f#"${TOOLS_DIR}"/}" "$(kind_label "$fkind")"
            printf '      remove it:  rm -f "%s"\n' "$f"
            found_foreign=true
        fi
    done
    # PATH entries pointing at a WSL filesystem
    while IFS= read -r cand; do
        case "$cand" in
            //wsl\$/*|*wsl.localhost*)
                printf '    ⚠ PATH contains a WSL path: %s\n' "$cand"
                found_foreign=true ;;
        esac
    done <<< "$(printf '%s' "$PATH" | tr ':' '\n')"
    if [ "$found_foreign" = "false" ]; then
        ok "No Linux/WSL binaries in the toolchain, no WSL paths on PATH"
    else
        problems=$((problems + 1))
    fi

    echo ""
    if [ "$problems" -eq 0 ]; then
        ok "Toolchain is correct for this platform — ./build.sh will work."
        echo ""
        return 0
    fi
    err "${problems} problem(s) found."
    echo "    Windows fix:  setup.cmd   (installs the Windows build-tools, removes Linux leftovers)"
    echo "    Then re-run:  setup.cmd --doctor"
    echo ""
    return 1
}

# ─────────────────────────────────────────────────────────────────────────
# Handle --doctor / --help before anything else
# ─────────────────────────────────────────────────────────────────────────
DOCTOR_MODE=false
for arg in "$@"; do
    case "$arg" in
        --doctor) DOCTOR_MODE=true ;;
        -h|--help)
            echo ""
            echo "  Usage: ./setup.sh [--doctor]"
            echo "    --doctor   Verify the toolchain without installing anything"
            echo ""
            exit 0 ;;
    esac
done

if $DOCTOR_MODE; then
    if run_doctor; then exit 0; else exit 1; fi
fi

# ─────────────────────────────────────────────────────────────────────────
# Step 1: Check what's already available
# ─────────────────────────────────────────────────────────────────────────
echo -e "${BOLD}  Checking available tools...${NC}"
echo ""

MISSING=""

# Is this tool usable HERE (PATH or tools/, .exe/.bat on Windows)?
# A file that exists but cannot run on this platform (a Linux ELF on Windows)
# does NOT count — that is the WSL/shared-tools trap this project hit before.
tool_ready() {
    local name="$1" cand
    while IFS= read -r cand; do
        [ -n "$cand" ] || continue
        kind_usable "$(classify_binary "$cand")" && return 0
    done <<< "$(tool_candidates "$name")"
    return 1
}

check_tool() {
    local name="$1" cand kind
    while IFS= read -r cand; do
        [ -n "$cand" ] || continue
        kind=$(classify_binary "$cand")
        if kind_usable "$kind"; then
            ok "$name found: $cand [$(kind_label "$kind")]"
            return 0
        fi
        warn "$name at $cand is a $(kind_label "$kind") — cannot run here, ignoring"
    done <<< "$(tool_candidates "$name")"
    if [ -d "/opt/android-sdk/build-tools" ]; then
        # Arch Linux /opt/android-sdk support
        local sdk_tool
        sdk_tool=$(find /opt/android-sdk/build-tools \( -name "$name" -o -name "$name.exe" \) -type f | sort -V | tail -n 1)
        if [ -n "$sdk_tool" ]; then
            ok "$name found in /opt/android-sdk: $sdk_tool"
            mkdir -p "$TOOLS_DIR"
            ln -sf "$sdk_tool" "${TOOLS_DIR}/${name}"
            return 0
        fi
    fi
    err "$name not found"
    MISSING="$MISSING $name"
    return 1
}

check_tool aapt2 || true
check_tool zipalign || true
check_tool apksigner || true

# apksigner is a Java program. Without a JDK the files are all present but
# signing fails, so it counts as a missing tool here — otherwise a fresh
# machine is told "all tools available" and dies later inside the build.
if command -v java &>/dev/null; then
    ok "java found: $(command -v java)"
else
    if $IS_WINDOWS; then
        err "java not found — apksigner needs a JDK 17+ (winget install EclipseAdoptium.Temurin.17.JDK)"
    else
        err "java not found — apksigner needs a JDK 17+ (e.g. sudo apt install openjdk-17-jdk)"
    fi
    MISSING="$MISSING java"
fi

# Check framework-res.apk
if [ -f "/usr/share/android-framework-res/framework-res.apk" ]; then
    ok "framework-res.apk found at /usr/share/android-framework-res/framework-res.apk"
elif [ -f "${TOOLS_DIR}/framework-res.apk" ]; then
    ok "framework-res.apk found in tools/"
elif [ -d "/opt/android-sdk/platforms" ]; then
    # Arch Linux platform support
    sdk_res=$(find /opt/android-sdk/platforms -name "framework-res.apk" | head -n 1)
    if [ -n "$sdk_res" ]; then
        ok "framework-res.apk found in /opt/android-sdk: $sdk_res"
        mkdir -p "$TOOLS_DIR"
        ln -sf "$sdk_res" "${TOOLS_DIR}/framework-res.apk"
    else
        err "framework-res.apk not found"
        MISSING="$MISSING framework-res.apk"
    fi
else
    err "framework-res.apk not found"
    MISSING="$MISSING framework-res.apk"
fi

if [ -z "$MISSING" ]; then
    echo ""
    ok "All tools are available! You're ready to build."
    echo ""
    echo "  Run: ./build.sh"
    echo ""
    exit 0
fi

# ─────────────────────────────────────────────────────────────────────────
# Step 2: Choose your environment
# ─────────────────────────────────────────────────────────────────────────
echo ""
echo -e "  ${BOLD}Choose your environment to install dependencies:${NC}"
echo -e "    ${BOLD}[1]${NC} Debian / Ubuntu / Linux Mint (uses apt)"
echo -e "    ${BOLD}[2]${NC} Arch Linux / Manjaro (uses pacman)"
echo -e "    ${BOLD}[3]${NC} Android (uses Termux pkg)"
echo -e "    ${BOLD}[4]${NC} Skip (Manual / Other)"
if $IS_WINDOWS; then
    echo -e "    ${BOLD}[5]${NC} Windows (Git Bash / MSYS2) — download build-tools  ${GREEN}<-- use this${NC}"
else
    echo -e "    ${BOLD}[5]${NC} Windows (Git Bash / MSYS2) — download build-tools"
fi
echo ""
if $IS_WINDOWS; then ENV_DEFAULT="5"; else ENV_DEFAULT="4"; fi
prompt "  Selection [1/2/3/4/5]: " "$ENV_DEFAULT"
env_choice="$REPLY"

case "$env_choice" in
    1)
        info "Debian/Ubuntu selected."
        info "Running: sudo apt update && sudo apt install -y \\"
        echo "         aapt android-sdk-build-tools apksigner android-framework-res zip"
        echo ""
        sudo apt update
        sudo apt install -y aapt android-sdk-build-tools apksigner android-framework-res zip

        # Re-check tools
        check_tool aapt2 || true
        check_tool zipalign || true
        check_tool apksigner || true

        # Force resource menu so user can pick Android 14/15/16
        acquire_framework_res force
        
        if command -v aapt2 &>/dev/null && command -v zipalign &>/dev/null && \
           command -v apksigner &>/dev/null && ([ -f "/usr/share/android-framework-res/framework-res.apk" ] || [ -f "${TOOLS_DIR}/framework-res.apk" ]); then
            echo ""
            ok "All tools and resources ready! Ready to build."
            echo ""
            echo "  Run: ./build.sh"
            echo ""
            exit 0
        fi
        ;;
    2)
        info "Arch Linux selected."
        info "Running: sudo pacman -S --needed android-tools jdk-openjdk zip"
        echo ""
        sudo pacman -S --needed android-tools jdk-openjdk zip

        # Re-check what's now available
        echo ""
        echo -e "${BOLD}  Verifying installation...${NC}"
        echo ""
        check_tool aapt2 || true
        check_tool zipalign || true
        check_tool apksigner || true

        acquire_framework_res force

        if command -v aapt2 &>/dev/null && command -v zipalign &>/dev/null && \
           command -v apksigner &>/dev/null; then
            # (Double check resources inside acquire_framework_res logic)
            if [ -f "/usr/share/android-framework-res/framework-res.apk" ] || [ -f "${TOOLS_DIR}/framework-res.apk" ]; then
                echo ""
                ok "All tools and resources ready! Ready to build."
                echo ""
                echo "  Run: ./build.sh"
                echo ""
                exit 0
            fi
        fi
        ;;
    3)
        info "Termux selected."
        info "Running: pkg install aapt2 apksigner android-tools openjdk-17 unzip zip curl tsu"
        echo ""

        # Try install — using `if` so `set -e` doesn't kill the script on failure
        TERMUX_PKG_OK=false
        if pkg install aapt2 apksigner android-tools openjdk-17 unzip zip curl tsu; then
            TERMUX_PKG_OK=true
            ok "Packages installed successfully"
        else
            warn "Package installation failed — this is often a repository mirror issue."
            echo ""
            echo -e "  ${YELLOW}Would you like to change the Termux repository mirror?${NC}"
            echo ""
            echo -e "    ${BOLD}[1]${NC} Run termux-change-repo (${GREEN}recommended${NC} — interactive mirror selector)"
            echo -e "        Launches a TUI where you pick a mirror close to your region."
            echo ""
            echo -e "    ${BOLD}[2]${NC} Set a known working mirror (Albatross — fast CDN)"
            echo -e "        Automatically configures a reliable mirror without interaction."
            echo ""
            echo -e "    ${BOLD}[3]${NC} Skip — I'll fix it manually"
            echo -e "        Shows manual commands to run later."
            echo ""
            prompt "  Choose [1/2/3]: " "3"
            repo_choice="$REPLY"

            case "$repo_choice" in
                1)
                    echo ""
                    info "Launching termux-change-repo..."
                    info "Use arrow keys to navigate, SPACE to select, ENTER to confirm."
                    info "Choose a mirror close to your region (e.g., Albatross, Grimler, etc.)"
                    echo ""
                    termux-change-repo
                    echo ""
                    info "Updating package lists..."
                    apt update
                    echo ""
                    info "Retrying package installation..."
                    if pkg install aapt2 apksigner android-tools openjdk-17 unzip zip curl tsu; then
                        TERMUX_PKG_OK=true
                        ok "Packages installed successfully after repo change"
                    else
                        warn "Installation still failed. Try selecting a different mirror and re-run ./setup.sh"
                    fi
                    ;;
                2)
                    echo ""
                    info "Setting Albatross CDN mirror..."
                    # Termux stores sources in $PREFIX/etc/apt/sources.list
                    SOURCES_FILE="${PREFIX}/etc/apt/sources.list"
                    if [ -f "$SOURCES_FILE" ]; then
                        # Comment out existing repo and add Albatross mirror
                        sed -i 's|^deb |#deb |' "$SOURCES_FILE" 2>/dev/null || true
                        echo "deb https://packages.termux.org/apt/termux-main termux-main" >> "$SOURCES_FILE"
                        ok "Mirror set to Albatross CDN"
                    else
                        # Fallback: write a fresh sources.list
                        mkdir -p "$(dirname "$SOURCES_FILE")" 2>/dev/null || true
                        echo "deb https://packages.termux.org/apt/termux-main termux-main" > "$SOURCES_FILE" 2>/dev/null || true
                        ok "Created sources.list with Albatross CDN mirror"
                    fi
                    echo ""
                    info "Updating package lists..."
                    apt update
                    echo ""
                    info "Retrying package installation..."
                    if pkg install aapt2 apksigner android-tools openjdk-17 unzip zip curl tsu; then
                        TERMUX_PKG_OK=true
                        ok "Packages installed successfully after mirror change"
                    else
                        warn "Installation still failed. Try option [1] (termux-change-repo) instead."
                    fi
                    ;;
                *)
                    echo ""
                    info "Skipping repo change. To fix manually:"
                    echo "     1. Run: termux-change-repo"
                    echo "     2. Select a mirror close to your region"
                    echo "     3. Run: apt update"
                    echo "     4. Run: pkg install aapt2 apksigner android-tools openjdk-17 unzip zip curl tsu"
                    echo "     5. Re-run: ./setup.sh"
                    ;;
            esac
        fi

        # Re-check what's now available
        echo ""
        echo -e "${BOLD}  Verifying installation...${NC}"
        echo ""
        check_tool aapt2 || true
        check_tool zipalign || true
        check_tool apksigner || true

        acquire_framework_res force

        if [ "$TERMUX_PKG_OK" = "true" ] && command -v aapt2 &>/dev/null && command -v zipalign &>/dev/null && \
           command -v apksigner &>/dev/null && ([ -f "/usr/share/android-framework-res/framework-res.apk" ] || [ -f "${TOOLS_DIR}/framework-res.apk" ]); then
            echo ""
            ok "All tools ready in Termux! Ready to build."
            echo ""
            echo "  Run: ./build.sh"
            echo ""
            exit 0
        fi
        ;;
    5)
        if ! $IS_WINDOWS; then
            warn "This option installs the Windows build-tools."
            warn "On this machine, pick the option matching your OS instead."
        else
            # Stop here if the install itself failed. Carrying on used to leave
            # half a toolchain (aapt2 only) and then die at the next prompt
            # with no explanation.
            if ! install_windows_tools; then
                echo ""
                err "The Windows toolchain was not installed."
                echo "    Fix the problem reported above (usually a missing JDK), then re-run:"
                echo "      setup.cmd"
                echo "    Check the result without installing anything:"
                echo "      setup.cmd --doctor"
                echo ""
                exit 1
            fi

            echo ""
            echo -e "${BOLD}  Verifying installation...${NC}"
            echo ""
            check_tool aapt2 || true
            check_tool zipalign || true
            check_tool apksigner || true

            acquire_framework_res force

            if tool_ready aapt2 && tool_ready zipalign && tool_ready apksigner && \
               { [ -f "${TOOLS_DIR}/framework-res.apk" ] || [ -f "/usr/share/android-framework-res/framework-res.apk" ]; }; then
                echo ""
                ok "All tools and resources ready! Ready to build."
                echo ""
                echo "  Run: ./build.sh    (or build.cmd on Windows)"
                echo ""
                exit 0
            fi
        fi
        ;;
    *)
        info "Skipping package manager installation."
        ;;
esac

# ─────────────────────────────────────────────────────────────────────────
# Step 3: Manual download into tools/
# ─────────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}  Manual download into tools/ directory${NC}"
echo ""

mkdir -p "${TOOLS_DIR}"

# --- aapt2 ---
if ! tool_ready aapt2; then
    echo ""
    info "Downloading aapt2 from Google Maven..."
    echo ""

    # Get latest version from Maven metadata
    AAPT2_VERSION=$(curl -sL "https://dl.google.com/dl/android/maven2/com/android/tools/build/aapt2/maven-metadata.xml" \
        | grep -oP '<release>\K[^<]+' || echo "")

    if [ -z "$AAPT2_VERSION" ]; then
        # Fallback to known working version
        AAPT2_VERSION="9.3.0-alpha07-15228143"
        info "Could not determine latest version, using: ${AAPT2_VERSION}"
    else
        ok "Latest aapt2 version: ${AAPT2_VERSION}"
    fi

    echo ""
    echo -e "  ${YELLOW}Downloading...${NC}"

    # Google publishes per-platform jars: -linux.jar or -windows.jar
    AAPT2_OS="linux"
    $IS_WINDOWS && AAPT2_OS="windows"
    AAPT2_URL="https://dl.google.com/dl/android/maven2/com/android/tools/build/aapt2/${AAPT2_VERSION}/aapt2-${AAPT2_VERSION}-${AAPT2_OS}.jar"
    curl -sL "$AAPT2_URL" -o /tmp/aapt2-download.jar

    # Extract only the native binary. The jar also ships META-INF/ and NOTICE,
    # which would otherwise litter tools/.
    cd "${TOOLS_DIR}"
    # A Kali/WSL run may have left an extensionless aapt2 here. On Windows that
    # file shadows aapt2.exe, so drop both spellings before extracting the
    # fresh one (MSYS resolves the bare name to the .exe, hence the pair).
    rm -f "${TOOLS_DIR}/aapt2" "${TOOLS_DIR}/aapt2.exe"
    unzip -o /tmp/aapt2-download.jar "aapt2.exe" 2>/dev/null \
        || unzip -o /tmp/aapt2-download.jar "aapt2" 2>/dev/null \
        || true
    chmod +x "${TOOLS_DIR}/aapt2" 2>/dev/null || true
    rm -f /tmp/aapt2-download.jar
    cd "${SCRIPT_DIR}"

    if [ -f "${TOOLS_DIR}/aapt2" ] || [ -f "${TOOLS_DIR}/aapt2.exe" ]; then
        ok "aapt2 installed to tools/"
    else
        err "Failed to extract aapt2 from JAR"
    fi
fi

# --- zipalign & apksigner (via Android SDK command-line tools) ---
if ! tool_ready zipalign; then
    echo ""
    info "zipalign not found."

    # Windows: one download provides aapt2.exe, zipalign.exe and apksigner
    if $IS_WINDOWS; then
        install_windows_tools || true
    # Otherwise Java is required for the sdkmanager route
    elif command -v java &>/dev/null; then
        echo -e "  ${YELLOW}→${NC} Java found — can use Android SDK command-line tools to get zipalign + apksigner."
        echo ""

        if [ ! -d "${TOOLS_DIR}/cmdline-tools" ]; then
            echo -e "  ${YELLOW}Downloading Android command-line tools...${NC}"
            curl -sL "https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip" \
                -o /tmp/cmdline-tools.zip
            unzip -q /tmp/cmdline-tools.zip -d "${TOOLS_DIR}/"
            rm -f /tmp/cmdline-tools.zip
            ok "Command-line tools downloaded"
        fi

        SDKMANAGER="${TOOLS_DIR}/cmdline-tools/bin/sdkmanager"

        if [ -f "$SDKMANAGER" ]; then
            echo "  Installing build-tools (requires accepting license)..."
            echo ""
            echo -e "  ${YELLOW}You may need to accept the Android SDK license.${NC}"
            echo -e "  ${YELLOW}Type 'y' when prompted.${NC}"
            echo ""
            yes | "$SDKMANAGER" --sdk_root="${TOOLS_DIR}/android-sdk" "build-tools;35.0.0" 2>/dev/null || \
                "$SDKMANAGER" --sdk_root="${TOOLS_DIR}/android-sdk" "build-tools;35.0.0" || true

            # Find installed build-tools
            BT_DIR=$(ls -d "${TOOLS_DIR}/android-sdk/build-tools/"* 2>/dev/null | head -1)
            if [ -n "$BT_DIR" ]; then
                for bt_tool in zipalign apksigner; do
                    if [ -f "${BT_DIR}/${bt_tool}" ]; then
                        ln -sf "${BT_DIR}/${bt_tool}" "${TOOLS_DIR}/${bt_tool}" 2>/dev/null || \
                            cp "${BT_DIR}/${bt_tool}" "${TOOLS_DIR}/" 2>/dev/null || true
                        chmod +x "${TOOLS_DIR}/${bt_tool}" 2>/dev/null || true
                    fi
                done
                ok "zipalign and apksigner installed from build-tools"

                # Also try to get framework-res.apk from platforms
                echo "  Installing platform SDK for framework-res.apk..."
                yes | "$SDKMANAGER" --sdk_root="${TOOLS_DIR}/android-sdk" "platforms;android-35" 2>/dev/null || true
                PLATFORM_DIR=$(ls -d "${TOOLS_DIR}/android-sdk/platforms/"* 2>/dev/null | head -1)
                if [ -n "$PLATFORM_DIR" ] && [ -f "${PLATFORM_DIR}/data/res/framework-res.apk" ]; then
                    cp "${PLATFORM_DIR}/data/res/framework-res.apk" "${TOOLS_DIR}/"
                    ok "framework-res.apk extracted from platform SDK"
                fi
            else
                info "Build-tools installation may have been skipped or failed."
                info "Try running manually: ${SDKMANAGER} --sdk_root=\"${TOOLS_DIR}/android-sdk\" \"build-tools;35.0.0\""
            fi
        fi
    else
        echo -e "  ${YELLOW}→${NC} Java not found, so sdkmanager won't work."
        echo -e "  ${YELLOW}→${NC} Option 1: Install Java, then re-run setup.sh"
        echo -e "  ${YELLOW}→${NC} Option 2: Install via your distro's package manager"
        echo ""
        if command -v pacman &>/dev/null; then
            echo "    Arch:       sudo pacman -S jdk17-openjdk android-tools"
        elif command -v dnf &>/dev/null; then
            echo "    Fedora:     sudo dnf install java-17-openjdk"
        elif command -v brew &>/dev/null; then
            echo "    macOS:      brew install openjdk"
        fi
        echo ""
        info "Then re-run ./setup.sh"
    fi
fi

# --- framework-res.apk fallback ---
acquire_framework_res

# ─────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}  ╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}  ║                  Setup Complete                     ║${NC}"
echo -e "${BOLD}  ╚══════════════════════════════════════════════════════╝${NC}"
echo ""

FINAL_MISSING=""
tool_ready aapt2 || FINAL_MISSING="$FINAL_MISSING aapt2"
tool_ready zipalign || FINAL_MISSING="$FINAL_MISSING zipalign"
tool_ready apksigner || FINAL_MISSING="$FINAL_MISSING apksigner"
command -v java &>/dev/null || FINAL_MISSING="$FINAL_MISSING java"
[ -f "/usr/share/android-framework-res/framework-res.apk" ] || [ -f "${TOOLS_DIR}/framework-res.apk" ] || FINAL_MISSING="$FINAL_MISSING framework-res.apk"

if [ -z "$FINAL_MISSING" ]; then
    ok "All tools ready!"
    echo ""
    echo "  Run: ./build.sh"
    echo ""
else
    # Non-zero so scripts (and the user) can tell this did not finish.
    echo -e "  ${YELLOW}Setup incomplete — still missing:${NC}$FINAL_MISSING"
    echo ""
    echo "  See vendor_extraction_guide.md for detailed instructions."
    echo "  Or re-run: ./setup.sh"
    echo "  Or check what is wrong: ./setup.sh --doctor"
    echo ""
    exit 1
fi
