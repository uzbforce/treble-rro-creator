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

# Every path below is built from an id, so the shape is checked here as well as
# at the verb that was handed one: a caller that forgets (or a marker file
# edited by hand) then gets an empty answer, never ../../etc.
profiles_has() { profiles_valid_id "${1:-}" && [ -d "$PROFILES_DIR/$1" ]; }
profiles_cfg() {
    profiles_valid_id "${1:-}" || return 1
    printf '%s/%s/config.env' "$PROFILES_DIR" "$1"
}
profiles_name_file() {
    profiles_valid_id "${1:-}" || return 1
    printf '%s/%s/name' "$PROFILES_DIR" "$1"
}

# Write a file whole or not at all: written beside it, then renamed over it. A
# switch interrupted halfway through must not leave a truncated config.env, and
# an interrupted marker write must not leave the list pointing at nothing.
profiles_put() {
    local dest="$1" tmp="$1.tmp.$$"
    if cat >"$tmp" 2>/dev/null && mv -f "$tmp" "$dest" 2>/dev/null; then
        return 0
    fi
    rm -f "$tmp" 2>/dev/null
    return 1
}

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
    profiles_valid_id "${1:-}" || return 1
    mkdir -p "$PROFILES_DIR" || return 1
    printf '%s\n' "$1" | profiles_put "$PROFILES_DIR/active"
}

