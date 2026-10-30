#!/usr/bin/env bash
# =============================================================================
# config.env preflight
# =============================================================================
# Catches the mistakes that build fine and only show up on the phone:
# placeholders left in place, a padding value with no corner to match it,
# brightness arrays whose lengths do not line up, a half-filled UDFPS triple,
# a key that no script reads (a typo), and so on.
#
# Everything here is a warning, because a value that looks odd can still be
# deliberate. Resources that cannot compile at all (a radius of "abc") are
# already an error in stuff/scripts/resources.sh.
#
# Sourced by build.sh right after config.env is loaded. Standalone:
#
#   ./stuff/scripts/validate.sh      read ./config.env and report
#   ./stuff/scripts/validate.sh --strict   exit 1 when anything is reported
# =============================================================================

if [ "${BASH_SOURCE[0]}" != "$0" ] && [ -z "${ROOT:-}" ]; then
    echo "This is an internal build script — run ./build.sh check instead." >&2
    return 1 2>/dev/null || exit 1
fi

VALIDATE_WARNINGS=0
VALIDATE_NOTES=0

_v_warn() {
    VALIDATE_WARNINGS=$((VALIDATE_WARNINGS + 1))
    if command -v warn >/dev/null 2>&1; then
        warn "$*"
    else
        echo "  ! $*" >&2
    fi
}

_v_note() {
    VALIDATE_NOTES=$((VALIDATE_NOTES + 1))
    if command -v info >/dev/null 2>&1; then
        info "$*"
    else
        echo "  - $*"
    fi
}

# is_set <value> -> true when the value is neither empty nor a placeholder.
is_set() {
    local v="${1:-}"
    [ -n "$v" ] || return 1
    case "$v" in *'<'*) return 1 ;; esac   # <codename>, <value>
    [[ "$v" =~ ^0+$ ]] && return 1        # 000, 0000
    return 0
}

_v_int() { printf '%s' "${1:-}" | tr -dc '0-9'; }

# list_count / list_ints / list_numbers come from resources.sh when build.sh
# runs; define them here for the standalone case.
command -v list_count >/dev/null 2>&1 || list_count() {
    local n=0 v
    for v in $1; do n=$((n + 1)); done
    printf '%s' "$n"
}
command -v list_ints >/dev/null 2>&1 || list_ints() {
    local v
    for v in $1; do [[ "$v" =~ ^[0-9]+$ ]] || return 1; done
    return 0
}
command -v list_numbers >/dev/null 2>&1 || list_numbers() {
    local v
    for v in $1; do [[ "$v" =~ ^[0-9]+([.][0-9]+)?$ ]] || return 1; done
    return 0
}

# ---------------------------------------------------------------------------
# Placeholders
# ---------------------------------------------------------------------------
_validate_placeholders() {
    local key value
    for key in DEVICE_MANUFACTURER DEVICE_MODEL DEVICE_CODENAME \
               ROUNDED_CORNER_RADIUS STATUS_BAR_HEIGHT UDFPS_X UDFPS_Y UDFPS_RADIUS \
               DEFAULT_REFRESH_RATE PEAK_REFRESH_RATE; do
        value="${!key:-}"
        if [ -z "$value" ]; then
            _v_warn "${key} is empty"
        elif is_set "$value"; then
            :
        else
            case "$key" in
                ROUNDED_CORNER_RADIUS|STATUS_BAR_HEIGHT|UDFPS_X|UDFPS_Y|UDFPS_RADIUS|DEFAULT_REFRESH_RATE|PEAK_REFRESH_RATE)
                    _v_warn "${key}=\"${value}\" is still the placeholder — the build will use 0"
                    ;;
                *)
                    _v_warn "${key}=\"${value}\" is still the placeholder"
                    ;;
            esac
        fi
    done
}

