#!/usr/bin/env bash
# =============================================================================
# config-edit.sh — read and write one key of config.env
# =============================================================================
# Sourced by the terminal menu (stuff/scripts/menu.sh) and by
# stuff/scripts/match-prop.sh. The probes carry their own copy of the writer
# because they are shipped standalone; anything new should source this.
#
# The file is the source of truth and stays hand-editable: these helpers rewrite
# one line, keep the indentation, keep the quoting the line already used, and
# turn a commented-out KEY= line into a live one (that is what "enable it"
# means). Nothing here validates values — `./build.sh check` does that.
# =============================================================================

: "${ROOT:?stuff/scripts/config-edit.sh must be sourced with ROOT set}"

# cfg_file -> the file the helpers act on, so a test can point somewhere else.
cfg_file() {
    printf '%s' "${CFG_FILE:-${CONFIG_FILE:-$ROOT/config.env}}"
}

# cfg_unquote VALUE -> the value without the quotes config.env puts around text,
# and without the escapes cfg_quote adds inside them.
cfg_unquote() {
    local v="$1" dq=0
    case "$v" in
        \"*) v="${v#\"}"; v="${v%\"}"; dq=1 ;;
        \'*) v="${v#\'}"; v="${v%\'}" ;;
    esac
    if [ "$dq" = 1 ] && [[ "$v" == *\\* ]]; then
        # bash inside double quotes only treats a backslash specially before
        # these four characters, so undo exactly those and leave C:\path alone.
        v="$(printf '%s' "$v" | sed 's/\\\([$`"\\]\)/\1/g')"
    fi
    printf '%s' "$v"
}

# cfg_safe_value VALUE -> the value with the characters that would break the
# file's one-key-per-line shape removed. A probe writes what the phone said, and
# a model name with a newline in it used to split the line in two.
cfg_safe_value() {
    local value="$1"
    value="${value//$'\r'/}"
    value="${value//$'\n'/ }"
    value="${value//$'\t'/ }"
    if [[ "$value" == *[[:cntrl:]]* ]]; then
        # A colour code from a pasted table is ESC + "[31m"; dropping only the
        # ESC would leave the "[31m" in the value, so the whole sequence goes.
        value="$(printf '%s' "$value" | LC_ALL=C sed $'s/\033\\[[0-9;]*[A-Za-z]//g' | LC_ALL=C tr -d '[:cntrl:]')"
    fi
    printf '%s' "$value"
}

# cfg_quote VALUE -> a value config.env can be sourced from.
# Plain words stay bare, as they are in the file today; anything a shell would
# split on, or anything that was already quoted, gets double quotes.
#
# Everything the shell expands inside double quotes is escaped, `$` and the
# backtick included: build.sh sources this file, so a saved value like
# `$(reboot)` would otherwise run as a command on the next build.
cfg_quote() {
    local value="$1" force="${2:-0}"
    case "$value" in
        "") printf '""'; return 0 ;;
    esac
    if [ "$force" != "1" ]; then
        case "$value" in
            *[[:space:]]*|*'#'*|*'"'*|*"'"*|*'$'*|*'`'*|*'\'*) ;;
            *) printf '%s' "$value"; return 0 ;;
        esac
    fi
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    value="${value//\$/\\\$}"
    value="${value//\`/\\\`}"
    printf '"%s"' "$value"
}

# cfg_get KEY -> the live value, unquoted, empty when the key is absent or off.
cfg_get() {
    local key="$1" file line value=""
    file="$(cfg_file)"
    [ -f "$file" ] || return 1
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"
        case "$line" in
            "$key="*) value="${line#*=}" ;;
        esac
    done <"$file"
    [ -n "$value" ] || return 0
    cfg_unquote "$value"
}

# cfg_has KEY -> 0 when KEY= (or #KEY=) exists in the file at all.
cfg_has() {
    local key="$1" file
    file="$(cfg_file)"
    [ -f "$file" ] || return 1
    grep -qE "^[[:space:]]*#?[[:space:]]*${key}=" "$file"
}

