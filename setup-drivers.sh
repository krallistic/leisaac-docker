#!/bin/bash
# setup-drivers.sh  —  PHASE 1 of 2  (run BEFORE setup-instance.sh)
# Run ON THE GCP INSTANCE, with sudo:   sudo bash setup-drivers.sh
#
# WHY THIS EXISTS
# The GCP Deep Learning VM image ships the "-server" NVIDIA driver flavor,
# which is COMPUTE-ONLY. nvidia-smi and CUDA work, but the userspace libraries
# Isaac Sim needs are absent:
#   - libGLX_nvidia.so / libnvidia-glvkspirv.so   -> Vulkan / RTX renderer
#   - libnvidia-encode.so (NVENC) / libnvcuvid.so -> WebRTC H.264 streaming
# The NVIDIA Container Toolkit injects these into the container FROM THE HOST
# (NVIDIA_DRIVER_CAPABILITIES=all requests graphics+video), so they must exist
# on the host first — otherwise: ERROR_INCOMPATIBLE_DRIVER (Vulkan) and
# "Couldn't initialize the capture device" / Net Stream 0x800E8401 (WebRTC).
#
# WHY IT REBOOTS
# The matching version is no longer in the apt repo (it only carries a newer
# patch), so installing these packages UPGRADES the whole driver userspace and
# the kernel-module package. The running (old) module then no longer matches
# the on-disk (new) userspace -> "driver/library version mismatch" until the
# new module is loaded. A reboot is the clean fix, so this script reboots.
#
# IDEMPOTENT: if the libraries are present and nvidia-smi is healthy, it does
# nothing. If they are present but nvidia-smi fails (install done, reboot
# pending), it just reboots.

set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ "$EUID" -ne 0 ]; then
    echo "ERROR: run as root or with sudo: sudo bash $0"
    exit 1
fi

echo "================================================================"
echo "leisaac driver setup — PHASE 1/2 — $(date)"
echo "================================================================"
echo ""

# --- Base driver (kernel module) must already be present ---------------------
if ! command -v nvidia-smi &>/dev/null; then
    echo "ERROR: nvidia-smi not found. Use the GCP Deep Learning VM image"
    echo "       (common-cu129-ubuntu-2204-nvidia-580) so the base driver is present."
    exit 1
fi

# --- Are the graphics + codec libs already present? --------------------------
have_libs() {
    ldconfig -p | grep -q 'libGLX_nvidia\.so' \
        && ldconfig -p | grep -q 'libnvidia-encode\.so' \
        && ldconfig -p | grep -q 'libnvcuvid\.so'
}

if have_libs; then
    echo ">>> Graphics + codec libraries already present."
    if nvidia-smi &>/dev/null; then
        echo ">>> nvidia-smi healthy — nothing to do."
        echo ">>> Proceed to PHASE 2:"
        echo "        sudo bash ${SCRIPT_DIR}/setup-instance.sh"
        exit 0
    fi
    echo "WARNING: libraries present but nvidia-smi fails — pending driver/library"
    echo "         version mismatch. Rebooting to load the matching kernel module."
    echo "         After reconnect, run: sudo bash ${SCRIPT_DIR}/setup-instance.sh"
    sleep 3
    reboot
    exit 0
fi

# --- Detect driver branch (e.g. 580) and package flavor (-server or "") ------
# CAUTION: when the kernel module isn't loaded, nvidia-smi prints
#   "NVIDIA-SMI has failed because it couldn't communicate with the NVIDIA driver"
# to STDOUT (not stderr), so `2>/dev/null` does NOT hide it and `cut -d.`
# yields that sentence as a bogus, non-empty "branch". So accept the nvidia-smi
# result ONLY if it's purely numeric; otherwise fall back to the installed
# package version, which is reliable even with the module unloaded.
BRANCH="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null \
          | head -1 | cut -d. -f1)"
if ! [[ "$BRANCH" =~ ^[0-9]+$ ]]; then
    BRANCH="$(dpkg -l 'libnvidia-compute-*' 2>/dev/null \
              | awk '/^ii/{print $2}' | grep -oE '[0-9]+' | head -1)"
fi
if ! [[ "$BRANCH" =~ ^[0-9]+$ ]]; then
    echo "ERROR: could not determine NVIDIA driver branch."
    echo "       nvidia-smi can't reach the driver and no libnvidia-compute-* package was found."
    echo "       Check: dpkg -l 'libnvidia-compute-*'   and   dmesg | grep -i nvidia"
    exit 1
fi

if dpkg -l "libnvidia-compute-${BRANCH}-server" &>/dev/null; then
    FLAVOR="-server"
elif dpkg -l "libnvidia-compute-${BRANCH}" &>/dev/null; then
    FLAVOR=""
else
    FLAVOR="-server"   # GCP DL VM default
fi

GL_PKG="libnvidia-gl-${BRANCH}${FLAVOR}"
ENC_PKG="libnvidia-encode-${BRANCH}${FLAVOR}"
DEC_PKG="libnvidia-decode-${BRANCH}${FLAVOR}"

echo ">>> Driver branch: ${BRANCH}   flavor: '${FLAVOR:-<none>}'"
echo ">>> Installing: ${GL_PKG} ${ENC_PKG} ${DEC_PKG}"
echo "    (no version pin — apt resolves a consistent set; this upgrades the"
echo "     driver userspace, hence the reboot below)"
echo ""

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y "${GL_PKG}" "${ENC_PKG}" "${DEC_PKG}"

echo ""
echo "================================================================"
echo "PHASE 1 complete — graphics + codec userspace installed."
echo ""
echo "REBOOT REQUIRED so the running kernel module matches the new"
echo "userspace (otherwise: 'driver/library version mismatch')."
echo ""
echo "Rebooting in 5s. After you reconnect, run PHASE 2:"
echo "    sudo bash ${SCRIPT_DIR}/setup-instance.sh"
echo "================================================================"
sleep 5
reboot