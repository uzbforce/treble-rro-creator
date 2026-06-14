#!/bin/bash
# =============================================================================
# Treble Overlay — Cleanup Utility
# =============================================================================
# Interactive script with two cleanup modes:
#
#   [1] Quick Clean — Removes only build artifacts and auto-generated files
#       (APKs, build/, .idsig, AndroidManifest.xml, module.prop). Backs up
#       config.env, sepolicy.rule, system/vendor/ to YOUR BACKUPS/ first.
#       Safe to run anytime.
#
#   [2] Full Clean  — Removes everything from Quick Clean, PLUS the vendor
#       device files (system/), config.env, and sepolicy.rule. Backs up
#       everything first, then restores fresh templates from:
#         "TEMPLATE RECOVERIES (Don't touch)/"
#       Use this when re-targeting a completely different device.
#
# Usage: ./cleanup.sh
# =============================================================================

set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'
BOLD='\033[1m'; NC='\033[0m'
ok()   { echo -e "  ${GREEN}✓${NC} $*"; }
info() { echo -e "  ${YELLOW}→${NC} $*"; }
warn() { echo -e "  ${RED}⚠${NC} $*"; }
step() { echo -e "\n${BOLD}━━━ $* ━━━${NC}"; }

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
BACKUP_DIR="YOUR BACKUPS"
TEMPLATE_DIR="TEMPLATE RECOVERIES (Don't touch)"

# ---------------------------------------------------------------------------
# Utility: count / format
# ---------------------------------------------------------------------------
fmt_size() {
    du -sh "$1" 2>/dev/null | cut -f1 || echo "0"
}

list_build_artifacts() {
    [ -d "out" ] && find out -type f \( -name '*.apk' -o -name '*.zip' \) 2>/dev/null | sort
}

# ---------------------------------------------------------------------------
# Backup helper — always creates/replaces a single backup
# ---------------------------------------------------------------------------
do_backup() {
    mkdir -p "$BACKUP_DIR"
    local backed_up=false

    [ -f "config.env" ] && { cp config.env "$BACKUP_DIR/config.env"; ok "Backed up config.env"; backed_up=true; } || true
    [ -f "sepolicy.rule" ] && { cp sepolicy.rule "$BACKUP_DIR/sepolicy.rule"; ok "Backed up sepolicy.rule"; backed_up=true; } || true
    [ -f "customize.sh" ] && { cp customize.sh "$BACKUP_DIR/customize.sh"; ok "Backed up customize.sh"; backed_up=true; } || true
    [ -f "service.sh" ] && { cp service.sh "$BACKUP_DIR/service.sh"; ok "Backed up service.sh"; backed_up=true; } || true

    if [ -d "system/vendor" ] && [ "$(find system/vendor -type f 2>/dev/null | wc -l)" -gt 0 ]; then
        rm -rf "$BACKUP_DIR/vendor"
        cp -r system/vendor "$BACKUP_DIR/vendor"
        ok "Backed up system/vendor/ ($(find system/vendor -type f 2>/dev/null | wc -l) files)"
        backed_up=true
    fi

    if $backed_up; then
        info "Backup saved to ${BACKUP_DIR}/"
    else
        info "Nothing to back up"
    fi
    echo ""
}

# ---------------------------------------------------------------------------
# Header
# ---------------------------------------------------------------------------
echo -e "${BOLD}"
echo "  ╔══════════════════════════════════════════════════════╗"
echo "  ║              Treble Overlay — Cleanup                ║"
echo "  ╚══════════════════════════════════════════════════════╝"
echo -e "${NC}"

# ---------------------------------------------------------------------------
# Check what's dirty
# ---------------------------------------------------------------------------
BUILD_ARTIFACTS=$(list_build_artifacts)
HAS_BUILD_DIR=$([ -d "build" ] && echo "yes" || echo "no")
HAS_OUT_DIR=$([ -d "out" ] && echo "yes" || echo "no")
HAS_CONFIG=$([ -f "config.env" ] && echo "yes" || echo "no")
HAS_VENDOR_FILES=$([ -d "system/vendor" ] && [ "$(find system/vendor -type f 2>/dev/null | wc -l)" -gt 0 ] && echo "yes" || echo "no")

echo -e "  ${BOLD}Current state:${NC}"
if [ -n "$BUILD_ARTIFACTS" ] || [ "$HAS_BUILD_DIR" = "yes" ] || [ "$HAS_OUT_DIR" = "yes" ]; then
    if [ -n "$BUILD_ARTIFACTS" ]; then
        while IFS= read -r f; do
            echo -e "    ${YELLOW}▲${NC} $f  ($(fmt_size "$f"))"
        done <<< "$BUILD_ARTIFACTS"
    fi
    [ "$HAS_BUILD_DIR" = "yes" ] && echo -e "    ${YELLOW}▲${NC} build/  ($(fmt_size "build"))"
    [ "$HAS_OUT_DIR" = "yes" ] && echo -e "    ${YELLOW}▲${NC} out/  ($(fmt_size "out"))"
    [ -f "AndroidManifest.xml" ] && echo -e "    ${YELLOW}▲${NC} AndroidManifest.xml  (auto-generated)"
    [ -f "module.prop" ] && echo -e "    ${YELLOW}▲${NC} module.prop  (auto-generated)"
