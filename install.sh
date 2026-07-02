#!/usr/bin/env bash
#
# XRT 2024.2 + Linux 6.17 (Ubuntu 24.04) installer for Alveo U50.
#
# Two modes:
#
#   --mode fast (default, ~3 minutes)
#     Install AMD's official 24.04 XRT deb, overlay 11 patched files onto
#     the DKMS source at /usr/src/xrt-2.18.0/, then rebuild DKMS.
#     Requires you to download xrt_*_24.04-amd64-xrt.deb from
#     https://www.amd.com/en/support/downloads/alveo-previous-downloads.html/accelerators/alveo/u50.html#alveotabs-item-vitis-tab
#     and place it under ./downloads/ (or pass --xrt-deb PATH).
#
#   --mode source (~30 minutes)
#     Clone XRT at the pinned tag, overlay the patched source files,
#     run xrtdeps.sh, build.sh -opt, make package, then apt install
#     the resulting deb (DKMS builds automatically at postinst).
#     Useful if you need to modify userspace, or if AMD ever pulls
#     the 24.04 deb.
#
# Common flags:
#   --mode fast|source        (default: fast)
#   --xrt-deb PATH            (fast mode) path to xrt_*_24.04-amd64-xrt.deb
#   --tag XRT_TAG             (source mode) override XRT tag (default: 202420.2.18.179)
#   --jobs N                  (source mode) build parallelism (default: nproc)
#   --skip-deps               (source mode) skip xrtdeps.sh
#   --skip-clone              (source mode) reuse existing ./XRT
#   -h | --help               show this help
#
# What neither mode does (AMD-copyright, still manual):
#   * Install U50 platform deb (Deployment tar.gz: base + validate)
#   * Install CMC / SC firmware (bundled in the same tar.gz)
#   * Install Development platform deb (optional, for Vitis xclbin build)
#   * Program the card's flash
#   Final banner prints exactly the commands to run.

set -euo pipefail

# ---------- config ----------
XRT_TAG_DEFAULT="202420.2.18.179"
DKMS_MODULE="xrt/2.18.0"
DKMS_SRC="/usr/src/xrt-2.18.0"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OVERLAY_DIR="$REPO_ROOT/xrt-overlay"
LOG_DIR="$REPO_ROOT/build-logs"

MODE="fast"
XRT_DEB=""
XRT_TAG="$XRT_TAG_DEFAULT"
JOBS="$(nproc)"
SKIP_DEPS=0
SKIP_CLONE=0

# ---------- arg parse ----------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)       MODE="$2";       shift 2 ;;
    --xrt-deb)    XRT_DEB="$2";    shift 2 ;;
    --tag)        XRT_TAG="$2";    shift 2 ;;
    --jobs)       JOBS="$2";       shift 2 ;;
    --skip-deps)  SKIP_DEPS=1;     shift   ;;
    --skip-clone) SKIP_CLONE=1;    shift   ;;
    -h|--help)    sed -n '/^# XRT 2024.2/,/^$/{s/^# \{0,1\}//;p}' "$0"; exit 0 ;;
    *)            echo "Unknown option: $1"; exit 2 ;;
  esac
done

case "$MODE" in
  fast|source) ;;
  *) echo "Invalid --mode: $MODE (must be fast or source)"; exit 2 ;;
esac

# ---------- helpers ----------
c_g='\033[1;32m'; c_r='\033[1;31m'; c_y='\033[1;33m'; c_z='\033[0m'
say()  { echo -e "${c_g}==> $*${c_z}"; }
warn() { echo -e "${c_y}!!  $*${c_z}"; }
die()  { echo -e "${c_r}XX  $*${c_z}" >&2; exit 1; }

as_root() {
  if [[ $EUID -eq 0 ]]; then "$@"; else sudo "$@"; fi
}

mkdir -p "$LOG_DIR"

