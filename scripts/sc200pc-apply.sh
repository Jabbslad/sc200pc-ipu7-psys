#!/usr/bin/env bash
# SC200PC PSYS deployment tool (self-contained).
#
# Installs / reports / rolls back everything needed to run the Samsung
# SC200PC front camera through the Intel IPU7 hardware ISP (PSYS) on
# Panther Lake, via icamerasrc/GStreamer.
#
# Artifacts you must supply in ./artifacts (verified by hash, never
# redistributed by this repo -- see README "Licensing"):
#   SC200PC_KAFC917_PTL.aiqb        OEM AIQB tuning
#   SC200PC_KAFC917.IPU75XA.bin     IPU75XA static graph (DOL2)
#   ipu75xa.so                      DOL2 HAL plugin build
#
# Usage: sc200pc-apply.sh apply|status|rollback|install|install-hook
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)

# Pinned identities (see README).
SENSOR_NAME=sc200pc
SENSOR_VERSION=0.9.0
IPU7_DKMS=ipu7-drivers/1.0.5
AIQB_SHA256=65b75702f33e880f9976cf51a3afa41e577dd33c1f1995e9a9fdfd1e29e5c99e
GRAPH_SHA256=c7fb4b2c96e9ffba6c87a902d235347a50dc81e52921347efca0003171c3a6cc
# Reference build's plugin hash. Override with your own build's hash when you
# compile from the pinned fork source (scripts/build-hal-plugin.sh); the source
# pin, not the binary hash, is the reproducibility anchor for from-source builds.
PLUGIN_SHA256=${PLUGIN_SHA256:-c3c37b89876d39531aa9980af44ac2759a292dfa8c53b070a76e4344893a4988}
FIRMWARE_SHA256=8ce12bc3c4355d589a8ad97bebbb036909e5985990ce1cf37789ce60fb52720f
CONFIG_SHA256=703616ce0ba9e709ee2d0ead6c0f6ba2ba39f3ad25d884f72f51b58739c41d9b
SENSOR_JSON_SHA256=31dff3d321898bc6bc9c8477d71e2d1f33238b477c515dd9a93c32ea0489b64e

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

MANAGED_FILES=(
    libcamhal_configs.json
    sensors/sc200pc-uf.json
    SC200PC_KAFC917_PTL.aiqb
    gcss/SC200PC_KAFC917.IPU75XA.bin
)

usage() {
    cat <<'EOF'
Usage: sc200pc-apply.sh apply|status|rollback|install|install-hook

  apply         Apply all SC200PC PSYS changes (no module reload).
  status        Report every managed component (read-only).
  rollback      Undo config, ISYS overlay, and HAL plugin changes.
  install       First-time setup: apply + install-hook.
  install-hook  Install the /usr/local/bin wrapper and the pacman hook.

Place these in ./artifacts first (verified by hash; see README):
  SC200PC_KAFC917_PTL.aiqb  SC200PC_KAFC917.IPU75XA.bin  ipu75xa.so
EOF
}

fail() { echo "error: $*" >&2; exit 1; }
require_root() { [[ $EUID -eq 0 ]] || fail "run this action through sudo"; }
sha_of() { sha256sum -- "$1" 2>/dev/null | awk '{print $1}'; }
verify_hash() { # path expected label
    [[ -f $1 ]] || fail "$3 missing: $1"
    [[ $(sha_of "$1") == "$2" ]] || fail "$3 has unexpected SHA-256: $1"
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

verify_config_sources() {
    verify_hash "$CONFIG_SRC/libcamhal_configs.json" "$CONFIG_SHA256" "libcamhal_configs.json"
    verify_hash "$CONFIG_SRC/sc200pc-uf.json" "$SENSOR_JSON_SHA256" "sc200pc-uf.json"
    verify_hash "$AIQB_SRC" "$AIQB_SHA256" "AIQB (artifacts/SC200PC_KAFC917_PTL.aiqb)"
    verify_hash "$GRAPH_SRC" "$GRAPH_SHA256" "graph (artifacts/SC200PC_KAFC917.IPU75XA.bin)"
}

install_config() {
    verify_config_sources
    backup_baseline
    install -D -m 0644 -- "$CONFIG_SRC/libcamhal_configs.json" "$CAMERA_DIR/libcamhal_configs.json"
    install -D -m 0644 -- "$CONFIG_SRC/sc200pc-uf.json" "$CAMERA_DIR/sensors/sc200pc-uf.json"
    install -D -m 0644 -- "$AIQB_SRC" "$CAMERA_DIR/SC200PC_KAFC917_PTL.aiqb"
    install -D -m 0644 -- "$GRAPH_SRC" "$CAMERA_DIR/gcss/SC200PC_KAFC917.IPU75XA.bin"
    echo "config: installed sensor JSON, libcamhal_configs, AIQB, and graph under $CAMERA_DIR"
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
    local installed src=""
    installed=$(sha_of "$PLUGIN_PATH")
    if [[ $installed == "$PLUGIN_SHA256" ]]; then
        echo "plugin: $PLUGIN_PATH already the DOL2 build"
        if [[ ! -f $STATE_DIR/hal-plugin/ipu75xa.so ]]; then
            install -D -m 0755 -- "$PLUGIN_PATH" "$STATE_DIR/hal-plugin/ipu75xa.so"
            echo "plugin: saved stable copy to $STATE_DIR/hal-plugin/ipu75xa.so"
        fi
        return 0
    fi
    if [[ -f $PLUGIN_SRC ]] && [[ $(sha_of "$PLUGIN_SRC") == "$PLUGIN_SHA256" ]]; then
        src="$PLUGIN_SRC"
    elif [[ -f $STATE_DIR/hal-plugin/ipu75xa.so ]] && [[ $(sha_of "$STATE_DIR/hal-plugin/ipu75xa.so") == "$PLUGIN_SHA256" ]]; then
        src="$STATE_DIR/hal-plugin/ipu75xa.so"
    fi
    if [[ -z $src ]]; then
        echo "plugin: WARNING installed ${installed:-<absent>} != pinned $PLUGIN_SHA256;" >&2
        echo "plugin: no matching build in artifacts/ or state; leaving plugin untouched" >&2
        return 0
    fi
    if [[ -f $PLUGIN_PATH ]] && [[ ! -f $STATE_DIR/hal-plugin/ipu75xa.so.pre-dol2 ]]; then
        install -D -m 0755 -- "$PLUGIN_PATH" "$STATE_DIR/hal-plugin/ipu75xa.so.pre-dol2"
    fi
    install -D -m 0755 -- "$src" "$PLUGIN_PATH"
    if [[ $src != "$STATE_DIR/hal-plugin/ipu75xa.so" ]]; then
        install -D -m 0755 -- "$src" "$STATE_DIR/hal-plugin/ipu75xa.so"
    fi
    echo "plugin: installed DOL2 build at $PLUGIN_PATH"
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
    if [[ $ph == "$PLUGIN_SHA256" ]]; then
        echo "plugin: matches pinned DOL2 build"
    else
        echo "plugin: differs from pinned $PLUGIN_SHA256"
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

do_install() {
    do_apply
    do_install_hook
}

case ${1:-} in
    apply) do_apply ;;
    status) do_status ;;
    rollback) do_rollback ;;
    install) do_install ;;
    install-hook) do_install_hook ;;
    -h|--help|help) usage ;;
    *) usage >&2; exit 2 ;;
esac
