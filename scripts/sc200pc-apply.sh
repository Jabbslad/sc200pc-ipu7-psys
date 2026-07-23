#!/usr/bin/env bash
# SC200PC PSYS deployment tool (single idempotent entry point).
#
# Runs the Samsung SC200PC front camera through the Intel IPU7 hardware ISP
# (PSYS) on Panther Lake, via icamerasrc/GStreamer.
#
#   install       First-time setup: fetch the AIQB, build the HAL plugin,
#                 install everything, and set up the pacman re-apply hook.
#                 The ONLY manual step is placing the out-of-band static graph
#                 in ./artifacts (see README "The graph").
#   apply         Idempotent re-apply (also run unattended by the pacman hook).
#                 No downloads or heavy builds; uses ./artifacts and the stable
#                 state copy.
#   status        Report every managed component (read-only).
#   rollback      Undo config, ISYS overlay, and HAL plugin changes.
#   install-hook  Install the /usr/local/bin wrapper + pacman hook only.
#
# Artifacts (./artifacts, git-ignored):
#   SC200PC_KAFC917_PTL.aiqb      auto-fetched by `install` (Samsung package)
#   SC200PC_KAFC917.IPU75XA.bin   YOU place this (out-of-band; see README)
#   ipu75xa.so                    auto-built by `install` from the project fork
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)

DOWNLOADER="$SCRIPT_DIR/download-windows-driver.sh"
BUILD_PLUGIN="$SCRIPT_DIR/build-hal-plugin.sh"

# Pinned identities (see README).
SENSOR_NAME=sc200pc
SENSOR_VERSION=0.9.0
IPU7_DKMS=ipu7-drivers/1.0.5
AIQB_SHA256=65b75702f33e880f9976cf51a3afa41e577dd33c1f1995e9a9fdfd1e29e5c99e
GRAPH_SHA256=c7fb4b2c96e9ffba6c87a902d235347a50dc81e52921347efca0003171c3a6cc
FIRMWARE_SHA256=8ce12bc3c4355d589a8ad97bebbb036909e5985990ce1cf37789ce60fb52720f
CONFIG_SHA256=703616ce0ba9e709ee2d0ead6c0f6ba2ba39f3ad25d884f72f51b58739c41d9b
SENSOR_JSON_SHA256=0b830982ec8f152605a2a74b003664e4d22126dbffdf35586b9f23e9a1f6313a
# Reference plugin build hash (this project's machine); informational only.
REFERENCE_PLUGIN_SHA256=768516aa0ea3f64d85b2dfc3943ffc18c4ed446cbca8d3868a2278188e5acf50

# Locations (overridable).
SENSOR_DKMS_SRC=${SENSOR_DKMS_SRC:-"$REPO_ROOT/driver"}
CONFIG_SRC=${CONFIG_SRC:-"$REPO_ROOT/config"}
PATCH=${PATCH:-"$REPO_ROOT/overlay/ipu7-isys-dualvc-default-route.patch"}
ARTIFACTS=${ARTIFACTS:-"$REPO_ROOT/artifacts"}
CAMERA_DIR=${CAMERA_DIR:-/etc/camera/ipu75xa}
STATE_DIR=${STATE_DIR:-/var/lib/sc200pc-ipu7-psys}
IPU7_SRC=${IPU7_SRC:-/usr/src/ipu7-drivers-1.0.5}
ISYS_FILE=drivers/media/pci/intel/ipu7/ipu7-isys-subdev.c
MODEPROBE_CONF=${MODEPROBE_CONF:-/etc/modprobe.d/sc200pc-dualvc.conf}
PLUGIN_PATH=${PLUGIN_PATH:-/usr/lib/libcamhal/plugins/ipu75xa.so}
FIRMWARE_PATH=${FIRMWARE_PATH:-/usr/lib/firmware/intel/ipu/ipu7ptl_fw.bin}
INSTALLED_SCRIPT=${INSTALLED_SCRIPT:-/usr/local/bin/sc200pc-apply.sh}
HOOK_SRC="$SCRIPT_DIR/sc200pc-reapply.hook"
HOOK_DST=${HOOK_DST:-/etc/pacman.d/hooks/sc200pc-reapply.hook}

