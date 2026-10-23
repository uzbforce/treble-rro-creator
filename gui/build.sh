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
#   A C compiler, because the window is a webview:
#     Windows  Git for Windows (for bash) + MinGW-w64 gcc on PATH.
#              "winget install MSYS2.MSYS2" then
#              "pacman -S mingw-w64-x86_64-gcc" is the shortest route.
#     Linux    gcc, pkg-config and the GTK/WebKitGTK development headers.
#              Whatever is missing is installed with the package manager this
#              distro already has — apt (Debian/Ubuntu), pacman (Arch) or dnf
#              (Fedora) — instead of being left as a Debian-only apt command.
#
#   Go 1.23+ — downloaded from go.dev into stuff/tools/go/ when the machine has
#   none, so a fresh clone builds with no setup step.
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
# command.

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

# ---------------------------------------------------------------------------
# Go: used when present, downloaded when not
# ---------------------------------------------------------------------------
# The launcher is the first command a new clone runs, so "install Go and come
# back" is not an answer. The official tarball is unpacked into
# stuff/tools/go/ — inside the clone, no root, and found again by every later
# build. A Go already on PATH is used when it is new enough; distro packages
# are often older than go.mod asks for, which is why a too-old one is passed
# over instead of trusted.

tools_dir="$here/../stuff/tools"
local_go="$tools_dir/go/bin/go"
case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) local_go="$local_go.exe" ;;
esac

go_required() {
    local req
    req="$(awk '$1 == "go" { print $2; exit }' "$here/../go.mod" 2>/dev/null || true)"
    echo "${req:-1.23}"
}

# version_at_least <have> <want>, both dotted ("1.23", "1.23.4").
version_at_least() {
    awk -v have="$1" -v want="$2" 'BEGIN {
        n = split(have, h, "."); m = split(want, w, ".")
        if (m > n) n = m
        for (i = 1; i <= n; i++) {
            a = (i in h) ? h[i] + 0 : 0
            b = (i in w) ? w[i] + 0 : 0
            if (a > b) exit 0
            if (a < b) exit 1
        }
        exit 0
    }'
}

go_usable() {
    [ -x "$1" ] || return 1
    local v
    v="$("$1" version 2>/dev/null | awk '{ sub(/^go/, "", $3); print $3 }')"
    [ -n "$v" ] || return 1
    version_at_least "$v" "$(go_required)"
}

# fetch_url <url> [outfile]: the body on stdout, or into the file.
fetch_url() {
    if command -v curl >/dev/null 2>&1; then
        if [ -n "${2:-}" ]; then
            # One repainted line: Go is ~70 MB, and a full meter for that is
            # hundreds of lines in the launcher's output.
            curl -fL --retry 2 --progress-bar -o "$2" "$1"
        else
            curl -fsSL --retry 2 "$1"
        fi
    elif command -v wget >/dev/null 2>&1; then
        if [ -n "${2:-}" ]; then
            wget -O "$2" "$1"
        else
            wget -qO- "$1"
        fi
    else
        return 1
    fi
}

# The os-arch half of the download name, empty when there is no official
# build for this machine.
go_platform() {
    local os arch
    case "$(uname -s)" in
        Linux*)
            # Termux is Android: its prefix is not an FHS root and Go's Linux
            # tarball is not built for it, but its own package manager has Go.
            case "${PREFIX:-}" in
                *com.termux*) return 1 ;;
            esac
            os=linux
            ;;
        Darwin*) os=darwin ;;
        MINGW*|MSYS*|CYGWIN*) os=windows ;;
        *) return 1 ;;
    esac
    case "$(uname -m)" in
        x86_64|amd64)        arch=amd64 ;;
        i386|i486|i586|i686)  arch=386 ;;
        aarch64|arm64)       arch=arm64 ;;
        armv6l|armv7l)       arch=armv6l ;;
        ppc64le)             arch=ppc64le ;;
        s390x)               arch=s390x ;;
        riscv64)             arch=riscv64 ;;
        *) return 1 ;;
    esac
    if [ "$os" = windows ] && [ "$arch" = armv6l ]; then
        return 1
    fi
    echo "$os-$arch"
}

install_go() {
    local platform ver file url tmp

    if ! platform="$(go_platform)"; then
        echo "Go $(go_required)+ is needed, and there is no download for this platform." >&2
        echo "  Install it from https://go.dev/dl/ and run this again." >&2
        case "${PREFIX:-}" in
            *com.termux*) echo "  On Termux: pkg install golang" >&2 ;;
        esac
        return 1
    fi

    # VERSION?m=text is the smallest way to ask go.dev what "latest" is: two
    # lines, the first being go1.24.5 and the second its release time.
    ver="$(fetch_url "https://go.dev/VERSION?m=text" 2>/dev/null | head -1 | tr -d '\r')" || ver=""
    case "$ver" in
        go1.*) ;;
        *)
            echo "Could not work out the current Go version — go.dev unreachable?" >&2
            echo "  Install Go $(go_required)+ from https://go.dev/dl/ and run this again." >&2
            return 1
            ;;
    esac

    case "$platform" in
        windows-*) file="$ver.$platform.zip" ;;
        *)         file="$ver.$platform.tar.gz" ;;
    esac
    url="https://go.dev/dl/$file"

    echo "go was not found — downloading Go ${ver#go} into stuff/tools/go…"
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/go-download.XXXXXX")" || return 1
    if ! fetch_url "$url" "$tmp/$file"; then
        echo "  The download failed: $url" >&2
        rm -rf "$tmp"
        return 1
    fi

    mkdir -p "$tools_dir"
    rm -rf "$tools_dir/go"
    case "$file" in
        *.zip)
            if ! command -v unzip >/dev/null 2>&1 || ! unzip -q "$tmp/$file" -d "$tools_dir"; then
                echo "  Could not unpack $file (is unzip installed?)" >&2
                rm -rf "$tmp"
                return 1
            fi
            ;;
        *)
            if ! tar -xzf "$tmp/$file" -C "$tools_dir"; then
                echo "  Could not unpack $file" >&2
                rm -rf "$tmp"
                return 1
            fi
            ;;
    esac
    rm -rf "$tmp"

    if ! go_usable "$local_go"; then
        echo "  Go unpacked but does not run from $local_go" >&2
        echo "  Install Go $(go_required)+ from https://go.dev/dl/ instead." >&2
        return 1
    fi
    echo "installed Go ${ver#go} in stuff/tools/go"
}

go_cmd=""
if command -v go >/dev/null 2>&1 && go_usable "$(command -v go)"; then
    go_cmd="$(command -v go)"
elif go_usable "$local_go"; then
    go_cmd="$local_go"
else
    install_go || exit 1
    go_cmd="$local_go"
fi
export PATH="$(dirname "$go_cmd"):$PATH"

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
# shim makes the requested name resolve instead of failing the build. A build
# without CGO imports no webview at all, so it needs none of this.
if [ "$cgo" = "1" ] && [ "$(uname -s)" = "Linux" ] && command -v pkg-config >/dev/null 2>&1; then
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
