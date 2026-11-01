#!/usr/bin/env bash
# =============================================================================
# Treble Overlay Creator
# =============================================================================
# One command for everything. With a terminal attached it opens the menu, which
# reaches every tool the desktop app has; with an argument it does exactly that
# one thing, as before.
#
#   ./build.sh                 the menu (on a terminal); otherwise: build
#   ./build.sh menu            the menu, even without a terminal
#   ./build.sh build           build (auto-installs the toolchain if needed)
#   ./build.sh setup           install / repair the toolchain only
#   ./build.sh doctor          check the toolchain (read-only)
#   ./build.sh check           validate config.env without building
#   ./build.sh --dry-run       print the resources config.env emits, build nothing
#   ./build.sh fod-build       rebuild the arm64 UDFPS helper (maintainers)
#   ./build.sh profiles        saved config.env setups, one per device
#   ./build.sh clean           remove build output
#   ./build.sh clean --all     start over for a different device
#
#   -y, --yes                  no questions (also: --with-vendor-hals)
#   -V, --version              print the version
#   -h, --help                 this help
#
# On Windows use build.cmd (cmd, PowerShell or a double-click). It finds Git
# Bash and passes the same arguments here. WSL is not supported on a Windows
# drive — see docs/windows.md.
# =============================================================================

# pipefail matters here: most build steps run a tool and parse its output in a
# pipeline (`aapt2 dump ... | sed | awk`). Without it a failed tool still exits
# 0 through the pipeline and the build carries on with empty input.
set -eo pipefail

# ---------------------------------------------------------------------------
# Project root
# ---------------------------------------------------------------------------
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Launched from cmd.exe, PWD can be "C:/..." instead of "/c/..."; MSYS does
# not recognise that form, so convert it before anything else uses it.
if command -v cygpath >/dev/null 2>&1; then
    ROOT=$(cygpath -u "$ROOT")
fi
export ROOT
cd "$ROOT"

source "$ROOT/stuff/scripts/common.sh"
source "$ROOT/stuff/scripts/toolchain.sh"

# Put stuff/tools/ on PATH (and its lib64 on LD_LIBRARY_PATH on Linux).
tools_on_path

# ---------------------------------------------------------------------------
# Options
# ---------------------------------------------------------------------------
MODE="build"
REQUESTED=$#
CHECK_MODE=false
DRY_RUN=false
ASSUME_YES=false
FORCE_VENDOR_HALS=false
CLEAN_ALL=false
FORCE_RES=""
ALLOW_UNKNOWN_RESOURCES=false

usage() {
    echo ""
    echo -e "  ${BOLD}Usage:${NC} ./build.sh [command] [options]"
    echo ""
    echo -e "  ${BOLD}Commands${NC}"
    echo "    (none)             The menu (on a terminal), otherwise a build"
    echo "    menu               The menu: build, config.env, addons, device probes"
    echo "    build              Build the overlay module (installs tools if needed)"
    echo "    profiles           Saved config.env setups: show, new, switch, rename, delete"
    echo "    setup              Install or repair the build tools"
    echo "    doctor             Check the toolchain, install nothing"
    echo "    check              Validate config.env, build nothing"
    echo "    install            Install out/<name>-ksu.zip on the phone, reboot, verify"
    echo "    fod-build          Rebuild the arm64 UDFPS helper from its Go source"
    echo "    clean              Remove build output"
    echo "    --dry-run          Print the resources config.env emits, build nothing"
    echo ""
    echo -e "  ${BOLD}Options${NC}"
    echo "    -y, --yes              Accept defaults, skip prompts"
    echo "    --with-vendor-hals     With --yes: include src/vendor/ in the module"
    echo "    --xiaomi-fod           Include the Xiaomi FOD helper (HBM + HIDL touch mode) in the module"
    echo "    --device SERIAL        With install: the phone to use, when more than one is attached"
    echo "    --zip PATH             With install: a module other than the newest build"
    echo "    --no-reboot            With install: hand it over, do not reboot or verify"
    echo "    --all                  With clean: also remove config and device files"
    echo "    --force                With setup: re-pick the resource dictionary"
    echo "    --allow-unknown-resources  Build even if a resource is missing from the target"
    echo "    --no-su                Termux: do not ask for root up front"
    echo "    -V, --version          Print the version"
    echo "    -h, --help             Show this help"
    echo ""
    echo -e "  ${BOLD}Windows:${NC} build.cmd [command] [options]"
    echo ""
}

# Options that only `install` understands are collected here and handed to
# install-module.sh, so the entry point keeps one parser.
INSTALL_EXTRA=()

# Everything after `profiles` belongs to profiles.sh (switch p2, rename p2 "…").
PROFILES_ARGS=()

