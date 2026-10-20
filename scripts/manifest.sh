#!/usr/bin/env bash
# =============================================================================
# WebUI manifest — the resource list the page renders
# =============================================================================
# The WebUI does not hard-code the values it can edit any more. build.sh writes
# webroot/webui-manifest.json from the resource XML it generated from
# config.env, and the page builds its editor from that file:
#
#   $RES_DIR/values/*.xml          framework overlay   (apk: fw)
#   $RES_DIR/values-land/*.xml     landscape config    (apk: fw, read-only)
#   $SYSUI_RES_DIR/values/*.xml    SystemUI overlay    (apk: sui)
#
# The page writes the value into the overlay APK's resources.arsc, so a
# resource only belongs here when it has a single value: arrays, maps and float
# dimens are listed as read-only (they still need a rebuild).
#
# Sourced by build.sh (common.sh loaded, config.env sourced). With ROOT set it
# can also be run on its own:
#
#   ./scripts/manifest.sh plan        print the resource plan (no build)
#   ./scripts/manifest.sh write F     write the manifest to F
# =============================================================================

# Sourced by build.sh, or run directly for the standalone commands below.
if [ "${BASH_SOURCE[0]}" != "$0" ] && [ -z "${ROOT:-}" ]; then
    echo "This is an internal build module — run ./build.sh instead." >&2
    return 1 2>/dev/null || exit 1
fi

# ---------------------------------------------------------------------------
# JSON / XML text helpers
# ---------------------------------------------------------------------------
json_escape() {
    printf '%s' "$1" | tr -d '\r' | sed 's/\\/\\\\/g; s/"/\\"/g'
}

# XML entities in a value (an "&amp;" in a cutout path, &quot; in a string).
xml_unescape() {
    printf '%s' "$1" | sed 's/&quot;/"/g; s/&apos;/'"'"'/g; s/&lt;/</g; s/&gt;/>/g; s/&amp;/\&/g'
}

# ---------------------------------------------------------------------------
# Grouping — how the page orders and titles its sections
# ---------------------------------------------------------------------------
manifest_group() { # <resource-name> -> group title
    case "$1" in
        rounded_corner_radius*|secondary_rounded_corner_radius*) printf 'Corners' ;;
        rounded_corner_content_padding|status_bar_padding*|status_bar_icons_padding*|ongoing_appops_dot_min_padding) printf 'Status bar content' ;;
        status_bar_height*|quick_qs_offset_height) printf 'Status bar' ;;
        config_mainBuiltInDisplayCutout) printf 'Cutout' ;;
        config_screenBrightnessBacklight|config_screenBrightnessNits) printf 'Auto-brightness' ;;
        config_autoBrightness*) printf 'Auto-brightness' ;;
        config_screenBrightness*) printf 'Brightness' ;;
        config_defaultRefreshRate|config_defaultPeakRefreshRate) printf 'Refresh rate' ;;
        doze_*|config_doze*|config_displayBlanksAfterDoze) printf 'Doze / AOD' ;;
        config_biometric_sensors|config_udfps_sensor_props|config_dozeUdfpsLongPressSensorType) printf 'Fingerprint' ;;
        config_displayLightSensorType) printf 'Sensors' ;;
        config_carrier_*|config_radio_access_family|skip_restoring_network_selection|config_switch_phone_on_voice_reg_state_change|config_telephony5gNonStandalone|config_device_volte_available|config_device_vt_available|config_device_wfc_ims_available) printf 'Telephony' ;;
        config_supportAudioSourceUnprocessed|config_camera_sound_forced|config_cameraDoubleTapPowerGestureEnabled|config_useDevInputEventForAudioJack) printf 'Audio / input' ;;
        config_power*|config_fillMainBuiltInDisplayCutout|config_wifiDisplaySupportsProtectedBuffers) printf 'Power / display' ;;
        *) printf 'Other' ;;
    esac
}

