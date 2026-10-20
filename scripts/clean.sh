#!/usr/bin/env bash
# =============================================================================
# Treble Overlay — clean implementation
# =============================================================================
# Run through the entry point:
#   ./build.sh clean          interactive (quick or full)
#   ./build.sh clean --all    full clean (asks for confirmation)
#   ./build.sh clean --all -y full clean, no questions
# =============================================================================

if [ -z "${ROOT:-}" ]; then
    echo "This is an internal module — run ./build.sh clean instead." >&2
    exit 1
fi

cd "$ROOT" || exit 1

CLEAN_ALL="${CLEAN_ALL:-false}"
ASSUME_YES="${ASSUME_YES:-false}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
fmt_size() { du -sh "$1" 2>/dev/null | cut -f1 || echo "?"; }

# README.md is tracked so a fresh clone keeps the folder; it is not a device file.
count_files() { find "$1" -type f ! -name README.md 2>/dev/null | wc -l | tr -d ' '; }

has_vendor_files() {
    [ -d "$VENDOR_DIR" ] && [ "$(count_files "$VENDOR_DIR")" -gt 0 ]
}

list_artifacts() {
    [ -d "$BUILD_DIR" ] && echo "build/  ($(fmt_size "$BUILD_DIR"))"
    [ -d "$OUT_DIR" ] && echo "out/  ($(fmt_size "$OUT_DIR"))"
    local f
    for f in AndroidManifest.xml module.prop Android.mk; do
        [ -f "$ROOT/$f" ] && echo "$f  (legacy auto-generated)"
    done
    return 0
}

do_backup() {
    mkdir -p "$BACKUP_DIR"
    local backed_up=false

    if [ -f "$CONFIG_FILE" ]; then
        cp "$CONFIG_FILE" "$BACKUP_DIR/config.env"
        ok "Backed up config.env"
        backed_up=true
    fi
    local f
    for f in customize.sh service.sh sepolicy.rule; do
        if [ -f "$MODULE_DIR/$f" ]; then
            cp "$MODULE_DIR/$f" "$BACKUP_DIR/$f"
            ok "Backed up $f"
            backed_up=true
        fi
    done
    if has_vendor_files; then
        rm -rf "$BACKUP_DIR/vendor"
        cp -R "$VENDOR_DIR" "$BACKUP_DIR/vendor"
        ok "Backed up src/vendor/ ($(count_files "$VENDOR_DIR")) files)"
        backed_up=true
    fi

    echo ""
    if $backed_up; then
        info "Backup saved to backups/"
    else
        info "Nothing to back up"
    fi
    echo ""
    return 0
}

remove_build_output() {
    if [ -d "$BUILD_DIR" ]; then
        rm -rf "$BUILD_DIR"
        ok "Removed: build/"
    fi
    if [ -d "$OUT_DIR" ]; then
        rm -rf "$OUT_DIR"
        ok "Removed: out/"
    fi
    local f
    for f in AndroidManifest.xml module.prop Android.mk; do
        if [ -f "$ROOT/$f" ]; then
            rm -f "$ROOT/$f"
            ok "Removed: $f (auto-generated)"
        fi
    done
    return 0
}

