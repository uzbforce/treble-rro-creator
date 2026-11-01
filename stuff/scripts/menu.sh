#!/usr/bin/env bash
# =============================================================================
# menu.sh — the terminal front end
# =============================================================================
# The desktop app and this file drive the same tools: the device probes, the
# addon catalog, the match-property ranking and build.sh's own verbs. The goal
# is that a phone with a terminal (Termux, ssh, a server) gets the same answers
# as the window, without a GUI toolkit.
#
#   ./build.sh                 opens this (when stdin is a terminal)
#   ./build.sh menu            opens this even when stdin is not a terminal
#   bash stuff/scripts/menu.sh same thing, standalone
#
# Every action shells out to the real entry point — `build.sh build`,
# `device-probe.sh --write`, `addons.sh set` — so there is exactly one
# implementation of each step and the menu cannot drift from the app.
# =============================================================================

if [ -z "${ROOT:-}" ]; then
    ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
    export ROOT
    . "$ROOT/stuff/scripts/common.sh"
fi
. "$ROOT/stuff/scripts/config-edit.sh"

# ---------------------------------------------------------------------------
# Small things
# ---------------------------------------------------------------------------
MENU_SLEEP="${MENU_SLEEP:-0}"

hr() { printf '  %s\n' "──────────────────────────────────────────────────────────"; }

# Read one line. Returns 1 at EOF (piped input, a launcher with no console) so
# callers can leave the menu instead of looping forever.
menu_read() {
    local prompt="${1:-} " answer=""
    printf '%s' "$prompt"
    if ! read -r answer; then
        echo ""
        return 1
    fi
    MENU_ANSWER="$answer"
    return 0
}

# Wait for Enter between screens, unless stdin is not a terminal.
pause_menu() {
    [ -t 0 ] || return 0
    printf '\n  %s ' "Press Enter to go back"
    read -r _ || true
    printf '\n'
}

# Count the rows config.env has, and how many are switched off.
cfg_counts() {
    local rows
    rows="$(cfg_rows 2>/dev/null)" || { CFG_ON=0; CFG_OFF=0; return 0; }
    CFG_ON="$(printf '%s\n' "$rows" | awk -F'\t' '$2 == 1' | grep -c . || true)"
    CFG_OFF="$(printf '%s\n' "$rows" | awk -F'\t' '$2 == 0' | grep -c . || true)"
}

output_summary() {
    local apks=0 zips=0 zip=""
    [ -d "$OUT_DIR/apks" ] && apks="$(find "$OUT_DIR/apks" -maxdepth 1 -name '*.apk' 2>/dev/null | grep -c . || true)"
    [ -d "$OUT_DIR" ] && zips="$(find "$OUT_DIR" -maxdepth 1 -name '*.zip' 2>/dev/null | grep -c . || true)"
    zip="$(find "$OUT_DIR" -maxdepth 1 -name '*.zip' 2>/dev/null | sort | head -n1)"
    if [ "$zips" -gt 0 ]; then
        printf '%s  (%s APK%s)' "${zip#$ROOT/}" "$apks" "$([ "$apks" = 1 ] || echo s)"
    else
        printf 'nothing built yet'
    fi
}

# ---------------------------------------------------------------------------
# Screen
# ---------------------------------------------------------------------------
menu_header() {
    cfg_counts
    echo ""
    echo -e "  ${BOLD}Treble Overlay Creator${NC}"
    hr
    printf '  %-11s %s\n' 'Device' "$(cfg_identity)"
    printf '  %-11s %s set · %s off\n' 'config.env' "$CFG_ON" "$CFG_OFF"
    printf '  %-11s %s\n' 'Output' "$(output_summary)"
    echo ""
}

menu_items() {
    cat << 'ITEMS'
     1  Build              dry run, build, check, doctor, clean
     2  config.env         browse and edit one key at a time
     3  Addons             module tweaks: settings and overlay resources
     4  Device             read manufacturer, model, codename from the phone
     5  Auto Detect        ROM answers: cutout, corners, refresh rate, VoLTE, 5G
     6  UDFPS              in-display fingerprint geometry
     7  Match property     which property the submission should match on
     8  Files              what was built, and where it is
     9  Docs               the guides in docs/
     q  Quit
ITEMS
}

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------
# The menu never re-implements a build step: it runs the entry point with the
# verb a user would type, so `build.sh doctor` and 1 → 4 are the same command.
run_entry() {
    ( cd "$ROOT" && bash "$ROOT/build.sh" "$@" )
}