AIQB_SRC="$ARTIFACTS/SC200PC_KAFC917_PTL.aiqb"
GRAPH_SRC="$ARTIFACTS/SC200PC_KAFC917.IPU75XA.bin"
PLUGIN_SRC="$ARTIFACTS/ipu75xa.so"
# Where the downloader extracts the OEM AIQB.
OEM_AIQB="$REPO_ROOT/downloads/windows-driver/extracted/camera/SC200PC_KAFC917_PTL.aiqb"

MANAGED_FILES=(
    libcamhal_configs.json
    sensors/sc200pc-uf.json
    SC200PC_KAFC917_PTL.aiqb
    gcss/SC200PC_KAFC917.IPU75XA.bin
)

usage() {
    cat <<'EOF'
Usage: sc200pc-apply.sh install|apply|status|rollback|install-hook

Run as your normal user. Downloads, clones, and builds run as you (keeping
build/ and artifacts/ user-owned); the tool prompts for your sudo password
only for system-level changes (DKMS, /etc, /usr).

  install       First-time setup: fetch AIQB + build plugin + install + hook.
                (Place the out-of-band graph in ./artifacts first.)
  apply         Idempotent re-apply (run by the pacman hook; no downloads).
  status        Report every managed component (read-only).
  rollback      Undo config, ISYS overlay, and HAL plugin changes.
  install-hook  Install the /usr/local/bin wrapper and the pacman hook only.

Artifacts in ./artifacts (git-ignored):
  SC200PC_KAFC917_PTL.aiqb     auto-fetched by `install`
  SC200PC_KAFC917.IPU75XA.bin  YOU provide (out-of-band; see README)
  ipu75xa.so                   auto-built by `install`
EOF
}

fail() { echo "error: $*" >&2; exit 1; }
require_root() { [[ $EUID -eq 0 ]] || fail "run this action through sudo"; }
# Re-exec the requested action under sudo only when it needs root, prompting for
# the password at that point. Build/fetch/download run unprivileged so build/
# and artifacts/ stay user-owned; only the system-level actions run as root.
need_root() {
    [[ $EUID -eq 0 ]] && return 0
    echo "sc200pc-apply: '$1' needs root privileges; asking for sudo…"
    exec sudo -- "$SCRIPT_DIR/sc200pc-apply.sh" "$1"
}
sha_of() { sha256sum -- "$1" 2>/dev/null | awk '{print $1}'; }
verify_hash() { # path expected label
    [[ -f $1 ]] || fail "$3 missing: $1"
    [[ $(sha_of "$1") == "$2" ]] || fail "$3 has unexpected SHA-256: $1"
}

# --- artifact provisioning (used by `install`) ---
ensure_aiqb() {
    if [[ -f $AIQB_SRC ]] && [[ $(sha_of "$AIQB_SRC") == "$AIQB_SHA256" ]]; then
        echo "aiqb: already staged"
        return 0
    fi
    echo "aiqb: downloading Samsung OEM package (its license applies)"
    "$DOWNLOADER" "$REPO_ROOT/downloads/windows-driver"
    [[ -f $OEM_AIQB ]] || fail "AIQB not found at $OEM_AIQB after download"
    install -D -m 0644 -- "$OEM_AIQB" "$AIQB_SRC"
    verify_hash "$AIQB_SRC" "$AIQB_SHA256" "AIQB"
    echo "aiqb: staged at $AIQB_SRC"
}

ensure_plugin() {
    "$BUILD_PLUGIN"
    [[ -f $PLUGIN_SRC ]] || fail "plugin build did not produce $PLUGIN_SRC"
    echo "plugin: available at $PLUGIN_SRC"
}

require_graph() {
    if [[ ! -f $GRAPH_SRC ]]; then
        fail "static graph missing: place SC200PC_KAFC917.IPU75XA.bin (sha256 $GRAPH_SHA256) into $ARTIFACTS/ (out-of-band; see README 'The graph')"
    fi
    verify_hash "$GRAPH_SRC" "$GRAPH_SHA256" "graph"
}

