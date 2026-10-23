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
#     Linux    gcc, pkg-config and the GTK/WebKitGTK development headers.
#              Whatever is missing is installed with the package manager this
#              distro already has — apt (Debian/Ubuntu), pacman (Arch) or dnf
#              (Fedora) — instead of being left as a Debian-only apt command.
#
# The window uses the engine the machine already has (WebView2 on Windows,
# WebKitGTK on Linux). CGO_ENABLED=0 still builds — it just opens the same UI
# in the default browser instead.
# =============================================================================
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
self="$here/${BASH_SOURCE[0]##*/}"
cd "$here"

release=false
for arg in "$@"; do
    case "$arg" in
        --release) release=true ;;
        -h|--help)
            awk '/^# =====/ { n++; next } n == 1 { sub(/^# ?/, ""); print }' "$self"
            exit 0
            ;;
        *) echo "unknown argument: $arg" >&2; exit 2 ;;
    esac
done

# ---------------------------------------------------------------------------
# The C deps the window needs, and who installs them
# ---------------------------------------------------------------------------
# The window is linked with CGO: a C compiler, pkg-config, and the GTK3 and
# WebKitGTK development headers. A missing one is installed with the package
# manager this machine already has, so an Arch box is not handed an apt
# command. Go is not on that list — several distros still package a version
# older than go.mod asks for — so it stays a download from go.dev, named for
# the distro below.

pkg_family() {
    if command -v apt-get >/dev/null 2>&1; then
        echo apt
    elif command -v pacman >/dev/null 2>&1; then
        echo pacman
    elif command -v dnf >/dev/null 2>&1; then
        echo dnf
    else
        echo unknown
    fi
}

# gcc is the name cgo looks for when CC is unset, so that is the one to check.
have_cc() {
    [ -n "${CC:-}" ] || command -v gcc >/dev/null 2>&1
}

have_pkgconfig() {
    command -v pkg-config >/dev/null 2>&1
}

have_gtk() {
    have_pkgconfig && pkg-config --exists gtk+-3.0 2>/dev/null
}

have_webkit() {
    have_pkgconfig || return 1
    pkg-config --exists webkit2gtk-4.0 2>/dev/null && return 0
    pkg-config --exists webkit2gtk-4.1 2>/dev/null
}

# Windows links against WebView2, so only the compiler is checked there.
window_deps_ok() {
    have_cc || return 1
    [ "$(uname -s)" = "Linux" ] || return 0
    have_gtk && have_webkit
}

# WebKitGTK is 4.1 on current releases and 4.0 on older ones, so apt is asked
# which name its repository carries; pacman and dnf have settled on 4.1.
apt_webkit_pkg() {
    if command -v apt-cache >/dev/null 2>&1 &&
       apt-cache show libwebkit2gtk-4.1-dev >/dev/null 2>&1; then
        echo libwebkit2gtk-4.1-dev
    else
        echo libwebkit2gtk-4.0-dev
    fi
}

# The four things under the name this distro gives them.
window_packages() {
    case "$1" in
        apt)    echo "build-essential pkg-config libgtk-3-dev $(apt_webkit_pkg)" ;;
        pacman) echo "gcc pkgconf gtk3 webkit2gtk-4.1" ;;
        dnf)    echo "gcc pkgconf-pkg-config gtk3-devel webkit2gtk4.1-devel" ;;
    esac
}

# can_install: root, or sudo that will not block. A password is only ever
# asked for when there is a terminal to type it into; a scripted or CI run gets
# the command to run by hand instead of a prompt nobody can answer.
can_install() {
    if [ "$(id -u)" -eq 0 ]; then
        return 0
    fi
    command -v sudo >/dev/null 2>&1 || return 1
    sudo -n true 2>/dev/null || [ -t 0 ] || [ -t 2 ]
}

as_root() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    else
        sudo "$@"
    fi
}