# cfg_rows -> one row per assignment, tab separated:
#   key <TAB> active(0|1) <TAB> line number <TAB> section <TAB> value
# A commented-out key is listed with active=0 so it can be turned on by name
# instead of by hunting for the '#'. Prose that happens to end in '=' is not a
# row: only `KEY=` and `#KEY=` (no space after the '#') count.
cfg_rows() {
    local file
    file="$(cfg_file)"
    [ -f "$file" ] || return 1
    awk '
        /^#[[:space:]]*─/ {
            sec = $0
            sub(/^#[[:space:]]*/, "", sec)
            gsub(/─/, "", sec)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", sec)
            next
        }
        /^[A-Za-z_][A-Za-z0-9_]*=/ || /^#[A-Za-z_][A-Za-z0-9_]*=/ {
            line = $0
            sub(/\r$/, "", line)
            key = line
            sub(/=.*/, "", key)
            active = 1
            if (key ~ /^#/) { active = 0; sub(/^#/, "", key) }
            value = substr(line, index(line, "=") + 1)
            printf "%s\t%d\t%d\t%s\t%s\n", key, active, NR, sec, value
        }
    ' "$file"
}

# cfg_sections -> the section titles in file order, one per line.
cfg_sections() {
    cfg_rows | awk -F'\t' '!seen[$4]++ && $4 != "" { print $4 }'
}

# cfg_set KEY VALUE -> rewrite (or add, or enable) that one line.
# Returns 0 when the file was written — also when the value was already right,
# because the caller only cares that the key now holds it.
cfg_set() {
    local key="$1" value file tmp line rest quoted new done=0 wrote=0
    # A pasted value can carry a newline; it would end the line early and turn
    # the rest of it into a key of its own.
    value="$(cfg_safe_value "$2")"
    file="$(cfg_file)"
    if [ -f "$file" ]; then
        tmp="$file.tmp.$$"
        : >"$tmp" || return 1
        while IFS= read -r line || [ -n "$line" ]; do
            local keep="${line%$'\r'}"
            # `KEY=` or `#KEY=` (no space after the '#'), which is how this
            # file disables one — a sentence in a comment that happens to
            # mention the key is left alone.
            if [ "$done" -eq 0 ] && [[ "$keep" =~ ^([[:space:]]*)#?${key}= ]]; then
                indent="${BASH_REMATCH[1]}"
                rest="${keep#*=}"
                quoted=0
                case "$rest" in \"*) quoted=1 ;; esac
                new="${indent}${key}=$(cfg_quote "$value" "$quoted")"
                printf '%s\n' "$new" >>"$tmp"
                done=1
                wrote=1
                continue
            fi
            printf '%s\n' "$keep" >>"$tmp"
        done <"$file"
        if [ "$done" -eq 0 ]; then
            printf '%s=%s\n' "$key" "$(cfg_quote "$value")" >>"$tmp"
            wrote=1
        fi
        mv "$tmp" "$file" || { rm -f "$tmp"; return 1; }
    else
        printf '%s=%s\n' "$key" "$(cfg_quote "$value")" >"$file" || return 1
        wrote=1
    fi
    return 0
}

# cfg_set_active KEY 0|1 -> comment out, or bring back, that one line.
# '#' with nothing after it is the file's own way of switching a key off, and
# cfg_rows reads it back the same way, so an inactive key stays listed.
cfg_set_active() {
    local key="$1" want="$2" file tmp keep done=0 indent rest
    file="$(cfg_file)"
    [ -f "$file" ] || return 1
    tmp="$file.tmp.$$"
    : >"$tmp" || return 1
    while IFS= read -r keep || [ -n "$keep" ]; do
        keep="${keep%$'\r'}"
        if [ "$done" -eq 0 ] && [[ "$keep" =~ ^([[:space:]]*)#?${key}= ]]; then
            indent="${BASH_REMATCH[1]}"
            rest="${keep#*=}"
            if [ "$want" = "1" ]; then
                printf '%s%s=%s\n' "$indent" "$key" "$rest" >>"$tmp"
            else
                printf '#%s%s=%s\n' "$indent" "$key" "$rest" >>"$tmp"
            fi
            done=1
            continue
        fi
        printf '%s\n' "$keep" >>"$tmp"
    done <"$file"
    mv "$tmp" "$file" || { rm -f "$tmp"; return 1; }
    return 0
}

# cfg_summary -> the four lines the menu header shows, from the live file.
cfg_identity() {
    local manuf model code
    manuf="$(cfg_get DEVICE_MANUFACTURER)"
    model="$(cfg_get DEVICE_MODEL)"
    code="$(cfg_get DEVICE_CODENAME)"
    if [ -z "$manuf" ] && [ -z "$model" ] && [ -z "$code" ]; then
        printf 'no device set'
        return 0
    fi
    printf '%s %s (%s)' "$manuf" "$model" "$code" | sed 's/^ *//; s/  */ /g'
}