restore_templates() {
    # git first: a tracked file's committed content is the template for this
    # release, so "start over" cannot hand back a copy that froze at an old
    # commit. templates/recoveries/ is only the no-.git fallback.
    if restore_from_release "config.env" "$RECOVERIES_DIR/config.env"; then
        ok "Restored: config.env"
    else
        warn "config.env was not restored — no git, and templates/recoveries/config.env is missing"
    fi

    # customize.sh and service.sh are generated from config.env at build time.
    # Only sepolicy.rule is a real template that can be restored here.
    if restore_from_release "src/module/sepolicy.rule" "$RECOVERIES_DIR/sepolicy.rule"; then
        ok "Restored: src/module/sepolicy.rule"
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Header and current state
# ---------------------------------------------------------------------------
banner "Treble Overlay — Cleanup"

echo -e "  ${BOLD}Current state${NC}"
local_artifacts=$(list_artifacts)
if [ -n "$local_artifacts" ]; then
    while IFS= read -r line; do
        echo -e "    ${YELLOW}▲${NC} $line"
    done <<< "$local_artifacts"
else
    echo -e "    ${GREEN}✓${NC} No build artifacts"
fi
[ -f "$CONFIG_FILE" ] && echo -e "    ${CYAN}●${NC} config.env  (device configuration)"
has_vendor_files && echo -e "    ${CYAN}●${NC} src/vendor/  ($(count_files "$VENDOR_DIR") device files)"
echo ""

# ---------------------------------------------------------------------------
# Choose a mode
# ---------------------------------------------------------------------------
if [ "$CLEAN_ALL" != "true" ]; then
    echo -e "  ${BOLD}What should be removed?${NC}"
    echo ""
    echo -e "    ${BOLD}[1]${NC} ${GREEN}Build output only${NC}"
    echo "        build/, out/, generated manifests. Keeps config.env and device files."
    echo "        Safe to run at any time."
    echo ""
    echo -e "    ${BOLD}[2]${NC} ${RED}Everything (start over)${NC}"
    echo "        Also removes config.env, src/vendor/ contents and the module scripts,"
    echo "        then restores the fresh templates. Use this to re-target a new device."
    echo ""
    ask "  Choose [1/2] or q to quit: " "q"

    case "$REPLY" in
        1) CLEAN_ALL=false ;;
        2) CLEAN_ALL=true ;;
        *) info "Cleanup cancelled."; exit 0 ;;
    esac
fi

# ---------------------------------------------------------------------------
# Full clean confirmation
# ---------------------------------------------------------------------------
if [ "$CLEAN_ALL" = "true" ] && ! $ASSUME_YES; then
    echo ""
    echo -e "  ${RED}${BOLD}This will delete:${NC}"
    echo "    • build/, out/ and generated manifests"
    echo "    • src/vendor/ contents ($(count_files "$VENDOR_DIR") files)"
    echo "    • config.env"
    echo "    • src/module/customize.sh, service.sh, sepolicy.rule"
    echo ""
    echo "  Everything is copied to backups/ first. config.env and sepolicy.rule are"
    echo "  restored to the version this clone shipped with (git checkout, or the"
    echo "  bundled copy when there is no .git); module scripts are generated again"
    echo "  at build time."
    echo ""
    ask "  Type YES to continue: " "no"
    if [ "$REPLY" != "YES" ]; then
        info "Full clean cancelled."
        exit 0
    fi
fi

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------
step "Backing up"
do_backup

step "Removing build output"
remove_build_output

if [ "$CLEAN_ALL" = "true" ]; then
    step "Removing device-specific files"

    if has_vendor_files; then
        find "$VENDOR_DIR" -mindepth 1 -maxdepth 1 ! -name README.md -exec rm -rf {} + 2>/dev/null || true
        ok "Removed: src/vendor/ contents"
    else
        info "src/vendor/ is already empty"
    fi

    rm -f "$CONFIG_FILE"
    ok "Removed: config.env"

    for f in customize.sh service.sh sepolicy.rule; do
        rm -f "$MODULE_DIR/$f"
    done
    ok "Removed: src/module/ scripts"

    step "Restoring templates"
    restore_templates

    # Keep the extraction folders ready for the next device.
    mkdir -p "$VENDOR_DIR/bin/hw" "$VENDOR_DIR/etc/init" \
             "$VENDOR_DIR/etc/vintf/manifest" "$VENDOR_DIR/lib64"
    ok "Re-created empty src/vendor/ structure"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
if [ "$CLEAN_ALL" = "true" ]; then
    echo -e "  ${GREEN}${BOLD}Full clean complete.${NC}"
    echo ""
    echo -e "  ${YELLOW}→${NC} Edit config.env for your device, then run: ./build.sh"
    echo -e "  ${YELLOW}→${NC} Vendor files are explained in docs/device-extraction.md"
    echo -e "  ${YELLOW}→${NC} Your previous files are in backups/"
else
    echo -e "  ${GREEN}${BOLD}Build output removed.${NC}"
    echo ""
    echo -e "  ${YELLOW}→${NC} config.env and device files are untouched."
    echo -e "  ${YELLOW}→${NC} Rebuild with: ./build.sh"
fi
echo ""