# ---------- overlay path map (source layout → DKMS flattened layout) ----------
# Format: <source-relative-path>|<dkms-relative-path>
# The DKMS layout under /usr/src/xrt-2.18.0/ flattens common/drv/include/
# to driver/include/, but keeps xocl/ as-is under driver/xocl/.
OVERLAY_MAP=(
  "src/runtime_src/core/pcie/driver/linux/xocl/xocl_drv.h|driver/xocl/xocl_drv.h"
  "src/runtime_src/core/pcie/driver/linux/xocl/userpf/Makefile|driver/xocl/userpf/Makefile"
  "src/runtime_src/core/pcie/driver/linux/xocl/mgmtpf/Makefile|driver/xocl/mgmtpf/Makefile"
  "src/runtime_src/core/pcie/driver/linux/xocl/lib/libqdma/QDMA/linux-kernel/driver/libqdma/qdma_compat.h|driver/xocl/lib/libqdma/QDMA/linux-kernel/driver/libqdma/qdma_compat.h"
  "src/runtime_src/core/pcie/driver/linux/xocl/subdev/p2p.c|driver/xocl/subdev/p2p.c"
  "src/runtime_src/core/common/drv/include/xrt_cu.h|driver/include/xrt_cu.h"
  "src/runtime_src/core/pcie/driver/linux/xocl/userpf/xocl_drv.c|driver/xocl/userpf/xocl_drv.c"
  "src/runtime_src/core/pcie/driver/linux/xocl/lib/libxdma.c|driver/xocl/lib/libxdma.c"
  "src/runtime_src/core/pcie/driver/linux/xocl/userpf/xocl_drm.c|driver/xocl/userpf/xocl_drm.c"
  "src/runtime_src/core/pcie/driver/linux/xocl/subdev/xiic.c|driver/xocl/subdev/xiic.c"
  "src/runtime_src/core/pcie/driver/linux/xocl/subdev/ulite.c|driver/xocl/subdev/ulite.c"
)

# ---------- preflight (shared) ----------
say "[1/N] preflight"

if [[ -f /etc/os-release ]]; then
  . /etc/os-release
  echo "  OS: $PRETTY_NAME"
  [[ "$ID" == "ubuntu" ]] || warn "not Ubuntu (ID=$ID); tested on 24.04 only"
fi

KREL="$(uname -r)"
KHDR="/lib/modules/$KREL/build"
echo "  Kernel: $KREL"
[[ -d "$KHDR" ]] || die "kernel headers not found (apt install linux-headers-$KREL)"

[[ -d "$OVERLAY_DIR" ]] || die "overlay dir missing: $OVERLAY_DIR"
OVERLAY_FILES=$(find "$OVERLAY_DIR" -type f | wc -l)
echo "  Overlay files: $OVERLAY_FILES"
(( OVERLAY_FILES == 11 )) || warn "expected 11 overlay files, found $OVERLAY_FILES"

echo "  Mode: $MODE"

# ---------- overlay function (source layout → DKMS) ----------
apply_overlay_to_dkms() {
  say "overlay 11 patched files onto $DKMS_SRC (with path flattening)"
  local pair src dst missing=0
  for pair in "${OVERLAY_MAP[@]}"; do
    src="${pair%%|*}"
    dst="${pair##*|}"
    if [[ ! -f "$OVERLAY_DIR/$src" ]]; then
      warn "  MISSING in overlay: $src"
      missing=$((missing+1))
      continue
    fi
    as_root install -m 644 -D "$OVERLAY_DIR/$src" "$DKMS_SRC/$dst"
    echo "  ✓ $dst"
  done
  (( missing == 0 )) || die "$missing overlay file(s) missing under $OVERLAY_DIR"

  # sanity: verify signatures landed
  declare -A CHECKS=(
    ["driver/xocl/xocl_drv.h"]="linux/vmalloc.h"
    ["driver/xocl/userpf/xocl_drm.c"]="FOP_UNSIGNED_OFFSET"
    ["driver/xocl/subdev/p2p.c"]="device_iommu_mapped"
    ["driver/include/xrt_cu.h"]="timer_container_of"
  )
  for f in "${!CHECKS[@]}"; do
    grep -q "${CHECKS[$f]}" "$DKMS_SRC/$f" \
      || die "post-overlay check failed: '${CHECKS[$f]}' not in $f"
  done
  say "  overlay verified"
}

