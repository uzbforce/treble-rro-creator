#!/usr/bin/env bash
# =============================================================================
# Desktop app (Go + native window)
# =============================================================================
# Builds the launcher window into gui/bin/. Two modes:
#
#   ./gui/build.sh              console build — errors and the UI URL print to
#                               the terminal; use this while developing
#   ./gui/build.sh --release    stripped, and no console window on Windows
#
# Requirements
#   Go 1.23+ and a C compiler, because the window is a webview:
#     Windows  Git for Windows (for bash) + MinGW-w64 gcc on PATH.
#              "winget install MSYS2.MSYS2" then
#              "pacman -S mingw-w64-x86_64-gcc" is the shortest route.
#     Linux    gcc + the GTK/WebKitGTK development headers:
#              apt install build-essential libgtk-3-dev libwebkit2gtk-4.0-dev
#
# The window uses the engine the machine already has (WebView2 on Windows,
# WebKitGTK on Linux). CGO_ENABLED=0 still builds — it just opens the same UI
# in the default browser instead.
# =============================================================================
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$here"

release=false
for arg in "$@"; do
    case "$arg" in
        --release) release=true ;;
        -h|--help) sed -n '2,25p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown argument: $arg" >&2; exit 2 ;;
    esac
done

command -v go >/dev/null 2>&1 || {
    echo "go was not found on PATH — install it from https://go.dev/dl/" >&2
    exit 1
}

# CGO needs a C compiler. Failing here with a sentence beats the wall of
# "exec: gcc: executable file not found" that `go build` prints instead.
if [ -z "${CC:-}" ] && ! command -v gcc >/dev/null 2>&1; then
    echo "A C compiler is missing: the window is built with CGO." >&2
    case "$(uname -s)" in
        MINGW*|MSYS*|CYGWIN*)
            echo "  winget install MSYS2.MSYS2          (then, in an MSYS2 shell)" >&2
            echo "  pacman -S mingw-w64-x86_64-gcc      (and put mingw64\\bin on PATH)" >&2
            ;;
        *)
            echo "  apt install build-essential        (or your distro's equivalent)" >&2
            ;;
    esac
    echo "Or build without a window: CGO_ENABLED=0 ./gui/build.sh" >&2
    exit 1
fi

ext=""
ldflags="-s -w"
case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)
        ext=".exe"
        if [ "$release" = "true" ]; then
            # No console window behind the app in a release build.
            ldflags="$ldflags -H windowsgui"
        fi
        ;;
esac

# webview_go asks pkg-config for webkit2gtk-4.0 by name. Ubuntu 24.04+ and
# Fedora 40+ ship only 4.1, which is ABI-compatible for our use; a two-line .pc
# shim makes the requested name resolve instead of failing the build.
if [ "$(uname -s)" = "Linux" ] && command -v pkg-config >/dev/null 2>&1; then
    if ! pkg-config --exists webkit2gtk-4.0 2>/dev/null; then
        if pkg-config --exists webkit2gtk-4.1 2>/dev/null; then
            shim="$here/.pkgconfig"
            mkdir -p "$shim"
            cat > "$shim/webkit2gtk-4.0.pc" <<'PC'
Name: webkit2gtk-4.0
Description: shim so webview_go's pkg-config name resolves to webkit2gtk-4.1
Version: 2.40.0
Requires: webkit2gtk-4.1
PC
            export PKG_CONFIG_PATH="$shim${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
            echo "note: using webkit2gtk-4.1 through a pkg-config shim"
        else
            echo "WebKitGTK development headers are missing." >&2
            echo "  apt install build-essential libgtk-3-dev libwebkit2gtk-4.1-dev" >&2
            echo "  (or build without a window: CGO_ENABLED=0 ./gui/build.sh)" >&2
            exit 1
        fi
    fi
fi

mkdir -p bin
CGO_ENABLED=1 go build -trimpath -ldflags "$ldflags" -o "bin/treble-rro-creator-gui$ext" .
echo "built gui/bin/treble-rro-creator-gui$ext"
