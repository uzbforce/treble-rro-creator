#!/usr/bin/env bash
# =============================================================================
# Generate the resource XML into a directory of its own (for the tests)
# =============================================================================
# The build writes src/framework/res/values/generated.xml and
# src/systemui/res/values/generated.xml, and both are gitignored — they are
# build artifacts. A fresh clone therefore has nothing for the manifest tests to
# read, and using the checkout's config.env would make the result depend on the
# machine the tests run on.
#
# So generate the files the manifest is built from, from a fixed config, into a
# temporary tree:
#
#   bash stuff/tests/gen-res.sh <outdir>
#
#   <outdir>/framework/res/values/*.xml
#   <outdir>/framework/res/values-land/*.xml
#   <outdir>/systemui/res/values/*.xml
#
# No Android tools are involved: this only runs the config.env -> XML half of
# the build (stuff/scripts/resources.sh).
# =============================================================================

set -eo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

OUT="${1:-}"
[ -n "$OUT" ] || { echo "usage: $0 <outdir>" >&2; exit 2; }

RES_DIR="$OUT/framework/res"
SYSUI_RES_DIR="$OUT/systemui/res"
mkdir -p "$RES_DIR/values" "$RES_DIR/values-land" "$SYSUI_RES_DIR/values"

# shellcheck source=/dev/null
source "$ROOT/stuff/scripts/common.sh"

# The fixed config. Everything the sliders do not cover still has to reach the
# manifest, so set the values that produce extra resources: a corner radius (6
# dimens), a status bar height (5 dimens + a landscape file) and the status bar
# paddings (SystemUI dimens).
ROUNDED_CORNER_RADIUS=100
STATUS_BAR_HEIGHT=76
STATUS_BAR_HEIGHT_LANDSCAPE=24
STATUS_BAR_PADDING_START=34
STATUS_BAR_PADDING_END=34
STATUS_BAR_CONTENT_PADDING=34
# One edge is enough to prove the waterfall band is emitted per edge (the four
# keys are independent).
WATERFALL_EDGE_LEFT=40
HAS_UDFPS=false
HAS_AOD=true
HAS_DOZE=false
HAS_AUTO_BRIGHTNESS=false
HAS_BURN_IN_PROTECTION=false
HAS_DOUBLE_TAP_WAKE=false
HAS_HBM=false
HAS_5G=false
HAS_VOLTE=false

# shellcheck source=/dev/null
source "$ROOT/stuff/scripts/resources.sh"
generate_resource_xml
generate_systemui_resource_xml
