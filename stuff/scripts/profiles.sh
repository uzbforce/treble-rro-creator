#!/usr/bin/env bash
# =============================================================================
# profiles.sh — saved config.env setups, one per device
# =============================================================================
# config.env holds one device: one codename, one corner radius, one match
# property. Anyone who builds for more than one phone used to keep copies by
# hand (`config.env.a90`, `config.env.zephyr`) and remember which was which.
#
# A profile is that copy, in a place the tool knows about:
#
#   stuff/profiles/p1/name        "Zephyr (Redmi Note 17)"
#   stuff/profiles/p1/config.env  that device's answers
#   stuff/profiles/active         "p1" — the profile config.env holds right now
#
# config.env at the root stays the file everything reads; a profile is a copy of
# it. Switching saves what config.env holds into the profile it came from, then
# copies the target over config.env, so a profile is only ever as stale as the
# file is. Nothing else writes one.
#
# The terminal menu (stuff/scripts/menu.sh → 'p') and the app (gui/profiles.go)
# both come through here, so they do the same thing to the same files.
#
#   bash stuff/scripts/profiles.sh show        the list, for a person
#   bash stuff/scripts/profiles.sh list        the list, tab separated
#   bash stuff/scripts/profiles.sh new "NAME"  copy config.env, switch to it
#   bash stuff/scripts/profiles.sh switch p2
#   bash stuff/scripts/profiles.sh rename p2 "Note 17"
#   bash stuff/scripts/profiles.sh delete p3
#   bash stuff/scripts/profiles.sh save        fold config.env into the active one
# =============================================================================

if [ -z "${ROOT:-}" ]; then
    ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
    export ROOT
fi
. "$ROOT/stuff/scripts/config-edit.sh"

PROFILES_DIR="${PROFILES_DIR:-$ROOT/stuff/profiles}"
PROFILES_MAX_NAME=40

# Profiles are numbered p1, p2, … with no exceptions, which is also the guard
# against a path: only that shape ever reaches the rm -rf in profiles_delete.
profiles_valid_id() { [[ "$1" =~ ^p[0-9]{1,6}$ ]]; }

profiles_ids() {
    local d
    [ -d "$PROFILES_DIR" ] || return 0
    for d in "$PROFILES_DIR"/p*/; do
        [ -d "$d" ] || continue
        d="${d%/}"
        profiles_valid_id "${d##*/}" && printf '%s\n' "${d##*/}"
    done | sort -t p -k 2 -n
}

profiles_has() { [ -n "${1:-}" ] && [ -d "$PROFILES_DIR/$1" ]; }
profiles_cfg() { printf '%s/%s/config.env' "$PROFILES_DIR" "$1"; }
profiles_name_file() { printf '%s/%s/name' "$PROFILES_DIR" "$1"; }

# The profile config.env belongs to, or nothing on a checkout that has none.
profiles_active() {
    local id=""
    if [ -f "$PROFILES_DIR/active" ]; then
        IFS= read -r id <"$PROFILES_DIR/active" || id=""
    fi
    profiles_valid_id "$id" || return 0
    profiles_has "$id" || return 0
    printf '%s' "$id"
}

profiles_set_active() {
    mkdir -p "$PROFILES_DIR" || return 1
    printf '%s\n' "$1" >"$PROFILES_DIR/active"
}

