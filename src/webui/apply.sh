#!/system/bin/sh
# =============================================================================
# Treble Overlay — WebUI helper
# =============================================================================
#
# Two mechanisms, because Android only allows one of them per value type:
#
#   dimens  the page patches the value straight into resources.arsc of the
#           overlay APK this module already ships (`apks`/`backup`/`restore`
#           below keep the paths and the pristine copies). A dimension the
#           build did not emit - config.env leaves the optional padding keys
#           commented out - is added to that table by the page, which then
#           writes the whole APK again. A static RRO is read when the
#           framework starts, so `reload` restarts zygote.
#           `cmd overlay fabricate` cannot be used for these: it only accepts
#           int/colour/bool/string data types and rejects a dimension with
#           "dataType is out of range of [16, 31] (too low)".
#
#   bools   a fabricated overlay (`cmd overlay fabricate`) still works and is
#           cheaper than repacking an APK, so config_displayBlanksAfterDoze is
#           registered at runtime and again at boot.
#
#   sh apply.sh get                 saved values + build-time defaults
#   sh apply.sh set KEY=VALUE ...   store values only
#   sh apply.sh apply [--boot]      register the fabricated (bool) overlays
#   sh apply.sh apks                overlay APK paths the page patches
#   sh apply.sh backup              keep a pristine copy of those APKs
#   sh apply.sh restore             put the pristine APKs back
#   sh apply.sh reload              restart zygote so the patched APKs load
#   sh apply.sh verify              exit 0 when every saved value is live
#   sh apply.sh restart             restart SystemUI only (no framework reload)
#   sh apply.sh status              effective (current) device values
#   sh apply.sh reset               restore the APKs and forget the values
#
# Resource arrays such as the auto-brightness curves cannot be expressed this
# way at all - those still need a rebuild.
#
# NOTE: fabricated overlay names may only contain alphanumerics, '_' and '.'
# (AOSP OverlayManagerServiceImpl.validateName with requireFilename=true).
# A hyphen in the name makes `fabricate` fail with
# "overlay name can only consist of alphanumeric characters, '_', and '.'",
# so every character outside that set is replaced with '_'.
# =============================================================================

