#!/usr/bin/env bash
# =============================================================================
# Launch the desktop app
# =============================================================================
# One command, from anywhere:
#
#   ./gui.sh                  build if needed, then open the window
#   ./gui.sh --rebuild        rebuild first (after a git pull, say)
#   ./gui.sh --release        build without a console window (Windows)
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
build_flags=()
app_args=()
for arg in "$@"; do
    case "$arg" in
        --rebuild) rebuild=true ;;
        --release) build_flags+=("--release") ;;
        *) app_args+=("$arg") ;;
    esac
done

# Rebuild when the binary is missing or older than the Go sources and the UI.
# --rebuild wins regardless, which is the dependable option after a pull that
# only touched go.sum.
stale() {
    [ -f "$exe" ] || return 0
    [ -n "$(find "$here/gui" -name '*.go' -newer "$exe" -print -quit 2>/dev/null)" ] && return 0
    [ -n "$(find "$here/gui/ui" -type f -newer "$exe" -print -quit 2>/dev/null)" ] && return 0
    [ -n "$(find "$here/go.mod" "$here/go.sum" -newer "$exe" -print -quit 2>/dev/null)" ] && return 0
    return 1
}

if [ "$rebuild" = "true" ] || stale; then
    if ! command -v go >/dev/null 2>&1; then
        if [ -f "$exe" ]; then
            echo "go was not found — starting the app that is already built." >&2
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

exec "$exe" ${app_args[@]+"${app_args[@]}"}
