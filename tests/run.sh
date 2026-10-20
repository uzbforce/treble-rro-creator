#!/usr/bin/env bash
# =============================================================================
# Everything that can be checked without Android tools
# =============================================================================
# CI runs this on every push (see .github/workflows/check.yml), and it is worth
# running before a release:
#
#   bash tests/run.sh
#
# 1. shell syntax of every shipped script (bash -n / sh -n, no execution)
# 2. the WebUI resource-table writer against tests/fixtures/*.apk
# 3. the WebUI manifest and the overlay-repo submission tree (Doze-off
#    vendor_hardware_overlay), built from
#    resource XML that tests/gen-res.sh generates into a temp directory (so a
#    fresh clone needs no build first)
# 4. every relative link and #anchor in the docs
# =============================================================================

set -euo pipefail
cd "$(dirname "$0")/.."

status=0
step() { printf '\n== %s ==\n' "$*"; }

step "shell syntax"
for f in build.sh gui.sh gui/build.sh scripts/*.sh tests/*.sh; do
    [ -f "$f" ] || continue
    if bash -n "$f"; then :; else echo "bash -n failed: $f"; status=1; fi
done
# apply.sh and the module scripts run under Android's mksh (/system/bin/sh).
for f in src/webui/apply.sh src/module/*.sh templates/*.sh templates/recoveries/*.sh; do
    [ -f "$f" ] || continue
    if command -v sh >/dev/null 2>&1; then
        if sh -n "$f"; then :; else echo "sh -n failed: $f"; status=1; fi
    fi
done
[ "$status" -eq 0 ] && echo "all scripts parse"

# The bug this guards: `clean --all` copied config.env from a frozen file, so a
# full clean handed back a version from an older commit. The copies below are
# now only the no-.git fallback, so they must equal the committed blob — not the
# working file, because local edits to config.env are normal.
step "template fallbacks match the release"
if command -v git >/dev/null 2>&1 && git rev-parse --git-dir >/dev/null 2>&1; then
    copy_status=0
    check_copy() {
        local rel="$1" copy="$2"
        if [ ! -f "$copy" ]; then
            echo "missing fallback: $copy"
            copy_status=1
        elif ! git show "HEAD:$rel" | diff -q - "$copy" >/dev/null; then
            echo "$copy differs from HEAD:$rel — run: git show HEAD:$rel > $copy"
            copy_status=1
        fi
    }
    check_copy config.env templates/recoveries/config.env
    check_copy src/module/sepolicy.rule templates/recoveries/sepolicy.rule
    if [ "$copy_status" -eq 0 ]; then echo "fallbacks match"; else status=1; fi
else
    echo "not a git checkout — skipping"
fi

# restore_from_release() is what clean.sh and build.sh call. Run it against a
# throwaway repository with a deliberately stale fallback, and once without
# .git, because "start over" silently returning old values is the failure mode.
step "restore picks the release, not the stale copy"
restore_here="$(pwd)"
restore_tmp="$(mktemp -d 2>/dev/null || mktemp -d -t treble-restore)"
if (
    cd "$restore_tmp" || exit 1
    git init -q . && git config user.email t@example.com && git config user.name t || exit 1
    # No .gitattributes here, and Git for Windows defaults to autocrlf=true,
    # which would check the file back out with CRLF and fail the greps below.
    git config core.autocrlf false
    mkdir -p src/module templates/recoveries
    printf 'KEY="released"\n' > config.env
    printf 'released rules\n' > src/module/sepolicy.rule
    printf 'STALE\n' > templates/recoveries/config.env
    printf 'STALE\n' > templates/recoveries/sepolicy.rule
    git add -A && git commit -qm one || exit 1
    # The user edits both files; the fallback copies are stale.
    printf 'KEY="mine"\n' > config.env
    printf 'my rules\n' > src/module/sepolicy.rule
    ROOT="$restore_tmp" bash -c 'source "$1/scripts/common.sh"; restore_from_release config.env "$ROOT/templates/recoveries/config.env" && restore_from_release src/module/sepolicy.rule "$ROOT/templates/recoveries/sepolicy.rule"' _ "$restore_here" || exit 2
    grep -qx 'KEY="released"' config.env || { echo "git restore did not win: $(cat config.env)"; exit 3; }
    grep -qx 'released rules' src/module/sepolicy.rule || exit 4
    # No .git (a zip download): the bundled copy is the only source left.
    rm -rf .git
    printf 'KEY="mine"\n' > config.env
    ROOT="$restore_tmp" bash -c 'source "$1/scripts/common.sh"; restore_from_release config.env "$ROOT/templates/recoveries/config.env"' _ "$restore_here" || exit 6
    grep -q 'STALE' config.env || { echo "fallback was not used without git"; exit 7; }
); then
    echo "restore behaves"
else
    echo "restore test failed (exit $?)"
    status=1
fi
rm -rf "$restore_tmp"

step "node tests"
if command -v node >/dev/null 2>&1; then
    node --test tests/arsc.test.js tests/manifest.test.js tests/hw-overlay.test.js \
        tests/gui-ui.test.js || status=1
else
    echo "node is not installed — skipping the resource-table tests"
    status=1
fi

# The desktop app is optional: a clone without Go is still a complete CLI
# install, so a missing toolchain skips instead of failing. CI installs Go and
# runs this step for real (see .github/workflows/check.yml).
step "desktop app (go)"
if command -v go >/dev/null 2>&1; then
    CGO_ENABLED=0 go test ./... || status=1
else
    echo "go is not installed — skipping the desktop app tests"
fi

step "documentation links"
if command -v node >/dev/null 2>&1; then
    node tests/docs-links.js || status=1
fi

if [ "$status" -ne 0 ]; then
    printf '\nSome checks failed.\n'
    exit 1
fi
printf '\nAll checks passed.\n'