install_window_deps() {
    local packages
    case "$1" in
        apt)
            echo "installing the GTK/WebKitGTK headers with apt…"
            # The WebKitGTK name is picked from the repository, so the lists
            # have to be current before apt-cache is asked.
            as_root apt-get update || true
            packages="$(window_packages apt)"
            as_root apt-get install -y $packages
            ;;
        pacman)
            echo "installing the GTK/WebKitGTK headers with pacman…"
            packages="$(window_packages pacman)"
            if ! as_root pacman -S --needed --noconfirm $packages; then
                # A 404 from every mirror is a sync database that still lists
                # versions the repositories have already replaced — pacman
                # cannot repair that from the local copy, so refresh it and
                # try once more.
                echo "pacman could not fetch those packages — refreshing its database and retrying…"
                as_root pacman -Sy --noconfirm || true
                as_root pacman -S --needed --noconfirm $packages
            fi
            ;;
        dnf)
            echo "installing the GTK/WebKitGTK headers with dnf…"
            packages="$(window_packages dnf)"
            as_root dnf install -y $packages
            ;;
        *)
            return 1
            ;;
    esac
}

# The by-hand version of the same thing, in this machine's package names.
window_deps_hint() {
    case "$(pkg_family)" in
        apt)    echo "  sudo apt install -y $(window_packages apt)" ;;
        pacman) echo "  sudo pacman -S --needed $(window_packages pacman)" ;;
        dnf)    echo "  sudo dnf install -y $(window_packages dnf)" ;;
        *)      echo "  install gcc, pkg-config, and the GTK3 and WebKitGTK development headers" ;;
    esac
}

command -v go >/dev/null 2>&1 || {
    go_min="$(awk '$1 == "go" { print $2; exit }' "$here/../go.mod" 2>/dev/null || true)"
    echo "go was not found on PATH — install Go ${go_min:-1.23}+ from https://go.dev/dl/" >&2
    if [ "$(uname -s)" = "Linux" ]; then
        case "$(pkg_family)" in
            pacman) echo "  (or from the distro, which tracks upstream: sudo pacman -S --needed go)" >&2 ;;
            dnf)    echo "  (or: sudo dnf install -y golang, if that is ${go_min:-1.23} or newer)" >&2 ;;
            apt)    echo "  (Debian and Ubuntu often package an older Go as golang-go; go.dev is the safe source)" >&2 ;;
        esac
    fi
    exit 1
}

# Only the CGO build links a window; the browser build needs none of this.
cgo=1
if [ "${CGO_ENABLED:-1}" = "0" ]; then
    cgo=0
fi

if [ "$cgo" = "1" ] && ! window_deps_ok; then
    if [ "$(uname -s)" = "Linux" ] && [ "$(pkg_family)" != "unknown" ] && can_install; then
        echo "the window is missing a C compiler, pkg-config or the GTK/WebKitGTK headers."
        install_window_deps "$(pkg_family)" || true
    fi
    if ! window_deps_ok; then
        case "$(uname -s)" in
            MINGW*|MSYS*|CYGWIN*)
                echo "A C compiler is missing: the window is built with CGO." >&2
                echo "  winget install MSYS2.MSYS2          (then, in an MSYS2 shell)" >&2
                echo "  pacman -S mingw-w64-x86_64-gcc      (and put mingw64\\bin on PATH)" >&2
                ;;
            *)
                echo "The window's build dependencies are still missing." >&2
                window_deps_hint >&2
                if [ "$(pkg_family)" = "pacman" ]; then
                    echo "  (a 404 from every mirror means the sync database is stale: sudo pacman -Syu)" >&2
                fi
                ;;
        esac
        echo "Or build without a window: CGO_ENABLED=0 ./gui/build.sh" >&2
        exit 1
    fi
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
            window_deps_hint >&2
            echo "  (or build without a window: CGO_ENABLED=0 ./gui/build.sh)" >&2
            exit 1
        fi
    fi
fi

mkdir -p bin
CGO_ENABLED=$cgo go build -trimpath -ldflags "$ldflags" -o "bin/treble-rro-creator-gui$ext" .
echo "built gui/bin/treble-rro-creator-gui$ext"