menu_build() {
    while :; do
        echo ""
        echo -e "  ${BOLD}Build${NC}"
        hr
        echo "     1  Dry run         print the resources config.env emits, build nothing"
        echo "     2  Build           build the module (installs tools if needed)"
        echo "     3  Check           validate config.env without building"
        echo "     4  Doctor          check the toolchain, install nothing"
        echo "     5  Clean           remove build output"
        echo "     6  Clean --all     start over for a different device"
        echo "     0  Back"
        echo ""
        menu_read "  >" || return 0
        case "$MENU_ANSWER" in
            1) run_entry --dry-run; pause_menu ;;
            2) run_entry build; pause_menu ;;
            3) run_entry check; pause_menu ;;
            4) run_entry doctor; pause_menu ;;
            5) run_entry clean; pause_menu ;;
            6)
                warn "This removes config.env and the device files too."
                if confirm "  Start over for a different device? [y/N] " n; then
                    run_entry clean --all
                fi
                pause_menu
                ;;
            0|q|'') return 0 ;;
            *) warn "Not one of the numbers above." ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# Files
# ---------------------------------------------------------------------------
menu_files() {
    echo ""
    echo -e "  ${BOLD}Files${NC}"
    hr
    printf '  %-12s %s\n' 'Project' "$ROOT"
    printf '  %-12s %s\n' 'config.env' "$ROOT/config.env"
    printf '  %-12s %s\n' 'Build tree' "${BUILD_DIR#$ROOT/}"
    echo ""
    if [ -d "$OUT_DIR" ] && [ -n "$(ls -A "$OUT_DIR" 2>/dev/null)" ]; then
        echo "  Output"
        find "$OUT_DIR" -maxdepth 2 -type f \( -name '*.zip' -o -name '*.apk' \) 2>/dev/null |
            while IFS= read -r f; do
                printf '    %-10s %s\n' "$(du -h "$f" 2>/dev/null | cut -f1)" "${f#$ROOT/}"
            done
    else
        echo "  Nothing built yet — 1 → 2 builds the module."
    fi
    pause_menu
}

# ---------------------------------------------------------------------------
# Docs
# ---------------------------------------------------------------------------
menu_docs() {
    local files=() i
    echo ""
    echo -e "  ${BOLD}Docs${NC}"
    hr
    [ -d "$ROOT/docs" ] || { warn "docs/ is missing from this checkout."; pause_menu; return 0; }
    while IFS= read -r f; do
        files+=("$f")
    done < <(find "$ROOT/docs" -maxdepth 1 -name '*.md' 2>/dev/null | LC_ALL=C sort)
    for i in "${!files[@]}"; do
        printf '  %2d  %s\n' "$((i + 1))" "$(basename "${files[$i]}")"
    done
    echo ""
    menu_read "  number to read, Enter to go back >" || return 0
    case "$MENU_ANSWER" in
        ''|q) return 0 ;;
        *[!0-9]*) warn "Not a number."; return 0 ;;
    esac
    if [ "$MENU_ANSWER" -lt 1 ] || [ "$MENU_ANSWER" -gt "${#files[@]}" ]; then
        warn "No such doc."
        return 0
    fi
    local pick="${files[$((MENU_ANSWER - 1))]}"
    echo ""
    if [ -t 1 ] && command -v less >/dev/null 2>&1; then
        less -R "$pick"
    else
        cat "$pick"
    fi
    return 0
}

# ---------------------------------------------------------------------------
# config.env
# ---------------------------------------------------------------------------
# The file keeps its shape: these helpers rewrite one line and leave the
# comments, the section headers and the quoting alone. A key that is commented
# out shows as `off` and can be switched on by number, which is the whole point
# of listing it — hunting for the '#' in a 240-line file is where mistakes
# happen.
cfg_each_row() { # <section> -> `key<TAB>active<TAB>value` rows of that section
    local section="$1"
    cfg_rows 2>/dev/null | awk -F'\t' -v s="$section" '$4 == s { print $1 "\t" $2 "\t" $5 }'
}