while [ $# -gt 0 ]; do
    arg="$1"
    case "$arg" in
        build)          MODE="build" ;;
        menu|--menu)    MODE="menu" ;;
        setup|--setup)  MODE="setup" ;;
        doctor|--doctor) MODE="doctor" ;;
        check|--check)  MODE="check" ;;
        install)        MODE="install" ;;
        profiles)
            MODE="profiles"
            PROFILES_ARGS=("${@:2}")
            break
            ;;
        --device|--adb|--zip)
            INSTALL_EXTRA+=("$arg" "${2:-}")
            shift ;;
        --no-reboot|--no-verify)
            INSTALL_EXTRA+=("$arg") ;;
        fod-build|--fod-build) MODE="fodbuild" ;;
        clean|--clean)  MODE="clean" ;;
        dry-run|--dry-run) MODE="dryrun" ;;
        -y|--yes)       ASSUME_YES=true ;;
        --with-vendor-hals) FORCE_VENDOR_HALS=true ;;
        --xiaomi-fod)   XIAOMI_FOD=true ;;
        --all)          CLEAN_ALL=true ;;
        --force)        FORCE_RES="force" ;;
        --allow-unknown-resources) ALLOW_UNKNOWN_RESOURCES=true ;;
        # Exported, so a menu that shells out for a build does not ask again.
        --no-su)        export TREBLE_NO_SU=1 ;;
        -V|--version)   echo "Treble RRO Creator ${TOOL_VERSION}"; exit 0 ;;
        -h|--help)      usage; exit 0 ;;
        *)
            err "            Unknown option: ${arg}"

            usage
            exit 2
            ;;
    esac
    shift
done

# No arguments and a terminal to talk on: the menu. Everything scripted passes
# a verb, so nothing that relied on the old no-argument build needs to change.
if [ "$REQUESTED" -eq 0 ] && [ "${TREBLE_MENU:-1}" != "0" ] && [ -t 0 ] && [ -t 1 ]; then
    MODE="menu"
fi

# --device, --zip and --no-reboot belong to install; taking them with another
# verb and quietly ignoring them would look like they had been used.
if [ "${#INSTALL_EXTRA[@]}" -gt 0 ] && [ "$MODE" != "install" ]; then
    err "            ${INSTALL_EXTRA[0]} only applies to 'install'"
    usage
    exit 2
fi

# A checkout on a Windows drive cannot be built from WSL (shared stuff/tools/).
wsl_guard

# Termux: the one root prompt of the session, asked before any screen is drawn.
# -y means "unattended", and an unattended run must not stop for a tap.
[ "$ASSUME_YES" = true ] || termux_root_handoff

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------
case "$MODE" in
    menu)
        # The terminal front end. It shells out to this same script for a build,
        # so a build started from the menu is the build a user would type.
        migrate_layout
        . "$ROOT/stuff/scripts/menu.sh"
        menu_main
        exit $?
        ;;

    doctor)
        if run_doctor; then exit 0; else exit 1; fi
        ;;

    setup)
        banner "Setup — build tools"
        migrate_layout
        # -y means "no questions": the desktop app has no terminal, so the
        # interactive menu would fall back to its default instead of using the
        # packages this machine already has. Auto is the installer a plain
        # build runs; it still asks for a sudo password when it needs one —
        # in a terminal sudo prompts, and the app has its own dialog for it.
        if $ASSUME_YES; then
            ensure_toolchain auto "$FORCE_RES"
        else
            ensure_toolchain interactive "$FORCE_RES"
        fi
        exit $?
        ;;

    check)
        # Config validation only: no tools, no output.
        CHECK_MODE=true
        source "$ROOT/stuff/scripts/build.sh"
        ;;

    fodbuild)
        # Maintainers only: the shipped helper is prebuilt on purpose, so no
        # user path reaches Go for it.
        bash "$ROOT/stuff/scripts/fod-build.sh"
        exit $?
        ;;

    install)
        migrate_layout
        # A child, not a source: it parses its own options and can be run on its
        # own (bash stuff/scripts/install-module.sh --zip out/x-ksu.zip).
        bash "$ROOT/stuff/scripts/install-module.sh" ${INSTALL_EXTRA[@]+"${INSTALL_EXTRA[@]}"}
        exit $?
        ;;

    profiles)
        migrate_layout
        . "$ROOT/stuff/scripts/profiles.sh"
        profiles_cli ${PROFILES_ARGS[@]+"${PROFILES_ARGS[@]}"}
        exit $?
        ;;

    clean)
        migrate_layout
        source "$ROOT/stuff/scripts/clean.sh"
        ;;

    dryrun)
        # Needs config.env and the resource generators, no toolchain: the point
        # is to see the plan in seconds.
        DRY_RUN=true
        source "$ROOT/stuff/scripts/build.sh"
        ;;

    build)
        # Move any files left in the old top-level layout into src/.
        migrate_layout
        if $IS_WINDOWS; then
            banner "Treble Overlay Builder — Windows"
        elif $IS_TERMUX; then
            banner "Treble Overlay Builder — Termux"
        else
            banner "Treble Overlay Builder — Linux"
        fi
        # Installs only what is missing; prints a summary and returns non-zero
        # when the machine still cannot build.
        ensure_toolchain auto
        # The installer may just have created stuff/tools/, so refresh PATH.
        tools_on_path
        source "$ROOT/stuff/scripts/build.sh"
        ;;
esac
