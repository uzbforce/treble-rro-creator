#!/usr/bin/env bash
# =============================================================================
# Treble Overlay — build implementation
# =============================================================================
# Executed by the root build.sh, which loads stuff/scripts/common.sh and
# stuff/scripts/toolchain.sh first and guarantees the toolchain is ready.
#
# Set by build.sh:  ROOT, TOOLS_DIR, BUILD_DIR, OUT_DIR, CHECK_MODE,
#                   ASSUME_YES, FORCE_VENDOR_HALS
# Edited by you:    config.env
#                   src/framework/res      framework overlay resources
#                   src/systemui/res       SystemUI overlay resources
#                   src/module/            customize.sh / service.sh / sepolicy.rule
#                   src/vendor/            optional vendor HAL files
#                   stuff/keys/            signing key + certificate
#
# Output:           out/apks/*.apk          signed overlays
#                   out/*.zip              flashable module + repo sources
# =============================================================================

if [ -z "${ROOT:-}" ]; then
    echo "This is an internal build module — run ./build.sh instead." >&2
    exit 1
fi

cd "$ROOT" || exit 1

# Relative paths: native aapt2/zipalign on Windows may not open /c/... paths.
RES_DIR="${FRAMEWORK_RES#"$ROOT"/}"
SYSUI_RES_DIR="${SYSTEMUI_RES#"$ROOT"/}"
MODULE_SRC_REL="${MODULE_DIR#"$ROOT"/}"
VENDOR_SRC_REL="${VENDOR_DIR#"$ROOT"/}"
BUILD_REL="${BUILD_DIR#"$ROOT"/}"
: "${DRY_RUN:=false}"

# Generators used by the build steps below.
source "$ROOT/stuff/scripts/resources.sh"
source "$ROOT/stuff/scripts/module.sh"
source "$ROOT/stuff/scripts/manifest.sh"
source "$ROOT/stuff/scripts/validate.sh"
source "$ROOT/stuff/scripts/hardware-overlay.sh"

# Never die silently: an unexpected `set -e` abort says where and why.
trap 'err "Unexpected failure at line ${LINENO}: ${BASH_COMMAND}"; err "Re-run with: bash -x ./build.sh  and report the last lines"' ERR

# Ask something without ever aborting the build. When stdin is not an
# interactive terminal (IDE task, CI, launcher without a console, piped input)
# `read` fails — under `set -e` that used to kill the script mid-run.
ASK_REPLY=""
ask_reply() {
    local prompt="$1"
    ASK_REPLY=""
    $ASSUME_YES && return 0
    if ! read -r -p "$prompt" ASK_REPLY; then
        ASK_REPLY=""
        info "No terminal input available — using the default answer."
    fi
    return 0
}

# Run a build command, indent its output, and abort with a clear message if it
# fails. (A pipeline would report sed's status, not the tool's.)
run_or_die() {
    local label="$1"; shift
    local log="${TMPDIR:-/tmp}/treble-build.$$.log"
    if "$@" >"$log" 2>&1; then
        [ -s "$log" ] && sed 's/^/  /' "$log"
        rm -f "$log"
        return 0
    fi
    [ -s "$log" ] && sed 's/^/  /' "$log"
    rm -f "$log"
    err "${label} failed"
    return 1
}

# ---------------------------------------------------------------------------
# Target resource audit
# ---------------------------------------------------------------------------
# An RRO that names a resource the target does not have is accepted by aapt2
# (especially with --auto-add-overlay) and then silently ignored at runtime.
# That is how a module can look fine and change nothing. Every generated entry
# is checked against the framework dictionary here.
framework_resource_index() {
    local cache="$BUILD_REL/framework-resources.txt"
    if [ ! -s "$cache" ] || [ "$PLATFORM_JAR" -nt "$cache" ]; then
        aapt2 dump resources "$PLATFORM_JAR" 2>/dev/null \
            | sed -n 's/^[[:space:]]*resource 0x[0-9a-fA-F]* //p' \
            | awk '{ print $1 }' \
            | sort -u > "$cache"
    fi
    printf '%s' "$cache"
}

# Print XML with comments removed, so examples inside <!-- --> are not audited.
strip_xml_comments() {
    awk '
        FNR == 1 { inc = 0 }
        {
            line = $0
            if (inc) {
                if (line ~ /-->/) { sub(/^.*-->/, "", line); inc = 0 }
                else next
            }
            while (line ~ /<!--/) {
                if (line ~ /-->/) { sub(/<!--.*-->/, "", line) }
                else { sub(/<!--.*$/, "", line); inc = 1; break }
            }
            print line
        }
    ' "$@"
}