cfg_edit_value() {
    local key="$1" current value
    current="$(cfg_get "$key")"
    printf '\n  %s = %s\n' "$key" "${current:-<empty>}"
    menu_read "  new value (Enter keeps it, - clears it)" || return 0
    value="$MENU_ANSWER"
    [ -z "$value" ] && { info "Left it alone."; return 0; }
    [ "$value" = "-" ] && value=""
    if cfg_set "$key" "$value"; then
        ok "$key is now ${value:-<empty>}"
    else
        err "Could not write config.env — is it read-only?"
    fi
}

cfg_section() { # <section title>
    local section="$1" rows=() row i n=0
    while :; do
        rows=()
        while IFS= read -r row; do
            [ -n "$row" ] && rows+=("$row")
        done < <(cfg_each_row "$section")

        echo ""
        echo -e "  ${BOLD}${section:-Unsectioned}${NC}"
        hr
        if [ "${#rows[@]}" -eq 0 ]; then
            info "This section has no keys."
            pause_menu
            return 0
        fi
        for i in "${!rows[@]}"; do
            local key="${rows[$i]%%$'\t'*}" rest="${rows[$i]#*$'\t'}"
            local active="${rest%%$'\t'*}" value="${rest#*$'\t'}"
            local state='on '
            [ "$active" = "1" ] || state='off'
            value="$(printf '%s' "$value" | sed 's/^"\(.*\)"$/\1/')"
            printf '  %3d  %s  %-30s %-34.34s\n' "$((i + 1))" "$state" "$key" "$value"
        done
        echo ""
        echo "    number = edit value · d number = switch off · e number = switch on"
        menu_read "  >" || return 0
        case "$MENU_ANSWER" in
            ''|0|q) return 0 ;;
            d*|D*)
                i="${MENU_ANSWER#?}"
                case "$i" in ''|*[!0-9]*) warn "d needs a number, like d3."; continue ;; esac
                if [ "$i" -lt 1 ] || [ "$i" -gt "${#rows[@]}" ]; then warn "No such key."; continue; fi
                key="${rows[$((i - 1))]%%$'\t'*}"
                if cfg_set_active "$key" 0; then ok "$key switched off"; else err "Could not write config.env"; fi
                ;;
            e*|E*)
                i="${MENU_ANSWER#?}"
                case "$i" in ''|*[!0-9]*) warn "e needs a number, like e3."; continue ;; esac
                if [ "$i" -lt 1 ] || [ "$i" -gt "${#rows[@]}" ]; then warn "No such key."; continue; fi
                key="${rows[$((i - 1))]%%$'\t'*}"
                if cfg_set_active "$key" 1; then ok "$key switched on"; else err "Could not write config.env"; fi
                ;;
            *[!0-9]*) warn "Not a number." ;;
            *)
                if [ "$MENU_ANSWER" -lt 1 ] || [ "$MENU_ANSWER" -gt "${#rows[@]}" ]; then
                    warn "No such key."
                    continue
                fi
                cfg_edit_value "${rows[$((MENU_ANSWER - 1))]%%$'\t'*}"
                ;;
        esac
    done
}

menu_config() {
    local sections=() i
    while :; do
        sections=()
        while IFS= read -r s; do
            [ -n "$s" ] && sections+=("$s")
        done < <(cfg_sections 2>/dev/null)

        cfg_counts
        echo ""
        echo -e "  ${BOLD}config.env${NC}"
        hr
        printf '  %s set · %s off · %s\n\n' "$CFG_ON" "$CFG_OFF" "$ROOT/config.env"
        if [ "${#sections[@]}" -eq 0 ]; then
            err "config.env is missing or empty: $ROOT/config.env"
            pause_menu
            return 0
        fi
        for i in "${!sections[@]}"; do
            printf '  %2d  %s\n' "$((i + 1))" "${sections[$i]}"
        done
        echo "     0  Back"
        menu_read "  section >" || return 0
        case "$MENU_ANSWER" in
            ''|0|q) return 0 ;;
            *[!0-9]*) warn "Not a number." ;;
            *)
                if [ "$MENU_ANSWER" -lt 1 ] || [ "$MENU_ANSWER" -gt "${#sections[@]}" ]; then
                    warn "No such section."
                    continue
                fi
                cfg_section "${sections[$((MENU_ANSWER - 1))]}"
                ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# Addons