# ==================================================================
#                              FAST MODE
# ==================================================================
if [[ "$MODE" == "fast" ]]; then
  say "[2/6] install prereqs (dkms, rsync, kernel headers)"
  as_root apt-get update -qq
  as_root apt-get install -y --no-install-recommends \
    dkms rsync ca-certificates \
    linux-headers-"$KREL" \
    2>&1 | tee "$LOG_DIR/apt-prereqs.log"

  # locate XRT deb
  if [[ -z "$XRT_DEB" ]]; then
    XRT_DEB=$(ls -1 "$REPO_ROOT"/downloads/xrt_*_24.04-amd64-xrt.deb 2>/dev/null | head -1 || true)
  fi
  if [[ -z "$XRT_DEB" || ! -f "$XRT_DEB" ]]; then
    cat <<EOF

${c_r}Cannot find AMD's official XRT deb.${c_z}

Please download from:
  https://www.amd.com/en/support/downloads/alveo-previous-downloads.html/accelerators/alveo/u50.html#alveotabs-item-vitis-tab

Select the "Vitis 2024.2" tab and download:
  xrt_202420.2.18.179_24.04-amd64-xrt.deb  (~18 MB)

Then either:
  1. Place it under $REPO_ROOT/downloads/  and rerun this script, or
  2. Pass its path with --xrt-deb /path/to/xrt_*.deb

EOF
    exit 1
  fi
  say "[3/6] using XRT deb: $(basename "$XRT_DEB")"

  # apt install XRT deb -- DKMS build will FAIL here (that's OK)
  say "[4/6] apt install XRT deb (DKMS build expected to FAIL on kernel >=6.10)"
  # `|| true` because DKMS failure is expected and we handle it next
  as_root apt install -y "$XRT_DEB" 2>&1 | tee "$LOG_DIR/apt-install-xrt.log" || true

  [[ -d "$DKMS_SRC" ]] || die "DKMS source not found at $DKMS_SRC (apt install probably didn't finish)"

  # apply overlay onto DKMS source
  say "[5/6] apply overlay to DKMS source"
  apply_overlay_to_dkms

  # rebuild DKMS
  say "[6/6] rebuild DKMS module ($DKMS_MODULE)"
  as_root dkms remove "$DKMS_MODULE" --all 2>/dev/null || true
  as_root dkms install "$DKMS_MODULE" 2>&1 | tee "$LOG_DIR/dkms-install.log"

# ==================================================================
#                             SOURCE MODE
# ==================================================================
else
  XRT_DIR="$REPO_ROOT/XRT"

  say "[2/9] install build prereqs (git, cmake, dkms, build-essential)"
  as_root apt-get update -qq
  as_root apt-get install -y --no-install-recommends \
    git cmake build-essential dkms rsync curl ca-certificates \
    linux-headers-"$KREL" \
    2>&1 | tee "$LOG_DIR/apt-prereqs.log"

  # clone XRT
  if (( SKIP_CLONE )); then
    say "[3/9] skip clone, reusing $XRT_DIR"
    [[ -d "$XRT_DIR/.git" ]] || die "$XRT_DIR is not a git repo"
  else
    if [[ -d "$XRT_DIR/.git" ]]; then
      say "[3/9] XRT exists; checking out $XRT_TAG"
      (cd "$XRT_DIR" && git fetch --tags origin && git checkout -f "$XRT_TAG")
    else
      say "[3/9] clone XRT tag $XRT_TAG"
      git clone --branch "$XRT_TAG" --depth 1 https://github.com/Xilinx/XRT.git "$XRT_DIR"
    fi
  fi

  say "[4/9] init submodules"
  (cd "$XRT_DIR" && git submodule update --init --recursive --depth 1 --jobs 4) \
    2>&1 | tee "$LOG_DIR/submodule.log"

  say "[5/9] overlay 11 patched files onto XRT source tree"
  rsync -av --checksum "$OVERLAY_DIR/" "$XRT_DIR/" 2>&1 | tee "$LOG_DIR/overlay.log"

  if (( SKIP_DEPS )); then
    say "[6/9] skip xrtdeps.sh"
  else
    say "[6/9] run xrtdeps.sh (installs XRT's own deps; may take a while)"
    as_root "$XRT_DIR/src/runtime_src/tools/scripts/xrtdeps.sh" \
      2>&1 | tee "$LOG_DIR/xrtdeps.log"
  fi

  say "[7/9] build XRT userspace (build.sh -opt, -j${JOBS})"
  (cd "$XRT_DIR/build" && ./build.sh -opt -j"$JOBS") \
    2>&1 | tee "$LOG_DIR/build.log"

  say "[7/9] make package"
  (cd "$XRT_DIR/build/Release" && make package -j"$JOBS") \
    2>&1 | tee "$LOG_DIR/package.log"

  XRT_DEB_BUILT=$(ls -1 "$XRT_DIR"/build/Release/xrt_*-amd64-xrt.deb 2>/dev/null | head -1) \
    || die "xrt_*-xrt.deb not produced"
  echo "  built: $(basename "$XRT_DEB_BUILT")"

  say "[8/9] apt install self-built XRT deb (triggers DKMS build)"
  as_root apt install -y "$XRT_DEB_BUILT" 2>&1 | tee "$LOG_DIR/apt-install-xrt.log"

  say "[9/9] verify DKMS"