audit_framework_resources() {
    local index report entries applied=0 ignored=0
    index=$(framework_resource_index)
    report="$OUT_DIR/${OVERLAY_NAME}-overrides.txt"

    if [ ! -s "$index" ]; then
        err "Could not read the resource table from ${PLATFORM_JAR}"
        return 1
    fi

    entries=$(strip_xml_comments "$RES_DIR"/values*/*.xml 2>/dev/null | awk '
        /<(bool|dimen|integer|string|string-array|integer-array|array|item)[[:space:]>]/ {
            line = $0
            tag = line
            sub(/^[^<]*</, "", tag)
            sub(/[^a-z-].*$/, "", tag)
            if (match(line, /name="[^"]+"/) == 0) next
            name = substr(line, RSTART + 6, RLENGTH - 7)
            type = ""
            if (tag == "item") {
                if (match(line, /type="[^"]+"/)) type = substr(line, RSTART + 6, RLENGTH - 7)
                if (type == "") type = "dimen"
            } else if (tag == "string-array" || tag == "integer-array" || tag == "array") {
                type = "array"
            } else {
                type = tag
            }
            print tag " " name " " type
        }
    ' || true)

    {
        echo "# Treble overlay resource audit"
        echo "# target dictionary: ${PLATFORM_JAR}"
        echo "# generated from:    ${CONFIG_FILE}"
        echo "#"
        echo "# APPLIES = the resource exists in the target and will be overridden"
        echo "# IGNORED = the resource is not in the target; Android silently drops it"
        echo ""
    } > "$report"

    local tag name type ignored_list=""
    while read -r tag name type; do
        [ -n "$name" ] || continue
        [ -n "$type" ] || continue
        if grep -qxF "$type/$name" "$index"; then
            applied=$((applied + 1))
            echo "APPLIES  $type/$name" >> "$report"
        else
            ignored=$((ignored + 1))
            ignored_list="${ignored_list}${type}/${name}
"
            echo "IGNORED  $type/$name  (not present in target)" >> "$report"
        fi
    done <<< "$entries"

    echo "" >> "$report"
    echo "Summary: ${applied} apply, ${ignored} ignored" >> "$report"

    data_count=$(grep -c '<item' "$RES_DIR/xml/power_profile.xml" 2>/dev/null || true)
    if [ "${data_count:-0}" -eq 0 ] && [ -f "$RES_DIR/xml/power_profile.xml" ]; then
        echo "" >> "$report"
        echo "SKIPPED  xml/power_profile  (empty template — not compiled into the APK)" >> "$report"
    fi

    ok "Resource audit: ${applied} overrides exist in the target"
    info "Report: ${report}"

    if [ "$ignored" -gt 0 ]; then
        warn "${ignored} resource(s) are not in the target and would do nothing:"
        while IFS= read -r line; do
            [ -n "$line" ] && warn "  ${line}"
        done <<< "$ignored_list"

        if $ALLOW_UNKNOWN_RESOURCES; then
            warn "Continuing because --allow-unknown-resources was given."
        else
            err "Refusing to build a module that would silently change nothing."
            err "Fix the resource names above, or re-run with --allow-unknown-resources"
            err "if you are intentionally targeting a newer framework."
            return 1
        fi
    fi
    return 0
}

# Values derived from config.env
OVERLAY_VERSION="1.0"
OVERLAY_VERSION_CODE=1
# ---------------------------------------------------------------------------
# Backup helper
# ---------------------------------------------------------------------------
do_backup() {
    mkdir -p "$BACKUP_DIR"
    local backed_up=false
    [ -f "$CONFIG_FILE" ]              && { cp "$CONFIG_FILE" "$BACKUP_DIR/config.env";              ok "Backed up config.env";             backed_up=true; }
    [ -f "$MODULE_DIR/sepolicy.rule" ] && { cp "$MODULE_DIR/sepolicy.rule" "$BACKUP_DIR/sepolicy.rule"; ok "Backed up sepolicy.rule";       backed_up=true; }
    [ -d "$VENDOR_DIR" ]               && { rm -rf "$BACKUP_DIR/vendor"; cp -R "$VENDOR_DIR" "$BACKUP_DIR/vendor"; ok "Backed up src/vendor/"; backed_up=true; }
    [ -f "$MODULE_DIR/customize.sh" ]  && { cp "$MODULE_DIR/customize.sh" "$BACKUP_DIR/customize.sh"; ok "Backed up customize.sh";       backed_up=true; }
    [ -f "$MODULE_DIR/service.sh" ]    && { cp "$MODULE_DIR/service.sh" "$BACKUP_DIR/service.sh";     ok "Backed up service.sh";         backed_up=true; }
    echo ""
    if $backed_up; then
        info "Backup saved to stuff/backups/"
    else
        info "Nothing to back up"
    fi
}

# ---------------------------------------------------------------------------
# Load or create config
# ---------------------------------------------------------------------------
if [ ! -f "$CONFIG_FILE" ]; then
    echo -e "\n${YELLOW}No config.env found.${NC}\n"

    USE_EXAMPLE=false
    if [ -f "$CONFIG_EXAMPLE" ]; then
        echo -e "  ${BOLD}Use the example config (config.env.example) for testing?${NC}"
        echo -e "  This will pre-fill values for the Samsung Galaxy A90 5G as a reference."
        ask_reply "  [y/N] "
        use_example="$ASK_REPLY"
        echo ""
        if [[ "$use_example" =~ ^[Yy]$ ]]; then
            cp "$CONFIG_EXAMPLE" "$CONFIG_FILE"
            echo -e "  ${GREEN}✓${NC} Copied config.env.example → config.env"
            echo -e "  ${YELLOW}→${NC} Proceeding with build using example values...\n"
            USE_EXAMPLE=true
        fi
    fi

    if [ "$USE_EXAMPLE" != "true" ]; then
        echo -e "  ${YELLOW}Generating placeholder config.env — edit it for YOUR device, then re-run.${NC}\n"

        # The starter is the committed config.env (see restore_from_release):
        # stuff/templates/recoveries/ is only the fallback for a checkout without .git.
        if ! restore_from_release "config.env" "$RECOVERIES_DIR/config.env"; then
            err "Template config missing: neither git HEAD nor stuff/templates/recoveries/config.env has it"
            exit 1
        fi

        echo -e "  ${YELLOW}→${NC} Created ${BOLD}$CONFIG_FILE${NC} with placeholder values."
        echo -e "  ${YELLOW}→${NC} Edit it for your device, then re-run: ${BOLD}./build.sh${NC}"
        exit 0
    fi
fi

source "$CONFIG_FILE"

# config.env names the signing key relative to the project root. Keys moved to
# stuff/keys/, so an older config.env that still says keys/platform.pk8 keeps
# working: either path resolves, and neither is rewritten on disk.
if [ -n "${PLATFORM_KEY:-}" ] && [ ! -f "$PLATFORM_KEY" ] && [ -f "stuff/$PLATFORM_KEY" ]; then
    PLATFORM_KEY="stuff/$PLATFORM_KEY"
    PLATFORM_CERT="stuff/$PLATFORM_CERT"
fi

# ── Auto-generate identity strings ─────────────────────────────────────────
# Users only need to set DEVICE_CODENAME and DEVICE_MANUFACTURER. The derivation
# lives in stuff/scripts/common.sh so the standalone helpers agree with the build.
derive_overlay_identity

# Validate required values
[ -z "$DEVICE_CODENAME" ] && { err "DEVICE_CODENAME not set in config.env"; exit 1; }
[ -z "$DEVICE_MANUFACTURER" ] && { err "DEVICE_MANUFACTURER not set in config.env"; exit 1; }

# ---------------------------------------------------------------------------
# Device identity check — only check the key codename values
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# Device identity check
# ---------------------------------------------------------------------------
# All identity values are filled — show summary and confirm
echo ""
echo -e "  ${GREEN}┌──────────────────────────────────────────────────────────┐${NC}"
echo -e "  ${GREEN}│${NC}  Device configuration detected                       ${GREEN}│${NC}"
echo -e "  ${GREEN}└──────────────────────────────────────────────────────────┘${NC}"
echo -e ""
echo -e "  ${BOLD}Identity:${NC}"
echo -e "    Device:        ${DEVICE_MANUFACTURER} ${DEVICE_MODEL} (${DEVICE_CODENAME})"
echo -e "    Overlay:       ${OVERLAY_NAME}"
echo -e "    Package:       ${OVERLAY_PACKAGE}"
echo -e "    Match:         ${CONDITION_DESC}"
echo -e ""
echo -e "  ${BOLD}Display:${NC}"
[ -n "$ROUNDED_CORNER_RADIUS" ] && [[ "$ROUNDED_CORNER_RADIUS" != *"<"* ]] && echo -e "    Rounded corners: ${ROUNDED_CORNER_RADIUS}px"
[ -n "$STATUS_BAR_HEIGHT" ] && [[ "$STATUS_BAR_HEIGHT" != *"<"* ]] && echo -e "    Status bar:      ${STATUS_BAR_HEIGHT}px"
echo -e ""
echo -e "  ${BOLD}Features:${NC}"
echo -e "    UDFPS:           ${HAS_UDFPS}"
echo -e "    AOD:             ${HAS_AOD}"
echo -e "    Doze:            ${HAS_DOZE}"
echo -e "    5G:              ${HAS_5G}"
echo -e "    VoLTE:           ${HAS_VOLTE}"
echo -e ""
echo -e "  ${BOLD}Builder:${NC}"
echo -e "    Android:         ${ANDROID_VERSION} (API ${COMPILE_SDK_VERSION})"
echo ""

# ---------------------------------------------------------------------------
# Preflight: placeholders, inconsistent values, keys nothing reads
# ---------------------------------------------------------------------------
step "Checking config.env"
validate_config
echo ""

# ---------------------------------------------------------------------------
# Dry run — print what config.env produces and stop before any tool is needed
# ---------------------------------------------------------------------------
if [ "$DRY_RUN" = "true" ]; then
    step "Resource plan (dry run)"
    mkdir -p "$RES_DIR/values" "$RES_DIR/values-land" "$SYSUI_RES_DIR/values"
    generate_resource_xml
    generate_systemui_resource_xml
    echo ""
    print_resource_plan
    echo ""
    info "Dry run: nothing was compiled, signed or packaged."
    echo ""
    exit 0
fi

# Check mode — validate and exit
if [ "$CHECK_MODE" = "true" ]; then
    echo ""
    if [ "${VALIDATE_WARNINGS:-0}" -eq 0 ]; then
        echo -e "  ${GREEN}✓${NC} Config validation passed"
    else
        echo -e "  ${YELLOW}⚠${NC} ${VALIDATE_WARNINGS} config warning(s) — see the list above"
    fi
    echo -e "  ${YELLOW}→${NC} Run without --check to build"
    echo ""
    exit 0
fi

if ! $ASSUME_YES; then
    echo -e "  ${YELLOW}Are these values correct for your device?${NC}"
fi
ask_reply "  [Y/n] "
confirm_values="$ASK_REPLY"

if [[ "$confirm_values" =~ ^[Nn] ]]; then
    echo ""
    echo -e "  ${YELLOW}→${NC} Edit config.env with the correct values, then re-run: ${BOLD}./build.sh${NC}"
    echo ""
    exit 0
fi

# ---------------------------------------------------------------------------
# Build mode selection
# ---------------------------------------------------------------------------
step "Build mode"

HAS_VENDOR_FILES=false
if [ -d "$VENDOR_SRC_REL/bin/hw" ] && [ "$(ls -A "$VENDOR_SRC_REL"/bin/hw/ 2>/dev/null | grep -c .)" -gt 0 ]; then
    echo -e ""
    echo -e "  ${BOLD}[1]${NC} Overlay-only — simpler, safer, no vendor HALs"
    echo -e "  ${BOLD}[2]${NC} Include vendor HALs — for fingerprint, vibrator, etc."
    echo -e ""
    if $ASSUME_YES; then
        # Non-interactive: default to the safe overlay-only build.
        if $FORCE_VENDOR_HALS; then
            build_mode="2"
            info "Non-interactive: build mode 2 (vendor HALs)"
        else
            build_mode="1"
            info "Non-interactive: build mode 1 (overlay-only)"
        fi
    else
        ask_reply "  Choose [1/2]: "
        build_mode="$ASK_REPLY"
    fi
    if [[ "$build_mode" == "2" ]]; then
        INCLUDE_VENDOR_HALS=true
        echo -e "  ${GREEN}→${NC} Building with vendor HAL files and sepolicy.rule"
    else
        INCLUDE_VENDOR_HALS=false
        echo -e "  ${YELLOW}→${NC} Overlay-only build (vendor HALs and sepolicy.rule skipped)"
    fi
else
    INCLUDE_VENDOR_HALS=false
    # The documented tar pulls paths as vendor/bin/hw/…; extracting it from
    # inside src/vendor yields src/vendor/vendor/… and nothing is found.
    if [ -d "$VENDOR_SRC_REL/vendor" ]; then
        warn "${VENDOR_SRC_REL}/vendor/ exists — the HAL tarball was extracted one level too deep."
        warn "  Move it up: mv ${VENDOR_SRC_REL}/vendor/* ${VENDOR_SRC_REL}/ && rmdir ${VENDOR_SRC_REL}/vendor"
    fi
    echo -e "  ${YELLOW}→${NC} No vendor HAL files found — building overlay-only"
fi
# ---------------------------------------------------------------------------
# Dependency check
# ---------------------------------------------------------------------------
step "Checking dependencies"
tool_ready aapt2 || { err "Missing: aapt2 — run ./build.sh setup"; exit 1; }
if ! tool_ready zipalign; then
    if $IS_TERMUX; then
        # zipalign lives in the 'aapt' package (aapt2 does not ship it).
        warn "zipalign missing on Termux — install it with: pkg install aapt"
        warn "Continuing without it: APKs stay unaligned (valid, just not mmap-aligned)"
    else
        err "Missing: zipalign — run ./build.sh setup"
        exit 1
    fi
fi

# Windows cannot execute Linux binaries. A Linux aapt2/zipalign sitting in
# stuff/tools/ (left there by a WSL/Kali run of this project on the same checkout)
# shadows the .exe on PATH and used to fail much later, mid-build, with
# "cannot execute binary file: Exec format error". Catch it up front instead.
if $IS_WINDOWS; then
    for cmd in aapt2 zipalign; do
        _bin=$(command -v "$cmd")
        _magic=$(head -c 2 "$_bin" 2>/dev/null | od -An -tx1 | tr -d ' \n')
        if [ "$_magic" != "4d5a" ]; then
            err "${cmd} at ${_bin} is not a Windows program (no PE header)."
            err "This is usually a Linux/WSL binary left in the shared stuff/tools/ folder."
            err "Fix:   rm -f \"${_bin}\"   then re-run ./build.sh setup"
            err "Check: ./build.sh doctor        (or build.cmd doctor)"
            exit 1
        fi
    done
fi

# apksigner ships as a .bat wrapper on Windows and `command -v` does not
# resolve .bat files, so locate the real binary explicitly.
APKSIGNER_BIN=""
if command -v apksigner >/dev/null 2>&1; then
    APKSIGNER_BIN="$(command -v apksigner)"
elif [ -f "${TOOLS_DIR}/apksigner" ]; then
    APKSIGNER_BIN="${TOOLS_DIR}/apksigner"
elif [ -f "${TOOLS_DIR}/apksigner.bat" ]; then
    APKSIGNER_BIN="${TOOLS_DIR}/apksigner.bat"
elif command -v apksigner.bat >/dev/null 2>&1; then
    APKSIGNER_BIN="$(command -v apksigner.bat)"
fi
[ -n "$APKSIGNER_BIN" ] || { err "Missing: apksigner — run ./build.sh setup"; exit 1; }

# apksigner is a Java tool; fail early with a useful message rather than
# deep inside the signing step.
command -v java >/dev/null 2>&1 || {
    err "Java not found — apksigner needs a JDK (17+). Install one and re-run."; exit 1;
}

# A zip tool is required to package the module; create_zip() picks the best one.
if ! command -v zip >/dev/null 2>&1 && ! command -v 7z >/dev/null 2>&1 \
   && ! command -v powershell >/dev/null 2>&1; then
    err "Missing: zip (or 7z / PowerShell) — needed to package the module"
    exit 1
fi
ok "All tools found"
ok "apksigner: ${APKSIGNER_BIN}"

# Determine PLATFORM_JAR location (check stuff/tools/ first, then system path)
if [ ! -f "$PLATFORM_JAR" ]; then
    # Check if it's in the stuff/tools/ directory
    if [ -f "${TOOLS_DIR}/framework-res.apk" ]; then
        PLATFORM_JAR="${TOOLS_DIR}/framework-res.apk"
    elif [ -d "/data/data/com.termux" ] && [ ! -f "${TOOLS_DIR}/framework-res.apk" ]; then
        # On Termux, try to pull it if missing
        info "Running on Android (Termux) and framework-res.apk is missing."
        info "Attempting to pull from /system/framework/framework-res.apk..."
        mkdir -p "$TOOLS_DIR"
        if cp /system/framework/framework-res.apk "${TOOLS_DIR}/framework-res.apk" 2>/dev/null; then
            PLATFORM_JAR="${TOOLS_DIR}/framework-res.apk"
            ok "framework-res.apk auto-pulled successfully"
        elif su -c "cp /system/framework/framework-res.apk \"${TOOLS_DIR}/framework-res.apk\"" 2>/dev/null; then
            PLATFORM_JAR="${TOOLS_DIR}/framework-res.apk"
            ok "framework-res.apk auto-pulled successfully (via su)"
        fi
    fi
fi

if [ ! -f "$PLATFORM_JAR" ]; then
    err "Platform JAR not found."
    err "Checked: config.env PLATFORM_JAR path"
    err "Also checked: stuff/tools/framework-res.apk"
    err ""
    err "Install android-framework-res or pull from device:"
    err "  adb pull /system/framework/framework-res.apk stuff/tools/"
    err ""
    err "Or run: ./build.sh setup"
    exit 1
fi
# Prefer a project-relative path: native Windows tools would otherwise get an
# MSYS path (/c/...) that some of them fail to open.
case "$PLATFORM_JAR" in
    "$ROOT"/*) PLATFORM_JAR="${PLATFORM_JAR#"$ROOT"/}" ;;
esac
ok "Platform JAR: ${PLATFORM_JAR}"

# ---------------------------------------------------------------------------
# Clean
# ---------------------------------------------------------------------------
step "Cleaning previous build"
rm -f "${OVERLAY_NAME}.apk" "${OVERLAY_NAME}-systemui.apk" "${OVERLAY_NAME}-ksu.zip" "${OVERLAY_NAME}-hardware-overlay.zip"
rm -rf "$BUILD_DIR" "$OUT_DIR"
mkdir -p "$BUILD_REL/compiled" "$BUILD_REL/apk" "$BUILD_REL/systemui" "$OUT_DIR/apks"
ok "Build directory cleaned"

# ---------------------------------------------------------------------------
# Generate AndroidManifest.xml
# ---------------------------------------------------------------------------
step "Generating AndroidManifest.xml"

cat > "$BUILD_REL/AndroidManifest.xml" << MANIFEST
<?xml version="1.0" encoding="utf-8"?>
<!--
    Treble Overlay — ${OVERLAY_NAME}
    Device: ${DEVICE_MANUFACTURER} ${DEVICE_MODEL} (${DEVICE_CODENAME})
    Target: Android framework resources ("android" package)
    Condition: ${CONDITION_DESC}
    Generated by build.sh from config.env
-->

<manifest xmlns:android="http://schemas.android.com/apk/res/android"
    package="${OVERLAY_PACKAGE}"
    android:versionCode="${OVERLAY_VERSION_CODE}"
    android:versionName="${OVERLAY_VERSION}">

    <application
        android:extractNativeLibs="false"
        android:usesNonSdkApi="true" />

    <uses-sdk
        android:minSdkVersion="${MIN_SDK_VERSION}"
        android:targetSdkVersion="${TARGET_SDK_VERSION}" />

    <overlay
        android:targetPackage="android"
        android:priority="${OVERLAY_PRIORITY}"
        android:isStatic="true"
${OVERLAY_CONDITION}

</manifest>
MANIFEST
ok "AndroidManifest.xml generated"

cat > "$BUILD_REL/systemui/AndroidManifest.xml" << MANIFEST_SYSTEMUI
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
    package="${OVERLAY_PACKAGE_SYSTEMUI}"
    android:versionCode="1"
    android:versionName="1.0">

    <application
        android:extractNativeLibs="false"
        android:usesNonSdkApi="true" />

    <uses-sdk
        android:minSdkVersion="${MIN_SDK_VERSION}"
        android:targetSdkVersion="${TARGET_SDK_VERSION}" />

    <overlay
        android:targetPackage="com.android.systemui"
        android:priority="${OVERLAY_PRIORITY_SYSTEMUI}"
        android:isStatic="true"
${OVERLAY_CONDITION}

</manifest>
MANIFEST_SYSTEMUI
ok "SystemUI AndroidManifest.xml generated"

# ---------------------------------------------------------------------------
# Generate module.prop
# ---------------------------------------------------------------------------
step "Generating module.prop"

DESCRIPTION="${DEVICE_MODEL} overlay"
[ -n "$ROUNDED_CORNER_RADIUS" ] && [[ "$ROUNDED_CORNER_RADIUS" != *"<"* ]] && DESCRIPTION="${DESCRIPTION}: rounded corners (${ROUNDED_CORNER_RADIUS}px)"
[ "$HAS_AOD" = "true" ] && DESCRIPTION="${DESCRIPTION}, AOD"
[ "$HAS_UDFPS" = "true" ] && DESCRIPTION="${DESCRIPTION}, UDFPS"
[ "$HAS_5G" = "true" ] && DESCRIPTION="${DESCRIPTION}, 5G"
[ "$HAS_VOLTE" = "true" ] && DESCRIPTION="${DESCRIPTION}, VoLTE"
[ "$HAS_VENDOR_FINGERPRINT_HAL" = "true" ] && DESCRIPTION="${DESCRIPTION}, fingerprint HAL"
[ "$HAS_VENDOR_VIBRATOR_HAL" = "true" ] && DESCRIPTION="${DESCRIPTION}, vibrator HAL"

cat > "$BUILD_REL/module.prop" << MODPROP
id=${OVERLAY_NAME}
name=Treble Overlay - ${DEVICE_MANUFACTURER} ${DEVICE_MODEL}
version=${OVERLAY_VERSION}
versionCode=${OVERLAY_VERSION_CODE}
author=${DEVICE_MANUFACTURER}
description=${DESCRIPTION}
MODPROP
ok "module.prop generated"
info "Generating Android.mk"
cat > "$BUILD_REL/Android.mk" << ANDROIDMK
LOCAL_PATH := \$(call my-dir)
include \$(CLEAR_VARS)

LOCAL_MODULE := ${OVERLAY_NAME}
LOCAL_MODULE_TAGS := optional
LOCAL_SRC_FILES := ${OVERLAY_NAME}.apk
LOCAL_MODULE_CLASS := APPS
LOCAL_CERTIFICATE := platform
LOCAL_MODULE_OWNER := ${DEVICE_MANUFACTURER}
LOCAL_DEX_PREOPT := false
LOCAL_MODULE_PATH := \$(TARGET_OUT_PRODUCT)/overlay

include \$(BUILD_PREBUILT)
ANDROIDMK
ok "Android.mk generated"


# ---------------------------------------------------------------------------
# Generate auto-config XML from config.env
# ---------------------------------------------------------------------------
step "Generating resource XML from config.env"
mkdir -p "$RES_DIR/values" "$SYSUI_RES_DIR/values"
generate_resource_xml
generate_systemui_resource_xml

# ---------------------------------------------------------------------------
# Audit: every emitted name must exist in the target resource table
# ---------------------------------------------------------------------------
step "Auditing resources against the target framework"
audit_framework_resources || exit 1

# ---------------------------------------------------------------------------
# Stage resources for compilation
# ---------------------------------------------------------------------------
# Compile a copy so a placeholder power_profile.xml can be left out without
# touching the user's source file. An empty power_profile overrides the GSI's
# battery/CPU data with nothing, which breaks battery statistics.
RES_STAGE="$BUILD_REL/res"
SYSUI_STAGE="$BUILD_REL/res_systemui"
rm -rf "$RES_STAGE" "$SYSUI_STAGE"
cp -R "$RES_DIR" "$RES_STAGE"
if power_profile_is_placeholder "$RES_STAGE/xml/power_profile.xml"; then
    rm -f "$RES_STAGE/xml/power_profile.xml"
    warn "power_profile.xml is still the empty template — not compiled into the APK"
    info "Extract your device's profile and replace src/framework/res/xml/power_profile.xml"
    info "to override battery/CPU power data (see docs/device-extraction.md)."
fi
if [ -d "$SYSUI_RES_DIR" ]; then
    cp -R "$SYSUI_RES_DIR" "$SYSUI_STAGE"
fi

# ---------------------------------------------------------------------------
# Compile framework-res overlay
# ---------------------------------------------------------------------------
step "Compiling framework-res overlay"
run_or_die "aapt2 compile (framework resources)" \
    aapt2 compile --dir "$RES_STAGE" -o "$BUILD_REL/compiled/" || exit 1
ok "Framework resources compiled"

# ---------------------------------------------------------------------------
# Compile SystemUI overlay
# ---------------------------------------------------------------------------
step "Compiling SystemUI overlay"
mkdir -p "$BUILD_REL/compiled_systemui"
if [ -d "$SYSUI_STAGE" ] && [ "$(ls -A "$SYSUI_STAGE" 2>/dev/null)" ]; then
    run_or_die "aapt2 compile (SystemUI resources)" \
        aapt2 compile --dir "$SYSUI_STAGE" -o "$BUILD_REL/compiled_systemui/" || exit 1
    ok "SystemUI resources compiled"
else
    info "No SystemUI resources found — skipping SystemUI overlay"
fi

# ---------------------------------------------------------------------------
# Link framework-res overlay
# ---------------------------------------------------------------------------
step "Linking framework-res APK"
run_or_die "aapt2 link (framework overlay)" \
    aapt2 link --manifest "$BUILD_REL/AndroidManifest.xml" \
    -I "${PLATFORM_JAR}" \
    --auto-add-overlay \
    --compile-sdk-version-code "${COMPILE_SDK_VERSION}" \
    --compile-sdk-version-name "${ANDROID_VERSION}" \
    -o "$BUILD_REL/apk/unsigned.apk" \
    "$BUILD_REL/compiled"/*.flat || exit 1
ok "Framework-res APK linked"

# ---------------------------------------------------------------------------
# Link SystemUI overlay (if resources exist)
# ---------------------------------------------------------------------------
LINKED_SYSTEMUI=false
if [ -f "$BUILD_REL/compiled_systemui/values_config.arsc.flat" ] || [ "$(ls "$BUILD_REL/compiled_systemui"/*.flat 2>/dev/null | wc -l)" -gt 0 ]; then
    # --no-resource-deduping: aapt2 otherwise collapses a resource that holds
    # the same value in every configuration into one default entry. The
    # status_bar_background addon writes its transparent item once per density
    # (see resources.sh) and deduping would drop that back to the default
    # config, which loses to the ROM's density-qualified 9-patch.
    step "Linking SystemUI APK"
    run_or_die "aapt2 link (SystemUI overlay)" \
        aapt2 link --manifest "$BUILD_REL/systemui/AndroidManifest.xml" \
        -I "${PLATFORM_JAR}" \
        --auto-add-overlay \
        --no-resource-deduping \
        --compile-sdk-version-code "${COMPILE_SDK_VERSION}" \
        --compile-sdk-version-name "${ANDROID_VERSION}" \
        -o "$BUILD_REL/apk/systemui_unsigned.apk" \
        "$BUILD_REL/compiled_systemui"/*.flat || exit 1
    LINKED_SYSTEMUI=true
    ok "SystemUI APK linked"
fi

# ---------------------------------------------------------------------------
# Zipalign
# ---------------------------------------------------------------------------
step "Zipaligning APKs"
run_or_die "zipalign (framework overlay)" \
    align_apk "$BUILD_REL/apk/unsigned.apk" "$BUILD_REL/apk/aligned.apk" || exit 1
ok "Framework-res APK aligned"

if [ "$LINKED_SYSTEMUI" = "true" ]; then
    run_or_die "zipalign (SystemUI overlay)" \
        align_apk "$BUILD_REL/apk/systemui_unsigned.apk" "$BUILD_REL/apk/systemui_aligned.apk" || exit 1
    ok "SystemUI APK aligned"
fi

# ---------------------------------------------------------------------------
# Sign
# ---------------------------------------------------------------------------
step "Signing APKs"

if [ ! -f "$PLATFORM_KEY" ] || [ ! -f "$PLATFORM_CERT" ]; then
    err "Signing keys not found!"
    err "  Key:  ${PLATFORM_KEY}"
    err "  Cert: ${PLATFORM_CERT}"
    err "Update PLATFORM_KEY/PLATFORM_CERT in config.env or generate new keys"
    exit 1
fi

run_or_die "apksigner sign (framework overlay)" \
    "$APKSIGNER_BIN" sign --key "${PLATFORM_KEY}" --cert "${PLATFORM_CERT}" \
    --v1-signing-enabled true --v2-signing-enabled true --v4-signing-enabled false \
    --out "out/apks/${OVERLAY_NAME}.apk" "$BUILD_REL/apk/aligned.apk" || exit 1
ok "Framework-res APK signed: out/apks/${OVERLAY_NAME}.apk"

if [ "$LINKED_SYSTEMUI" = "true" ]; then
    run_or_die "apksigner sign (SystemUI overlay)" \
        "$APKSIGNER_BIN" sign --key "${PLATFORM_KEY}" --cert "${PLATFORM_CERT}" \
        --v1-signing-enabled true --v2-signing-enabled true --v4-signing-enabled false \
        --out "out/apks/${OVERLAY_NAME}-systemui.apk" "$BUILD_REL/apk/systemui_aligned.apk" || exit 1
    ok "SystemUI APK signed: out/apks/${OVERLAY_NAME}-systemui.apk"
fi

# ---------------------------------------------------------------------------
# Verify
# ---------------------------------------------------------------------------
step "Verifying APKs"
run_or_die "apksigner verify (framework overlay)" \
    "$APKSIGNER_BIN" verify "out/apks/${OVERLAY_NAME}.apk" || exit 1
ok "Framework-res APK verified"
if [ "$LINKED_SYSTEMUI" = "true" ]; then
    run_or_die "apksigner verify (SystemUI overlay)" \
        "$APKSIGNER_BIN" verify "out/apks/${OVERLAY_NAME}-systemui.apk" || exit 1
    ok "SystemUI APK verified"
fi

SIZE_FW=$(du -sh "out/apks/${OVERLAY_NAME}.apk" 2>/dev/null | cut -f1)
info "Framework APK size: ${SIZE_FW}"
if [ "$LINKED_SYSTEMUI" = "true" ]; then
    SIZE_SU=$(du -sh "out/apks/${OVERLAY_NAME}-systemui.apk" 2>/dev/null | cut -f1)
    info "SystemUI APK size: ${SIZE_SU}"
fi

# ---------------------------------------------------------------------------
# Build module zip (KernelSU / KSU Next / APatch / Magisk)
# ---------------------------------------------------------------------------
step "Building module zip"

MODULE_TMP="$BUILD_REL/module_tmp"
rm -rf "$MODULE_TMP"
mkdir -p "${MODULE_TMP}/system/product/overlay"

# Copy overlay APKs
cp "out/apks/${OVERLAY_NAME}.apk" "${MODULE_TMP}/system/product/overlay/"
if [ "$LINKED_SYSTEMUI" = "true" ]; then
    cp "out/apks/${OVERLAY_NAME}-systemui.apk" "${MODULE_TMP}/system/product/overlay/"
fi

# Copy module metadata
cp "$BUILD_REL/module.prop" "${MODULE_TMP}/"

# Module WebUI: a page in webroot/ lets the user edit values and apply them
# without rebuilding. KernelSU/KSU Next/APatch show it directly; Magisk users
# open it with a WebUI host (WebUI X, KsuWebUI, MMRL).
if [ -d "$ROOT/src/webui" ]; then
    rm -rf "${MODULE_TMP}/webroot"
    cp -R "$ROOT/src/webui" "${MODULE_TMP}/webroot"
    # Build-time values so the page can show what the module currently uses.
    # Saved WebUI values in webui.conf take precedence at runtime.
    {
        printf 'RADIUS=%s\n'      "${ROUNDED_CORNER_RADIUS//[^0-9]/}"
        printf 'SB_HEIGHT=%s\n'    "${STATUS_BAR_HEIGHT//[^0-9]/}"
        printf 'PAD_CONTENT=%s\n'  "${STATUS_BAR_CONTENT_PADDING//[^0-9]/}"
        printf 'PAD_START=%s\n'    "${STATUS_BAR_PADDING_START//[^0-9]/}"
        printf 'PAD_END=%s\n'      "${STATUS_BAR_PADDING_END//[^0-9]/}"
        printf 'DOZE_BLANK=%s\n'   "${CONFIG_DISPLAY_BLANKS_AFTER_DOZE:-false}"
    } > "${MODULE_TMP}/webui-defaults.conf"
    # The page renders its editor from this list, so what it can edit comes
    # from the same resource XML the build compiles - not a second table.
    WEBUI_RES_COUNT=$(write_webui_manifest "${MODULE_TMP}/webroot/webui-manifest.json")
    ok "webroot/: WebUI included (KSU / KSU Next / APatch / Magisk hosts)"
    info "webroot/webui-manifest.json: ${WEBUI_RES_COUNT} resource(s) editable from the page"
fi

# Module addons: Settings values the module applies itself, which no overlay
# resource can express (the volume panel side, the screen timeout, ...). The
# clone keeps the choice in src/module/addons.conf — that is what the desktop
# app's Addons tab writes — and the phone's page edits the packed copy. Only the
# addons listed in the file are enforced, so an untouched file changes nothing.
if [ -f "$MODULE_DIR/addons.conf" ]; then
    cp "$MODULE_DIR/addons.conf" "${MODULE_TMP}/addons.conf"
    chmod 0644 "${MODULE_TMP}/addons.conf"
    ADDON_COUNT=$(grep -c '^[A-Za-z]' "${MODULE_TMP}/addons.conf" 2>/dev/null || true)
    ok "addons.conf included (${ADDON_COUNT:-0} addon(s) chosen)"
else
    info "addons.conf not found — the module ships no addons"
fi

# Use src/module/customize.sh when present, otherwise generate one.
if [ -f "$MODULE_DIR/customize.sh" ]; then
    cp "$MODULE_DIR/customize.sh" "${MODULE_TMP}/customize.sh" && chmod +x "${MODULE_TMP}/customize.sh"
    ok "customize.sh: using src/module/customize.sh"
elif [ "$INCLUDE_VENDOR_HALS" = "true" ]; then
    generate_customize_sh "$MODULE_TMP"
    ok "customize.sh auto-generated from vendor/ contents"
else
    # Overlay-only: simple customize.sh
    cat > "${MODULE_TMP}/customize.sh" << 'CUSTOMIZE_SIMPLE'
#!/sbin/sh
# MODPATH is exported by the manager when it sources this script; fall back to
# the script location (some managers run it as `sh customize.sh`, where $0 is
# not a path).
MODPATH=${MODPATH:-${0%/*}}
[ -d "$MODPATH/system" ] || MODPATH="."
ui_print "  Installing ${MODPATH##*/}..."
set_perm_recursive $MODPATH/system/product/overlay 0 0 0755 0644 u:object_r:system_file:s0

# The zip may lose the executable bit depending on the manager's extractor.
if [ -f "$MODPATH/fod/xiaomi-fod" ]; then
    set_perm "$MODPATH/fod/xiaomi-fod" 0 0 0755
fi

# Values saved in the WebUI live outside the module directory (an update
# replaces this one), so bring them back. The page re-applies them onto the new
# APKs the next time it is opened.
if [ -f "$MODPATH/webroot/apply.sh" ]; then
    sh "$MODPATH/webroot/apply.sh" restore-conf >/dev/null 2>&1 || true
fi

# Module addons: the saved choices also survive an update through that folder.
# Applying them now means a rebuild does not need a reboot to take effect.
if [ -f "$MODPATH/webroot/addons.sh" ]; then
    sh "$MODPATH/webroot/addons.sh" restore-conf >/dev/null 2>&1 || true
    sh "$MODPATH/webroot/addons.sh" apply >/dev/null 2>&1 || true
fi

ui_print "  ✓ Module installed successfully!"
CUSTOMIZE_SIMPLE
    chmod +x "${MODULE_TMP}/customize.sh"
    ok "customize.sh generated (overlay-only)"
fi

# META-INF: Magisk's installer entry point. KernelSU and APatch source
# customize.sh directly and ignore this directory, so one zip serves all three.
generate_magisk_meta "${MODULE_TMP}"

# sepolicy.rule
if [ "$INCLUDE_VENDOR_HALS" = "true" ] && [ -f "$MODULE_DIR/sepolicy.rule" ]; then
    if grep -q '^allow' "$MODULE_DIR/sepolicy.rule" 2>/dev/null; then
        RULE_COUNT=$(grep -c '^allow' "$MODULE_DIR/sepolicy.rule")
        cp "$MODULE_DIR/sepolicy.rule" "${MODULE_TMP}/" && ok "Included sepolicy.rule (${RULE_COUNT} allow rules)"
    else
        info "sepolicy.rule has no allow rules — template only, skipping"
    fi
else
    if [ "$INCLUDE_VENDOR_HALS" = "true" ]; then
        info "sepolicy.rule not found or has no rules — skipping"
    else
        info "sepolicy.rule skipped (overlay-only build)"
    fi
fi

# service.sh — use src/module/service.sh when present, otherwise generate one
if [ -f "$MODULE_DIR/service.sh" ]; then
    sed -e "s/@OVERLAY_PACKAGE@/${OVERLAY_PACKAGE}/g" \
        -e "s/@OVERLAY_PACKAGE_SYSTEMUI@/${OVERLAY_PACKAGE_SYSTEMUI}/g" \
        -e "s/@MODULE_ID@/${OVERLAY_NAME}/g" \
        "$MODULE_DIR/service.sh" > "${MODULE_TMP}/service.sh"
    chmod +x "${MODULE_TMP}/service.sh"
    ok "service.sh: using src/module/service.sh (package: ${OVERLAY_PACKAGE})"
else
    generate_service_sh "$MODULE_TMP"
    # Substitute placeholders in the generated file
    sed -i -e "s/@OVERLAY_PACKAGE@/${OVERLAY_PACKAGE}/g" \
           -e "s/@OVERLAY_PACKAGE_SYSTEMUI@/${OVERLAY_PACKAGE_SYSTEMUI}/g" \
           -e "s/@MODULE_ID@/${OVERLAY_NAME}/g" \
           "${MODULE_TMP}/service.sh"
    ok "service.sh auto-generated (package: ${OVERLAY_PACKAGE})"
fi

# Xiaomi touch-panel FOD helper. The binary is built from src/module/fod/main.go
# for arm64; service.sh starts it only when the device has Xiaomi FOD hardware.
# Only pack it for UDFPS builds, where service.sh can actually use it.
if [ "$HAS_UDFPS" = "true" ] && [ -f "$MODULE_DIR/fod/xiaomi-fod" ]; then
    mkdir -p "${MODULE_TMP}/fod"
    cp "$MODULE_DIR/fod/xiaomi-fod" "${MODULE_TMP}/fod/xiaomi-fod"
    chmod 0755 "${MODULE_TMP}/fod/xiaomi-fod"
    ok "fod/xiaomi-fod included (Xiaomi touch-panel FOD mode)"
fi

# post-fs-data.sh — set a persist.* match property before zygote starts
if [ -f "$MODULE_DIR/post-fs-data.sh" ]; then
    cp "$MODULE_DIR/post-fs-data.sh" "${MODULE_TMP}/post-fs-data.sh" \
        && chmod +x "${MODULE_TMP}/post-fs-data.sh"
    ok "post-fs-data.sh: using src/module/post-fs-data.sh"
else
    MATCH_PROP_YES=no
    if [ -n "$DEVICE_PROP_NAME" ] && [[ "$DEVICE_PROP_NAME" == persist.* ]]; then
        MATCH_PROP_YES=yes
    fi
    generate_post_fs_data_sh "${MODULE_TMP}" "$MATCH_PROP_YES"
    sed -i -e "s|@MATCH_PROP@|${DEVICE_PROP_NAME}|g" \
           -e "s|@MATCH_VALUE@|${DEVICE_PROP_VALUE}|g" \
           -e "s|@MODULE_ID@|${OVERLAY_NAME}|g" \
           "${MODULE_TMP}/post-fs-data.sh"
    if [ "$MATCH_PROP_YES" = "yes" ]; then
        ok "post-fs-data.sh sets ${DEVICE_PROP_NAME}=${DEVICE_PROP_VALUE} before zygote"
    else
        ok "post-fs-data.sh: WebUI boot guard only (no persist.* match property)"
    fi
fi

# ---------------------------------------------------------------------------
# Copy vendor HAL files (only if INCLUDE_VENDOR_HALS is set)
# ---------------------------------------------------------------------------
VENDOR_HALS_COPIED=false

if [ "$INCLUDE_VENDOR_HALS" = "true" ]; then
    # Vendor HAL binaries
    if [ -d "$VENDOR_SRC_REL/bin/hw" ] && [ "$(ls -A "$VENDOR_SRC_REL"/bin/hw/ 2>/dev/null | grep -c .)" -gt 0 ]; then
        mkdir -p "${MODULE_TMP}/system/vendor/bin/hw"
        cp -R "$VENDOR_SRC_REL"/bin/hw/. "${MODULE_TMP}/system/vendor/bin/hw/"
        for f in "$VENDOR_SRC_REL"/bin/hw/*; do
            [ -f "$f" ] && ok "Vendor HAL: $(basename "$f")"
        done
        VENDOR_HALS_COPIED=true
    fi

    # Shared libraries
    if [ -d "$VENDOR_SRC_REL/lib64" ] && [ "$(ls -A "$VENDOR_SRC_REL"/lib64/ 2>/dev/null | grep -c .)" -gt 0 ]; then
        mkdir -p "${MODULE_TMP}/system/vendor/lib64"
        cp "$VENDOR_SRC_REL"/lib64/*.so "${MODULE_TMP}/system/vendor/lib64/" 2>/dev/null || true
        for f in "$VENDOR_SRC_REL"/lib64/*.so; do
            [ -f "$f" ] && ok "Vendor lib: $(basename "$f")"
        done
    fi

    # Init .rc files. A dumped tree can contain subdirectories (etc/init/hw/),
    # so copy the contents recursively instead of a plain glob.
    if [ -d "$VENDOR_SRC_REL/etc/init" ] && [ "$(ls -A "$VENDOR_SRC_REL"/etc/init/ 2>/dev/null | grep -c .)" -gt 0 ]; then
        mkdir -p "${MODULE_TMP}/system/vendor/etc/init"
        cp -R "$VENDOR_SRC_REL"/etc/init/. "${MODULE_TMP}/system/vendor/etc/init/"
        ok "Included $(find "$VENDOR_SRC_REL/etc/init" -type f -name '*.rc' 2>/dev/null | wc -l) init .rc files"
    fi

    # VINTF manifest fragments
    if [ -d "$VENDOR_SRC_REL/etc/vintf/manifest" ] && [ "$(ls -A "$VENDOR_SRC_REL"/etc/vintf/manifest/ 2>/dev/null | grep -c .)" -gt 0 ]; then
        mkdir -p "${MODULE_TMP}/system/vendor/etc/vintf/manifest"
        cp -R "$VENDOR_SRC_REL"/etc/vintf/manifest/. "${MODULE_TMP}/system/vendor/etc/vintf/manifest/"
        ok "Included $(ls "$VENDOR_SRC_REL"/etc/vintf/manifest/* 2>/dev/null | wc -l) VINTF manifest files"
    fi

    if [ "$VENDOR_HALS_COPIED" = "true" ]; then
        info "Vendor HAL files included in module"
    else
        info "No vendor HAL files found — build pure overlay only"
    fi
else
    info "Vendor HAL files skipped (overlay-only build)"
fi

# ---------------------------------------------------------------------------
# Package module
# ---------------------------------------------------------------------------
create_zip "$MODULE_TMP" "${ROOT}/out/${OVERLAY_NAME}-ksu.zip" \
    || { err "Failed to package module zip"; exit 1; }
rm -rf "$MODULE_TMP"
ok "Module packaged: out/${OVERLAY_NAME}-ksu.zip (KernelSU / KSU Next / APatch / Magisk)"

# ---------------------------------------------------------------------------
# Build Hardware Overlay Repo Structure (AOSP source-based)
# ---------------------------------------------------------------------------
step "Building Hardware Overlay Repo structure"

# The submission tree (manifests, Android.mk, resources minus the repo's
# blacklist, notes) is written by stuff/scripts/hardware-overlay.sh, which is also
# runnable on its own: ./stuff/scripts/hardware-overlay.sh plan|write <dir>
HW_OVERLAY_DIR="$BUILD_REL/hardware_overlay"
write_hardware_overlay "$HW_OVERLAY_DIR" || { err "Failed to generate the hardware overlay tree"; exit 1; }
FW_HW_DIR="$HW_FW_DIR"
SYSUI_HW_DIR="${HW_SYSUI_DIR:-}"

# Package it
create_zip "$HW_OVERLAY_DIR" "${ROOT}/out/${OVERLAY_NAME}-hardware-overlay.zip" \
    || { err "Failed to package hardware overlay sources"; exit 1; }
ok "Hardware Overlay Repo package created: out/${OVERLAY_NAME}-hardware-overlay.zip"

# 3. Build Hardware Overlay TEST Flashable Zip
# This builds an APK from the *merged* hardware overlay source and packages it
# into a simple flashable module so you can test if the AOSP repo version works.
step "Building Hardware Overlay TEST Flashable Zip"

TEST_BUILD_DIR="$BUILD_REL/hw_test"
rm -rf "$TEST_BUILD_DIR"
mkdir -p "$TEST_BUILD_DIR/compiled" "$TEST_BUILD_DIR/apk" "$TEST_BUILD_DIR/module/system/product/overlay"

# 3a. Compile merged Framework resources
info "Building TEST Framework APK..."
run_or_die "TEST: aapt2 compile (framework)" \
    aapt2 compile --dir "$FW_HW_DIR/res" -o "$TEST_BUILD_DIR/compiled/" || exit 1
run_or_die "TEST: aapt2 link (framework)" \
    aapt2 link --manifest "$FW_HW_DIR/AndroidManifest.xml" \
    -I "${PLATFORM_JAR}" \
    --auto-add-overlay \
    --compile-sdk-version-code "${COMPILE_SDK_VERSION}" \
    --compile-sdk-version-name "${ANDROID_VERSION}" \
    -o "$TEST_BUILD_DIR/apk/unsigned.apk" \
    "$TEST_BUILD_DIR/compiled"/*.flat || exit 1

run_or_die "TEST: zipalign (framework)" \
    align_apk "$TEST_BUILD_DIR/apk/unsigned.apk" "$TEST_BUILD_DIR/apk/aligned.apk" || exit 1
run_or_die "TEST: apksigner sign (framework)" \
    "$APKSIGNER_BIN" sign --key "${PLATFORM_KEY}" --cert "${PLATFORM_CERT}" \
    --v1-signing-enabled true --v2-signing-enabled true --v4-signing-enabled false \
    --out "$TEST_BUILD_DIR/module/system/product/overlay/${OVERLAY_NAME}.apk" "$TEST_BUILD_DIR/apk/aligned.apk" || exit 1

# 3b. Compile merged SystemUI resources (if exists)
if [ "$LINKED_SYSTEMUI" = "true" ]; then
    info "Building TEST SystemUI APK..."
    mkdir -p "$TEST_BUILD_DIR/compiled_systemui" "$TEST_BUILD_DIR/apk_systemui"
    run_or_die "TEST: aapt2 compile (SystemUI)" \
        aapt2 compile --dir "$SYSUI_HW_DIR/res" -o "$TEST_BUILD_DIR/compiled_systemui/" || exit 1
    run_or_die "TEST: aapt2 link (SystemUI)" \
        aapt2 link --manifest "$SYSUI_HW_DIR/AndroidManifest.xml" \
        -I "${PLATFORM_JAR}" \
        --auto-add-overlay \
        --compile-sdk-version-code "${COMPILE_SDK_VERSION}" \
        --compile-sdk-version-name "${ANDROID_VERSION}" \
        -o "$TEST_BUILD_DIR/apk_systemui/unsigned.apk" \
        "$TEST_BUILD_DIR/compiled_systemui"/*.flat || exit 1

    run_or_die "TEST: zipalign (SystemUI)" \
        align_apk "$TEST_BUILD_DIR/apk_systemui/unsigned.apk" "$TEST_BUILD_DIR/apk_systemui/aligned.apk" || exit 1
    run_or_die "TEST: apksigner sign (SystemUI)" \
        "$APKSIGNER_BIN" sign --key "${PLATFORM_KEY}" --cert "${PLATFORM_CERT}" \
        --v1-signing-enabled true --v2-signing-enabled true --v4-signing-enabled false \
        --out "$TEST_BUILD_DIR/module/system/product/overlay/${OVERLAY_NAME}-systemui.apk" "$TEST_BUILD_DIR/apk_systemui/aligned.apk" || exit 1
fi

# Package into test module
cp "$BUILD_REL/module.prop" "$TEST_BUILD_DIR/module/"
sed -i "s/^name=.*/name=Treble Overlay TEST - ${DEVICE_MANUFACTURER} ${DEVICE_CODENAME}/" "$TEST_BUILD_DIR/module/module.prop"
sed -i "s/^description=.*/description=Test build of merged source overlays for Hardware Overlay Repo submission./" "$TEST_BUILD_DIR/module/module.prop"

cat > "$TEST_BUILD_DIR/module/customize.sh" << 'CUSTOM_EOF'
#!/sbin/sh
# MODPATH is exported by the manager; fall back to the script location.
MODPATH=${MODPATH:-${0%/*}}
ui_print "  Installing Hardware Overlay TEST module..."
set_perm_recursive $MODPATH/system/product/overlay 0 0 0755 0644 u:object_r:system_file:s0
ui_print "  ✓ TEST module installed."
CUSTOM_EOF
chmod +x "$TEST_BUILD_DIR/module/customize.sh"
generate_magisk_meta "$TEST_BUILD_DIR/module"

create_zip "$TEST_BUILD_DIR/module" "${ROOT}/out/${OVERLAY_NAME}-hardware-overlay-test.zip" \
    || { err "Failed to package hardware overlay TEST module"; exit 1; }
ok "Hardware Overlay TEST module created: out/${OVERLAY_NAME}-hardware-overlay-test.zip"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo -e "${GREEN}${BOLD}  ╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}${BOLD}  ║              BUILD COMPLETE ✓                        ║${NC}"
echo -e "${GREEN}${BOLD}  ╚══════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${BOLD}Output files (out/):${NC}"
echo "    out/apks/${OVERLAY_NAME}.apk         $(du -sh "out/apks/${OVERLAY_NAME}.apk" | cut -f1)"
if [ "$LINKED_SYSTEMUI" = "true" ]; then
    echo "    out/apks/${OVERLAY_NAME}-systemui.apk  $(du -sh "out/apks/${OVERLAY_NAME}-systemui.apk" | cut -f1)"
fi
echo ""
echo "    out/${OVERLAY_NAME}-ksu.zip              (Main module: KSU / KSU Next / APatch / Magisk)"
echo "    out/${OVERLAY_NAME}-hardware-overlay.zip (Submit to the overlay repo — no module needed)"
echo "    out/${OVERLAY_NAME}-hardware-overlay-test.zip (Test repo version locally)"
echo ""
echo -e "  ${BOLD}Getting it built into the GSI:${NC}"
echo "    docs/submission.md  —  the zip's _submission/HOW-TO-SUBMIT.md has the steps"
echo "    for your device (folders, overlay.mk lines, match value, priority)."
echo ""
echo -e "  ${RED}${BOLD}⚠ IMPORTANT (KernelSU / KSU Next Users):${NC}"
echo "    - You MUST install a mount system like 'Magic Mount' for overlays to activate."
echo "    - DO NOT use 'OverlayFS' — it mounts fine, but a mistake in your own"
echo "      sepolicy.rule or VINTF manifests then bootloops the device; magic mount"
echo "      ignores the bad file and boots. See docs/how-it-works.md."
echo "    - If you are using Hybrid Mount, you need to choose magic mount for the overlay module."
echo ""
echo -e "  ${BOLD}Deploy:${NC}"
echo "    Standard: Install out/${OVERLAY_NAME}-ksu.zip via your Manager App."
echo ""
echo "    Manual (ADB):"
echo "      adb push out/${OVERLAY_NAME}-ksu.zip /sdcard/"
echo "      adb shell su -c 'ksud module install /sdcard/${OVERLAY_NAME}-ksu.zip'"
echo ""
echo -e "  ${BOLD}Verify:${NC}"
echo "    adb shell cmd overlay list | grep ${OVERLAY_NAME#treble-overlay-}"
echo "    adb shell cmd overlay lookup ${OVERLAY_PACKAGE} android:dimen/rounded_corner_radius"
echo "    adb shell cmd overlay lookup ${OVERLAY_PACKAGE} android:dimen/status_bar_height_default"
echo ""
echo -e "  ${BOLD}Resource audit:${NC}"
echo "    out/${OVERLAY_NAME}-overrides.txt  (APPLIES / IGNORED per resource)"
echo ""