# ---------------------------------------------------------------------------
# The catalog lives in src/webui/addons.sh and is read here, not copied: the
# module page on the phone and the desktop app read the same file. The menu
# only chooses which `set` to run.
addons_script() { printf '%s' "$ROOT/src/webui/addons.sh"; }
addons_conf() { printf '%s' "$ROOT/src/module/addons.conf"; }

addons_call() { # <verb> ... — in the clone, with the clone's addons.conf
    ADDONS_DIR="$ROOT" ADDONS_CONF="$(addons_conf)" sh "$(addons_script)" "$@"
}

addons_saved() { # <id> -> the value in addons.conf, empty when unset
    local file
    file="$(addons_conf)"
    [ -f "$file" ] || return 0
    awk -F= -v id="$1" '$1 == id { sub(/^[^=]*=/, ""); print; exit }' "$file"
}

menu_addons() {
    local script rows=() row i ans id label choices default kind value saved mark
    script="$(addons_script)"
    if [ ! -f "$script" ]; then
        err "$script is missing — this checkout is incomplete."
        pause_menu
        return 0
    fi
    while :; do
        rows=()
        while IFS= read -r row; do
            [ -n "$row" ] && rows+=("$row")
        done < <(addons_call catalog 2>/dev/null)

        echo ""
        echo -e "  ${BOLD}Addons${NC}"
        hr
        echo "  A setting changes on the phone now; an overlay resource needs a rebuild."
        echo "    #  addon                          now          choices"
        for i in "${!rows[@]}"; do
            IFS='|' read -r id choices default label _ kind <<<"${rows[$i]}"
            saved="$(addons_saved "$id")"
            value="${saved:-$default}"
            mark=' '
            if [ -n "$saved" ]; then
                mark='*'
                [ "$saved" = "$default" ] && mark='-'
            fi
            printf '  %3d %s %-30.30s %-12.12s %s%s\n' "$((i + 1))" "$mark" "$label" "$value" \
                "$(printf '%s' "$choices" | tr ',' '/')" "$([ "$kind" = overlay ] && echo ' (overlay)')"
        done
        echo ""
        echo "    * = chosen · - = chosen as the default · plain = the ROM's own value"
        echo "    number = choose a value · number=value = set both · r = reset · Enter = back"
        menu_read "  >" || return 0
        ans="$MENU_ANSWER"
        case "$ans" in
            ''|0|q) return 0 ;;
            r|R)
                addons_call reset
                info "Every addon is back to the ROM's own value."
                continue
                ;;
        esac

        if [[ "$ans" == *=* ]]; then
            id="${ans%%=*}"
            value="${ans#*=}"
            if ! printf '%s\n' "${rows[@]}" | awk -F'|' -v id="$id" '$1 == id { found = 1 } END { exit !found }'; then
                warn "No addon called '$id'."
                continue
            fi
            addons_call set "$id=$value"
            continue
        fi

        case "$ans" in
            *[!0-9]*) warn "Not a number, number=value, or r."; continue ;;
        esac
        if [ "$ans" -lt 1 ] || [ "$ans" -gt "${#rows[@]}" ]; then
            warn "No such addon."
            continue
        fi
        IFS='|' read -r id choices default label row kind <<<"${rows[$((ans - 1))]}"
        echo ""
        echo -e "  ${BOLD}${label}${NC}"
        printf '  %s\n' "$row"
        echo ""
        printf '  choices: %s · now: %s\n' "$(printf '%s' "$choices" | tr ',' '/')" "$(addons_saved "$id" || printf '%s' "$default")"
        menu_read "  value (Enter keeps it)" || return 0
        value="$MENU_ANSWER"
        [ -z "$value" ] && continue
        addons_call set "$id=$value"
    done
}

