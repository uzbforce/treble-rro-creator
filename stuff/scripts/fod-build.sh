#!/usr/bin/env bash
# =============================================================================
# Rebuild src/module/fod/xiaomi-fod from its source
# =============================================================================
# The helper ships as a prebuilt arm64 binary: it is compiled for Android, and
# neither a user's desktop nor Termux should need a Go toolchain for it. The
# source stays next to it (src/module/fod/main.go), so the binary can be rebuilt
# instead of being an opaque blob — this script is that rebuild.
#
#   ./build.sh fod-build        # or: bash stuff/scripts/fod-build.sh
#
# Go 1.23+ on PATH is required. The output is not byte-identical across Go
# releases, so a changed hash after a toolchain update is normal. What has to
# keep working is the compile, which stuff/tests/run.sh checks for android/arm64
# on every push — that is the guard against source and binary drifting apart.
# =============================================================================

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)" || exit 1
SRC="$ROOT/src/module/fod"
OUT="$SRC/xiaomi-fod"

if ! command -v go >/dev/null 2>&1; then
    echo "fod-build: go is not on PATH — install Go 1.23+ to rebuild the helper" >&2
    exit 1
fi

echo "fod-build: compiling src/module/fod/main.go for android/arm64"
(
    cd "$SRC" || exit 1
    GOOS=android GOARCH=arm64 CGO_ENABLED=0 GO111MODULE=off \
        go build -trimpath -ldflags="-s -w" -o "$OUT" main.go
) || { echo "fod-build: compilation failed" >&2; exit 1; }

chmod 0644 "$OUT"
echo "fod-build: wrote $OUT"
if command -v sha256sum >/dev/null 2>&1; then
    printf 'fod-build: sha256 %s\n' "$(sha256sum "$OUT" | cut -d' ' -f1)"
fi