# ---------------------------------------------------------------------------
# Display geometry
# ---------------------------------------------------------------------------
_validate_display() {
    local radius sb_height land pad_content pad_start pad_end
    radius=$(_v_int "${ROUNDED_CORNER_RADIUS:-}")
    sb_height=$(_v_int "${STATUS_BAR_HEIGHT:-}")
    land=$(_v_int "${STATUS_BAR_HEIGHT_LANDSCAPE:-}")
    pad_content=$(_v_int "${STATUS_BAR_CONTENT_PADDING:-}")
    pad_start=$(_v_int "${STATUS_BAR_PADDING_START:-}")
    pad_end=$(_v_int "${STATUS_BAR_PADDING_END:-}")

    if [ -n "$radius" ] && [ "$radius" -gt 400 ]; then
        _v_warn "ROUNDED_CORNER_RADIUS=${radius}px is larger than any phone corner (check the unit)"
    fi

    # The three padding keys only make sense together, and they must agree:
    # the framework and SystemUI paths override each other instead of adding up.
    if [ -n "$pad_content$pad_start$pad_end" ]; then
        if [ -z "$pad_content" ] || [ -z "$pad_start" ] || [ -z "$pad_end" ]; then
            _v_warn "STATUS_BAR_CONTENT_PADDING, _PADDING_START and _PADDING_END should all be set"
        elif [ "$pad_content" != "$pad_start" ] || [ "$pad_content" != "$pad_end" ]; then
            _v_warn "status bar padding differs (${pad_content}/${pad_start}/${pad_end}) — set all three to the same value"
        fi
        if [ -n "$radius" ] && [ "$radius" -gt 0 ] && [ "$pad_start" -gt "$radius" ]; then
            _v_warn "STATUS_BAR_PADDING_START=${pad_start} is wider than the corner (${radius}px)"
        fi
    fi

    if [ -n "$sb_height" ] && [ "$sb_height" -gt 0 ]; then
        if [ "$sb_height" -lt 48 ]; then
            _v_warn "STATUS_BAR_HEIGHT=${sb_height}px is very small (a normal bar is 60-140px)"
        elif [ "$sb_height" -gt 400 ]; then
            _v_warn "STATUS_BAR_HEIGHT=${sb_height}px is very large (a normal bar is 60-140px)"
        fi
    fi
    if [ -n "$land" ] && [ -n "$sb_height" ] && [ "$land" -gt "$sb_height" ]; then
        _v_note "status bar landscape (${land}px) is taller than portrait (${sb_height}px)"
    fi

    # A path with no suffix is in px — that is the default the parser uses, and
    # it is how MIUI stores its own (e.g. "M 0,0 H -29 V 118 H 29 V 0 H 0 Z").
    # Only an unknown @unit is a mistake; @dp/@left/@right/@top/@bottom are the
    # documented ones.
    case "${DISPLAY_CUTOUT:-}" in
        "") ;;
        *'<'*) ;;
        *'@'*)
            case "$DISPLAY_CUTOUT" in
                *@dp|*@px|*@left|*@right|*@top|*@bottom) ;;
                *) _v_warn "DISPLAY_CUTOUT has an unknown @unit suffix (use @dp, @left, @right, @top, @bottom, or none for px)" ;;
            esac
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Fingerprint / sensors
# ---------------------------------------------------------------------------
_validate_udfps() {
    local triple_set=false
    if [ -n "${UDFPS_X:-}${UDFPS_Y:-}${UDFPS_RADIUS:-}" ]; then
        if is_set "${UDFPS_X:-}" && is_set "${UDFPS_Y:-}" && is_set "${UDFPS_RADIUS:-}"; then
            triple_set=true
        else
            triple_set=partial
        fi
    fi

    if [ "$HAS_UDFPS" = "true" ]; then
        if [ "$triple_set" = "partial" ]; then
            _v_warn "HAS_UDFPS=true but UDFPS_X/Y/RADIUS are only partly set — the GSI default stays"
        elif [ "$triple_set" = "false" ]; then
            _v_note "HAS_UDFPS=true without coordinates — the HAL/SystemUI locates the sensor"
        fi
        if [ "$(_v_int "${UDFPS_RADIUS:-0}")" -le 0 ] 2>/dev/null && [ "$triple_set" = "true" ]; then
            _v_warn "UDFPS_RADIUS must be greater than 0 (typically 60-120)"
        fi
    else
        [ "$triple_set" = "false" ] || _v_warn "UDFPS_* is set while HAS_UDFPS=false — it will be ignored"
        if [ "${HAS_SAMSUNG_FOD:-false}" = "true" ] || [ "${HAS_SAMSUNG_VIBRATOR:-false}" = "true" ] \
           || [ "${HAS_SAMSUNG_FINGERPRINT:-false}" = "true" ]; then
            _v_warn "HAS_SAMSUNG_* is true while HAS_UDFPS=false — those resources are not emitted"
        fi
    fi
}