# ---------------------------------------------------------------------------
# Probes
# ---------------------------------------------------------------------------
# device-probe.sh, udfps-probe.sh and device-id.sh all print a report and, with
# --write, put the winners in config.env. That is the only difference between
# the two answers here, so the submenu asks it instead of inventing options.
# Ctrl-C is how the probes' device wait is left ("up to 120s; Ctrl-C stops
# this"). A script's bash shares the foreground process group with the child it
# is waiting on, so the interrupt reaches this menu too: without the trap the
# whole menu died and the user lost their place. The trap lets the probe exit on
# its own while the menu stays put; 130 is the probe's "interrupted" code, so in
# that case there is no report to read and nothing to press a key for.
probe_run() {
    local rc=0
    trap ':' INT
    bash "$@" || rc=$?
    trap - INT
    # Never return the probe's status: build.sh runs this with `set -e`, so a
    # 130 here would end the menu as surely as the signal did.
    if [ "$rc" -eq 130 ]; then return 0; fi
    pause_menu || true
    return 0
}

probe_menu() { # <title> <script> <note>
    local title="$1" script="$2" note="$3" dir
    while :; do
        echo ""
        echo -e "  ${BOLD}${title}${NC}"
        hr
        # %b so a note can wrap by itself: a one-paragraph description on a
        # phone-width terminal would otherwise run off the edge.
        [ -n "$note" ] && printf '  %b\n' "$note" && echo ""
        echo "     1  Read the connected phone (report only)"
        echo "     2  Read the connected phone and write the answers to config.env"
        echo "     3  Read an unpacked firmware folder instead"
        echo "     0  Back"
        menu_read "  >" || return 0
        case "$MENU_ANSWER" in
            1) probe_run "$script" ;;
            2) probe_run "$script" --write ;;
            3)
                menu_read "  folder holding the unpacked ROM" || return 0
                dir="$MENU_ANSWER"
                [ -n "$dir" ] || continue
                if [ ! -d "$dir" ]; then
                    warn "No such folder: $dir"
                    continue
                fi
                if confirm "  Write what it finds to config.env? [y/N] " n; then
                    probe_run "$script" --firmware "$dir" --write
                else
                    probe_run "$script" --firmware "$dir"
                fi
                ;;
            0|q|'') return 0 ;;
            *) warn "Not one of the numbers above." ;;
        esac
    done
}

menu_device() {
    probe_menu "Device" "$ROOT/stuff/scripts/device-id.sh" \
        "Reads DEVICE_MANUFACTURER, DEVICE_MODEL and DEVICE_CODENAME, and the module condition."
}

menu_detect() {
    probe_menu "Auto Detect" "$ROOT/stuff/scripts/device-probe.sh" \
        "What the ROM says about the hardware: cutout path, corner radius, status\n  bar height, refresh rates, VoLTE and 5G flags, the light sensor and the OEM\n  switches. Anything it cannot read is reported, not guessed."
}

menu_udfps() {
    probe_menu "UDFPS" "$ROOT/stuff/scripts/udfps-probe.sh" \
        "The in-display fingerprint sensor's centre and radius."
}

menu_match() {
    probe_run "$ROOT/stuff/scripts/match-prop.sh"
}

# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------
menu_main() {
    while :; do
        menu_header
        menu_items
        echo ""
        menu_read "  >" || { echo ""; return 0; }
        case "$MENU_ANSWER" in
            1) menu_build ;;
            2) menu_config ;;
            3) menu_addons ;;
            4) menu_device ;;
            5) menu_detect ;;
            6) menu_udfps ;;
            7) menu_match ;;
            8) menu_files ;;
            9) menu_docs ;;
            q|Q|quit|exit) return 0 ;;
            '') return 0 ;;
            *) warn "Pick a number from the list, or q to quit." ;;
        esac
        [ "$MENU_SLEEP" = "0" ] || sleep "$MENU_SLEEP"
    done
}

# Standalone: `bash stuff/scripts/menu.sh`. Sourced by build.sh, which calls
# menu_main itself.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    menu_main
fi