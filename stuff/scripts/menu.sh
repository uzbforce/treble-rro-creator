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
# The device-source helpers (device_is_termux, device_local_begin) live with the
# adb code the probes share. Sourcing it here defines functions only.
. "$ROOT/stuff/scripts/adb-device.sh"

# ---------------------------------------------------------------------------
# Small things
# ---------------------------------------------------------------------------
MENU_SLEEP="${MENU_SLEEP:-0}"

# A width-aware rule under a section title. Every screen used to draw a fixed
# 58-character one, which wrapped onto a second line on a phone.
hr() { ui_rule 2; }

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
# The state of the checkout in one box: which phone, how much of config.env is
# filled in, what the last build left behind.
menu_header() {
    cfg_counts
    ui_panel "Treble Overlay Creator" \
        "Device|$(cfg_identity)" \
        "config.env|${CFG_ON} set ${UI_DOT} ${CFG_OFF} off" \
        "Output|$(output_summary)"
}

# 11 is the width of the longest label here, so every description starts in the
# same column instead of ragging after each label.
MENU_LW=14

menu_items() {
    ui_item 1 'Build'          'dry run, build, check, doctor, clean' "$MENU_LW"
    ui_item 2 'config.env'     'browse and edit one key at a time' "$MENU_LW"
    ui_item 3 'Addons'         'module tweaks: settings and overlay resources' "$MENU_LW"
    ui_item 4 'Device'         'read manufacturer, model, codename from the phone' "$MENU_LW"
    ui_item 5 'Auto Detect'    'ROM answers: cutout, corners, refresh rate, VoLTE, 5G' "$MENU_LW"
    ui_item 6 'UDFPS'          'in-display fingerprint geometry' "$MENU_LW"
    ui_item 7 'Match property' 'which property the submission should match on' "$MENU_LW"
    ui_item 8 'Files'          'what was built, and where it is' "$MENU_LW"
    ui_item 9 'Docs'           'the guides in docs/' "$MENU_LW"
    ui_item q 'Quit' '' "$MENU_LW"
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
        ui_heading 'Build'
        ui_item 1 'Dry run'     'print the resources config.env emits, build nothing' 11
        ui_item 2 'Build'       'build the module (installs tools if needed)' 11
        ui_item 3 'Check'       'validate config.env without building' 11
        ui_item 4 'Doctor'      'check the toolchain, install nothing' 11
        ui_item 5 'Clean'       'remove build output' 11
        ui_item 6 'Clean --all' 'start over for a different device' 11
        ui_item 0 'Back' '' 11
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
    local -a table=() f
    ui_heading 'Files'
    ui_panel 'Where things are' \
        "Project|$ROOT" \
        "config.env|$ROOT/config.env" \
        "Build tree|${BUILD_DIR#$ROOT/}"
    echo ""
    if [ -d "$OUT_DIR" ] && [ -n "$(ls -A "$OUT_DIR" 2>/dev/null)" ]; then
        while IFS= read -r f; do
            table+=("$(du -h "$f" 2>/dev/null | cut -f1)|${f#$ROOT/}")
        done < <(find "$OUT_DIR" -maxdepth 2 -type f \( -name '*.zip' -o -name '*.apk' \) 2>/dev/null | LC_ALL=C sort)
        if [ "${#table[@]}" -gt 0 ]; then
            ui_table 'Size|Built file' "${table[@]}"
        else
            info "out/ exists but holds no .zip or .apk yet."
        fi
    else
        info "Nothing built yet — 1 → 2 builds the module."
    fi
    pause_menu
}

