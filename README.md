# sc200pc-ipu7-psys

Linux enablement for the **Samsung SC200PC** front camera (ACPI `SSLC2000`) on
**Intel Panther Lake IPU7** (`8086:b05d`), using the **hardware ISP (PSYS)**
path: SC200PC sensor → IPU7 ISYS → IPU7 PSYS → NV12, exposed through the Intel
HAL via `icamerasrc`/GStreamer.

The SC200PC is a DOL2 HDR sensor: it reads out two 1928×1088 RAW10 virtual
channels (long + short exposure) that the IPU7 merges into 1920×1080 NV12.

## What this repo ships (all original code)

| Path | Contents |
|---|---|
| `driver/` | `sc200pc.c` V4L2 subdev driver (dual-VC streams) + DKMS packaging |
| `config/` | `sc200pc-uf.json` sensor descriptor; `libcamhal_configs.json` (Intel Apache-2.0, SC200PC entry added, header preserved) |
| `overlay/` | `ipu7-isys-dualvc-default-route.patch` — ISYS dual-VC route for CSI2 port 0 |
| `scripts/sc200pc-apply.sh` | single idempotent deployment tool (`apply`/`status`/`rollback`/`install`) |
| `scripts/download-windows-driver.sh` | downloads the Samsung OEM package (source of the AIQB) |
| `scripts/sc200pc-reapply.hook` | pacman hook that re-applies after an `intel-ipu7-camera` upgrade |

## What you must supply (not distributed here)

These are OEM/Intel artifacts with **unresolved redistribution rights**, so they
are **not committed**. Place them in `./artifacts/` (git-ignored); the tool
verifies each by SHA-256 and refuses to install a mismatch. (`ipu75xa.so` is
built from source — its hash is environment-specific; see "Building the HAL
plugin" below.)

| File | SHA-256 | Source |
|---|---|---|
| `SC200PC_KAFC917_PTL.aiqb` | `65b75702…5c99e` | Samsung OEM package (`scripts/download-windows-driver.sh`, then extract `camera/SC200PC_KAFC917_PTL.aiqb`) |
| `SC200PC_KAFC917.IPU75XA.bin` | `c7fb4b2c…a6cc` | IPU75XA DOL2 static graph — **obtained out-of-band** (a project release asset or the private investigation repo). See "The graph" below. |
| `ipu75xa.so` | `c3c37b89…4988` (reference) | Build from the project fork — `scripts/build-hal-plugin.sh` clones `github.com/Jabbslad/ipu7-camera-hal` branch `sc200pc-dol2` (pinned source `73fbf90…`). See "Building the HAL plugin" below. |

## Prerequisites

- Panther Lake system with IPU7P5 and the SC200PC (`ACPI\SSLC2000`).
- The `intel-ipu7-camera` stack: IPU7 kernel drivers (DKMS), April firmware, and
  the proprietary `libia_*` libraries (Intel's `ipu7-camera-bins`).
- `dkms`, kernel headers for your running kernel, `patch`, `gst-plugins-*`.

## Install

```sh
# 1. Obtain the artifacts (see table above) and drop them into ./artifacts/
#    e.g. the AIQB from the Samsung package:
./scripts/download-windows-driver.sh        # downloads + extracts the OEM package

# 2. First-time setup (DKMS sensor driver, ISYS overlay, HAL config, hook):
sudo ./scripts/sc200pc-apply.sh install

# 3. Activate the kernel-side changes:
sudo modprobe -r sc200pc intel_ipu7_isys && sudo modprobe intel_ipu7_isys && sudo modprobe sc200pc
#    (or reboot)
```

`sc200pc-apply.sh status` reports every component and its hash at any time.
`sc200pc-apply.sh rollback` undoes the config, ISYS overlay, and HAL plugin.

## What survives what

| Event | Mechanism |
|---|---|
| Kernel upgrade | DKMS auto-rebuilds `sc200pc` and the patched `ipu7-drivers` |
| `pacman -Syu intel-ipu7-camera` | the pacman hook re-runs `sc200pc-apply.sh apply` |

## The graph

The IPU75XA static graph is **not** in this repo and there is no generator here.
It cannot be produced by patching an existing graph: the April Linux reader uses
a different binary ABI than the Windows generation that produced the OEM graph
(records are 6260 bytes vs the OEM's 6244, fields at different offsets, unpacked
instead of packed RAW10), so it is a full decode/re-serialize, not a byte diff —
and a diff would be OEM-derived anyway. Obtain the validated graph
(`c7fb4b2c…`) out-of-band and let the tool verify it.

## Building the HAL plugin

`ipu75xa.so` is Intel's IPU75XA HAL plugin (Apache-2.0) with the project's
SC200PC DOL2 enablement layered on top. It is **not** a binary download — you
build it from the project fork of Intel's `ipu7-camera-hal`.

The fork branch `sc200pc-dol2` is Intel's April release tag (`ef307675` /
`20260406_1900_297`) plus 18 SC200PC DOL2 commits. The build script pins the
exact source commit, so the build is reproducible **from source**; the resulting
binary hash is environment-specific and only matches the reference `c3c37b89…`
on the reference machine.

```sh
./scripts/build-hal-plugin.sh   # clones the fork, builds, writes artifacts/ipu75xa.so
# then install using your build's hash (printed by the script):
sudo PLUGIN_SHA256=<your-build-hash> ./scripts/sc200pc-apply.sh apply
```

Building requires the Intel IPU7 camera dev dependencies (AIQ/CCA/AIC headers
and libraries from `ipu7-camera-bins`) plus `cmake` and the usual HAL build deps.

## Licensing

- `driver/sc200pc.c` and the scripts: **GPL-2.0-only**.
- `config/libcamhal_configs.json`: derived from Intel's **Apache-2.0** file; the
  Intel copyright/license header is preserved and the SC200PC entry was added.
- `config/sc200pc-uf.json`, `overlay/*.patch`: original, GPL-2.0-only.
- The **AIQB**, **static graph**, Intel **firmware**, and Intel **`libia_*`
  libraries** are Samsung/Intel proprietary. They are **not redistributed** by
  this repo; you obtain them yourself. Redistribution rights for the AIQB and
  graph are **not established** — review the Intel Limited Distribution document
  in the Samsung package before any production or public redistribution.

## Status

Short-stream proof only: 1920×1080 NV12 at ~30 fps through `icamerasrc`, with
AE/AWB convergence on a static scene. Sustained (30-minute), suspend/resume,
reopen, privacy, and application-integration validation are **not** complete.