# ---------------------------------------------------------------------------
# Brightness / refresh rate
# ---------------------------------------------------------------------------
_validate_brightness() {
    local levels backlight nits screen_nits n_levels n_backlight n_nits n_screen rr rr_peak

    levels="${AUTO_BRIGHTNESS_LEVELS:-}"
    backlight="${AUTO_BRIGHTNESS_BACKLIGHT_VALUES:-}"
    nits="${AUTO_BRIGHTNESS_DISPLAY_VALUES_NITS:-}"
    screen_nits="${SCREEN_BRIGHTNESS_NITS:-}"

    if [ -n "$levels" ]; then
        n_levels=$(list_count "$levels")
        if ! list_ints "$levels"; then
            _v_warn "AUTO_BRIGHTNESS_LEVELS must be integers"
        fi
        if [ -n "$backlight" ]; then
            n_backlight=$(list_count "$backlight")
            if [ "$n_backlight" -ne $((n_levels + 1)) ]; then
                _v_warn "AUTO_BRIGHTNESS_BACKLIGHT_VALUES has ${n_backlight} values, needs $((n_levels + 1)) (levels + 1)"
            fi
        fi
        if [ -n "$nits" ]; then
            n_nits=$(list_count "$nits")
            if [ "$n_nits" -ne $((n_levels + 1)) ]; then
                _v_warn "AUTO_BRIGHTNESS_DISPLAY_VALUES_NITS has ${n_nits} values, needs $((n_levels + 1)) (levels + 1)"
            fi
        fi
    elif [ -n "$backlight$nits" ]; then
        _v_warn "AUTO_BRIGHTNESS_BACKLIGHT_VALUES/NITS are set but AUTO_BRIGHTNESS_LEVELS is empty — nothing is emitted"
    fi

    if [ -n "$screen_nits" ]; then
        if [ -z "${SCREEN_BRIGHTNESS_BACKLIGHT:-}" ]; then
            _v_warn "SCREEN_BRIGHTNESS_NITS needs SCREEN_BRIGHTNESS_BACKLIGHT (same number of values)"
        else
            n_nits=$(list_count "$screen_nits")
            n_screen=$(list_count "$SCREEN_BRIGHTNESS_BACKLIGHT")
            [ "$n_nits" = "$n_screen" ] || \
                _v_warn "SCREEN_BRIGHTNESS_NITS has ${n_nits} values, SCREEN_BRIGHTNESS_BACKLIGHT has ${n_screen} — they must match"
        fi
    fi

    rr=$(_v_int "${DEFAULT_REFRESH_RATE:-}")
    rr_peak=$(_v_int "${PEAK_REFRESH_RATE:-}")
    if [ -n "$rr_peak" ] && [ -n "$rr" ] && [ "$rr_peak" -lt "$rr" ]; then
        _v_warn "PEAK_REFRESH_RATE=${rr_peak} is lower than DEFAULT_REFRESH_RATE=${rr}"
    fi
    if [ -n "${PEAK_REFRESH_RATE:-}" ] && [ -z "$rr" ]; then
        _v_warn "PEAK_REFRESH_RATE is set without DEFAULT_REFRESH_RATE — neither is emitted"
    fi
}

# ---------------------------------------------------------------------------
# Module metadata
# ---------------------------------------------------------------------------
# These are baked into the APK and module.prop, so a wrong one is only visible
# on the phone. Check the one value Android refuses to take as free text.
_validate_metadata() {
    local code="${OVERLAY_VERSION_CODE:-}"
    if [ -n "$code" ] && ! [[ "$code" =~ ^[0-9]+$ ]]; then
        _v_warn "OVERLAY_VERSION_CODE=\"${code}\" is not a whole number — android:versionCode must be an integer"
    fi
}

# ---------------------------------------------------------------------------
# Overlay identity
# ---------------------------------------------------------------------------
_validate_overlay() {
    if [ -z "${DEVICE_PROP_NAME:-}" ]; then
        _v_note "DEVICE_PROP_NAME is empty — the overlay is not matched to a property (applies everywhere)"
    elif [ -z "${DEVICE_PROP_VALUE:-}" ]; then
        _v_warn "DEVICE_PROP_NAME is set but DEVICE_PROP_VALUE is empty"
    fi

    if [ -n "${OVERLAY_PRIORITY:-}" ] && [ -n "${OVERLAY_PRIORITY_SYSTEMUI:-}" ] \
       && [ "$OVERLAY_PRIORITY" = "$OVERLAY_PRIORITY_SYSTEMUI" ]; then
        _v_warn "OVERLAY_PRIORITY and OVERLAY_PRIORITY_SYSTEMUI are identical (${OVERLAY_PRIORITY}) — the SystemUI overlay must win"
    fi

    if [ ! -d "${ROOT:-.}/src/vendor/bin/hw" ] || \
       [ "$(ls -A "${ROOT:-.}/src/vendor/bin/hw" 2>/dev/null | grep -c .)" -eq 0 ]; then
        if [ "${HAS_VENDOR_FINGERPRINT_HAL:-false}" = "true" ] || [ "${HAS_VENDOR_VIBRATOR_HAL:-false}" = "true" ]; then
            _v_warn "HAS_VENDOR_*_HAL is true but src/vendor/bin/hw is empty — see docs/device-extraction.md"
        fi
    fi
}

