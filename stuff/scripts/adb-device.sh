#!/usr/bin/env bash
# =============================================================================
# adb-device.sh — which connected phone a probe talks to
# =============================================================================
# Sourced by device-probe.sh and udfps-probe.sh. Both used to carry the same
# rule ("exactly one device, or stop"), which stops being useful the moment a
# second phone is on the desk.
#
#   adb_pick_device ADB SERIAL PROGRAM
#
# ADB is the adb binary to run, SERIAL is what --device said ("" for automatic),
# PROGRAM names the script in the messages. On success DEVICE_SERIAL holds the
# serial to pass to `adb -s`; on failure the reason has already been printed.
#
# The state matters. adb can see a phone it cannot talk to (unauthorized,
# offline, no permissions), and each of those has its own fix — telling the user
# to plug the phone in is wrong advice for all three.
#
# Detection is the fragile part, so it is hardened against what adb actually
# does rather than what its manual says:
#
#   * `adb devices` is a stream, not a table. A daemon start, a version
#     mismatch, or a "no permissions" line shares it with the devices, so only
#     lines whose second column is a real state are read as devices.
#   * the listing can lie. It is a snapshot, so the chosen serial is confirmed
#     with `get-state` before anything is run against it.
#   * a wedged server hangs instead of failing. Every adb call here is bounded,
#     and a timeout says "adb kill-server" instead of hanging the probe.
#   * the first call after the server restarts can come back with no header at
#     all. That is retried; a genuinely empty list is not.
#   * a phone that is still "connecting" (wireless adb, or just plugged in)
#     becomes ready in a second or two, so it is waited for briefly.
#   * a serial can be listed twice, and wireless transports look like
#     `192.168.1.5:5555`; duplicates are dropped and the transport is labelled.
# =============================================================================

# The states adb puts in the second column of `devices`, space-padded so a
# value can be tested with `index(states, " " $2 " ")`.
ADB_DEVICE_STATES=" device offline unauthorized bootloader recovery sideload rescue host connecting no "

# The model and product from one `adb devices -l` line, for a menu a human can
# read. Both are optional in adb's output, so this never assumes either. A
# TCP/mDNS serial is called out: with USB and wireless adb on, the same phone
# can be listed twice and the two entries are otherwise identical.
adb_device_label() {
    local line="$1" model product serial suffix=""
    model="$(printf '%s\n' "$line" | sed -n 's/.* model:\([^ ]*\).*/\1/p')"
    product="$(printf '%s\n' "$line" | sed -n 's/.* product:\([^ ]*\).*/\1/p')"
    [ -n "$model" ] || model="$(printf '%s\n' "$line" | sed -n 's/.* device:\([^ ]*\).*/\1/p')"
    serial="$(printf '%s\n' "$line" | awk '{print $1}')"
    case "$serial" in
        *:*) suffix=" [wireless]" ;;
    esac
    if [ -n "$model" ] && [ -n "$product" ]; then
        printf '%s (%s)%s' "$model" "$product" "$suffix"
    elif [ -n "$model" ]; then
        printf '%s%s' "$model" "$suffix"
    else
        printf 'no model reported%s' "$suffix"
    fi
}

# One line per device on stdin, already in `devices -l` form.
adb_device_table() {
    local line serial state
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        serial="${line%% *}"
        state="$(printf '%s\n' "$line" | awk '{print $2}')"
        printf '  %-18s %-13s %s\n' "$serial" "$state" "$(adb_device_label "$line")"
    done
}

# The fix for every device that is attached but not ready. Printed after the
# table so the last thing on screen is the action, not the list.
adb_device_advice() {
    printf '%s\n' "${1:-}" | awk '
        $2 == "unauthorized" { print "  " $1 ": unlock the phone and accept the USB debugging prompt" }
        $2 == "offline"      { print "  " $1 ": offline — unplug and replug it, or run adb kill-server" }
        $2 == "no"           { print "  " $1 ": no permissions — Linux needs a udev rule, Windows a driver" }
        $2 == "connecting"   { print "  " $1 ": still connecting — wait a moment and run it again" }
        $2 == "bootloader"   { print "  " $1 ": in the bootloader — boot Android to read the running ROM" }
        $2 == "recovery"     { print "  " $1 ": in recovery — adb works there, but dumpsys and getprop of the ROM do not" }
        $2 == "sideload"     { print "  " $1 ": sideload mode — reboot to Android first" }
        $2 == "rescue"       { print "  " $1 ": rescue mode — reboot to Android first" }
    '
}