SELF="$0"
case "$SELF" in
    */*) SELF_DIR=${SELF%/*} ;;
    *)   SELF_DIR=. ;;
esac
MODDIR=$(cd "$SELF_DIR/.." 2>/dev/null && pwd)
[ -n "$MODDIR" ] || MODDIR=$SELF_DIR
CONF="$MODDIR/webui.conf"
DEFAULTS="$MODDIR/webui-defaults.conf"
OWNER="com.android.shell"
PREFIX="treble_webui"

# WEBUI_CMD only exists so the script can be exercised off-device.
CMD=${WEBUI_CMD:-/system/bin/cmd}

KEYS="RADIUS SB_HEIGHT PAD_CONTENT PAD_START PAD_END DOZE_BLANK"

say() { echo "$*"; }

# --- storage ---------------------------------------------------------------

conf_value() { # <file> <key>
    [ -f "$1" ] || return 0
    sed -n "s/^$2=//p" "$1" 2>/dev/null | tail -n 1
}

get_effective() { # <key> -> saved value, else the build-time default
    v=$(conf_value "$CONF" "$1")
    if [ -z "$v" ]; then
        v=$(conf_value "$DEFAULTS" "$1")
    fi
    printf '%s' "$v"
}

put_conf() { # <key> <value>
    key=$1
    val=$2
    tmp="$CONF.tmp"
    if [ -f "$CONF" ]; then
        grep -v "^${key}=" "$CONF" > "$tmp" 2>/dev/null
    else
        : > "$tmp" 2>/dev/null
    fi
    printf '%s=%s\n' "$key" "$val" >> "$tmp" 2>/dev/null
    if ! mv "$tmp" "$CONF" 2>/dev/null; then
        rm -f "$tmp" 2>/dev/null
        say "x cannot write $CONF (uid $(id -u 2>/dev/null))"
        say "  The WebUI host ran this script without write access to the module."
        return 1
    fi
    return 0
}

# --- fabrication -----------------------------------------------------------

overlay_name() { # <type/name> -> name valid for FabricatedOverlay
    printf '%s_%s' "$PREFIX" "$(printf '%s' "$1" | tr -c 'A-Za-z0-9_.' '_')"
}

# overlay_id <type/name> -> owner-qualified overlay id shown by `overlay list`
overlay_id() {
    printf '%s:%s' "$OWNER" "$(overlay_name "$1")"
}

# wait_enabled <type/name> -> 0 when the manager reports the overlay enabled.
# Prints the last list line seen so the caller can show what the manager thinks.
# `cmd overlay enable` exits 0 even when the transaction is rejected (Android
# logs the reason and leaves the overlay disabled), so its exit code proves
# nothing; the state in `overlay list` is the only reliable signal.
wait_enabled() {
    n=$(overlay_name "$1")
    i=0
    line=""
    while [ "$i" -lt 3 ]; do
        line=$("$CMD" overlay list --user 0 2>/dev/null | grep -F ":$n" | head -n 1 | tr -d '\r')
        case "$line" in
            "[x]"*) printf '%s' "$line"; return 0 ;;
        esac
        i=$((i + 1))
        sleep 1
    done
    printf '%s' "$line"
    return 1
}

fabricate() { # <target> <type/name> <type-id> <encoded-value>
    target=$1
    resource=$2
    tid=$3
    enc=$4
    name=$(overlay_name "$resource")

    out=$("$CMD" overlay fabricate --target "$target" --name "$name" \
        "$target:$resource" "$tid" "$enc" 2>&1)
    if [ $? -ne 0 ]; then
        say "x $resource: $(printf '%s' "$out" | tr '\n' ' ')"
        return 1
    fi
    if ! "$CMD" overlay enable --user 0 "$OWNER:$name" >/dev/null 2>&1; then
        say "x $resource: registered but could not be enabled"
        return 1
    fi
    line=$(wait_enabled "$resource")
    if [ $? -ne 0 ]; then
        if [ -n "$line" ]; then
            say "x $resource: the overlay manager did not enable it (${line})"
        else
            say "x $resource: fabricated overlay is not registered with the overlay manager"
        fi
        return 1
    fi
    # The module ships a static overlay for the same resource. Static overlays
    # cannot be disabled or reprioritised while the device runs, so the
    # fabricated one has to be moved above them explicitly. The overlay id is
    # owner:name; some builds only accept the bare name, so try both.
    if ! "$CMD" overlay set-priority "$OWNER:$name" highest >/dev/null 2>&1; then
        "$CMD" overlay set-priority "$name" highest >/dev/null 2>&1 || \
            say "! $resource: fabricated, but priority could not be raised above the static overlay"
    fi
    say "+ $resource = $enc"
    return 0
}

bool_value() { # <target> <bool/name> true|false
    case "$3" in
        true|1) enc=1 ;;
        false|0) enc=0 ;;
        "") return 0 ;;
        *) say "x $2: '$3' is not true/false"; return 1 ;;
    esac
    fabricate "$1" "$2" 0x12 "$enc"
}

# --- reading the device ----------------------------------------------------

lookup_raw() { # <query-package> <target> <type/name>
    "$CMD" overlay lookup "$1" "$2:$3" 2>/dev/null | head -n 1 | tr -d '\r'
}

# lookup_px / lookup_bool take the resource as "dimen/name" or "bool/name".
# The target package is repeated in the resource id (android:dimen/...).

lookup_px() { # <query-package> <target> <dimen/name> -> integer px, empty on failure
    printf '%s' "$(lookup_raw "$1" "$2" "$3")" | \
        sed -n 's/^[[:space:]]*\(-\{0,1\}[0-9][0-9]*\).*/\1/p'
}

lookup_bool() { # <query-package> <target> <bool/name>
    printf '%s' "$(lookup_raw "$1" "$2" "$3")" | tr -d '[:space:]'
}

