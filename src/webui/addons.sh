#!/system/bin/sh
# =============================================================================
# Treble Overlay — module addons
# =============================================================================
# An addon is a tweak the *module* makes on the phone. It is not a config.env
# key, and it is chosen in the app's Addons tab (or the page's Addons card),
# not in the overlay resource files.
#
# There are two kinds, and the catalog says which is which:
#
#   setting  a Settings value the module writes. One `settings put` changes it
#            on a running phone — no APK, no reboot — and service.sh re-applies
#            it at every boot. The overlay APK alone cannot do one.
#   overlay  a resource the build bakes into an overlay APK — framework (the
#            navigation bar height, the 180° rotation flag) or SystemUI (the
#            status bar background). It only changes after a rebuild and a
#            flash, because a resource is read when its process starts.
#
# The live addons survive an overlay rebuild; the overlay ones *are* the rebuild.
#
# One catalog lives in this file and every front-end reads it:
#
#   the desktop app   runs this script in the clone (Addons tab)
#   the module page   runs it in webroot/ on the phone (Addons card)
#   service.sh        runs it at every boot so saved choices stick
#
#   sh addons.sh list                 catalog + saved + live values, as JSON
#   sh addons.sh set ID=VALUE ...     save choices; apply the live ones now
#   sh addons.sh apply [ID ...]       apply what is saved (all ids, or those)
#   sh addons.sh reset                back to the defaults, forget the choices
#   sh addons.sh status               what the device resolves now, as key=value
#   sh addons.sh restore-conf         customize.sh: bring the saved file back
#
# The saved file is addons.conf at the module root (src/module/addons.conf in
# the clone). Only the addons that differ from the default are written into it:
# a value nobody changed is not enforced on every boot, so an untouched phone
# keeps behaving like the ROM shipped it.
#
# ADDONS_CONF, ADDONS_DIR and ADDONS_SETTINGS exist so this can be exercised
# off-device (stuff/tests/addons-sh.test.js) and by the desktop app, which has
# no installed module but does have the clone.
# =============================================================================

# The module directory is one level above this script (webroot/), except when
# the script is run by its bare name from the module root ('sh addons.sh'), in
# which case '..' would be the folder above the module.
SELF="$0"
case "$SELF" in
    */*) SELF_DIR=${SELF%/*}
         MODDIR=$(cd "$SELF_DIR/.." 2>/dev/null && pwd) ;;
    *)   SELF_DIR=.
         MODDIR=$(pwd) ;;
esac
MODDIR=${ADDONS_DIR:-$MODDIR}
[ -n "$MODDIR" ] || MODDIR=$SELF_DIR
# In the clone the module files are kept in src/module/, so the script in
# src/webui/ has one directory in between; an installed module keeps the same
# files at its root.
[ -d "$MODDIR/module" ] && MODDIR="$MODDIR/module"

CONF=${ADDONS_CONF:-$MODDIR/addons.conf}
# Outside the module directory on purpose: an update replaces that directory.
# It is the same folder apply.sh mirrors webui.conf into.
STATE_DIR=${ADDONS_STATE_DIR:-/data/adb/treble-webui/${MODDIR##*/}}
SETTINGS=${ADDONS_SETTINGS:-settings}

say() { printf '%s\n' "$*"; }