else
    echo -e "    ${GREEN}✓${NC} No build artifacts found"
fi
[ "$HAS_CONFIG" = "yes" ] && echo -e "    ${CYAN}●${NC} config.env  (device configuration)"
[ "$HAS_VENDOR_FILES" = "yes" ] && echo -e "    ${CYAN}●${NC} system/vendor/  (${BOLD}$(find system/vendor -type f 2>/dev/null | wc -l)${NC} device-specific files)"

echo ""
echo -e "  ${BOLD}Choose cleanup mode:${NC}"
echo ""
echo -e "    ${BOLD}[1]${NC} ${GREEN}Quick Clean${NC} — Remove build artifacts only"
echo -e "        APKs, build/, auto-generated files. Preserves config.env and vendor files."
echo ""
echo -e "    ${BOLD}[2]${NC} ${RED}Full Clean${NC}  — Remove build artifacts + vendor files + config"
echo -e "        Removes APKs, build/, system/, config.env, sepolicy.rule, customize.sh."
echo -e "        Restores fresh templates from TEMPLATE RECOVERIES/."
echo -e "        ${YELLOW}Use this when re-targeting a completely different device.${NC}"
echo ""

# ---------------------------------------------------------------------------
# Prompt
# ---------------------------------------------------------------------------
read -r -p "  Enter choice [1/2] or q to quit: " choice