manifest_group_rank() { # <group> -> sort key (display order)
    case "$1" in
        'Corners')                printf '10' ;;
        'Status bar')             printf '20' ;;
        'Status bar content')     printf '30' ;;
        'Cutout')                 printf '40' ;;
        'Brightness')             printf '50' ;;
        'Auto-brightness')        printf '60' ;;
        'Refresh rate')           printf '70' ;;
        'Doze / AOD')             printf '80' ;;
        'Fingerprint')            printf '90' ;;
        'Sensors')                printf '100' ;;
        'Telephony')              printf '110' ;;
        'Audio / input')          printf '120' ;;
        'Power / display')        printf '130' ;;
        *)                        printf '900' ;;
    esac
}

# ---------------------------------------------------------------------------
# Rows
# ---------------------------------------------------------------------------
# manifest_rows prints one tab-separated row per resource:
#
#   rank <TAB> group <TAB> apk <TAB> ro <TAB> type <TAB> name <TAB> value
#
# apk is "fw" or "sui" (the file the page patches), ro=1 means read-only
# (landscape config, array, float dimen) — listed so the page can show it, but
# not editable without a rebuild.
_manifest_xml_rows() { # <apk> <ro> <file>
    local apk="$1" ro="$2" file="$3"
    [ -f "$file" ] || return 0
    awk -v apk="$apk" -v ro="$ro" '
        function name_of(line) {
            if (match(line, /name="[^"]+"/)) return substr(line, RSTART + 6, RLENGTH - 7)
            return ""
        }
        # A value may be empty, inline, or on the lines between the tags
        # (<string name="x">\n   text\n</string>).
        function emit(tag, name, value,   v, r) {
            v = value
            gsub(/[ \t\r\n]+/, " ", v)
            sub(/^ /, "", v)
            sub(/ $/, "", v)
            # A resource reference cannot be patched into a literal value.
            r = ro
            if (v ~ /^[@?]/) r = 1
            printf "%s\t%s\t%s\t%s\t%s\n", apk, r, tag, name, v
        }
        {
            line = $0
            sub(/\r/, "", line)
            sub(/<!--.*/, "", line)
            if (line ~ /^[[:space:]]*<\/?resources/) next

            # Inside an array element every <item> belongs to that array.
            if (inarray) {
                if (line ~ /<\/[[:space:]]*(integer-array|string-array|array)/) inarray = 0
                next
            }

            # A value that started on an earlier line.
            if (open != "") {
                if (match(line, /<\/[[:space:]]*(dimen|bool|integer|string)/)) {
                    emit(open, openname, buf substr(line, 1, RSTART - 1))
                    open = ""; openname = ""; buf = ""
                } else {
                    buf = buf " " line
                }
                next
            }

            if (line ~ /^[[:space:]]*<(integer-array|string-array|array)[[:space:]]/) {
                n = name_of(line)
                # An array is never editable here: one overlay resource holds one
                # value, and an array is many.
                if (n != "") printf "%s\t1\tarray\t%s\t\n", apk, n
                if (line !~ /<\/[[:space:]]*(integer-array|string-array|array)/) inarray = 1
                next
            }

            if (line ~ /^[[:space:]]*<(dimen|bool|integer|string)[[:space:]]/) {
                tag = line
                sub(/^[^<]*</, "", tag)
                sub(/[^a-z].*$/, "", tag)
                n = name_of(line)
                if (n == "") next
                if (match(line, /<\/[[:space:]]*[a-z]+/) && line ~ ("</" tag)) {
                    v = line
                    sub(/^[^>]*>/, "", v)
                    sub(/<\/[^>]*>.*$/, "", v)
                    emit(tag, n, v)
                } else {
                    open = tag; openname = n; buf = ""
                }
                next
            }
        }
    ' "$file"
}

manifest_rows() {
    local file group rank ro apk
    {
        for file in "${RES_DIR}"/values/*.xml; do
            [ -f "$file" ] || continue
            _manifest_xml_rows fw 0 "$file"
        done
        for file in "${SYSUI_RES_DIR}"/values/*.xml; do
            [ -f "$file" ] || continue
            _manifest_xml_rows sui 0 "$file"
        done
        # Landscape overrides live in a different configuration than the one the
        # page patches, so they are listed read-only.
        for file in "${RES_DIR}"/values-land/*.xml; do
            [ -f "$file" ] || continue
            _manifest_xml_rows fw 1 "$file"
        done
        for file in "${SYSUI_RES_DIR}"/values-land/*.xml; do
            [ -f "$file" ] || continue
            _manifest_xml_rows sui 1 "$file"
        done
    } | while IFS=$'\t' read -r apk ro type name value; do
        [ -n "$name" ] || continue
        group=$(manifest_group "$name")
        rank=$(manifest_group_rank "$group")
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$rank" "$group" "$apk" "$ro" "$type" "$name" "$value"
    done | sort -t $'\t' -k1,1n -k2,2 -k5,5 -k6,6 | \
        awk -F '\t' '!seen[$3 "/" $5 "/" $6]++'
}

# ---------------------------------------------------------------------------
# Manifest
# ---------------------------------------------------------------------------
write_webui_manifest() { # <outfile>
    local out="$1" count
    local id="${OVERLAY_NAME:-treble-overlay}"

    mkdir -p "$(dirname "$out")" 2>/dev/null || true

    # The whole table is written by one awk: a $(...) per field would spawn a
    # few hundred processes, which is minutes on Windows.
    manifest_rows | awk -F '\t' \
        -v id="$(json_escape "$id")" \
        -v gen="$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null)" '
        function esc(s) { gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); return s }
        BEGIN {
            printf "{\n  \"id\": \"%s\",\n  \"generated\": \"%s\",\n  \"resources\": [", id, gen
            first = 1
        }
        {
            if ($6 == "") next
            printf "%s\n    {\"res\": \"%s:%s/%s\", \"type\": \"%s\", \"name\": \"%s\", \"value\": \"%s\", \"apk\": \"%s\", \"group\": \"%s\", \"ro\": %s}", \
                (first ? "" : ","), $3, $5, esc($6), $5, esc($6), esc($7), $3, esc($2), ($4 == "1" ? "true" : "false")
            first = 0
        }
        END { printf "\n  ]\n}\n" }
    ' > "$out"

    count=$(grep -c '"res"' "$out" 2>/dev/null || true)
    printf '%s' "${count:-0}"
}

# Human-readable plan: the same rows the manifest is built from.
print_resource_plan() {
    local rank group apk ro type name value count=0 last=""
    while IFS=$'\t' read -r rank group apk ro type name value; do
        [ -n "$name" ] || continue
        if [ "$group" != "$last" ]; then
            printf '\n  %b%s%b\n' "${BOLD:-}" "$group" "${NC:-}"
            last="$group"
        fi
        printf '    %-3s %-8s %-42s %s%s\n' "$apk" "$type" "$name" "$value" \
            "$([ "$ro" = "1" ] && printf '  (read-only — rebuild)' || true)"
        count=$((count + 1))
    done <<EOF
$(manifest_rows)
EOF
    printf '\n  %s resource(s) from config.env\n' "$count"
}

# ---------------------------------------------------------------------------
# Standalone use: ./scripts/manifest.sh plan|write <file>
# ---------------------------------------------------------------------------
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    set -e
    ROOT="$(cd "$(dirname "$0")/.." && pwd)"
    export ROOT
    cd "$ROOT"
    source "$ROOT/scripts/common.sh"
    # shellcheck source=/dev/null
    [ -f "$ROOT/config.env" ] && source "$ROOT/config.env"
    RES_DIR="src/framework/res"
    SYSUI_RES_DIR="src/systemui/res"
    [ -n "${OVERLAY_NAME:-}" ] || OVERLAY_NAME="treble-overlay-standalone"
    case "${1:-plan}" in
        plan)
            print_resource_plan
            ;;
        write)
            [ -n "${2:-}" ] || { echo "usage: $0 write <file>" >&2; exit 2; }
            n=$(write_webui_manifest "$2")
            echo "wrote $n resource(s) to $2"
            ;;
        *)
            echo "usage: $0 [plan|write <file>]" >&2
            exit 2
            ;;
    esac
fi