# ---------------------------------------------------------------------------
# Catalog
# ---------------------------------------------------------------------------
# id|choices|default|label|summary|kind
#
# The value names are what the page and the app show, so they are plain words:
# "left"/"right", not "0"/"1". The mapping to the Settings value is in
# apply_one() below, and live_value() maps it back. Keep the summaries free of
# '|' and keep them one sentence: they are rendered as-is.
#
# kind is "setting" or "overlay" (see the top of this file). Only "setting" ids
# reach apply_one()/live_value(); the build reads the overlay ids out of the
# saved file and emits them as overlay resources (see resources.sh).
#
# A two-choice addon whose choices are exactly on,off is drawn as a switch;
# anything else is a picker.
catalog() {
    cat << 'CATALOG_EOF'
volume_panel|right,left|right|Volume panel side|The volume slider slides in from this edge instead of the other one.|setting
captive_portal|on,off|on|Captive portal check|Android's "sign in to this network" probe. Off stops the false no-internet warnings a GSI shows on some networks.|setting
stay_awake|on,off|off|Screen never sleeps|Leave the display on indefinitely, on battery too. Only the power button turns it off again.|setting
status_clock|on,off|on|Status bar clock|Hide the time in the status bar so the notification icons get its room. The lock-screen clock is left alone.|setting
any_rotation|on,off|off|Upside-down rotation|Allow the 180° rotation Android normally refuses, in every app and launcher that can turn.|overlay
nav_bar_padding|on,off|on|Navigation bar padding|Reserve no space for the gesture bar: content reaches the bottom edge while the pill stays visible and swipeable.|overlay
status_bar_background|on,off|on|Status bar background|Remove the shade behind the status bar, so the bar sits directly on the wallpaper or the app.|overlay
hide_notch|on,off|off|Hide the notch|Black out the strip the notch sits in and keep every app below it, so nothing can draw under the camera.|overlay
CATALOG_EOF
}

# Every id, one per line.
ids() {
    catalog | while IFS='|' read -r id choices def label summary kind; do
        case "$id" in ''|'#'*) continue ;; esac
        printf '%s\n' "$id"
    done
}

catalog_field() { # <id> <field number> -> that field, empty when unknown
    catalog | awk -F'|' -v id="$1" -v f="$2" '$1 == id { print $f; exit }'
}

choices_of() { catalog_field "$1" 2; }
default_of() { catalog_field "$1" 3; }
label_of()   { catalog_field "$1" 4; }
summary_of() { catalog_field "$1" 5; }
kind_of()    { catalog_field "$1" 6; }

valid_value() { # <id> <value>
    case " $(choices_of "$1" | tr ',' ' ') " in
        *" $2 "*) return 0 ;;
    esac
    return 1
}

bad_value() { say "x $1: '$2' is not one of: $(choices_of "$1" | tr ',' '/')"; }

# ---------------------------------------------------------------------------
# The saved file
# ---------------------------------------------------------------------------
# Same shape as config.env — ID=VALUE lines, '#' comments — so it can be read
# and edited by hand. apply.sh keeps webui.conf in the module the same way.
conf_value() { # <key> -> saved value, empty when not saved
    [ -f "$CONF" ] || return 0
    awk -v k="$1" 'index($0, k "=") == 1 { v = substr($0, length(k) + 2) } END { printf "%s", v }' "$CONF" 2>/dev/null
}

has_saved() {
    [ -f "$CONF" ] || return 1
    grep -q '^[A-Za-z]' "$CONF" 2>/dev/null
}

put_conf() { # <key> <value>
    key=$1
    val=$2
    tmp="$CONF.tmp"
    if [ -f "$CONF" ]; then
        awk -v k="$key" -v v="$val" '
            index($0, k "=") == 1 { if (!done) { print k "=" v; done = 1 } next }
            { print }
            END { if (!done) print k "=" v }
        ' "$CONF" > "$tmp" 2>/dev/null
    else
        {
            printf '%s\n' \
                '# =============================================================================' \
                '# Module addons — Treble Overlay' \
                '# =============================================================================' \
                '# Written by the desktop app (Addons tab) or by this module on the phone.' \
                '# Only what is listed here is enforced, and it is enforced on every boot.' \
                '# Remove an ID=VALUE line (or use Reset) to hand that setting back.' \
                '# The list of addons and their values: docs/addons.md' \
                '# ============================================================================='
            printf '%s=%s\n' "$key" "$val"
        } > "$tmp" 2>/dev/null
    fi
    if [ ! -f "$tmp" ] || ! mv "$tmp" "$CONF" 2>/dev/null; then
        rm -f "$tmp" 2>/dev/null
        say "x cannot write $CONF (uid $(id -u 2>/dev/null))"
        say "  The WebUI host ran this script without write access to the module."
        return 1
    fi
    chmod 600 "$CONF" 2>/dev/null || true
    return 0
}

del_conf() { # <key>
    [ -f "$CONF" ] || return 0
    tmp="$CONF.tmp"
    awk -v k="$1" 'index($0, k "=") != 1' "$CONF" > "$tmp" 2>/dev/null \
        && mv "$tmp" "$CONF" 2>/dev/null
    chmod 600 "$CONF" 2>/dev/null || true
    return 0
}