case "$choice" in
    1)
        echo ""
        step "Quick Clean — Backup first"
        do_backup

        step "Quick Clean — Removing build artifacts"
        
        [ -d "build" ] && rm -rf build && ok "Removed: build/"
        [ -d "out" ] && rm -rf out && ok "Removed: out/"
        [ -d ".module_tmp" ] && rm -rf .module_tmp && ok "Removed: .module_tmp/"
        for f in AndroidManifest.xml module.prop; do
            [ -f "$f" ] && rm -f "$f" && ok "Removed: $f (auto-generated)"
        done
        
        echo ""
        echo -e "  ${GREEN}${BOLD}Quick clean complete.${NC}"
        echo -e "  ${YELLOW}→${NC} config.env and vendor files are untouched."
        echo -e "  ${YELLOW}→${NC} A backup was saved to ${BACKUP_DIR}/"
        echo -e "  ${YELLOW}→${NC} Run ./build.sh to rebuild."
        ;;
        
    2)
        echo ""
        echo -e "  ${RED}${BOLD}╔══════════════════════════════════════════════════════╗${NC}"
        echo -e "  ${RED}${BOLD}║                    WARNING !                         ║${NC}"
        echo -e "  ${RED}${BOLD}╚══════════════════════════════════════════════════════╝${NC}"
        echo ""
        echo -e "  This will permanently delete:"
        echo ""
        echo -e "    ${BOLD}❶${NC} All build artifacts (APKs, build/, etc.)"
        echo -e "    ${BOLD}❷${NC} ${RED}system/vendor/${NC} — all HAL binaries, init scripts,"
        echo -e "        VINTF manifests, and shared libraries"
        echo -e "    ${BOLD}❸${NC} ${RED}config.env${NC} — your device configuration"
        echo -e "    ${BOLD}❹${NC} ${RED}sepolicy.rule${NC} — your SELinux policy rules"
        echo -e "    ${BOLD}❺${NC} ${RED}customize.sh${NC} — module install script"
        echo -e "    ${BOLD}❻${NC} ${RED}service.sh${NC} — post-boot init script"
        echo ""
        echo -e "  ${YELLOW}Before deleting, everything is backed up to ${BACKUP_DIR}/${NC}"
        echo ""
        echo -e "  ${YELLOW}After cleanup, fresh templates are restored from:${NC}"
        echo -e "    ${BOLD}${TEMPLATE_DIR}/${NC}"
        echo -e "  ${YELLOW}(config.env, sepolicy.rule, customize.sh, service.sh)${NC}"
        echo ""
        echo -e "  ${YELLOW}Source files res/, systemui_overlay/, and keys/${NC}"
        echo -e "  ${YELLOW}are preserved.${NC}"
        echo ""
        echo -e -n "  Type ${BOLD}YES${NC} to confirm full cleanup: "
        read -r confirm
        echo ""
        
        if [ "$confirm" != "YES" ]; then
            echo -e "  ${YELLOW}→${NC} Full clean cancelled."
            exit 0
        fi
        
        step "Full Clean — Backup first"
        do_backup
        
        step "Full Clean — Build artifacts"
        
        [ -d "build" ] && rm -rf build && ok "Removed: build/"
        [ -d "out" ] && rm -rf out && ok "Removed: out/"
        [ -d ".module_tmp" ] && rm -rf .module_tmp && ok "Removed: .module_tmp/"
        for f in AndroidManifest.xml module.prop; do
            [ -f "$f" ] && rm -f "$f" && ok "Removed: $f (auto-generated)"
        done
        
        step "Full Clean — Vendor device files"
        
        if [ -d "system/product" ] && [ "$(find system/product -type f 2>/dev/null | wc -l)" -gt 0 ]; then
            rm -rf system/product && ok "Removed: system/product/ (device overlay APK)"
        else
            info "system/product/ is empty or missing — nothing to remove"
        fi
        
        if [ -d "system/vendor" ] && [ "$(find system/vendor -type f 2>/dev/null | wc -l)" -gt 0 ]; then
            VENDOR_COUNT=$(find system/vendor -type f 2>/dev/null | wc -l)
            rm -rf system/vendor && ok "Removed: system/vendor/ (${VENDOR_COUNT} device-specific files)"
        else
            info "system/vendor/ is empty or missing — nothing to remove"
        fi

        # Remove system/ entirely if it's now empty
        if [ -d "system" ] && [ "$(find system -type f 2>/dev/null | wc -l)" -eq 0 ]; then
            rmdir system/vendor/bin/hw system/vendor/bin system/vendor/etc/init system/vendor/etc/vintf/manifest system/vendor/etc/vintf system/vendor/etc system/vendor/lib64 system/vendor system/product/overlay system/product system 2>/dev/null || true
            info "system/ directory removed (empty)"
        fi
        
        step "Full Clean — Configuration & user files"
        
        [ -f "config.env" ] && rm -f config.env && ok "Removed: config.env" || true
        [ -f "sepolicy.rule" ] && rm -f sepolicy.rule && ok "Removed: sepolicy.rule" || true
        [ -f "customize.sh" ] && rm -f customize.sh && ok "Removed: customize.sh" || true
        [ -f "service.sh" ] && rm -f service.sh && ok "Removed: service.sh" || true
        
        step "Full Clean — Restoring templates from ${TEMPLATE_DIR}/"
        
        if [ -d "$TEMPLATE_DIR" ]; then
            if [ -f "$TEMPLATE_DIR/config.env" ]; then
                cp "$TEMPLATE_DIR/config.env" config.env && ok "Restored: config.env (from template)"
            else
                warn "Template config.env not found in ${TEMPLATE_DIR}/"
            fi
            if [ -f "$TEMPLATE_DIR/sepolicy.rule" ]; then
                cp "$TEMPLATE_DIR/sepolicy.rule" sepolicy.rule && ok "Restored: sepolicy.rule (empty template)"
            else
                warn "Template sepolicy.rule not found in ${TEMPLATE_DIR}/"
            fi
            if [ -f "$TEMPLATE_DIR/customize.sh" ]; then
                cp "$TEMPLATE_DIR/customize.sh" customize.sh && ok "Restored: customize.sh (generic template)"
            else
                warn "Template customize.sh not found in ${TEMPLATE_DIR}/"
            fi
            if [ -f "$TEMPLATE_DIR/service.sh" ]; then
                cp "$TEMPLATE_DIR/service.sh" service.sh && ok "Restored: service.sh (generic template)"
            else
                warn "Template service.sh not found in ${TEMPLATE_DIR}/"
            fi
        else
            warn "TEMPLATE RECOVERIES directory not found — skipping template restore"
            warn "Create it with: mkdir -p '${TEMPLATE_DIR}'"
            warn "Place config.env, sepolicy.rule, customize.sh templates inside"
        fi

        # Re-create empty vendor directories for extraction readiness
        mkdir -p system/vendor/bin/hw system/vendor/etc/init system/vendor/etc/vintf/manifest system/vendor/lib64
        ok "Re-created empty system/vendor/ structure (ready for extraction)"
        
        echo ""
        echo -e "  ${RED}${BOLD}Full clean complete.${NC}"
        echo -e "  ${YELLOW}→${NC} Build artifacts, vendor files, and config removed."
        echo -e "  ${YELLOW}→${NC} Templates restored from ${TEMPLATE_DIR}/ (config.env, sepolicy.rule, customize.sh, service.sh)"
        echo -e "  ${YELLOW}→${NC} Backup saved to ${BACKUP_DIR}/ (in case you need it back)"
        echo -e "  ${YELLOW}→${NC} Edit config.env for your device, then run ./build.sh"
        echo -e "  ${YELLOW}→${NC} Extract vendor files per vendor_extraction_guide.md"
        ;;
        
    q|Q)
        echo -e "  ${YELLOW}→${NC} Cleanup cancelled."
        exit 0
        ;;
        
    *)
        echo -e "  ${RED}Invalid choice.${NC} Run ./cleanup.sh again and select 1 or 2."
        exit 1
        ;;
esac
