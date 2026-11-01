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

# Which source the probes read: 0 = a phone on the end of adb, 1 = this phone.
DEVICE_LOCAL=0
DEVICE_SERIAL=""
# How a command is run as root in local mode: "root" when the script already is
# root, otherwise the binary that escalates (su, tsu, sudo).
DEVICE_ROOT_CMD=""

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

# Text folded at INDENT, using the shared wrapper when the caller has ui.sh and
# a plain indented line when it does not (this file is sourced by probes that
# print JSON and never draw a box).
adb_device_wrap() { # TEXT INDENT
    if command -v ui_wrap >/dev/null 2>&1; then
        ui_wrap "$1" "$2"
    else
        printf '%*s%s\n' "${2:-0}" '' "$1"
    fi
}

# One line per device on stdin, already in `devices -l` form.
#
# Numbered, because the prompt right after the list accepts a number. The model
# sits beside the serial when the window is wide enough for it and moves to its
# own indented line on a phone, rather than being cut or pushing the row wide.
adb_device_table() {
    local -a serials=() states=() labels=()
    local line serial state label cols n=0 sw=0 stw=0 numw=2
    cols="${COLUMNS:-80}"
    if command -v ui_cols >/dev/null 2>&1; then cols="$(ui_cols)"; fi
    case "$cols" in ''|*[!0-9]*) cols=80 ;; esac
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        n=$((n + 1))
        serial="${line%% *}"
        state="$(printf '%s\n' "$line" | awk '{print $2}')"
        label="$(adb_device_label "$line")"
        serials+=("$serial"); states+=("$state"); labels+=("$label")
        [ "${#serial}" -gt "$sw" ] && sw=${#serial}
        [ "${#state}" -gt "$stw" ] && stw=${#state}
    done
    [ "${#serials[@]}" -gt 0 ] || return 0
    [ "${#serials[@]}" -lt 10 ] || numw=3
    # One line each when the widest row fits, otherwise the label drops to its
    # own wrapped line, and when even `number serial state` is too wide the
    # serial goes below the number. Padded to the widest value, not to a guess.
    local i head
    for i in "${!serials[@]}"; do
        head=$(( 2 + numw + 2 + sw + 2 + stw ))
        if [ -n "${labels[$i]}" ] && [ $(( head + 2 + ${#labels[$i]} )) -le "$cols" ]; then
            printf '  %*d  %-*s  %-*s  %s\n' "$numw" "$((i + 1))" \
                "$sw" "${serials[$i]}" "$stw" "${states[$i]}" "${labels[$i]}"
        elif [ "$head" -le "$cols" ]; then
            printf '  %*d  %-*s  %s\n' "$numw" "$((i + 1))" \
                "$sw" "${serials[$i]}" "${states[$i]}"
            [ -n "${labels[$i]}" ] && adb_device_wrap "${labels[$i]}" 6
        else
            printf '  %*d  %s\n' "$numw" "$((i + 1))" "${serials[$i]}"
            adb_device_wrap "${states[$i]}" 6
            [ -n "${labels[$i]}" ] && adb_device_wrap "${labels[$i]}" 6
        fi
    done
}

# The fix for every device that is attached but not ready. Printed after the
# table so the last thing on screen is the action, not the list.
adb_device_advice() {
    local serial message
    printf '%s\n' "${1:-}" | awk '
        $2 == "unauthorized" { print $1 "|unlock the phone and accept the USB debugging prompt" }
        $2 == "offline"      { print $1 "|offline — unplug and replug it, or run adb kill-server" }
        $2 == "no"           { print $1 "|no permissions — Linux needs a udev rule, Windows a driver" }
        $2 == "connecting"   { print $1 "|still connecting — wait a moment and run it again" }
        $2 == "bootloader"   { print $1 "|in the bootloader — boot Android to read the running ROM" }
        $2 == "recovery"     { print $1 "|in recovery — adb works there, but dumpsys and getprop of the ROM do not" }
        $2 == "sideload"     { print $1 "|sideload mode — reboot to Android first" }
        $2 == "rescue"       { print $1 "|rescue mode — reboot to Android first" }
    ' | while IFS='|' read -r serial message; do
        [ -n "$serial" ] || continue
        printf '  %s%s%s\n' "${UI_BOLD:-}" "$serial" "${UI_OFF:-}"
        adb_device_wrap "$message" 4
    done
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

# ---------------------------------------------------------------------------
# This phone, read directly (Termux)
# ---------------------------------------------------------------------------
# In Termux there is no adb server to dial: the phone is the machine the script
# is running on. "Plug the phone in" is advice nobody can follow there, and
# installing platform-tools only adds a binary that still has nothing to talk to.
#
# With root, the same commands the probes send over `adb shell` run natively —
# getprop, cmd overlay, wm size/density, dumpsys and reads of /vendor — so local
# mode is not a smaller detector, it is the same one with a shorter cable. Root
# is not optional: an app UID is refused `cmd`, `dumpsys` and most /vendor files.
#
# DEVICE_LOCAL=1 selects it, DEVICE_ROOT_CMD says how to escalate, and the
# probe's `serial` becomes "local" so nothing tries `adb -s local`.

device_is_termux() {
    [ -n "${TERMUX_VERSION:-}" ] && return 0
    case "${PREFIX:-}" in */com.termux/*) return 0 ;; esac
    case "${HOME:-}" in /data/data/com.termux/*) return 0 ;; esac
    return 1
}

# The binary that reaches root on this phone, or "root" when we are already it.
# su, tsu (Termux's su wrapper) and sudo all take `-c CMD`.
device_root_cmd() {
    if [ "$(id -u 2>/dev/null)" = 0 ]; then printf 'root'; return 0; fi
    local c
    for c in su tsu sudo; do
        command -v "$c" >/dev/null 2>&1 && { printf '%s' "$c"; return 0; }
    done
    return 1
}

# One command string as root on this phone, the same shape `adb shell` takes, so
# the probes never learn which source they have.
device_local_run() {
    case "${DEVICE_ROOT_CMD:-root}" in
        root) sh -c "$1" ;;
        su)   su -c "$1" ;;
        tsu)  tsu -c "$1" ;;
        sudo) sudo sh -c "$1" ;;
        *)    sh -c "$1" ;;
    esac
}

# Switch the probes over to this phone. PROG names the script in messages.
# Verifies root before claiming local mode, so a denied prompt is a clear line
# rather than a probe that silently reports nothing.
device_local_begin() {
    local prog="$1" cmd
    if [ "$(id -u 2>/dev/null)" = 0 ]; then
        DEVICE_ROOT_CMD=root
    else
        cmd="$(device_root_cmd)" || {
            printf '%s: reading this phone needs root, and no su/tsu/sudo was found.\n' "$prog" >&2
            printf '  pkg install tsu\n  then start the tool with: tsu ./build.sh\n' >&2
            return 1
        }
        DEVICE_ROOT_CMD="$cmd"
        if [ "$(device_local_run 'id -u' </dev/null 2>/dev/null | tr -d '\r' | tail -n1)" != 0 ]; then
            printf '%s: root was not granted — accept the su prompt (or run the tool with tsu) and try again.\n' "$prog" >&2
            DEVICE_ROOT_CMD=""
            return 1
        fi
    fi
    DEVICE_LOCAL=1
    DEVICE_SERIAL=local
    # The menu announces this once before the probe starts; saying it again on
    # every run reads like a second, failed attempt. DEVICE_LOCAL_QUIET=1 is set
    # when the answer was already given.
    if [ "${DEVICE_LOCAL_QUIET:-0}" != 1 ]; then
        printf '%s: reading this phone directly%s\n' "$prog" \
            "$([ "$DEVICE_ROOT_CMD" = root ] && printf ' (already root)' || printf ' (via %s)' "$DEVICE_ROOT_CMD")" >&2
    fi
    return 0
}

# Offer the local source. Only in Termux, and only when nobody already answered
# the question (DEVICE_LOCAL_REQUEST=1 asked and granted, 0 declined) — the menu
# asks once per session and passes the answer down.
device_local_offer() {
    local prog="$1" answer
    device_is_termux || return 1
    if [ -t 0 ] && [ -t 2 ]; then
        printf '%s: Termux has no adb link to a phone underneath — this machine is the phone.\n' "$prog" >&2
        printf '%s: read it directly as root? [Y/n] ' "$prog" >&2
        IFS= read -r answer || answer=y
        case "$answer" in [nN]*) return 1 ;; esac
    fi
    device_local_begin "$prog"
}

# Whether adb can see a ready device right now, without the 120s wait: that wait
# is for a cable being plugged in, and in Termux there is nothing to plug in.
adb_device_ready_now() {
    local adb="$1" want="${2:-}"
    adb_device_list "$adb" 25 || return 1
    if [ -n "$want" ]; then
        printf '%s\n' "$ADB_DEVICES" | awk -v s="$want" '$1 == s && $2 == "device"' | grep -q .
    else
        printf '%s\n' "$ADB_DEVICES" | awk '$2 == "device"' | grep -q .
    fi
}

# Where adb is. A probe's `--adb PATH` (in $adb before this file is sourced)
# wins, then PATH, then the copy the toolchain installs. Defined here rather
# than in each probe so device_connect does not depend on them defining it.
adb="${adb:-}"
resolve_adb() {
    [ -n "$adb" ] && return 0
    adb="$(command -v adb 2>/dev/null || true)"
    [ -n "$adb" ] && return 0
    for adb in "${ROOT:-.}/stuff/tools/platform-tools/adb" "${ROOT:-.}/stuff/tools/platform-tools/adb.exe"; do
        [ -x "$adb" ] && return 0
    done
    adb=""
    return 1
}

# One command on the chosen phone, CRs stripped and errors dropped. The single
# place the two sources meet: both take a command string.
device_sh() {
    if [ "${DEVICE_LOCAL:-0}" = 1 ]; then
        # The local shell is already root, so the probes' `su 0` retries would be
        # a second escalation with nothing to gain — and a second su prompt. The
        # prefix is dropped so those calls stay quiet.
        case "$1" in
            'su 0 '*) set -- "${1#su 0 }" ;;
        esac
        device_local_run "$1" </dev/null 2>/dev/null | tr -d '\r'
    else
        "$adb" ${serial:+-s "$serial"} shell "$1" </dev/null 2>/dev/null | tr -d '\r'
    fi
}

# Copy a file off the chosen phone. adb pull runs as the shell user and falls
# back to `su 0 cat` for root-only paths (/vendor/overlay); local mode is
# already root, so one cat covers both.
#
# The path is quoted for the shell on the other end, not for this one: a name
# holding a single quote would otherwise end the quoting early and cat something
# else (or nothing).
sh_quote() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

device_pull() {
    local remote="$1" local_path="$2" to="$2"
    if [ "${DEVICE_LOCAL:-0}" = 1 ]; then
        device_local_run "cat $(sh_quote "$remote")" >"$local_path" 2>/dev/null
        [ -s "$local_path" ] && return 0
        return 1
    fi
    # A Windows adb cannot open an MSYS /tmp path, so the local half is converted
    # when cygpath exists (Git Bash); elsewhere the path is passed as it is.
    if command -v cygpath >/dev/null 2>&1; then to="$(cygpath -w "$local_path")"; fi
    "$adb" ${serial:+-s "$serial"} pull "$remote" "$to" >/dev/null 2>&1 \
        && [ -s "$local_path" ] && return 0
    "$adb" ${serial:+-s "$serial"} exec-out "su 0 cat $(sh_quote "$remote")" >"$local_path" 2>/dev/null \
        && [ -s "$local_path" ] && return 0
    return 1
}

# device_connect PROG [WANT] — where the answers come from, for every probe.
#
# WANT is the --device value; "local" (also this/self/here) asks for this phone.
# DEVICE_LOCAL_REQUEST=1/0 forces the answer, which is what the menu sets after
# asking once. Sets DEVICE_LOCAL, DEVICE_ROOT_CMD, DEVICE_SERIAL and the probe's
# `serial`; on failure the reason has already been printed.
#
# Precedence, most specific first: a serial or "local" typed on the command
# line, then the session's answer, then what this machine allows (in Termux,
# adb has nothing to talk to, so the local source is offered there instead).
device_connect() {
    local prog="$1" want="${2:-}" mode="${DEVICE_LOCAL_REQUEST:-}"
    case "$want" in
        local|this|self|here)
            device_local_begin "$prog" || return 1
            serial="$DEVICE_SERIAL"
            return 0
            ;;
        '')
            ;;
        *)
            mode=""
            ;;
    esac
    case "$mode" in
        1)
            # The question was answered before this probe started (the menu asks
            # once a session), so do not announce the switch again.
            DEVICE_LOCAL_QUIET=1
            device_local_begin "$prog" || return 1
            serial="$DEVICE_SERIAL"
            return 0
            ;;
    esac
    # Termux, and adb cannot see the phone right now: ask about the direct
    # source before the device wait, because in Termux that wait cannot end.
    if [ -z "$mode" ] && device_is_termux \
        && ! { resolve_adb 2>/dev/null && adb_device_ready_now "$adb" "$want"; }; then
        device_local_offer "$prog" && { serial="$DEVICE_SERIAL"; return 0; }
    fi
    resolve_adb || {
        if device_is_termux; then
            printf '%s: adb cannot reach a phone from Termux — the phone is this machine, and reading it needs root.\n' "$prog" >&2
            printf '  start the tool as root: tsu %s/build.sh   (pkg install tsu if it is missing)\n' "${ROOT:-.}" >&2
        else
            printf '%s: adb was not found — install platform-tools, or pass --adb PATH\n' "$prog" >&2
        fi
        return 1
    }
    adb_pick_device "$adb" "$want" "$prog" || return 1
    serial="$DEVICE_SERIAL"
    return 0
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

# A probe run from the menu is usually started while the phone is still in the
# user's hand. Failing on the spot ("plug the phone in") is the wrong answer
# there: the next thing the user does is plug it in, and then has to run the
# menu again. Wait for a device to appear instead — but only on a terminal, so a
# script still gets an immediate answer.
#
# ADB_WAIT_SECONDS sets the deadline and also allows waiting without a terminal
# (0 never waits); that is the switch the tests use.
#
# On success ADB_DEVICES holds the new listing, ready devices included.
adb_device_wait() {
    local adb="$1" prog="$2" limit waited=0 ready attached now last=""
    if [ -n "${ADB_WAIT_SECONDS:-}" ]; then
        limit="$ADB_WAIT_SECONDS"
    elif [ -t 0 ] && [ -t 2 ]; then
        limit=120
    else
        return 1
    fi
    case "$limit" in ''|*[!0-9]*) return 1 ;; esac
    [ "$limit" -gt 0 ] || return 1

    printf '%s: waiting for a device to become ready — plug the phone in and allow USB debugging\n' "$prog" >&2
    printf '  (up to %ss; Ctrl-C stops this)\n' "$limit" >&2
    while [ "$waited" -lt "$limit" ]; do
        sleep 1
        waited=$((waited + 1))
        # adb is allowed to be unplugged and replugged while this runs: only a
        # listing that could not be produced at all ends the wait early.
        adb_device_list "$adb" || {
            case "${ADB_DEVICES_NOTE:-}" in
                *'was not found'*) return 1 ;;
            esac
            continue
        }
        attached="$ADB_DEVICES"
        ready="$(printf '%s\n' "$attached" | awk '$2 == "device"')"
        if [ -n "$ready" ]; then
            printf '  found %s\n' "$(printf '%s\n' "$ready" | awk '{print $1}' | tr '\n' ' ' | sed 's/ *$//')" >&2
            return 0
        fi
        # Say something when the state changes (unauthorized → device is the
        # prompt being accepted, offline → nothing yet) and otherwise stay quiet
        # apart from a nudge, so a slow wait does not scroll the screen away.
        now="$(printf '%s\n' "$attached" | awk 'NF { print "  " $1 " (" $2 ")" }')"
        if [ "$now" != "$last" ]; then
            [ -z "$now" ] || printf '%s\n' "$now" >&2
            last="$now"
        elif [ $((waited % 15)) -eq 0 ]; then
            printf '  still waiting — %ss of %ss\n' "$waited" "$limit" >&2
        fi
    done
    printf '%s: no device appeared within %ss.\n' "$prog" "$limit" >&2
    return 1
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
                [ -z "${ADB_DEVICES_NOTE:-}" ] || printf '%s: %s\n' "$prog" "$ADB_DEVICES_NOTE" >&2
                printf '%s: %s is not attached — plug the phone in and allow USB debugging.\n' "$prog" "$want" >&2
            fi
            # Waiting is the point here: the phone was named but is not ready
            # yet (just plugged in, or its debugging prompt is still on screen).
            # Both resolve in seconds, so wait rather than fail and be re-run.
            if adb_device_wait "$adb" "$prog"; then
                attached="$ADB_DEVICES"
                ready="$(printf '%s\n' "$attached" | awk '$2 == "device"')"
                ready_count="$(printf '%s\n' "$ready" | grep -c . || true)"
                state="$(printf '%s\n' "$attached" | awk -v s="$want" '$1 == s { print $2; exit }')"
                [ "$state" = "device" ] && serial="$want"
                # The serial that came up may not be the one typed (a phone that
                # was off reports a new one), so a single ready device is taken
                # as the one meant.
                if [ -z "$serial" ] && [ "$ready_count" -eq 1 ]; then
                    serial="$(printf '%s\n' "$ready" | awk '{print $1}' | head -n1)"
                fi
            fi
            if [ -z "$serial" ]; then
                printf '%s: %s did not become ready.\n' "$prog" "$want" >&2
                return 1
            fi
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
        # A phone left unauthorized or offline is fixed in a second; waiting
        # turns that into the same run instead of another menu trip.
        adb_device_wait "$adb" "$prog" || return 1
        attached="$ADB_DEVICES"
        ready="$(printf '%s\n' "$attached" | awk '$2 == "device"')"
        ready_count="$(printf '%s\n' "$ready" | grep -c . || true)"
        if [ "$ready_count" -eq 1 ]; then
            serial="$(printf '%s\n' "$ready" | awk '{print $1}' | head -n1)"
        elif [ "$ready_count" -eq 0 ]; then
            return 1
        elif [ ! -t 0 ]; then
            printf '%s: %d devices are ready:\n' "$prog" "$ready_count" >&2
            printf '%s\n' "$ready" | adb_device_table >&2
            printf '%s: choose one with --device SERIAL\n' "$prog" >&2
            return 1
        elif ! serial="$(adb_device_choose "$ready")"; then
            printf '%s: no device chosen.\n' "$prog" >&2
            return 1
        fi
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