# The saved file lives in two places: the module (what this script reads) and
# $STATE_DIR (what survives an update, because the update replaces the module).
mirror_conf() {
    mkdir -p "$STATE_DIR" 2>/dev/null || return 0
    if [ -f "$CONF" ]; then
        cp "$CONF" "$STATE_DIR/addons.conf" 2>/dev/null || true
    else
        rm -f "$STATE_DIR/addons.conf" 2>/dev/null || true
    fi
    chmod 600 "$STATE_DIR/addons.conf" 2>/dev/null || true
}

# customize.sh calls this after the new zip is unpacked. The packaged file is
# the app's latest word, so its choices win: restoring the old file over it made
# a freshly built "hide the notch" come up unset, because the phone still had
# the previous install's copy. Only the addons the new file does not name are
# carried over - those are the ones chosen on the phone, which the app never
# saw. A build that names nothing at all is a plain rebuild, so the saved file
# is restored whole, the way it always was.
restore_conf() {
    [ -f "$STATE_DIR/addons.conf" ] || return 0
    if ! has_saved; then
        if cp "$STATE_DIR/addons.conf" "$CONF" 2>/dev/null; then
            chmod 600 "$CONF" 2>/dev/null || true
            say "+ saved addons restored"
        fi
        return 0
    fi

    restored=0
    while IFS= read -r line; do
        key=${line%%=*}
        [ -n "$key" ] || continue
        # A line from an older catalog is not brought back (reset prunes it).
        [ -n "$(default_of "$key")" ] || continue
        [ -z "$(conf_value "$key")" ] || continue
        put_conf "$key" "${line#*=}" || return 1
        restored=$((restored + 1))
    done <<EOF
$(grep '^[A-Za-z]' "$STATE_DIR/addons.conf" 2>/dev/null)
EOF
    [ "$restored" -gt 0 ] && say "+ $restored saved addon(s) restored"
    return 0
}

# ---------------------------------------------------------------------------
# Settings
# ---------------------------------------------------------------------------
have_settings() { command -v "$SETTINGS" >/dev/null 2>&1; }

setting_get() { # <namespace> <key> -> value, empty for null/absent
    have_settings || return 0
    out=$("$SETTINGS" get "$1" "$2" 2>/dev/null | tr -d '\r' | tail -n 1)
    case "$out" in
        ""|null) printf '' ;;
        *) printf '%s' "$out" ;;
    esac
}

put() { # <addon> <namespace> <key> <value>
    if ! have_settings; then
        say "x $1: the settings command is not available on this device"
        return 1
    fi
    err=$("$SETTINGS" put "$2" "$3" "$4" 2>&1)
    if [ $? -ne 0 ]; then
        say "x $1: $(printf '%s' "$err" | tr '\n' ' ' | sed 's/ *$//')"
        return 1
    fi
    return 0
}

# What the device resolves right now, in the catalog's words. Empty when the
# phone says nothing (or there is no phone — the desktop app has none).
live_value() {
    case "$1" in
        volume_panel)
            case "$(setting_get secure volume_panel_on_left)" in
                1) printf left ;;
                0) printf right ;;
            esac ;;
        captive_portal)
            case "$(setting_get global captive_portal_mode)" in
                1) printf on ;;
                0) printf off ;;
            esac ;;
        stay_awake)
            # The addon lives in one key: a screen timeout no UI can pick.
            case "$(setting_get system screen_off_timeout)" in
                2147483647) printf on ;;
                *)          printf off ;;
            esac ;;
        status_clock)
            # icon_blacklist is one list for the whole bar ("clock", "rotate",
            # ...), so the clock is hidden by being present in it, not by a
            # value of its own.
            case " $(setting_get secure icon_blacklist | tr ',' ' ') " in
                *" clock "*) printf off ;;
                *)           printf on ;;
            esac ;;
    esac
}