# Turn what the user typed into a serial from READY (the `devices -l` lines of
# ready devices): a menu number, a full serial, or a prefix that only one serial
# starts with. Prints nothing and fails when the answer is not unambiguous.
adb_device_resolve() {
    local ready="$1" choice="${2:-}" count n matches
    [ -n "$choice" ] || return 1
    count="$(printf '%s\n' "$ready" | grep -c . || true)"
    case "$choice" in
        *[!0-9]*) ;;
        *)
            n=$((choice + 0))
            if [ "$n" -ge 1 ] && [ "$n" -le "$count" ]; then
                printf '%s\n' "$ready" | sed -n "${n}p" | awk '{print $1}'
                return 0
            fi
            ;;
    esac
    matches="$(printf '%s\n' "$ready" | awk -v c="$choice" 'index($1, c) == 1 { print $1 }')"
    if [ "$(printf '%s\n' "$matches" | grep -c . || true)" -eq 1 ]; then
        printf '%s' "$matches"
        return 0
    fi
    return 1
}

# Prompt on stderr instead of stdout: stdout is often JSON that a caller parses.
# Reads stdin, so it can be exercised with a pipe in tests.
adb_device_choose() {
    local ready="$1" count choice resolved tries=0
    count="$(printf '%s\n' "$ready" | grep -c . || true)"
    printf 'More than one device is connected:\n' >&2
    printf '%s\n' "$ready" | adb_device_table >&2
    while [ "$tries" -lt 3 ]; do
        tries=$((tries + 1))
        printf 'Which device? [1-%d] or a serial: ' "$count" >&2
        IFS= read -r choice || return 1
        if resolved="$(adb_device_resolve "$ready" "$choice")"; then
            printf '%s' "$resolved"
            return 0
        fi
        printf '  not one of them\n' >&2
    done
    return 1
}

# Run a command with a deadline, because adb has no timeout of its own and a
# wedged server otherwise hangs the probe with nothing on screen. LIMIT is in
# tenths of a second. The child writes a sentinel when it finishes, so a finished
# process is never mistaken for a running one. 124 means "did not answer".
adb_device_exec() {
    local limit="$1" out="$2" pid waited=0 status=0
    shift 2
    rm -f "$out.done" "$out.status"
    ( "$@" >"$out" 2>"$out.err"; printf '%s' "$?" >"$out.status"; : >"$out.done" ) &
    pid=$!
    while [ ! -f "$out.done" ]; do
        if [ "$waited" -ge "$limit" ]; then
            # The adb client only: the server is a separate process and killing
            # it is the user's decision (adb kill-server).
            kill "$pid" 2>/dev/null
            sleep 0.2
            kill -9 "$pid" 2>/dev/null
            wait "$pid" 2>/dev/null
            return 124
        fi
        sleep 0.1
        waited=$((waited + 1))
    done
    wait "$pid" 2>/dev/null
    status="$(cat "$out.status" 2>/dev/null || printf 0)"
    return "${status:-0}"
}

# The attached devices, one `devices -l` line each, in no particular order.
# Sets ADB_DEVICES to those lines and ADB_DEVICES_NOTE to whatever adb said
# about itself, so a wedged server or a "no permissions" complaint can be shown
# instead of a bare "nothing found". Returns non-zero only when adb could not
# produce a list at all.
#
# The results are assigned to variables rather than printed because the caller
# usually wants them in `$( )`, and a subshell would throw the note away.
adb_device_list() {
    local adb="$1" limit="${2:-200}" dir status attempt=0 header=0
    ADB_DEVICES=""
    ADB_DEVICES_NOTE=""
    if [ ! -x "$adb" ] && ! command -v "$adb" >/dev/null 2>&1; then
        ADB_DEVICES_NOTE="adb was not found at $adb — install platform-tools, or point ADB at it"
        return 127
    fi
    dir="$(mktemp -d 2>/dev/null || printf '%s' "${TMPDIR:-/tmp}/adb-device.$$")"
    mkdir -p "$dir" 2>/dev/null

    # The first call after the server restarts can return no header at all (a
    # version mismatch kills the daemon mid-command). That is worth retrying; an
    # empty list under a real header is not, because the answer is the same.
    while :; do
        attempt=$((attempt + 1))
        adb_device_exec "$limit" "$dir/devices" "$adb" devices -l
        status=$?
        if [ "$status" -eq 124 ]; then
            ADB_DEVICES_NOTE="adb did not answer within $((limit / 10))s — run adb kill-server, then try again"
            rm -rf "$dir"
            return 1
        fi
        if grep -q 'List of devices attached' "$dir/devices" 2>/dev/null; then header=1; break; fi
        if [ "$attempt" -ge 3 ]; then break; fi
        sleep 0.7
    done

    ADB_DEVICES_NOTE="$(
        sed 's/\r$//' "$dir/devices.err" 2>/dev/null |
            sed '/^[[:space:]]*$/d' |
            tr '\n' ' ' |
            sed 's/[[:space:]]*$//'
    )"
    if [ "$header" -eq 0 ]; then
        [ -n "$ADB_DEVICES_NOTE" ] || ADB_DEVICES_NOTE="adb devices exited $status without a device list"
        rm -rf "$dir"
        return 1
    fi

    # Only real device lines, one per serial: the same stream carries daemon
    # chatter and version warnings, and a table with those in it is worse than
    # no table at all.
    ADB_DEVICES="$(awk -v states="$ADB_DEVICE_STATES" '
        { sub(/\r$/, "") }
        NF >= 2 && index(states, " " $2 " ") { if (!seen[$1]++) print }
    ' "$dir/devices")"
    rm -rf "$dir"
    return 0
}