fi

# ---------- verify (shared) ----------
echo "--- dkms status ---"
dkms status | tee "$LOG_DIR/dkms-status.txt"
if ! dkms status | grep -q "^xrt.*installed"; then
  warn "DKMS not showing installed; see $LOG_DIR/dkms-status.txt and"
  warn "  /var/lib/dkms/xrt/2.18.0/build/make.log"
fi

if [[ -x /opt/xilinx/xrt/bin/xbutil ]]; then
  # shellcheck disable=SC1091
  source /opt/xilinx/xrt/setup.sh 2>/dev/null || true
  echo "--- xbutil --version ---"
  xbutil --version || true
fi

cat <<EOF

$(echo -e "${c_g}=========================================================================${c_z}")
XRT + DKMS ready. Remaining manual steps for Alveo U50 bring-up:

  1. Source XRT env:
       source /opt/xilinx/xrt/setup.sh

  2. Download from AMD (Vitis 2024.2 tab):
     https://www.amd.com/en/support/downloads/alveo-previous-downloads.html/accelerators/alveo/u50.html#alveotabs-item-vitis-tab

       * Deployment Target Platform  (xilinx-u50-gen3x16-xdma_*_all.deb.tar.gz)
       * Development Target Platform (only if you use Vitis to build xclbin)

     Extract the deployment tar.gz to get 4 deb files:
       xilinx-cmc-u50_*.deb                        # CMC firmware
       xilinx-sc-fw-u50_*.deb                      # Satellite controller firmware
       xilinx-u50-gen3x16-xdma-base_5-*.deb        # shell bitstream
       xilinx-u50-gen3x16-xdma-validate_5-*.deb    # validate xclbin

     Install:
       tar xzf xilinx-u50-gen3x16-xdma_*_all.deb.tar.gz
       sudo apt install ./xilinx-cmc-u50_*.deb \\
                        ./xilinx-sc-fw-u50_*.deb \\
                        ./xilinx-u50-gen3x16-xdma-base_5-*.deb \\
                        ./xilinx-u50-gen3x16-xdma-validate_5-*.deb

  3. Physically install the U50 card, FULL power off (not reboot), then on.

  4. Flash shell:
       sudo /opt/xilinx/xrt/bin/xbmgmt examine
       sudo /opt/xilinx/xrt/bin/xbmgmt program --base --device <bdf>
       # FULL power cycle again (SC latches only on 12V rail drop)

  5. Validate:
       sudo /opt/xilinx/xrt/bin/xbutil validate --device <bdf>

Logs from this run: $LOG_DIR/
$(echo -e "${c_g}=========================================================================${c_z}")
EOF