# do_status prints shell-friendly key=value lines. The WebUI reads exactly
# these keys, so keep the names stable.
do_status() {
    uid=$(id -u 2>/dev/null)
    sdk=$(getprop ro.build.version.sdk 2>/dev/null)
    [ -n "$sdk" ] || sdk=$(getprop ro.system.build.version.sdk 2>/dev/null)
    model=$(getprop ro.product.model 2>/dev/null | tr -d '\r')

    list=$("$CMD" overlay list --user 0 2>/dev/null)
    if "$CMD" overlay list >/dev/null 2>&1; then
        cmd_state=ok
    else
        cmd_state=unavailable
    fi
    total=$(printf '%s\n' "$list" | grep -c "$PREFIX")
    enabled=$(printf '%s\n' "$list" | grep -c "^\[x\].*$PREFIX")
    # The module's own static overlays (me.phh.treble.overlay.*). If these are
    # not enabled, the module never applied anything and the device is showing
    # ROM values regardless of the WebUI.
    static_on=$(printf '%s\n' "$list" | grep -c '^\[x\] me\.phh\.treble\.overlay\.')

    say "cmd=$cmd_state"
    say "uid=${uid:-?}"
    say "sdk=${sdk:-?}"
    say "model=${model:-Android}"
    say "overlay_total=${total:-0}"
    say "overlay_enabled=${enabled:-0}"
    say "static_overlays=${static_on:-0}"
    say "radius=$(lookup_px android android dimen/rounded_corner_radius)"
    say "sb_height=$(lookup_px android android dimen/status_bar_height_default)"
    say "pad_content=$(lookup_px android android dimen/rounded_corner_content_padding)"
    say "pad_start=$(lookup_px com.android.systemui com.android.systemui dimen/status_bar_padding_start)"
    say "pad_end=$(lookup_px com.android.systemui com.android.systemui dimen/status_bar_padding_end)"
    say "doze_blank=$(lookup_bool android android bool/config_displayBlanksAfterDoze)"
    say "conf=$([ -f "$CONF" ] && echo yes || echo no)"
    say "patched=$(ls "$(overlay_dir)"/*.webui-orig 2>/dev/null | grep -c .)"
}

# --- commands --------------------------------------------------------------

do_get() {
    for key in $KEYS; do
        value=$(get_effective "$key")
        [ -n "$value" ] && say "$key=$value"
    done
}

do_apply() {
    # `cmd overlay fabricate` is root-only: the shell command itself checks
    # Binder.getCallingUid() == 0 and the FRRO is written to /data/resource-cache
    # as that uid. Without root every fabricate is rejected, so say why instead
    # of printing a bare error for each resource.
    uid=$(id -u 2>/dev/null)
    if [ "$uid" != "0" ]; then
        say "x not running as root (uid ${uid:-?})"
        say "  Overlays can only be created by root. Open this page from"
        say "  KernelSU / KSU Next / APatch, or enable root mode in the WebUI host."
        return 2
    fi

    if ! "$CMD" overlay list >/dev/null 2>&1; then
        say "x overlay service not reachable"
        return 1
    fi

    # Only the boolean is fabricated here. `cmd overlay fabricate` accepts data
    # types 16..31 (int, colour, bool) and nothing else, so a dimension cannot
    # be registered that way at all - the page writes dimensions into the
    # resources.arsc of the shipped overlay APKs instead.
    want=$(get_effective DOZE_BLANK)
    [ -n "$want" ] || return 0
    bool_value android "bool/config_displayBlanksAfterDoze" "$want"
}

# Compare every saved slider value with what the device resolves right now.
# Returns 0 only when all of them are live. This is what tells a patch that has
# been scanned from one that is still waiting for a reload.
# verify_px <key> <query-package> <target> <dimen/name>
verify_px() {
    want=$(normalize_px "$(get_effective "$1")")
    [ -n "$want" ] || return 0
    now=$(lookup_px "$2" "$3" "$4")
    if [ -z "$now" ]; then
        # An unreadable value is not "correct": the old code skipped the
        # comparison, so a broken lookup made a failed apply look successful.
        say "? $3:$4 could not be read (lookup returned nothing)"
        mismatch=1
    elif [ "$now" != "$want" ]; then
        say "! $3:$4 is ${now}px, wanted ${want}px"
        mismatch=1
    fi
}