# A name is one line and fits a menu column. Anything else (a newline from a
# paste, a name too long for the table) is cleaned here rather than at each
# caller.
profiles_clean_name() {
    local name
    # Control characters would end a line or a table cell early; a pipe is the
    # separator the tables are built from, so it becomes a slash.
    name="$(printf '%s' "${1:-}" | LC_ALL=C tr -d '\000-\037\177' | tr '|' '/')"
    name="${name#"${name%%[![:space:]]*}"}"
    name="${name%"${name##*[![:space:]]}"}"
    while [ "${#name}" -gt 0 ] && [ "${name: -1}" = ' ' ]; do name="${name% }" ; done
    if [ "${#name}" -gt "$PROFILES_MAX_NAME" ]; then
        name="${name:0:$PROFILES_MAX_NAME}"
    fi
    printf '%s' "$name"
}

# A table cell is joined to the next one by a pipe, and the listing parsed by
# gui/profiles.go by a tab. A device name comes from config.env, which is edited
# by hand, so one of those characters in it used to split the row — the app then
# showed half a device and silently dropped the rest.
profiles_cell() {
    printf '%s' "${1:-}" | LC_ALL=C tr '\t\177' '  ' | tr '|' '/' | sed 's/  */ /g'
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

# Two rows that read the same are worse than no names at all: the list is what
# the user picks from. Comparison ignores case and runs of spaces, so "Pixel  8"
# cannot sit next to "pixel 8".
profiles_name_key() {
    printf '%s' "$1" | LC_ALL=C tr '[:upper:]' '[:lower:]' | sed 's/  */ /g; s/^ //; s/ $//'
}

# The id of the profile already called NAME (except itself, when renaming).
profiles_named() {
    local want id
    want="$(profiles_name_key "$1")"
    [ -n "$want" ] || return 1
    for id in $(profiles_ids); do
        [ "$id" = "${2:-}" ] && continue
        if [ "$(profiles_name_key "$(profiles_name "$id")")" = "$want" ]; then
            printf '%s' "$id"
            return 0
        fi
    done
    return 1
}

# out/ is not per profile: it keeps what the last build produced, named for that
# device, and nothing about a switch cleans it. Installing the previous device's
# module looks like a working phone until something reads the wrong overlay, so
# say it once, on stderr, and carry on.
profiles_out_note() {
    local count
    [ -d "$ROOT/out" ] || return 0
    count="$(find "$ROOT/out" -maxdepth 1 -name '*.zip' 2>/dev/null | grep -c . || true)"
    [ "${count:-0}" -gt 0 ] || return 0
    printf 'profiles: out/ still holds the previous build (%s zip%s) — build again for this device\n' \
        "$count" "$(if [ "$count" = 1 ]; then printf ''; else printf 's'; fi)" >&2
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
    cat "$ROOT/config.env" | profiles_put "$(profiles_cfg "$id")"
}

# Create the next profile and make it active. It starts as a copy of config.env
# (that is the point: one device's answers, tweaked for the next), or of the
# example on a checkout that has no config.env yet. Prints the new id.
profiles_new_with() {
    local name id n m src taken
    mkdir -p "$PROFILES_DIR" || return 1
    # The folder is claimed with mkdir, which fails when it exists: two shells
    # creating a profile at the same moment then land on p3 and p4, where a
    # `[ -d ]` check first would hand both of them p3 and one would overwrite
    # the other's answers.
    n=1
    until mkdir "$PROFILES_DIR/p$n" 2>/dev/null; do
        [ -d "$PROFILES_DIR/p$n" ] || return 1
        n=$((n + 1))
        [ "$n" -le 999999 ] || return 1
    done
    id="p$n"
    name="$(profiles_clean_name "${1:-}")"
    if [ -n "$name" ]; then
        # Both checks skip the folder just claimed: it is empty, so its name is
        # its own default, and that must not read as a collision with itself.
        if taken="$(profiles_named "$name" "$id")"; then
            rmdir "$PROFILES_DIR/$id" 2>/dev/null || true
            printf 'profiles: "%s" is already taken by p%s — name this one something else\n' \
                "$name" "${taken#p}" >&2
            return 1
        fi
    else
        # The default name follows the folder number, but a rename or a delete
        # can leave that number in use, so the first free one is used. The
        # counter is its own: bumping the folder number here would name p3
        # "Profile #4" and leave the pair looking unrelated.
        m=$n
        while [ -n "$(profiles_named "Profile #$m" "$id")" ]; do m=$((m + 1)); done
        name="Profile #$m"
    fi
    src="$ROOT/config.env"
    [ -f "$src" ] || src="$ROOT/config.env.example"
    # A half-made profile (a folder with no answers, or with no name) would show
    # up in the list as a device with nothing set and switch to an empty file, so
    # the failure of any step takes the whole folder with it.
    if ! { if [ -f "$src" ]; then cp -f "$src" "$(profiles_cfg "$id")"; else : >"$(profiles_cfg "$id")"; fi; } \
        || ! printf '%s\n' "$name" | profiles_put "$(profiles_name_file "$id")" \
        || ! profiles_set_active "$id"; then
        rm -rf "$PROFILES_DIR/$id"
        printf 'profiles: could not create %s\n' "$id" >&2
        return 1
    fi
    printf '%s' "$id"
}

# A checkout that has never seen a profile gets Profile #1 from whatever
# config.env holds, so the first look at the list is not an empty box.
#
# When folders exist but the marker does not, the profile config.env came from
# is the one holding the same bytes — that is provable, and it is the only case
# adopted automatically. Guessing the first folder instead is not harmless: the
# next switch saves config.env into the profile it is active for, so a wrong
# guess overwrites the other device's saved answers.
profiles_ensure() {
    local id
    id="$(profiles_active)"
    [ -n "$id" ] && return 0
    if [ -d "$PROFILES_DIR" ]; then
        if [ -f "$ROOT/config.env" ]; then
            for id in $(profiles_ids); do
                if cmp -s "$ROOT/config.env" "$(profiles_cfg "$id")"; then
                    profiles_set_active "$id"
                    return $?
                fi
            done
        fi
        if [ -n "$(profiles_ids | head -n 1)" ]; then
            printf 'profiles: no profile is active — the marker was lost.\n' >&2
            printf 'profiles: `profiles switch <id>` to say which one config.env belongs to.\n' >&2
            return 1
        fi
    fi
    [ -n "$(profiles_new_with '')" ]
}

# Keep what config.env holds, then load that profile into it.
profiles_switch() {
    local id="$1" src
    profiles_valid_id "$id" || { printf 'profiles: %s is not a profile id\n' "$id" >&2; return 2; }
    profiles_has "$id" || { printf 'profiles: no such profile: %s\n' "$id" >&2; return 1; }
    src="$(profiles_cfg "$id")"
    # A profile folder whose config.env went missing (deleted by hand, a sync
    # that skipped it) would otherwise be copied as nothing and empty out
    # config.env — the one file everything reads.
    if [ ! -f "$src" ]; then
        printf 'profiles: %s has no config.env — that folder is damaged; delete it or save over it\n' "$id" >&2
        return 1
    fi
    profiles_save >/dev/null 2>&1 || true
    cat "$src" | profiles_put "$ROOT/config.env" || return 1
    profiles_set_active "$id" || return 1
    profiles_out_note
    return 0
}

# Save this one, then carry on in a copy of it.
profiles_new() {
    local id
    profiles_ensure >/dev/null || true
    id="$(profiles_new_with "${1:-}")" || return 1
    profiles_switch "$id" || return 1
    printf '%s' "$id"
}

profiles_rename() {
    local id="$1" name taken
    profiles_valid_id "$id" || { printf 'profiles: %s is not a profile id\n' "$id" >&2; return 2; }
    profiles_has "$id" || { printf 'profiles: no such profile: %s\n' "$id" >&2; return 1; }
    name="$(profiles_clean_name "${2:-}")"
    if [ -z "$name" ]; then
        printf 'profiles: a profile needs a name\n' >&2
        return 2
    fi
    if taken="$(profiles_named "$name" "$id")"; then
        printf 'profiles: "%s" is already taken by p%s\n' "$name" "${taken#p}" >&2
        return 1
    fi
    printf '%s\n' "$name" | profiles_put "$(profiles_name_file "$id")"
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
    rm -rf "$PROFILES_DIR/$id" 2>/dev/null || true
    if [ -d "$PROFILES_DIR/$id" ]; then
        printf 'profiles: could not delete %s — its folder is still there\n' "$id" >&2
        return 1
    fi
    return 0
}

# One line per profile, tab separated: id, active(0|1), name, device. This is
# what gui/profiles.go parses; it is not meant for a person to read.
profiles_list() {
    local id active mark
    profiles_ensure >/dev/null || true
    active="$(profiles_active)"
    for id in $(profiles_ids); do
        mark=0
        [ "$id" = "$active" ] && mark=1
        printf '%s\t%s\t%s\t%s\n' "$id" "$mark" \
            "$(profiles_name "$id")" "$(profiles_cell "$(profiles_identity "$id")")"
    done
}

# The same thing for a person: a table with the profile in use marked.
profiles_print() {
    local -a rows=() ids=()
    local id active n=0 mark name device
    profiles_ensure >/dev/null || true
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
        rows+=("$mark|$(profiles_name "$id")|$(profiles_cell "$(profiles_identity "$id")")")
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