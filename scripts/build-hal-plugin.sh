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
# Adaptive source tip: Intel April tag + 24 SC200PC DOL2 commits.
PINNED_HAL_COMMIT=${PINNED_HAL_COMMIT:-1dac1fda169b80ac23e1ffa6f9a49844f435f59e}
SRC_DIR=${SRC_DIR:-"$REPO_ROOT/build/ipu7-camera-hal"}
BUILD_OUT=${BUILD_OUT:-"$SRC_DIR/out"}
ARTIFACTS=${ARTIFACTS:-"$REPO_ROOT/artifacts"}
PLUGIN_OUT="$ARTIFACTS/ipu75xa.so"
SRC_SIDECAR="$ARTIFACTS/ipu75xa.so.src"

# Intel imaging binaries (headers + libs the HAL links against). Public Intel
# repo, pinned to the April release tag.
BINS_URL=${BINS_URL:-https://github.com/intel/ipu7-camera-bins.git}
BINS_TAG=${BINS_TAG:-20260406_1900_297}
BINS_COMMIT=${BINS_COMMIT:-cead7320d84ee9ade4f60d74e935b16b5a760945}
# Optional override: point at an existing ipu7-camera-bins checkout instead of
# cloning (e.g. offline, or for local iteration).
IPU7_BINS_DIR=${IPU7_BINS_DIR:-}
# Reference build's plugin hash (this machine); informational for from-source builds.
REFERENCE_PLUGIN_SHA256=decb16bdcac15d0cb10455ac29c54e548e66ba799acf97502bfd8e3e83a7154c

fail() { echo "error: $*" >&2; exit 1; }
sha_of() { sha256sum -- "$1" 2>/dev/null | awk '{print $1}'; }
require_writable() { # dir — must be user-writable (a prior `sudo` run may have left it root-owned)
    local d=$1
    if [[ -e $d && ! -w $d ]]; then
        fail "$d is not writable by $USER (root-owned from a previous sudo run). Fix with: sudo chown -R $USER \"$d\""
    fi
}

# Idempotent skip: already built from the pinned commit?
if [[ -f $PLUGIN_OUT && -f $SRC_SIDECAR && $(cat "$SRC_SIDECAR") == "$PINNED_HAL_COMMIT" ]]; then
    echo "plugin: up to date (built from ${PINNED_HAL_COMMIT:0:12})"
    echo "    sha256: $(sha_of "$PLUGIN_OUT")"
    exit 0
fi

# Build/artifacts must be user-writable before any clone/build/install.
require_writable "$REPO_ROOT/build"
require_writable "$ARTIFACTS"

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

# Provision the Intel imaging binaries: clone the public repo at the pinned
# April tag, or use a provided checkout (IPU7_BINS_DIR).
resolve_bins() {
    if [[ -n $IPU7_BINS_DIR ]]; then
        BINS=$IPU7_BINS_DIR
        echo "==> using provided Intel bins: $BINS"
        return 0
    fi
    BINS="$REPO_ROOT/build/ipu7-camera-bins"
    if [[ -d $BINS/.git ]] && [[ $(git -C "$BINS" rev-parse HEAD 2>/dev/null) == "$BINS_COMMIT" ]]; then
        echo "==> Intel bins already cloned at $BINS_TAG"
    else
        echo "==> fetching $BINS_URL (tag $BINS_TAG)"
        rm -rf "$BINS"
        git clone --depth 1 --branch "$BINS_TAG" "$BINS_URL" "$BINS"
    fi
    local head
    head=$(git -C "$BINS" rev-parse HEAD)
    [[ $head == "$BINS_COMMIT" ]] || fail "Intel bins checkout $head != pinned $BINS_COMMIT"
}
resolve_bins

# Point pkg-config at the bins. The checkout's .pc files declare prefix=/usr
# (installed form), so rewrite prefix to the bins root into a temp override dir.
pc_override_dir=$(mktemp -d)
trap 'rm -rf "$pc_override_dir"' EXIT
for pc in "$BINS"/lib/pkgconfig/ia_imaging-*.pc; do
    sed "s|^prefix=.*|prefix=$BINS|" "$pc" > "$pc_override_dir/$(basename "$pc")"
done
export PKG_CONFIG_PATH="$pc_override_dir${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
echo "==> using Intel April imaging binaries: $BINS"

echo "==> configuring (RelWithDebInfo, ENABLE_DOL_FEATURE=ON, policy>=3.5)"
# Clean configure: only reached when no successful build exists yet (sidecar
# absent), so removing a stale/partial build tree is safe and avoids reusing a
# poisoned CMake cache from a failed run.
rm -rf "$BUILD_OUT"
# jsoncpp include-layout shim: the HAL includes <jsoncpp/json/json.h> (Debian
# layout), while e.g. Arch installs jsoncpp headers as <json/json.h>. When the
# Debian layout is absent, generate a compat include dir for the build.
CXXFLAGS_EXTRA=""
if ! echo '#include <jsoncpp/json/json.h>' | c++ -E -x c++ - >/dev/null 2>&1; then
    json_includedir=$(pkg-config --variable=includedir jsoncpp 2>/dev/null || echo /usr/include)
    [[ -f $json_includedir/json/json.h ]] || fail "jsoncpp development headers not found (install jsoncpp)"
    mkdir -p "$BUILD_OUT/compat-include/jsoncpp"
    ln -sfn "$json_includedir/json" "$BUILD_OUT/compat-include/jsoncpp/json"
    CXXFLAGS_EXTRA="-I$BUILD_OUT/compat-include"
    echo "==> using jsoncpp compat include: $BUILD_OUT/compat-include"
fi
# Force the plugin to link libstdc++ DYNAMICALLY. Without this, the c++ driver
# leaves libstdc++ off the link line and the plugin ends up with a statically
# embedded libstdc++ (thousands of std:: symbols, including a weak
# std::istream::_M_extract). At runtime GStreamer loads the plugin RTLD_GLOBAL,
# so jsoncpp's decodeDouble resolves _M_extract to the plugin's embedded copy
# instead of the system libstdc++ -- two C++ runtimes interpose and the HAL
# segfaults in JsonParserBase::openJsonFile at plugin init. The clean live-canary
# reference build (768516aa) carried this exact flag and links libstdc++ dynamically.
cmake -B "$BUILD_OUT" -S "$SRC_DIR" \
    -DCMAKE_BUILD_TYPE=RelWithDebInfo \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DCMAKE_INSTALL_PREFIX=/usr \
    -DCMAKE_CXX_FLAGS="$CXXFLAGS_EXTRA" \
    -DCMAKE_SHARED_LINKER_FLAGS="-Wl,-Bdynamic -l:libstdc++.so.6" \
    -DENABLE_DOL_FEATURE=ON \
    -DBUILD_CAMHAL_PLUGIN=ON \
    -DBUILD_CAMHAL_ADAPTOR=ON \
    -DIPU_VERSIONS=ipu75xa \
    -DUSE_STATIC_GRAPH=ON \
    -DUSE_STATIC_GRAPH_AUTOGEN=ON

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