verify_all() {
    if ! "$CMD" overlay list >/dev/null 2>&1; then
        say "! overlay service not reachable"
        return 1
    fi

    mismatch=0

    verify_px RADIUS      android              android              dimen/rounded_corner_radius
    verify_px SB_HEIGHT   android              android              dimen/status_bar_height_default
    verify_px PAD_CONTENT android              android              dimen/rounded_corner_content_padding
    verify_px PAD_START   com.android.systemui com.android.systemui dimen/status_bar_padding_start
    verify_px PAD_END     com.android.systemui com.android.systemui dimen/status_bar_padding_end

    want=$(get_effective DOZE_BLANK)
    if [ -n "$want" ]; then
        now=$(lookup_bool android android bool/config_displayBlanksAfterDoze)
        if [ -z "$now" ]; then
            say "? android:bool/config_displayBlanksAfterDoze could not be read"
            mismatch=1
        elif [ "$now" != "$want" ]; then
            say "! android:bool/config_displayBlanksAfterDoze is '$now', wanted '$want'"
            mismatch=1
        fi
    fi

    if [ "$mismatch" -ne 0 ]; then
        say "  A dimension that does not change means the framework has not read"
        say "  the patched overlay yet: run 'sh apply.sh reload' (or reboot)."
    fi
    return $mismatch
}

normalize_px() { # "096" -> "96", "000" -> "0", "" -> ""
    [ -n "$1" ] || return 0
    v=$(printf '%s' "$1" | sed 's/^0*//')
    printf '%s' "${v:-0}"
}

do_restart_systemui() {
    # At boot SystemUI may not have been started yet; killing an empty pid
    # would leave the stale values on screen. Wait a moment for it.
    n=0
    while [ "$n" -lt 10 ]; do
        pid=$(pidof com.android.systemui 2>/dev/null)
        [ -n "$pid" ] && break
        n=$((n + 1))
        sleep 2
    done
    if [ -n "$pid" ]; then
        # SystemUI is a persistent app: init starts it again immediately.
        # shellcheck disable=SC2086
        kill -9 $pid 2>/dev/null && { say "SystemUI restarted (pid ${pid% *})"; return 0; }
    fi
    if command -v killall >/dev/null 2>&1 && killall com.android.systemui 2>/dev/null; then
        say "SystemUI restarted"
        return 0
    fi
    if command -v pkill >/dev/null 2>&1 && pkill -f com.android.systemui 2>/dev/null; then
        say "SystemUI restarted"
        return 0
    fi
    say "! Could not restart SystemUI - reboot or run 'killall com.android.systemui' as root"
    return 1
}

# --- the shipped overlay APKs ----------------------------------------------
# The page rewrites the value of a dimension inside resources.arsc of these
# files. Both are named after the module id; the SystemUI one has a -systemui
# suffix. Nothing here parses the APK - the page does that - this only hands
# out the paths and keeps a pristine copy to fall back to.

overlay_dir() { printf '%s' "$MODDIR/system/product/overlay"; }

fw_apk() {
    for apk in "$(overlay_dir)"/*.apk; do
        [ -f "$apk" ] || continue
        case "$apk" in
            *-systemui.apk) ;;
            *) printf '%s' "$apk"; return 0 ;;
        esac
    done
}

sui_apk() {
    for apk in "$(overlay_dir)"/*-systemui.apk; do
        [ -f "$apk" ] && { printf '%s' "$apk"; return 0; }
    done
}

do_apks() {
    fw=$(fw_apk)
    sui=$(sui_apk)
    say "fw=${fw:-}"
    say "sui=${sui:-}"
    say "write=$([ -w "$(overlay_dir)" ] && echo yes || echo no)"
    say "uid=$(id -u 2>/dev/null)"
}

# Keep the APK the build produced, so the page can be undone after a patch.
# $apk.webui-orig also tells the rest of the script whether an APK was patched.
do_backup() {
    dir=$(overlay_dir)
    [ -d "$dir" ] || { say "x overlay directory not found: $dir"; return 1; }
    [ "$(id -u 2>/dev/null)" = "0" ] || {
        say "x backup needs root (uid $(id -u 2>/dev/null))"; return 1
    }

    rc=0
    for apk in "$dir"/*.apk; do
        [ -f "$apk" ] || continue
        name=${apk##*/}
        if [ -f "$apk.webui-orig" ]; then
            say "+ backup kept: $name"
            continue
        fi
        # cp -p keeps the timestamp, but the copy is never mounted, so only
        # its contents matter.
        if cp -p "$apk" "$apk.webui-orig" 2>/dev/null; then
            say "+ backup: $name"
        else
            say "x cannot write $apk.webui-orig"
            rc=1
        fi
    done
    return $rc
}