# icon_blacklist carries every status bar icon SystemUI should leave out, and
# the clock is one entry in it. Writing it for the clock therefore has to keep
# whatever else the user (or another module) put there: a plain `put` would
# replace the whole list. An empty result writes an empty value, which is what
# a phone that never had the key answers anyway.
icon_blacklist_set() { # <hide|show> the clock
    ib_list=$(setting_get secure icon_blacklist | tr ',' '\n' | awk 'NF && $0 != "clock"')
    if [ "$1" = hide ]; then
        ib_list=$(printf '%s\n%s\n' "$ib_list" clock | awk 'NF')
    fi
    ib_value=$(printf '%s\n' "$ib_list" | awk 'NF { printf "%s%s", (n++ ? "," : ""), $0 }')
    put status_clock secure icon_blacklist "$ib_value"
}

apply_one() { # <id> <value>
    id=$1
    v=$2
    # An overlay addon is a build-time decision; the running APK cannot change
    # it, so there is nothing to put. The caller has already saved the choice.
    if [ "$(kind_of "$id")" = overlay ]; then
        return 0
    fi
    case "$id" in
        volume_panel)
            case "$v" in
                left)  put "$id" secure volume_panel_on_left 1 ;;
                right) put "$id" secure volume_panel_on_left 0 ;;
                *)     bad_value "$id" "$v"; return 1 ;;
            esac ;;
        captive_portal)
            case "$v" in
                on)  put "$id" global captive_portal_mode 1 ;;
                off) put "$id" global captive_portal_mode 0 ;;
                *)   bad_value "$id" "$v"; return 1 ;;
            esac ;;
        stay_awake)
            # 2147483647 ms is the largest an int Setting can hold — about 24
            # days, which is "until the power button" for any practical use.
            case "$v" in
                on)  put "$id" system screen_off_timeout 2147483647 ;;
                off) put "$id" system screen_off_timeout 60000 ;;
                *)   bad_value "$id" "$v"; return 1 ;;
            esac ;;
        status_clock)
            case "$v" in
                on)  icon_blacklist_set show ;;
                off) icon_blacklist_set hide ;;
                *)   bad_value "$id" "$v"; return 1 ;;
            esac ;;
        *)
            say "x $id: no such addon"
            return 1 ;;
    esac
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------
cmd_list() { # JSON: the catalog, what is saved, what the phone resolves
    if has_saved; then saved_any=yes; else saved_any=no; fi
    if have_settings; then device=yes; else device=no; fi
    printf '{"conf":"%s","device":"%s","addons":[' "$saved_any" "$device"
    first=1
    catalog | while IFS='|' read -r id choices def label summary kind; do
        case "$id" in ''|'#'*) continue ;; esac
        [ "$first" = 1 ] || printf ','
        first=0
        saved=$(conf_value "$id")
        if [ -n "$saved" ]; then
            value=$saved
            is_saved=true
        else
            value=$def
            is_saved=false
        fi
        printf '{"id":"%s","kind":"%s","label":"%s","summary":"%s","choices":[%s],"default":"%s","value":"%s","saved":%s,"live":"%s"}' \
            "$id" "$kind" \
            "$(printf '%s' "$label" | sed 's/\\/\\\\/g; s/"/\\"/g')" \
            "$(printf '%s' "$summary" | sed 's/\\/\\\\/g; s/"/\\"/g')" \
            "$(printf '%s' "$choices" | awk -F, '{ for (i = 1; i <= NF; i++) printf "%s\"%s\"", (i > 1 ? "," : ""), $i }')" \
            "$def" "$value" "$is_saved" "$(live_value "$id")"
    done
    printf ']}\n'
}