# --- sensor driver (DKMS) ---
apply_sensor_dkms() {
    local kver dest stale
    kver=$(uname -r)
    if dkms status "$SENSOR_NAME/$SENSOR_VERSION" -k "$kver" 2>/dev/null | grep installed >/dev/null; then
        echo "sensor: DKMS $SENSOR_NAME/$SENSOR_VERSION already installed for $kver"
        return 0
    fi
    [[ -d $SENSOR_DKMS_SRC ]] || fail "sensor DKMS source not found: $SENSOR_DKMS_SRC"
    dest="/usr/src/$SENSOR_NAME-$SENSOR_VERSION"
    echo "sensor: installing DKMS source into $dest"
    install -D -m 0644 -- "$SENSOR_DKMS_SRC/dkms.conf" "$dest/dkms.conf"
    install -D -m 0644 -- "$SENSOR_DKMS_SRC/Kbuild" "$dest/Kbuild"
    install -D -m 0644 -- "$SENSOR_DKMS_SRC/Makefile" "$dest/Makefile"
    install -D -m 0644 -- "$SENSOR_DKMS_SRC/sc200pc.c" "$dest/sc200pc.c"
    if [[ -f $SENSOR_DKMS_SRC/README.md ]]; then
        install -D -m 0644 -- "$SENSOR_DKMS_SRC/README.md" "$dest/README.md"
    fi
    stale="/lib/modules/$kver/updates/sc200pc.ko"
    if [[ -e $stale ]]; then
        echo "sensor: removing stale manual module $stale"
        rm -f -- "$stale"
    fi
    if ! dkms status "$SENSOR_NAME/$SENSOR_VERSION" 2>/dev/null | grep "$SENSOR_NAME/$SENSOR_VERSION" >/dev/null; then
        dkms add -m "$SENSOR_NAME" -v "$SENSOR_VERSION"
    fi
    echo "sensor: building $SENSOR_NAME/$SENSOR_VERSION for $kver"
    dkms build -m "$SENSOR_NAME" -v "$SENSOR_VERSION" -k "$kver"
    dkms install -m "$SENSOR_NAME" -v "$SENSOR_VERSION" -k "$kver"
    echo "sensor: DKMS installed (takes effect on module reload or boot)"
}

# --- ISYS dual-VC overlay ---
apply_isys() {
    local kver line
    kver=$(uname -r)
    if grep -q dual_vc_port "$IPU7_SRC/$ISYS_FILE" 2>/dev/null; then
        echo "isys: overlay already applied"
    else
        mkdir -p "$IPU7_SRC/.sc200pc-overlay-backup"
        if [[ ! -f $IPU7_SRC/.sc200pc-overlay-backup/$(basename "$ISYS_FILE") ]]; then
            cp -a "$IPU7_SRC/$ISYS_FILE" "$IPU7_SRC/.sc200pc-overlay-backup/"
        fi
        patch -d "$IPU7_SRC" -p1 --forward <"$PATCH"
        echo "isys: applied overlay to $IPU7_SRC"
    fi
    echo "isys: building $IPU7_DKMS for $kver"
    dkms build "$IPU7_DKMS" -k "$kver"
    dkms install "$IPU7_DKMS" -k "$kver"
    line="options intel_ipu7_isys dual_vc_port=0"
    if [[ -f $MODEPROBE_CONF ]] && grep -qxF "$line" "$MODEPROBE_CONF"; then
        echo "isys: $MODEPROBE_CONF already set"
    else
        echo "isys: writing $MODEPROBE_CONF"
        printf '%s\n' "$line" >"$MODEPROBE_CONF"
    fi
    echo "isys: installed (takes effect on module reload or boot)"
}

revert_isys() {
    local kver
    kver=$(uname -r)
    if grep -q dual_vc_port "$IPU7_SRC/$ISYS_FILE" 2>/dev/null; then
        patch -d "$IPU7_SRC" -p1 -R <"$PATCH"
        echo "isys: reverted overlay"
    else
        echo "isys: overlay not applied"
    fi
    dkms build "$IPU7_DKMS" -k "$kver"
    dkms install "$IPU7_DKMS" -k "$kver"
    if [[ -f $MODEPROBE_CONF ]]; then
        rm -f -- "$MODEPROBE_CONF"
        echo "isys: removed $MODEPROBE_CONF"
    fi
}

# --- HAL config (sensor JSON, libcamhal_configs, AIQB, graph) ---
backup_baseline() {
    [[ -e $STATE_DIR/baseline.complete ]] && return 0
    local relative
    mkdir -p -- "$STATE_DIR"
    for relative in "${MANAGED_FILES[@]}"; do
        if [[ -e $CAMERA_DIR/$relative ]]; then
            install -D -m 0644 -- "$CAMERA_DIR/$relative" "$STATE_DIR/baseline/$relative"
        else
            install -D -m 0644 /dev/null "$STATE_DIR/baseline/$relative.absent"
        fi
    done
    touch "$STATE_DIR/baseline.complete"
}