# The list is a snapshot: a phone can be listed as ready and still not open. Ask
# adb to open it, bounded like everything else.
adb_device_alive() {
    local adb="$1" serial="$2" dir status
    dir="$(mktemp -d 2>/dev/null || printf '%s' "${TMPDIR:-/tmp}/adb-device.$$")"
    mkdir -p "$dir" 2>/dev/null
    adb_device_exec 100 "$dir/state" "$adb" -s "$serial" get-state
    status=$?
    rm -rf "$dir"
    return "$status"
}

adb_pick_device() {
    local adb="$1" want="$2" prog="$3"
    local attached ready ready_count state serial sleeping waited=0

    adb_device_list "$adb" || {
        printf '%s: %s\n' "$prog" "${ADB_DEVICES_NOTE:-adb did not answer}" >&2
        return 1
    }
    attached="$ADB_DEVICES"

    # Wireless adb and a phone that was just plugged in show "connecting" for a
    # moment. Waiting a couple of seconds turns that into the phone the user
    # means, instead of "nothing is ready" and a retry they have to time.
    while [ -n "$(printf '%s\n' "$attached" | awk '$2 == "connecting"')" ] && [ "$waited" -lt 25 ]; do
        sleep 0.2
        waited=$((waited + 1))
        adb_device_list "$adb" || break
        attached="$ADB_DEVICES"
    done

    ready="$(printf '%s\n' "$attached" | awk '$2 == "device"')"
    ready_count="$(printf '%s\n' "$ready" | grep -c . || true)"

    serial=""
    if [ -n "$want" ]; then
        # An explicit serial is used as typed, but it still has to be attached:
        # otherwise adb's own "device not found" is the only explanation the
        # user gets, with no hint about what is actually plugged in.
        state="$(printf '%s\n' "$attached" | awk -v s="$want" '$1 == s { print $2; exit }')"
        case "$state" in
            device) serial="$want" ;;
            '')
                printf '%s: %s is not attached.\n' "$prog" "$want" >&2
                ;;
            *)
                printf '%s: %s is attached but %s.\n' "$prog" "$want" "$state" >&2
                ;;
        esac
        if [ -z "$serial" ]; then
            if [ -n "$attached" ]; then
                printf 'Attached devices:\n' >&2
                printf '%s\n' "$attached" | adb_device_table >&2
                adb_device_advice "$attached" >&2
            else
                printf 'No device is attached — plug one in and allow USB debugging.\n' >&2
                [ -z "${ADB_DEVICES_NOTE:-}" ] || printf '  %s\n' "$ADB_DEVICES_NOTE" >&2
            fi
            return 1
        fi
    elif [ "$ready_count" -eq 0 ]; then
        [ -z "${ADB_DEVICES_NOTE:-}" ] || printf '%s: %s\n' "$prog" "$ADB_DEVICES_NOTE" >&2
        if [ -n "$attached" ]; then
            printf '%s: no device is ready to talk to:\n' "$prog" >&2
            printf '%s\n' "$attached" | adb_device_table >&2
        else
            printf '%s: no device in adb devices — plug the phone in and allow USB debugging.\n' "$prog" >&2
        fi
        adb_device_advice "$attached" >&2
        return 1
    elif [ "$ready_count" -eq 1 ]; then
        serial="$(printf '%s\n' "$ready" | awk '{print $1}' | head -n1)"
        sleeping="$(printf '%s\n' "$attached" | awk '$2 != "device" { print $1 " (" $2 ")" }' | tr '\n' ' ')"
        [ -z "$sleeping" ] || printf '%s: using %s; not ready: %s\n' "$prog" "$serial" "${sleeping% }" >&2
    else
        # Several phones. Ask when there is a terminal to ask on; never guess,
        # because picking the wrong one is how the wrong phone gets written to.
        if [ ! -t 0 ]; then
            printf '%s: %d devices are ready:\n' "$prog" "$ready_count" >&2
            printf '%s\n' "$ready" | adb_device_table >&2
            printf '%s: choose one with --device SERIAL\n' "$prog" >&2
            return 1
        fi
        if ! serial="$(adb_device_choose "$ready")"; then
            printf '%s: no device chosen.\n' "$prog" >&2
            return 1
        fi
    fi

    # The list is a snapshot; this is the check that adb can actually open it.
    adb_device_alive "$adb" "$serial"
    case $? in
        0) ;;
        124)
            printf '%s: %s is listed as ready but adb did not answer within 10s — run adb kill-server.\n' "$prog" "$serial" >&2
            return 1
            ;;
        *)
            printf '%s: %s is listed as ready but did not answer get-state — replug it.\n' "$prog" "$serial" >&2
            return 1
            ;;
    esac
    DEVICE_SERIAL="$serial"
    return 0
}