# Put the build-time APKs back. cat into the existing file instead of mv: that
# keeps the inode and the u:object_r:system_file:s0 label the module mount needs.
do_restore() {
    dir=$(overlay_dir)
    rc=0
    restored=0
    for apk in "$dir"/*.apk; do
        [ -f "$apk" ] || continue
        [ -f "$apk.webui-orig" ] || continue
        if cat "$apk.webui-orig" > "$apk" 2>/dev/null; then
            # The file is pristine again, so the copy is no longer needed:
            # without this the next reset would "restore" the same APK again
            # and keep reporting a patch that is gone.
            rm -f "$apk.webui-orig"
            say "+ restored: ${apk##*/}"
            restored=$((restored + 1))
        else
            say "x cannot restore ${apk##*/}"
            rc=1
        fi
    done
    rm -f "$dir"/*.webui-new 2>/dev/null
    [ "$restored" -gt 0 ] || say "! no backup found - nothing to restore"
    return $rc
}

# A static RRO is read when the framework starts, so the overlay manager has to
# scan the APKs again before a patched value can show up. That happens on boot,
# or when zygote is restarted: init starts a fresh system_server, which re-reads
# /product/overlay and regenerates the cached idmaps.
do_reload() {
    if [ "$(id -u 2>/dev/null)" != "0" ]; then
        say "x reload needs root (uid $(id -u 2>/dev/null))"
        return 1
    fi
    say "reload=zygote (the screen goes black for about 20 s)"
    if setprop ctl.restart zygote 2>/dev/null; then
        return 0
    fi
    for pid in $(pidof zygote64 zygote 2>/dev/null); do
        kill -9 "$pid" 2>/dev/null && { say "reload=kill $pid"; return 0; }
    done
    say "x could not restart the framework - reboot to load the overlays"
    return 1
}

do_reset() {
    if [ "$(id -u 2>/dev/null)" != "0" ]; then
        say "x reset needs root (uid $(id -u 2>/dev/null))"
        return 1
    fi

    had_conf=false
    [ -f "$CONF" ] && had_conf=true

    # Any *.webui-orig means the page patched an APK, so there are values to
    # undo even when the boolean overlay was never registered.
    patched=$(ls "$(overlay_dir)"/*.webui-orig 2>/dev/null | grep -c .)
    [ -n "$patched" ] || patched=0

    active=$("$CMD" overlay list --user 0 2>/dev/null | grep -c "^\[x\].*$PREFIX")
    [ -n "$active" ] || active=0

    if [ "$active" -eq 0 ] && ! $had_conf && [ "$patched" -eq 0 ]; then
        say "No saved overrides - nothing to reset."
        return 0
    fi

    rc=0
    if [ "$patched" -gt 0 ]; then
        do_restore || rc=1
    fi

    if [ "$active" -gt 0 ] && "$CMD" overlay list >/dev/null 2>&1; then
        "$CMD" overlay disable --user 0 \
            "$(overlay_id bool/config_displayBlanksAfterDoze)" >/dev/null 2>&1
    fi

    rm -f "$CONF"
    say "Reset - saved values removed."
    # Only a restored APK needs the framework to scan again: an overlay that is
    # enabled or disabled takes effect in the running system immediately.
    if [ "$patched" -gt 0 ]; then
        say "! The framework still has the patched values: 'sh apply.sh reload'"
        say "  (or a reboot) loads the build-time ones again."
        # Machine-readable marker: the page restarts the framework for this.
        say "reload=needed"
    fi
    return $rc
}

do_diag() {
    say "uid=$(id -u 2>/dev/null)"
    say "su=$(command -v su 2>/dev/null || echo none)"
    say "write=$([ -w "$MODDIR" ] && echo yes || echo no)"
    say "release=$(getprop ro.build.version.release 2>/dev/null)"
    say "sdk=$(getprop ro.build.version.sdk 2>/dev/null)"
    say "module=$MODDIR"
    say "webroot=$([ -f "$MODDIR/webroot/index.html" ] && echo yes || echo no)"
    say "apply=$([ -f "$MODDIR/webroot/apply.sh" ] && echo yes || echo no)"
    say "defaults=$([ -f "$DEFAULTS" ] && echo yes || echo no)"
    say "conf=$([ -f "$CONF" ] && echo yes || echo no)"
    say "cmd=$("$CMD" overlay list >/dev/null 2>&1 && echo ok || echo unavailable)"
    say "boot_log=$([ -f "$MODDIR/webui-boot.log" ] && echo yes || echo no)"
    say "--- overlay APKs (patched by the page) ---"
    for apk in "$(overlay_dir)"/*.apk; do
        [ -f "$apk" ] || continue
        if [ -f "$apk.webui-orig" ]; then
            say "patched: ${apk##*/} ($(wc -c < "$apk" | tr -d ' ') bytes, backup kept)"
        else
            say "build:   ${apk##*/} ($(wc -c < "$apk" | tr -d ' ') bytes)"
        fi
    done
    say "--- saved values ---"
    do_get
    say "static_overlays=$("$CMD" overlay list --user 0 2>/dev/null | grep -c '^\[x\] me\.phh\.treble\.overlay\.')"
    say "--- overlay list (mine) ---"
    "$CMD" overlay list --user 0 2>&1 | grep -E "$PREFIX|Error" || say "(none registered)"
    say "--- live values ---"
    if verify_all; then
        say "ok: every saved value is live"
    else
        say "verify failed (see the lines above)"
    fi
    say "--- overlay manager log (last 20) ---"
    logs=$(logcat -d -s OverlayManager 2>/dev/null | tail -n 20)
    if [ -n "$logs" ]; then
        printf '%s\n' "$logs"
    else
        say "(no OverlayManager log lines)"
    fi
    if [ -f "$MODDIR/webui-boot.log" ]; then
        say "--- boot apply (last run) ---"
        tail -n 12 "$MODDIR/webui-boot.log"
    fi
}