install_one() { # src dest_rel pinned
    local src=$1 dest_rel=$2 pinned=$3
    if [[ -f $src ]]; then
        verify_hash "$src" "$pinned" "$(basename "$dest_rel")"
        install -D -m 0644 -- "$src" "$CAMERA_DIR/$dest_rel"
        echo "config: installed $dest_rel"
    elif [[ -f $CAMERA_DIR/$dest_rel ]] && [[ $(sha_of "$CAMERA_DIR/$dest_rel") == "$pinned" ]]; then
        echo "config: $dest_rel already correct (source absent; left in place)"
    else
        fail "config source missing and installed $dest_rel is not the pinned version"
    fi
}

install_config() {
    backup_baseline
    install_one "$CONFIG_SRC/libcamhal_configs.json" libcamhal_configs.json "$CONFIG_SHA256"
    install_one "$CONFIG_SRC/sc200pc-uf.json" sensors/sc200pc-uf.json "$SENSOR_JSON_SHA256"
    install_one "$AIQB_SRC" SC200PC_KAFC917_PTL.aiqb "$AIQB_SHA256"
    install_one "$GRAPH_SRC" gcss/SC200PC_KAFC917.IPU75XA.bin "$GRAPH_SHA256"
}

rollback_config() {
    [[ -e $STATE_DIR/baseline.complete ]] || fail "no baseline to roll back ($STATE_DIR)"
    local relative
    for relative in "${MANAGED_FILES[@]}"; do
        if [[ -f $STATE_DIR/baseline/$relative.absent ]]; then
            rm -f -- "$CAMERA_DIR/$relative"
        else
            install -D -m 0644 -- "$STATE_DIR/baseline/$relative" "$CAMERA_DIR/$relative"
        fi
    done
    echo "config: restored pre-install configuration"
}

# --- HAL plugin ---
apply_plugin() {
    local installed desired
    installed=$(sha_of "$PLUGIN_PATH")
    # Desired hash: explicit override, else the built artifact's own hash.
    desired=${PLUGIN_SHA256:-}
    if [[ -z $desired && -f $PLUGIN_SRC ]]; then
        desired=$(sha_of "$PLUGIN_SRC")
    fi

    # 1. Already the target build -> keep a stable copy, done.
    if [[ -n $desired && $installed == "$desired" ]]; then
        echo "plugin: $PLUGIN_PATH already the target build"
        if [[ ! -f $STATE_DIR/hal-plugin/ipu75xa.so ]]; then
            install -D -m 0755 -- "$PLUGIN_PATH" "$STATE_DIR/hal-plugin/ipu75xa.so"
            echo "plugin: saved stable copy to $STATE_DIR/hal-plugin/ipu75xa.so"
        fi
        return 0
    fi
    # 2. Have the target artifact -> install it.
    if [[ -n $desired && -f $PLUGIN_SRC && $(sha_of "$PLUGIN_SRC") == "$desired" ]]; then
        if [[ -f $PLUGIN_PATH && ! -f $STATE_DIR/hal-plugin/ipu75xa.so.pre-dol2 ]]; then
            install -D -m 0755 -- "$PLUGIN_PATH" "$STATE_DIR/hal-plugin/ipu75xa.so.pre-dol2"
        fi
        install -D -m 0755 -- "$PLUGIN_SRC" "$PLUGIN_PATH"
        install -D -m 0755 -- "$PLUGIN_SRC" "$STATE_DIR/hal-plugin/ipu75xa.so"
        echo "plugin: installed target build at $PLUGIN_PATH"
        return 0
    fi
    # 3. Fall back to our own previously-installed stable copy.
    if [[ -f $STATE_DIR/hal-plugin/ipu75xa.so ]]; then
        install -D -m 0755 -- "$STATE_DIR/hal-plugin/ipu75xa.so" "$PLUGIN_PATH"
        echo "plugin: restored stable copy at $PLUGIN_PATH"
        return 0
    fi
    # 4. Nothing available.
    echo "plugin: WARNING no plugin available (artifacts/ipu75xa.so or stable copy); leaving $PLUGIN_PATH untouched" >&2
    return 0
}

