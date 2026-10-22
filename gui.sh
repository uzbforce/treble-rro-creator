#!/usr/bin/env bash
# =============================================================================
# Launch the desktop app
# =============================================================================
# One command, from anywhere:
#
#   ./gui.sh                  build if needed, then open the window
#   ./gui.sh --rebuild        rebuild first (after a git pull, say)
#   ./gui.sh --release        build without a console window (Windows)
#   ./gui.sh --detach         like --release, and let the console close too
#   ./gui.sh --browser        no native window; use the default browser instead
#   ./gui.sh -clone ~/other   start on a different clone
#
# It only needs Go the first time — a checkout that already has gui/bin/ filled
# in runs without a toolchain, and the app finds its clone by walking up from
# where it lives, so no path has to be typed.
#
# Windows: double-click gui.cmd instead; it finds Git Bash and calls this.
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
app_args=()
for arg in "$@"; do
    case "$arg" in
        --rebuild) rebuild=true ;;
        --release) release=true ;;
        --detach)
            # There is nothing to detach from without a release build: a
            # console build would just get a console window of its own.
            detach=true
            release=true
            ;;
        *) app_args+=("$arg") ;;
    esac
done
build_flags=()
if [ "$release" = "true" ]; then
    build_flags+=("--release")
fi

# Whether a rebuild is possible at all. Without Go the launcher can still start
# the binary that is already there, but it cannot make it any newer — and the UI
# is embedded in that binary, so "no toolchain" means "the old page".
have_go=false
command -v go >/dev/null 2>&1 && have_go=true

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
    # other way round): the mode is linked in, so that needs a rebuild. Without
    # Go there is nothing to relink with, and starting the existing binary is
    # still better than refusing to open it.
    [ "$have_go" = "true" ] || return 1
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
    if [ "$have_go" != "true" ]; then
        if [ -f "$exe" ]; then
            echo "go was not found — starting the app that is already built." >&2
            if sources_newer; then
                echo "  That binary is older than gui/, so the window shows the OLD page:" >&2
                echo "  the UI is embedded in it, not read from disk." >&2
                echo "  Install Go and a C compiler, then run: ./gui.sh --rebuild" >&2
            fi
        else
            echo "The app is not built yet and go was not found on PATH." >&2
            echo "  Install Go from https://go.dev/dl/ and run this again." >&2
            exit 1
        fi
    else
        echo "building the app…"
        bash "$here/gui/build.sh" ${build_flags[@]+"${build_flags[@]}"}
    fi
fi

if [ "$detach" = "true" ]; then
    case "$(uname -s)" in
        MINGW*|MSYS*|CYGWIN*)
            # `start` hands the program to the shell, so cmd.exe stops waiting
            # here and this console closes while the app keeps running. Only a
            # window-only build can be passed on this way: a console build
            # launched like this would open a console window of its own, so
            # when that is all there is (no go to rebuild with) it still runs
            # in this one, and says why.
            if [ "$(pe_subsystem "$exe")" = "2" ] && command -v cygpath >/dev/null 2>&1; then
                cmd.exe //c start "" "$(cygpath -w "$exe")" ${app_args[@]+"${app_args[@]}"}
                exit 0
            fi
            echo "note: this is a console build, so the console stays while the window is open." >&2
            echo "      install go and run ./gui.sh --detach once to get the console-free build." >&2
            ;;
    esac
fi

exec "$exe" ${app_args[@]+"${app_args[@]}"}