# ---------------------------------------------------------------------------
# Overlay-repo submission (out/<name>-hardware-overlay.zip)
# ---------------------------------------------------------------------------
# The overlay repo compares android:requiredSystemPropertyValue with plain
# string equality and rejects duplicate priorities, so a value that looks fine
# here can make the submitted overlay inert or fail their tests/tests.sh.
_validate_submission() {
    local prop value prio file count
    prop="${HW_OVERLAY_MATCH_PROP:-ro.product.vendor.device}"
    value="${HW_OVERLAY_MATCH_VALUE:-${DEVICE_CODENAME:-}}"

    case "$value" in
        +*|-*|\**|*\**)
            _v_warn "HW_OVERLAY_MATCH_VALUE=\"${value}\" looks like a glob, but the overlay repo compares it with exact string equality — the submitted overlay would never activate"
            ;;
    esac
    if [ -n "${HW_OVERLAY_MATCH_PROP:-}" ] && [ -z "$value" ]; then
        _v_warn "HW_OVERLAY_MATCH_PROP is set but no value — set HW_OVERLAY_MATCH_VALUE (adb shell getprop ${prop})"
    fi
    if [ -z "${HW_OVERLAY_MATCH_PROP+x}" ] && [ -n "${HW_OVERLAY_MATCH_VALUE:-}" ]; then
        _v_note "HW_OVERLAY_MATCH_VALUE is set without HW_OVERLAY_MATCH_PROP — the default property ro.product.vendor.device is used"
    fi
    case "$prop" in
        ro.vendor.product.*)
            _v_warn "HW_OVERLAY_MATCH_PROP=\"${prop}\" is deprecated in the overlay repo — ro.product.vendor.device is preferred"
            ;;
    esac

    # Priority collisions: the repo's tests/tests.sh fails on a duplicate.
    prio="${HW_OVERLAY_PRIORITY:-}"
    if [ -n "$prio" ]; then
        file="${ROOT:-.}/stuff/scripts/data/treble-overlay-priorities.txt"
        if [ -f "$file" ]; then
            count=$(grep -cx "$prio" "$file" 2>/dev/null || true)
            if [ "${count:-0}" -gt 0 ]; then
                _v_warn "HW_OVERLAY_PRIORITY=${prio} is already used by another overlay in the overlay repo — tests/tests.sh will reject it"
            fi
        fi
    fi

    # The repo's tests reject config_automatic_brightness_available=true with no
    # curve to go with it.
    if [ "${HAS_AUTO_BRIGHTNESS:-false}" = "true" ] && [ -z "${AUTO_BRIGHTNESS_LEVELS:-}" ]; then
        _v_warn "HAS_AUTO_BRIGHTNESS=true without AUTO_BRIGHTNESS_LEVELS — the overlay repo's tests reject auto-brightness with no curve"
    fi

    # Resources on the repo's blacklist are dropped from the submission
    # automatically; build.sh prints which ones, so nothing to check here.
    return 0
}

# ---------------------------------------------------------------------------
# Typos: a key no script reads
# ---------------------------------------------------------------------------
_validate_unknown_keys() {
    local conf="${CONFIG_FILE:-$ROOT/config.env}"
    local scripts="${ROOT:-.}/stuff/scripts"
    local key
    [ -f "$conf" ] || return 0
    while IFS= read -r key; do
        [ -n "$key" ] || continue
        if ! grep -rqE "(^|[^A-Za-z0-9_])${key}([^A-Za-z0-9_]|$)" \
                "$scripts" "${ROOT:-.}/src/module" 2>/dev/null; then
            _v_warn "${key} is not read by any build script — typo?"
        fi
    done <<EOF
$(sed -n 's/^\([A-Z][A-Z0-9_]*\)=.*/\1/p' "$conf" 2>/dev/null | sort -u)
EOF
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
validate_config() {
    VALIDATE_WARNINGS=0
    VALIDATE_NOTES=0
    _validate_placeholders
    _validate_display
    _validate_udfps
    _validate_brightness
    _validate_overlay
    _validate_metadata
    _validate_submission
    _validate_unknown_keys

    if [ "$VALIDATE_WARNINGS" -eq 0 ]; then
        [ "$VALIDATE_NOTES" -gt 0 ] || _v_note "config.env looks consistent"
        return 0
    fi
    if command -v info >/dev/null 2>&1; then
        info "${VALIDATE_WARNINGS} config warning(s) — the build continues, the list above is what to fix"
    fi
    [ "${VALIDATE_STRICT:-false}" = "true" ] && return 1
    return 0
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
    export ROOT
    cd "$ROOT"
    source "$ROOT/stuff/scripts/common.sh"
    CONFIG_FILE="$ROOT/config.env"
    # shellcheck source=/dev/null
    [ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE"
    VALIDATE_STRICT=false
    [ "${1:-}" = "--strict" ] && VALIDATE_STRICT=true
    validate_config
    exit $?
fi