rollback_plugin() {
    if [[ -f $STATE_DIR/hal-plugin/ipu75xa.so.pre-dol2 ]]; then
        install -D -m 0755 -- "$STATE_DIR/hal-plugin/ipu75xa.so.pre-dol2" "$PLUGIN_PATH"
        echo "plugin: restored pre-DOL2 plugin"
    else
        echo "plugin: no pre-DOL2 backup; reinstall intel-ipu7-camera for the stock plugin"
    fi
}

# --- firmware ---
verify_firmware() {
    local fw
    fw=$(sha_of "$FIRMWARE_PATH")
    if [[ $fw == "$FIRMWARE_SHA256" ]]; then
        echo "firmware: matches pinned April hash"
    else
        echo "firmware: WARNING ${fw:-<absent>} != pinned $FIRMWARE_SHA256" >&2
    fi
}

# --- top-level actions ---
do_apply() {
    require_root
    apply_sensor_dkms
    apply_isys
    install_config
    apply_plugin
    verify_firmware
    echo "apply: complete. Reload modules or reboot to activate kernel-side changes."
}

do_install() {
    # User-level provisioning: download, build, graph check (no root).
    ensure_aiqb
    ensure_plugin
    require_graph
    # Privileged part (DKMS, ISYS overlay, config, plugin, hook) as root.
    need_root __install_privileged
    # Reached only when already running as root.
    do_apply
    do_install_hook
}

do_status() {
    local kver ph relative
    kver=$(uname -r)
    echo "== kernel: $kver =="
    echo "-- sensor driver (DKMS) --"
    dkms status "$SENSOR_NAME/$SENSOR_VERSION" 2>/dev/null || true
    if [[ -z $(dkms status "$SENSOR_NAME/$SENSOR_VERSION" 2>/dev/null) ]]; then
        echo "not registered with DKMS"
    fi
    if lsmod | grep '^sc200pc ' >/dev/null; then echo "loaded: yes"; else echo "loaded: no"; fi
    echo "-- ISYS dual-VC overlay --"
    if grep -q dual_vc_port "$IPU7_SRC/$ISYS_FILE" 2>/dev/null; then
        echo "overlay: applied"
    else
        echo "overlay: not applied"
    fi
    if [[ -f $MODEPROBE_CONF ]] && grep -qxF "options intel_ipu7_isys dual_vc_port=0" "$MODEPROBE_CONF"; then
        echo "modprobe: set"
    else
        echo "modprobe: NOT set"
    fi
    echo "-- HAL config --"
    for relative in "${MANAGED_FILES[@]}"; do
        if [[ -f $CAMERA_DIR/$relative ]]; then
            printf 'present  %s  %s\n' "$(sha_of "$CAMERA_DIR/$relative")" "$relative"
        else
            printf 'missing   -  %s\n' "$relative"
        fi
    done
    echo "-- HAL plugin --"
    ph=$(sha_of "$PLUGIN_PATH")
    echo "installed: ${ph:-<absent>}"
    if [[ $ph == "$REFERENCE_PLUGIN_SHA256" ]]; then
        echo "plugin: matches the reference build"
    else
        echo "plugin: differs from reference $REFERENCE_PLUGIN_SHA256 (expected for a from-source build)"
    fi
    echo "-- firmware --"
    verify_firmware
}

do_rollback() {
    require_root
    rollback_config
    revert_isys
    rollback_plugin
    echo "rollback: complete. Reload modules or reboot to activate kernel-side changes."
}

do_install_hook() {
    require_root
    [[ -f $HOOK_SRC ]] || fail "hook source not found: $HOOK_SRC"
    local repo_script="$SCRIPT_DIR/sc200pc-apply.sh"
    {
        echo '#!/usr/bin/env bash'
        echo '# Wrapper installed by: sc200pc-apply.sh install-hook'
        printf 'exec %q "$@"\n' "$repo_script"
    } >"$INSTALLED_SCRIPT"
    chmod 0755 "$INSTALLED_SCRIPT"
    install -D -m 0644 -- "$HOOK_SRC" "$HOOK_DST"
    echo "installed wrapper: $INSTALLED_SCRIPT -> $repo_script"
    echo "installed hook:    $HOOK_DST"
}

case ${1:-} in
    install) do_install ;;
    apply) need_root apply; do_apply ;;
    status) do_status ;;
    rollback) need_root rollback; do_rollback ;;
    install-hook) need_root install-hook; do_install_hook ;;
    __install_privileged) require_root; do_apply; do_install_hook ;;
    -h|--help|help) usage ;;
    *) usage >&2; exit 2 ;;
esac
