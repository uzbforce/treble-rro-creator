#!/usr/bin/env bash
# =============================================================================
# Treble RRO Creator — desktop app
# =============================================================================
# One command, from anywhere:
#
#   ./treble-rro-creator.sh                  build if needed, then open the window
#   ./treble-rro-creator.sh --rebuild        rebuild first (after a git pull, say)
#   ./treble-rro-creator.sh --release        no console window (Windows; the default)
#   ./treble-rro-creator.sh --detach         accepted for scripts; hand-off is automatic
#   ./treble-rro-creator.sh --browser        no window; use the default browser
#   ./treble-rro-creator.sh -clone ~/other   start on a different clone
#
# The first launch builds the app, downloading Go into stuff/tools/_go/ when the
# machine has none; a checkout that already has gui/bin/ filled in runs without
# a toolchain at all, and the app finds its clone by walking up from where it
# lives, so no path has to be typed.
#
# Windows: double-click treble-rro-creator.cmd; it finds Git Bash and calls this.
# =============================================================================
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exe="$here/gui/bin/treble-rro-creator-gui"
case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) exe="$exe.exe" ;;
esac

rebuild=false
release=false
detach=false
browser=false
app_args=()
for arg in "$@"; do
    case "$arg" in
        -h|--help)
            # The launcher's own flags, which the app knows nothing about: the
            # block between the second and third rule in the header above.
            printf '%s\n\n' "Treble RRO Creator — desktop app"
            awk '/^# =====/ { n++; next } n == 2 { sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"
            exit 0
            ;;
        --rebuild) rebuild=true ;;
        --release) release=true ;;
        # Accepted for the launchers and for people used to typing it: on
        # Windows the hand-off happens anyway.
        --detach) detach=true ;;
        --browser|-browser) browser=true ; app_args+=("$arg") ;;
        *) app_args+=("$arg") ;;
    esac
done

# On Windows the app is always the window-only build. The window is the whole
# UI, so a binary linked against a console only drags one along behind it —
# and dies when that console is closed. --browser is the exception: that run
# keeps its console, because that is where the server is watched and stopped.
case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)
        if [ "$browser" = "false" ]; then
            release=true
        fi
        ;;
esac
build_flags=()
if [ "$release" = "true" ]; then
    build_flags+=("--release")
fi

# Whether Windows gives a program a console window is decided by one field in
# the executable itself: the PE subsystem, 3 for a console build (the default)
# and 2 for one linked with -H windowsgui. Reading it means the launcher knows
# what the binary on disk really is — including one unpacked from a release
# archive — instead of trusting a side file that can go stale.
pe_subsystem() {
    local off
    off=$(od -An -tu4 -j60 -N4 "$1" 2>/dev/null | tr -d ' \r')
    if [ -z "$off" ]; then
        return 2
    fi
    # 0x5c into the PE header
    od -An -tu2 -j$((off + 92)) -N2 "$1" 2>/dev/null | tr -d ' \r'
}

# Is the binary older than anything that goes into it? The UI is embedded, so a
# changed app.js or app.css means the window would still show the old page.
sources_newer() {
    [ -f "$exe" ] || return 0
    [ -n "$(find "$here/gui" -name '*.go' -newer "$exe" -print -quit 2>/dev/null)" ] && return 0
    [ -n "$(find "$here/gui/ui" -type f -newer "$exe" -print -quit 2>/dev/null)" ] && return 0
    [ -n "$(find "$here/go.mod" "$here/go.sum" -newer "$exe" -print -quit 2>/dev/null)" ] && return 0
    return 1
}

# Rebuild when the binary is missing or older than the Go sources and the UI.
# --rebuild wins regardless, which is the dependable option after a pull that
# only touched go.sum.
stale() {
    sources_newer && return 0
    # Asked for a window-only build but the exe on disk has a console (or the
    # other way round): the mode is linked in, so that needs a rebuild.
    case "$(uname -s)" in
        MINGW*|MSYS*|CYGWIN*)
            local want=3
            if [ "$release" = "true" ]; then
                want=2
            fi
            if [ "$(pe_subsystem "$exe")" != "$want" ]; then
                return 0
            fi
            ;;
    esac
    return 1
}

if [ "$rebuild" = "true" ] || stale; then
    echo "building the app…"
    if ! bash "$here/gui/build.sh" ${build_flags[@]+"${build_flags[@]}"}; then
        if [ -f "$exe" ]; then
            # The build is what would make the window new; failing it is no
            # reason to refuse to open the one that is already there.
            echo "the build failed — starting the app that is already built." >&2
            if sources_newer; then
                echo "  That binary is older than gui/, so the window shows the OLD page:" >&2
                echo "  the UI is embedded in it, not read from disk." >&2
                echo "  Fix what the build reported, then: ./treble-rro-creator.sh --rebuild" >&2
            fi
        else
            exit 1
        fi
    fi
fi

# Windows: hand the window to the background and return, however the launcher
# was started — double-clicked, or typed into a cmd window. The window owns no
# console of its own, so it outlives the cmd.exe that started it, and that
# cmd.exe finishing is what closes the console instead of leaving one sitting
# behind the app. Its output goes nowhere: with the console gone there is
# nothing to read it on, and keeping the handles is what would hold the console
# open. Failures land in gui.log next to the executable.
#
# A console build is the one thing left in the console, and only when there is
# no go to relink with: it would take the console down with it, so it says why.
if [ "$browser" = "false" ]; then
    case "$(uname -s)" in
        MINGW*|MSYS*|CYGWIN*)
            if [ "$(pe_subsystem "$exe")" = "2" ]; then
                "$exe" ${app_args[@]+"${app_args[@]}"} >/dev/null 2>&1 &
                exit 0
            fi
            echo "note: this is a console build, so the console stays while the window is open." >&2
            echo "      the relink needs a C compiler; run ./treble-rro-creator.sh --rebuild once it is installed." >&2
            ;;
    esac
fi

exec "$exe" ${app_args[@]+"${app_args[@]}"}
