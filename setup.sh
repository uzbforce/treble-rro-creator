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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

TOOLS_DIR="${SCRIPT_DIR}/tools"

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'
ok()   { echo -e "  ${GREEN}✓${NC} $*"; }
info() { echo -e "  ${YELLOW}→${NC} $*"; }
err()  { echo -e "  ${RED}✗${NC} $*"; }

echo ""
echo -e "${BOLD}  ╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}  ║      Treble Overlay — Build Tools Setup             ║${NC}"
echo -e "${BOLD}  ╚══════════════════════════════════════════════════════╝${NC}"
echo ""

acquire_framework_res() {
    local force="$1"
    if [ "$force" != "force" ] && ([ -f "/usr/share/android-framework-res/framework-res.apk" ] || [ -f "${TOOLS_DIR}/framework-res.apk" ]); then
        return 0
    fi

    echo ""
    info "Almost ready! We just need framework-res.apk (the resource dictionary)."
    echo "  Options to get it:"
    echo -e "    ${BOLD}[1]${NC} Download Android 13 Resources (${GREEN}Recommended${NC})"
    echo -e "    ${BOLD}[2]${NC} Download Android 14"
    echo -e "    ${BOLD}[3]${NC} Download Android 15"
    echo -e "    ${BOLD}[4]${NC} Download Android 16 (Preview)"
    echo -e "    ${BOLD}[5]${NC} Pull from your device (${YELLOW}Often fails / missing resources${NC})"
    echo -e "    ${BOLD}[n]${NC} Skip for now"
    echo ""
    read -r -p "  Choose [1/2/3/4/5]: " res_choice

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
# Step 1: Check what's already available
# ─────────────────────────────────────────────────────────────────────────
echo -e "${BOLD}  Checking available tools...${NC}"
echo ""

MISSING=""

check_tool() {
    local name="$1"
    if command -v "$name" &>/dev/null; then
        local path
        path=$(command -v "$name")
        ok "$name found in PATH: $path"
        return 0
    elif [ -x "${TOOLS_DIR}/${name}" ]; then
        ok "$name found in tools/"
        return 0
    elif [ -d "/opt/android-sdk/build-tools" ]; then
        # Arch Linux /opt/android-sdk support
        local sdk_tool
        sdk_tool=$(find /opt/android-sdk/build-tools -name "$name" -type f -executable | sort -V | tail -n 1)
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

# Check framework-res.apk
if [ -f "/usr/share/android-framework-res/framework-res.apk" ]; then
    ok "framework-res.apk found at /usr/share/android-framework-res/framework-res.apk"
elif [ -f "${TOOLS_DIR}/framework-res.apk" ]; then
    ok "framework-res.apk found in tools/"
elif [ -d "/opt/android-sdk/platforms" ]; then
    # Arch Linux platform support
    local sdk_res
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
echo ""
read -r -p "  Selection [1/2/3/4]: " env_choice

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
        pkg install aapt2 apksigner android-tools openjdk-17 unzip zip curl tsu

        # Re-check what's now available
        echo ""
        echo -e "${BOLD}  Verifying installation...${NC}"
        echo ""
        check_tool aapt2 || true
        check_tool zipalign || true
        check_tool apksigner || true

        acquire_framework_res force

        if command -v aapt2 &>/dev/null && command -v zipalign &>/dev/null && \
           command -v apksigner &>/dev/null && ([ -f "/usr/share/android-framework-res/framework-res.apk" ] || [ -f "${TOOLS_DIR}/framework-res.apk" ]); then
            echo ""
            ok "All tools ready in Termux! Ready to build."
            echo ""
            echo "  Run: ./build.sh"
            echo ""
            exit 0
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
if ! command -v aapt2 &>/dev/null && ! [ -x "${TOOLS_DIR}/aapt2" ]; then
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

    AAPT2_URL="https://dl.google.com/dl/android/maven2/com/android/tools/build/aapt2/${AAPT2_VERSION}/aapt2-${AAPT2_VERSION}-linux.jar"
    curl -sL "$AAPT2_URL" -o /tmp/aapt2-download.jar

    # Extract aapt2 binary from the JAR (which is a ZIP containing the native binary)
    cd "${TOOLS_DIR}"
    unzip -o /tmp/aapt2-download.jar aapt2 2>/dev/null || {
        # Some versions may have different structure
        unzip -o /tmp/aapt2-download.jar 2>/dev/null
    }
    chmod +x "${TOOLS_DIR}/aapt2" 2>/dev/null || true
    rm -f /tmp/aapt2-download.jar
    cd "${SCRIPT_DIR}"

    if [ -x "${TOOLS_DIR}/aapt2" ]; then
        ok "aapt2 installed to tools/ ($(du -sh "${TOOLS_DIR}/aapt2" | cut -f1))"
    else
        err "Failed to extract aapt2 from JAR"
    fi
fi

# --- zipalign & apksigner (via Android SDK command-line tools) ---
if ! command -v zipalign &>/dev/null && ! [ -x "${TOOLS_DIR}/zipalign" ]; then
    echo ""
    info "zipalign not found."

    # Check if Java is available for sdkmanager
    if command -v java &>/dev/null; then
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
command -v aapt2 &>/dev/null || [ -x "${TOOLS_DIR}/aapt2" ] || FINAL_MISSING="$FINAL_MISSING aapt2"
command -v zipalign &>/dev/null || [ -x "${TOOLS_DIR}/zipalign" ] || FINAL_MISSING="$FINAL_MISSING zipalign"
command -v apksigner &>/dev/null || [ -x "${TOOLS_DIR}/apksigner" ] || FINAL_MISSING="$FINAL_MISSING apksigner"
[ -f "/usr/share/android-framework-res/framework-res.apk" ] || [ -f "${TOOLS_DIR}/framework-res.apk" ] || FINAL_MISSING="$FINAL_MISSING framework-res.apk"

if [ -z "$FINAL_MISSING" ]; then
    ok "All tools ready!"
    echo ""
    echo "  Run: ./build.sh"
    echo ""
else
    echo -e "  ${YELLOW}Still missing:${NC}$FINAL_MISSING"
    echo ""
    echo "  See vendor_extraction_guide.md for detailed instructions."
    echo "  Or re-run: ./setup.sh"
    echo ""
fi
