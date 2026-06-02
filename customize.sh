#!/sbin/sh
# =============================================================================
# Treble Overlay — KSU/Magisk Module Install Script (Template)
# =============================================================================
# This is a template for TEMPLATE RECOVERIES. During the build process,
# build.sh auto-generates the actual customize.sh that ships in the module.
#
# If you need custom SELinux contexts for specific HAL binaries (e.g.,
# hal_fingerprint_default_exec, hal_vibrator_default_exec), you can:
#   1. Place a customize.sh at the project root with your custom set_perm calls
#   2. build.sh will detect it and use it instead of auto-generating
#
# ⚠ NOTE: The auto-generated version uses generic vendor_file:s0 for binaries.
#   This works functionally but won't trigger SELinux domain transitions
#   (e.g., init → hal_fingerprint_default). If your HAL needs device node
#   access, you likely need the correct per-HAL contexts.
#   See sepolicy.rule.example for reference SELinux types.
# =============================================================================

MODPATH=${0%/*}

ui_print "  Installing ${MODPATH##*/}..."

# ── Overlay APKs ──────────────────────────────────────────────────────────
set_perm_recursive $MODPATH/system/product/overlay 0 0 0644 u:object_r:system_file:s0

# ── Vendor HAL binaries ───────────────────────────────────────────────────
# Add custom set_perm calls for each HAL binary here with the correct context.
# Example:
#   set_perm $MODPATH/system/vendor/bin/hw/android.hardware.biometrics.fingerprint@2.3-service.samsung \
#       0 2000 0755 u:object_r:vendor_file:s0
if [ -d "$MODPATH/system/vendor/bin/hw" ]; then
    for binary in $MODPATH/system/vendor/bin/hw/*; do
        [ -f "$binary" ] && set_perm "$binary" 0 2000 0755 u:object_r:vendor_file:s0
    done
    ui_print "  • Vendor HAL binaries set ($(ls $MODPATH/system/vendor/bin/hw/ 2>/dev/null | wc -l) files)"
fi

# ── Shared libraries ──────────────────────────────────────────────────────
if [ -d "$MODPATH/system/vendor/lib64" ]; then
    set_perm_recursive $MODPATH/system/vendor/lib64 0 0 0644 u:object_r:vendor_file:s0
    ui_print "  • Vendor shared libraries set"
fi

# ── Init .rc files ────────────────────────────────────────────────────────
if [ -d "$MODPATH/system/vendor/etc/init" ]; then
    set_perm_recursive $MODPATH/system/vendor/etc/init 0 0 0644 u:object_r:vendor_configs_file:s0
    ui_print "  • Init .rc files set"
fi

# ── VINTF manifest fragments ──────────────────────────────────────────────
if [ -d "$MODPATH/system/vendor/etc/vintf/manifest" ]; then
    set_perm_recursive $MODPATH/system/vendor/etc/vintf/manifest 0 0 0644 u:object_r:vendor_configs_file:s0
    ui_print "  • VINTF manifest files set"
fi

# ── Done ──────────────────────────────────────────────────────────────────
ui_print "  ✓ Module installed successfully!"