# ---------------------------------------------------------------------------
# Docs
# ---------------------------------------------------------------------------
menu_docs() {
    local files=() i
    ui_heading 'Docs'
    [ -d "$ROOT/docs" ] || { warn "docs/ is missing from this checkout."; pause_menu; return 0; }
    while IFS= read -r f; do
        files+=("$f")
    done < <(find "$ROOT/docs" -maxdepth 1 -name '*.md' 2>/dev/null | LC_ALL=C sort)
    for i in "${!files[@]}"; do
        ui_item "$((i + 1))" "$(basename "${files[$i]}")"
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

cfg_section_stats() { # -> `section<TAB>set<TAB>off`, in file order
    cfg_rows 2>/dev/null | awk -F'\t' '
        { if (!($4 in seen)) { seen[$4] = 1; order[n++] = $4 }
          if ($2 == 1) on[$4]++ ; else off[$4]++ }
        END { for (i = 0; i < n; i++) printf "%s\t%d\t%d\n", order[i], on[order[i]], off[order[i]] }
    '
}

# cfg_list_row NUM KEYW KEY ACTIVE VALUE — one line of a config.env section.
#
# A key has three things worth seeing at once: whether it is switched on, its
# name, and its value. They are three aligned columns when the window has room
# and two lines when it does not — the state keeps its colour either way, so
# scanning down the page is still "find the green ones".
cfg_list_row() {
    local num="$1" keyw="$2" key="$3" active="$4" value="$5"
    local cols state statepad color avail vw vcolor
    cols=$(ui_cols)
    if [ "$active" = "1" ]; then state='on'; color="$UI_GREEN"; else state='off'; color="$UI_DIM"; fi
    printf -v statepad '%*s' $((3 - ${#state})) ''
    # The colour is kept out of the text until printing, so measuring the value
    # never counts escape bytes.
    if [ -z "$value" ]; then value='(empty)'; vcolor="$UI_DIM"; else vcolor="$UI_BOLD"; fi
    # A key longer than the shared column is measured on its own: the column is
    # a convenience, not a licence to print past the window.
    [ "${#key}" -gt "$keyw" ] && keyw=${#key}

    avail=$((cols - (2 + 3 + 2 + 3 + 2 + keyw + 2)))
    # Three columns only when the whole value fits in the one that is left: a
    # value cut to `Redmi Not…` is worse than the two-line form, which has the
    # rest of the window to wrap into.
    if [ "$avail" -ge 8 ] && [ "${#value}" -le $((avail - 1)) ]; then
        vw=$((avail - 1))
        printf '  %s%3d%s  %s%-3s%s  %s%-*s%s  %s%s%s\n' \
            "$UI_DIM" "$num" "$UI_OFF" "$color" "$state" "$UI_OFF" \
            "$UI_DIM" "$keyw" "$key" "$UI_OFF" \
            "$vcolor" "$(ui_fit "$value" "$vw")" "$UI_OFF"
        return 0
    fi
    # No room for three columns: the key starts on the number's line and wraps
    # under itself, and the value wraps below. A 24-character property name is
    # wider than a phone, so both are wrapped rather than run off the edge.
    local l first=1
    ui_wrap "$key" 0 $((cols - 13)) | while IFS= read -r l; do
        if [ "$first" = 1 ]; then
            printf '  %s%3d%s  %s%-3s%s  %s%s%s\n' \
                "$UI_DIM" "$num" "$UI_OFF" "$color" "$state" "$UI_OFF" \
                "$UI_BOLD" "$l" "$UI_OFF"
            first=0
        else
            printf '            %s%s%s\n' "$UI_BOLD" "$l" "$UI_OFF"
        fi
    done
    ui_wrap "$value" 12 $((cols - 13)) | while IFS= read -r l; do
        printf '%s%s%s\n' "$vcolor" "$l" "$UI_OFF"
    done
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
        # One width for the key column, so the values line up down the page.
        local keyw=0
        for i in "${!rows[@]}"; do
            local k="${rows[$i]%%$'\t'*}"
            [ "${#k}" -gt "$keyw" ] && keyw=${#k}
        done
        [ "$keyw" -le 30 ] || keyw=30
        for i in "${!rows[@]}"; do
            local key="${rows[$i]%%$'\t'*}" rest="${rows[$i]#*$'\t'}"
            local active="${rest%%$'\t'*}" value="${rest#*$'\t'}"
            value="$(printf '%s' "$value" | sed 's/^"\(.*\)"$/\1/')"
            cfg_list_row "$((i + 1))" "$keyw" "$key" "$active" "$value"
        done
        echo ""
        ui_mark note "number = edit ${UI_DOT} d<number> = switch off ${UI_DOT} e<number> = switch on ${UI_DOT} 0 = back"
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
    local sections=() i lw name on off
    while :; do
        sections=()
        local -a counts=()
        while IFS=$'\t' read -r name on off; do
            [ -n "$name" ] || continue
            sections+=("$name")
            counts+=("$(printf '%s set %s %s off' "$on" "$UI_DOT" "$off")")
        done < <(cfg_section_stats 2>/dev/null)
        # A config.env with no section headers still has keys.
        if [ "${#sections[@]}" -eq 0 ]; then
            while IFS= read -r name; do
                [ -n "$name" ] && { sections+=("$name"); counts+=(''); }
            done < <(cfg_sections 2>/dev/null)
        fi

        cfg_counts
        ui_heading 'config.env'
        local hdr_cols hdr_path
        hdr_cols=$(ui_cols)
        hdr_path="$ROOT/config.env"
        if [ $(( 2 + ${#CFG_ON} + 5 + ${#CFG_OFF} + 6 + ${#hdr_path} )) -le "$hdr_cols" ]; then
            printf '  %s%d set%s %s %s%d off%s   %s%s%s\n\n' \
                "$UI_GREEN" "$CFG_ON" "$UI_OFF" "$UI_DOT" \
                "$UI_DIM" "$CFG_OFF" "$UI_OFF" "$UI_DIM" "$hdr_path" "$UI_OFF"
        else
            # A full checkout path is wider than a phone: the counts keep the
            # first line, the path wraps under them.
            printf '  %s%d set%s %s %s%d off%s\n' \
                "$UI_GREEN" "$CFG_ON" "$UI_OFF" "$UI_DOT" \
                "$UI_DIM" "$CFG_OFF" "$UI_OFF"
            ui_wrap "$hdr_path" 4 $((hdr_cols - 5)) | while IFS= read -r name; do
                printf '%s%s%s\n' "$UI_DIM" "$name" "$UI_OFF"
            done
            printf '\n'
        fi
        if [ "${#sections[@]}" -eq 0 ]; then
            err "config.env is missing or empty: $ROOT/config.env"
            pause_menu
            return 0
        fi
        lw=0
        for i in "${!sections[@]}"; do
            [ "${#sections[$i]}" -gt "$lw" ] && lw=${#sections[$i]}
        done
        for i in "${!sections[@]}"; do
            ui_item "$((i + 1))" "${sections[$i]}" "${counts[$i]}" "$lw"
        done
        ui_item 0 'Back'
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

# addons_row NUM MARK LABEL VALUE CHOICES [ (overlay) ] — one addon.
#
# MARK is `*` for a value you chose, `-` for one you chose that happens to be
# the ROM's own, and a space for an untouched addon. The chosen value is the
# bright one; the alternatives stay dim, so the page reads as a list of current
# settings and a menu of choices at the same time.
addons_row() {
    local num="$1" mark="$2" label="$3" value="$4" choices="$5" extra="${6:-}"
    local cols lw=30 vw=10 avail color
    cols=$(ui_cols)
    [ "$lw" -le "$cols" ] || lw=$((cols - 10))
    avail=$((cols - (2 + 3 + 1 + 2 + lw + 2 + vw + 2)))
    if [ "$mark" = '*' ]; then color="$UI_GREEN"; else color="$UI_DIM"; fi

    if [ "$avail" -ge 10 ]; then
        printf '  %s%3d%s %s%s%s  %s%-*s%s  %s%-*s%s  %s%s%s%s\n' \
            "$UI_DIM" "$num" "$UI_OFF" "$color" "$mark" "$UI_OFF" \
            "$UI_BOLD" "$lw" "$label" "$UI_OFF" \
            "$color" "$vw" "$value" "$UI_OFF" \
            "$UI_DIM" "$choices" "$extra" "$UI_OFF"
        return 0
    fi
    printf '  %s%3d%s %s%s%s  %s%s%s%s%s\n' \
        "$UI_DIM" "$num" "$UI_OFF" "$color" "$mark" "$UI_OFF" \
        "$UI_BOLD" "$label" "$UI_OFF" "$extra" ''
    printf '       %s%s%s  %s%s%s\n' "$color" "$value" "$UI_OFF" "$UI_DIM" "$choices" "$UI_OFF"
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

        ui_heading 'Addons'
        ui_mark note "A setting changes on the phone now; an overlay resource needs a rebuild."
        echo ""
        for i in "${!rows[@]}"; do
            IFS='|' read -r id choices default label _ kind <<<"${rows[$i]}"
            saved="$(addons_saved "$id")"
            value="${saved:-$default}"
            mark=' '
            if [ -n "$saved" ]; then
                mark='*'
                [ "$saved" = "$default" ] && mark='-'
            fi
            addons_row "$((i + 1))" "$mark" "$label" "$value" \
                "$(printf '%s' "$choices" | tr ',' '/')" \
                "$([ "$kind" = overlay ] && echo " ${UI_DIM}(overlay)${UI_OFF}")"
        done
        echo ""
        ui_mark note "* chosen  ${UI_DOT}  - chosen, same as the ROM  ${UI_DOT}  plain = the ROM's own value"
        ui_mark note "number = choose a value   number=value = set both   r = reset   Enter = back"
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
        ui_heading "$label"
        ui_mark note "$row"
        ui_panel "$label" \
            "now|$(addons_saved "$id" || printf '%s' "$default")" \
            "choices|$(printf '%s' "$choices" | tr ',' '/')" \
            "changes|$([ "$kind" = overlay ] && echo 'after the next build' || echo 'on the phone now')"
        echo ""
        menu_read "  value (Enter keeps it)" || return 0
        value="$MENU_ANSWER"
        [ -z "$value" ] && continue
        addons_call set "$id=$value"
    done
}

# ---------------------------------------------------------------------------
# Where the probes read from
# ---------------------------------------------------------------------------
# In Termux the phone the probes want is the one the menu is running on, and the
# reads a PC does over adb (`cmd`, `dumpsys`, /vendor) are what root unlocks
# there. ADB on Termux has nothing to dial, so without this the answer was
# always "no device in adb devices".
#
# Asked once per session and handed to every probe as DEVICE_LOCAL_REQUEST, so a
# session that said yes is not asked again on each run — and one that said no is
# not asked either.
probe_local=""

probe_source_ask() {
    [ -z "$probe_local" ] || return 0
    device_is_termux || return 0
    echo ""
    echo "  This is Termux, so the phone is this one rather than a device on a cable."
    echo "  Reading it directly needs root: the same getprop, cmd overlay, wm and"
    echo "  dumpsys reads a PC makes over adb."
    if confirm "  Read this phone as root? [Y/n] " y; then
        if device_local_begin "menu"; then
            probe_local=1
        else
            probe_local=0
        fi
    else
        probe_local=0
    fi
    # The menu itself never reads a phone; only the answer is passed on.
    DEVICE_LOCAL=0
    export DEVICE_LOCAL_REQUEST="$probe_local"
    echo ""
    return 0
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
        probe_source_ask
        ui_heading "$title"
        # ui_mark wraps the note itself: a one-paragraph description on a
        # phone-width terminal used to run off the edge.
        [ -n "$note" ] && ui_mark note "$note" && echo ""
        local who='the connected phone'
        [ "$probe_local" = 1 ] && who='this phone'
        ui_item 1 "Read $who" 'report only, nothing written' 24
        ui_item 2 "Read $who" 'and write the answers to config.env' 24
        ui_item 3 'Read a firmware folder' 'an unpacked ROM instead of a running phone' 24
        ui_item 0 'Back' '' 24
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
        "What the ROM says about the hardware: cutout path, corner radius, status bar height, refresh rates, VoLTE and 5G flags, the light sensor and the OEM switches. Anything it cannot read is reported, not guessed."
}

menu_udfps() {
    probe_menu "UDFPS" "$ROOT/stuff/scripts/udfps-probe.sh" \
        "The in-display fingerprint sensor's centre and radius."
}

menu_match() {
    probe_source_ask
    probe_run "$ROOT/stuff/scripts/match-prop.sh"
}

# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------
menu_main() {
    while :; do
        menu_header
        echo ""
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