# A name is one line and fits a menu column. Anything else (a newline from a
# paste, a name too long for the table) is cleaned here rather than at each
# caller.
profiles_clean_name() {
    local name
    name="$(printf '%s' "${1:-}" | LC_ALL=C tr -d '\000-\037\177')"
    name="${name#"${name%%[![:space:]]*}"}"
    name="${name%"${name##*[![:space:]]}"}"
    while [ "${#name}" -gt 0 ] && [ "${name: -1}" = ' ' ]; do name="${name% }" ; done
    if [ "${#name}" -gt "$PROFILES_MAX_NAME" ]; then
        name="${name:0:$PROFILES_MAX_NAME}"
    fi
    printf '%s' "$name"
}

profiles_name() {
    local id="$1" name=""
    if [ -f "$(profiles_name_file "$id")" ]; then
        IFS= read -r name <"$(profiles_name_file "$id")" || name=""
    fi
    name="$(profiles_clean_name "$name")"
    [ -n "$name" ] || name="Profile #${id#p}"
    printf '%s' "$name"
}

# Manufacturer, model and codename as that profile's config.env has them. For
# the profile in use the live file wins: it may have been edited a minute ago,
# and the list should not show yesterday's answer.
profiles_identity() {
    local id="$1" f manuf model code
    if [ "$id" = "$(profiles_active)" ] && [ -f "$ROOT/config.env" ]; then
        f="$ROOT/config.env"
    else
        f="$(profiles_cfg "$id")"
    fi
    [ -f "$f" ] || { printf 'no config.env'; return 0; }
    manuf="$(CFG_FILE="$f" cfg_get DEVICE_MANUFACTURER)"
    model="$(CFG_FILE="$f" cfg_get DEVICE_MODEL)"
    code="$(CFG_FILE="$f" cfg_get DEVICE_CODENAME)"
    if [ -z "$manuf" ] && [ -z "$model" ] && [ -z "$code" ]; then
        printf 'no device set'
        return 0
    fi
    printf '%s %s (%s)' "$manuf" "$model" "$code" | sed 's/^ *//; s/  */ /g'
}

# Fold config.env into the profile it belongs to. This is also what keeps a
# switch from throwing away edits made since the last one.
profiles_save() {
    local id
    id="$(profiles_active)"
    [ -n "$id" ] || return 1
    [ -f "$ROOT/config.env" ] || return 1
    mkdir -p "$PROFILES_DIR/$id" || return 1
    cp -f "$ROOT/config.env" "$(profiles_cfg "$id")" || return 1
    return 0
}

# Create the next profile and make it active. It starts as a copy of config.env
# (that is the point: one device's answers, tweaked for the next), or of the
# example on a checkout that has no config.env yet. Prints the new id.
profiles_new_with() {
    local name id n src
    mkdir -p "$PROFILES_DIR" || return 1
    n=1
    while [ -d "$PROFILES_DIR/p$n" ]; do n=$((n + 1)); done
    id="p$n"
    name="$(profiles_clean_name "${1:-}")"
    [ -n "$name" ] || name="Profile #$n"
    mkdir -p "$PROFILES_DIR/$id" || return 1
    src="$ROOT/config.env"
    [ -f "$src" ] || src="$ROOT/config.env.example"
    if [ -f "$src" ]; then
        cp -f "$src" "$(profiles_cfg "$id")" || return 1
    else
        : >"$(profiles_cfg "$id")" || return 1
    fi
    printf '%s\n' "$name" >"$(profiles_name_file "$id")" || return 1
    profiles_set_active "$id" || return 1
    printf '%s' "$id"
}

# A checkout that has never seen a profile gets Profile #1 from whatever
# config.env holds, so the first look at the list is not an empty box.
profiles_ensure() {
    local id
    id="$(profiles_active)"
    [ -n "$id" ] && return 0
    if [ -d "$PROFILES_DIR" ]; then
        id="$(profiles_ids | head -n 1)"
        if [ -n "$id" ]; then
            # Profiles exist but the marker was lost, or pointed at a folder
            # that was deleted out from under it: adopt the first one.
            profiles_set_active "$id"
            return $?
        fi
    fi
    [ -n "$(profiles_new_with '')" ]
}

# Keep what config.env holds, then load that profile into it.
profiles_switch() {
    local id="$1"
    profiles_valid_id "$id" || { printf 'profiles: %s is not a profile id\n' "$id" >&2; return 2; }
    profiles_has "$id" || { printf 'profiles: no such profile: %s\n' "$id" >&2; return 1; }
    profiles_save >/dev/null 2>&1 || true
    cp -f "$(profiles_cfg "$id")" "$ROOT/config.env" || return 1
    profiles_set_active "$id" || return 1
    return 0
}

# Save this one, then carry on in a copy of it.
profiles_new() {
    local id
    profiles_ensure >/dev/null 2>&1 || true
    id="$(profiles_new_with "${1:-}")" || return 1
    profiles_switch "$id" || return 1
    printf '%s' "$id"
}

profiles_rename() {
    local id="$1" name
    profiles_valid_id "$id" || { printf 'profiles: %s is not a profile id\n' "$id" >&2; return 2; }
    profiles_has "$id" || { printf 'profiles: no such profile: %s\n' "$id" >&2; return 1; }
    name="$(profiles_clean_name "${2:-}")"
    if [ -z "$name" ]; then
        printf 'profiles: a profile needs a name\n' >&2
        return 2
    fi
    printf '%s\n' "$name" >"$(profiles_name_file "$id")" || return 1
    return 0
}

# The profile in use is not deletable: config.env would be left belonging to
# nothing, and one profile is always kept for the same reason.
profiles_delete() {
    local id="$1" total
    profiles_valid_id "$id" || { printf 'profiles: %s is not a profile id\n' "$id" >&2; return 2; }
    profiles_has "$id" || { printf 'profiles: no such profile: %s\n' "$id" >&2; return 1; }
    if [ "$id" = "$(profiles_active)" ]; then
        printf 'profiles: %s is the profile in use — switch to another one first\n' "$id" >&2
        return 1
    fi
    total="$(profiles_ids | grep -c . || true)"
    if [ "${total:-0}" -le 1 ]; then
        printf 'profiles: that is the only profile — there has to be one\n' >&2
        return 1
    fi
    rm -rf "$PROFILES_DIR/$id"
}

# One line per profile, tab separated: id, active(0|1), name, device. This is
# what gui/profiles.go parses; it is not meant for a person to read.
profiles_list() {
    local id active mark
    profiles_ensure >/dev/null 2>&1 || true
    active="$(profiles_active)"
    for id in $(profiles_ids); do
        mark=0
        [ "$id" = "$active" ] && mark=1
        printf '%s\t%s\t%s\t%s\n' "$id" "$mark" \
            "$(profiles_name "$id")" "$(profiles_identity "$id")"
    done
}

# The same thing for a person: a table with the profile in use marked.
profiles_print() {
    local -a rows=() ids=()
    local id active n=0 mark name device
    profiles_ensure >/dev/null 2>&1 || true
    active="$(profiles_active)"
    for id in $(profiles_ids); do ids+=("$id"); done
    if [ "${#ids[@]}" -eq 0 ]; then
        printf '  no profiles yet\n'
        return 0
    fi
    for id in "${ids[@]}"; do
        n=$((n + 1))
        mark=' '
        [ "$id" = "$active" ] && mark='*'
        rows+=("$mark|$(profiles_name "$id")|$(profiles_identity "$id")")
    done
    if command -v ui_table >/dev/null 2>&1; then
        ui_table 'Use|Profile|Device' "${rows[@]}"
        return 0
    fi
    printf '\n'
    for id in "${rows[@]}"; do
        IFS='|' read -r mark name device <<<"$id"
        printf '  %s %-32s %s\n' "$mark" "$name" "$device"
    done
}

# ---------------------------------------------------------------------------
# Command line
# ---------------------------------------------------------------------------
# The same verbs from a terminal, from a script, or through build.sh:
#
#   ./build.sh profiles                the list
#   ./build.sh profiles new "Zephyr"   copy config.env and switch to the copy
#   ./build.sh profiles switch p2      load p2 into config.env
profiles_cli() {
    local id
    case "${1:-show}" in
        show|'') profiles_print ;;
        list) profiles_list ;;
        active) profiles_active ;;
        save) profiles_save ;;
        switch|use)
            id="${2:-}"
            profiles_switch "$id" || return 1
            printf 'profiles: now using "%s" — config.env holds it\n' "$(profiles_name "$id")"
            ;;
        new|create)
            id="$(profiles_new "${2:-}")" || return 1
            [ -n "$id" ] || return 1
            printf 'profiles: now using "%s" — config.env holds it\n' "$(profiles_name "$id")"
            ;;
        rename)
            id="${2:-}"
            profiles_rename "$id" "${3:-}" || return 1
            printf 'profiles: now called "%s"\n' "$(profiles_name "$id")"
            ;;
        delete|remove) profiles_delete "${2:-}" ;;
        *)
            printf 'profiles: unknown command: %s\n' "$1" >&2
            printf 'try: show, list, new, switch, rename, delete, save, active\n' >&2
            return 2
            ;;
    esac
}

# Sourced by build.sh and the menu, which call the functions themselves; run
# directly, it is the command line above.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    profiles_cli "$@"
    exit $?
fi