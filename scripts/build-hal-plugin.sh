#!/usr/bin/env bash
# Build the SC200PC DOL2 HAL plugin (ipu75xa.so) from the project fork of
# Intel's ipu7-camera-hal. Idempotent: skips the build if artifacts/ipu75xa.so
# was already built from the pinned source commit.
#
# The SC200PC DOL2 enablement lives on the fork branch 'sc200pc-dol2', based on
# Intel's April release tag (ef307675 / 20260406_1900_297) plus the project's
# DOL2 commits. We pin the exact source commit, so the build is reproducible
# from source; the resulting binary hash is environment-specific and only
# matches the reference build on the reference machine.
#
# Normally invoked automatically by `sc200pc-apply.sh install`; you can also
# run it standalone (as your user, to keep build artifacts user-owned).
#
# Prerequisites: cmake, a C++ toolchain, and the Intel IPU7 camera dev
# dependencies (AIQ/CCA/AIC headers/libraries from ipu7-camera-bins, plus
# libdrm, jsoncpp, etc. as the HAL's CMake requires).
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)

FORK_URL=${FORK_URL:-https://github.com/Jabbslad/ipu7-camera-hal.git}
FORK_BRANCH=${FORK_BRANCH:-sc200pc-dol2}
# Validated source tip: Intel April tag + 18 SC200PC DOL2 commits.
PINNED_HAL_COMMIT=${PINNED_HAL_COMMIT:-73fbf9023ab64d9fb780dbe082e9fdca2b16a0d3}
SRC_DIR=${SRC_DIR:-"$REPO_ROOT/build/ipu7-camera-hal"}
BUILD_OUT=${BUILD_OUT:-"$SRC_DIR/out"}
ARTIFACTS=${ARTIFACTS:-"$REPO_ROOT/artifacts"}
PLUGIN_OUT="$ARTIFACTS/ipu75xa.so"
SRC_SIDECAR="$ARTIFACTS/ipu75xa.so.src"
# Reference build's plugin hash (this machine); informational for from-source builds.
REFERENCE_PLUGIN_SHA256=c3c37b89876d39531aa9980af44ac2759a292dfa8c53b070a76e4344893a4988

fail() { echo "error: $*" >&2; exit 1; }
sha_of() { sha256sum -- "$1" 2>/dev/null | awk '{print $1}'; }

# Idempotent skip: already built from the pinned commit?
if [[ -f $PLUGIN_OUT && -f $SRC_SIDECAR && $(cat "$SRC_SIDECAR") == "$PINNED_HAL_COMMIT" ]]; then
    echo "plugin: up to date (built from ${PINNED_HAL_COMMIT:0:12})"
    echo "    sha256: $(sha_of "$PLUGIN_OUT")"
    exit 0
fi

echo "==> fetching $FORK_URL ($FORK_BRANCH)"
if [[ -d $SRC_DIR/.git ]]; then
    git -C "$SRC_DIR" fetch origin "$FORK_BRANCH"
else
    git clone "$FORK_URL" "$SRC_DIR"
fi
git -C "$SRC_DIR" checkout -q "$PINNED_HAL_COMMIT"
actual=$(git -C "$SRC_DIR" rev-parse HEAD)
[[ $actual == "$PINNED_HAL_COMMIT" ]] ||
    fail "checked-out HAL source $actual != pinned $PINNED_HAL_COMMIT"
echo "==> HAL source pinned at $PINNED_HAL_COMMIT"

echo "==> configuring (RelWithDebInfo, ENABLE_DOL_FEATURE=ON)"
cmake -B "$BUILD_OUT" -S "$SRC_DIR" \
    -DCMAKE_BUILD_TYPE=RelWithDebInfo \
    -DENABLE_DOL_FEATURE=ON

echo "==> building"
cmake --build "$BUILD_OUT" -j"$(nproc)"

so=$(find "$BUILD_OUT" -name 'ipu75xa.so' -type f | head -1)
[[ -n $so ]] || fail "ipu75xa.so not found in $BUILD_OUT"
install -D -m 0755 -- "$so" "$PLUGIN_OUT"
printf '%s\n' "$PINNED_HAL_COMMIT" >"$SRC_SIDECAR"

hash=$(sha_of "$PLUGIN_OUT")
echo "==> built $PLUGIN_OUT"
echo "    source:  $PINNED_HAL_COMMIT"
echo "    sha256:  $hash"
if [[ $hash == "$REFERENCE_PLUGIN_SHA256" ]]; then
    echo "    matches the reference build"
else
    echo "    note: differs from reference $REFERENCE_PLUGIN_SHA256"
    echo "    (expected on a different toolchain/libs; source is pinned)"
fi