main() {
    action="${1:-get}"
    [ $# -gt 0 ] && shift

    case "$action" in
        get)
            do_get
            ;;
        set)
            result=0
            for pair in "$@"; do
                key=${pair%%=*}
                val=${pair#*=}
                case " $KEYS " in
                    *" $key "*) put_conf "$key" "$val" || result=1 ;;
                    *) say "! unknown key: $key"; result=2 ;;
                esac
            done
            ;;
        apply)
            boot=false
            for a in "$@"; do
                case "$a" in
                    --boot) boot=true ;;
                esac
            done

            if $boot; then
                # init/OMS/package scanning are not ready immediately at boot.
                n=0
                while [ "$n" -lt 15 ]; do
                    "$CMD" overlay list >/dev/null 2>&1 && break
                    n=$((n + 1))
                    sleep 2
                done
                # Right after boot_completed the overlay manager can still be
                # finishing its first scan, and a fabricate call then fails.
                sleep 3
            fi

            # One attempt is enough: the boolean is the only thing registered
            # here, and a failure prints its own reason.
            result=1
            attempt=0
            while :; do
                do_apply
                result=$?
                [ "$result" -eq 0 ] && break
                [ "$result" -eq 2 ] && break
                attempt=$((attempt + 1))
                # At boot the overlay manager may still be settling.
                [ "$attempt" -ge 3 ] && break
                [ "$boot" = "true" ] || break
                sleep 5
            done
            ;;
        apks)
            do_apks
            ;;
        backup)
            do_backup
            result=$?
            ;;
        restore)
            do_restore
            result=$?
            ;;
        reload)
            do_reload
            result=$?
            ;;
        verify)
            verify_all
            result=$?
            ;;
        restart)
            do_restart_systemui
            result=$?
            ;;
        status)
            do_status
            ;;
        diag)
            do_diag
            ;;
        reset)
            do_reset
            ;;
        *)
            say "usage: sh apply.sh get|set|apply [--boot]|apks|backup|restore|reload|verify|restart|status|diag|reset"
            return 2
            ;;
    esac
    exit ${result:-0}
}

main "$@"