cmd_set() { # ID=VALUE ... — save, then make it true now
    rc=0
    for pair in "$@"; do
        id=${pair%%=*}
        if [ "$id" = "$pair" ]; then
            say "x '$pair' is not ID=VALUE"
            rc=1
            continue
        fi
        v=${pair#*=}
        if [ -z "$(default_of "$id")" ]; then
            say "x $id: no such addon"
            rc=1
            continue
        fi
        if ! valid_value "$id" "$v"; then
            bad_value "$id" "$v"
            rc=1
            continue
        fi
        # Only deviations are kept: setting an addon back to its default hands
        # that setting back to the ROM instead of pinning it on every boot.
        if [ "$v" = "$(default_of "$id")" ]; then
            del_conf "$id"
        else
            put_conf "$id" "$v" || rc=1
        fi
        say "+ $id=$v"
        # An overlay addon only exists inside the APK. Saving it is the shell's
        # whole job: the page writes the entry with Apply, and build.sh emits it
        # (or stops emitting it, when the choice is the default).
        if [ "$(kind_of "$id")" = overlay ]; then
            if [ "$v" = "$(default_of "$id")" ]; then
                say "  overlay addon: saved as the default — nothing to enforce"
            else
                say "  overlay addon: saved — Apply on the phone, or the next build, writes it"
            fi
            continue
        fi
        # On a desktop with no phone there is nothing to apply to, and the file
        # is the whole job; the script still exits 0 so the choice is saved.
        if have_settings; then
            # A failed put stays saved on purpose: the next boot tries again,
            # and `list` reports the row as saved but not live.
            apply_one "$id" "$v" || rc=1
        fi
    done
    mirror_conf
    # The choice is saved even when the device rejected a put (the next boot
    # tries again), but the exit code says so: the phone's page turns it into a
    # warning, and the desktop app has no `settings` to fail with.
    return $rc
}

cmd_apply() { # [ID ...] — apply what is saved; no output when nothing is
    rc=0
    if [ $# -gt 0 ]; then list="$*"; else list=$(ids); fi
    for id in $list; do
        v=$(conf_value "$id")
        [ -n "$v" ] || continue
        # A line left by an older catalog is not an error at boot; it is just
        # ignored. `reset` is what deletes it.
        [ -n "$(default_of "$id")" ] || continue
        # Overlay addons are already inside the APK; there is nothing to set.
        if [ "$(kind_of "$id")" = overlay ]; then
            continue
        fi
        apply_one "$id" "$v" || { rc=1; continue; }
        # Read it back: a put that the system rejected (a restricted namespace,
        # for instance) prints nothing but leaves the old value in place.
        now=$(live_value "$id")
        if [ "$now" != "$v" ]; then
            say "x $id: the device still reports '${now:-unset}'"
            rc=1
        else
            say "+ $id=$v"
        fi
    done
    return $rc
}

cmd_reset() {
    rc=0
    kept_overlay=no
    for id in $(ids); do
        v=$(conf_value "$id")
        [ -n "$v" ] || continue
        if [ "$(kind_of "$id")" = overlay ]; then
            # The flashed APK cannot be un-built from here. On the phone the
            # line stays because it describes what is installed; on the
            # desktop (no phone, no `settings`) it is just a build choice and
            # Clear all must remove it.
            if have_settings; then
                kept_overlay=yes
            else
                del_conf "$id"
            fi
            continue
        fi
        # Same guard as `set`: with no phone there is nothing to restore, and
        # clearing the file is the whole job.
        if have_settings; then
            apply_one "$id" "$(default_of "$id")" || rc=1
        fi
        del_conf "$id"
    done
    # Drop lines for addons that no longer exist (an older catalog shipped the
    # battery percentage and the clock seconds, which a GSI exposes itself).
    if [ -f "$CONF" ]; then
        for id in $(grep '^[A-Za-z]' "$CONF" 2>/dev/null | cut -d= -f1); do
            [ -n "$(default_of "$id")" ] || del_conf "$id"
        done
    fi
    mirror_conf
    say "+ live addons are back to their defaults; nothing is applied on boot"
    [ "$kept_overlay" = yes ] && say "  overlay addons stay as they are — the installed APK still has them"
    return $rc
}

cmd_status() { # key=value, the way apply.sh status reports
    for id in $(ids); do
        printf '%s=%s\n' "$id" "$(live_value "$id")"
    done
}

usage() {
    say "usage: addons.sh list | set ID=VALUE ... | apply [ID ...] | reset | status"
    say "       addons.sh restore-conf"
}

cmd=${1:-list}
[ $# -gt 0 ] && shift

case "$cmd" in
    list)         cmd_list ;;
    set)          cmd_set "$@" ;;
    apply)        cmd_apply "$@" ;;
    reset)        cmd_reset ;;
    status)       cmd_status ;;
    restore-conf) restore_conf ;;
    catalog)      catalog ;;
    help|-h|--help) usage ;;
    *)
        say "x unknown command: $cmd"
        usage
        exit 2 ;;
esac
exit $?
