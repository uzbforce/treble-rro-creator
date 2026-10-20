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
for f in build.sh scripts/*.sh tests/*.sh; do
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

step "node tests"
if command -v node >/dev/null 2>&1; then
    node --test tests/arsc.test.js tests/manifest.test.js tests/hw-overlay.test.js || status=1
else
    echo "node is not installed — skipping the resource-table tests"
    status=1
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
