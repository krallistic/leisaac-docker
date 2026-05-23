#!/bin/bash
# setup-instance.sh  —  PHASE 2 of 2  (run AFTER setup-drivers.sh + reboot)
# Run ON THE GCP INSTANCE (as root or with sudo).
#
# Instead of installing Isaac Sim / IsaacLab by hand, we use the official
# NVIDIA isaac-lab:2.3.2 Docker image which ships everything pre-installed
# and tested. This script sets up Docker, builds the thin leisaac layer on
# top, and downloads the USD assets to a host volume.
#
# PREREQUISITE: setup-drivers.sh must have run first (it installs the host
# graphics + video-codec driver libraries and reboots). The gate in section
# 1b fails fast if that step was skipped.
#
# Re-running is idempotent.

set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="/workspace"

source "$SCRIPT_DIR/env.sh" 2>/dev/null || true

echo ""
echo "================================================================"
echo "leisaac GCP setup (Docker) — PHASE 2/2 — $(date)"
echo "================================================================"
echo ""

if [ "$EUID" -ne 0 ]; then
    echo "ERROR: run as root or with sudo: sudo bash $0"
    exit 1
fi

# === 1. NVIDIA driver check ===============================================
echo ">>> NVIDIA driver check..."
if ! nvidia-smi &>/dev/null; then
    echo "ERROR: nvidia-smi failed. Use the GCP Deep Learning VM image:"
    echo "       common-cu129-ubuntu-2204-nvidia-580 (deeplearning-platform-release)"
    echo "       If you just ran setup-drivers.sh, a reboot may still be pending."
    exit 1
fi
nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader
echo ""

# === 1b. Graphics + codec library gate (PHASE 1 prerequisite) =============
# Isaac Sim needs the NVIDIA graphics (Vulkan/RTX) and video-codec (NVENC for
# WebRTC) userspace libs ON THE HOST so the container toolkit can inject them.
# The GCP "-server" driver flavor omits these; setup-drivers.sh installs them.
echo ">>> Verifying host graphics + codec libraries (from setup-drivers.sh)..."
MISSING=""
ldconfig -p | grep -q 'libGLX_nvidia\.so'    || MISSING="${MISSING} libGLX_nvidia[Vulkan/RTX]"
ldconfig -p | grep -q 'libnvidia-encode\.so' || MISSING="${MISSING} libnvidia-encode[NVENC/WebRTC]"
ldconfig -p | grep -q 'libnvcuvid\.so'       || MISSING="${MISSING} libnvcuvid[NVDEC]"
if [ -n "$MISSING" ]; then
    echo ""
    echo "ERROR: missing host driver libraries:${MISSING}"
    echo "       Run PHASE 1 first (it installs them and reboots):"
    echo "           sudo bash ${SCRIPT_DIR}/setup-drivers.sh"
    exit 1
fi
echo ">>> Graphics + codec libraries present."
echo ""

# === 2. Docker + NVIDIA Container Toolkit =================================
echo ">>> Checking Docker..."
if ! command -v docker &>/dev/null; then
    echo ">>> Installing Docker..."
    curl -fsSL https://get.docker.com | sh
    systemctl enable --now docker
fi

echo ">>> Checking NVIDIA Container Toolkit..."
if ! dpkg -l nvidia-container-toolkit &>/dev/null 2>&1; then
    echo ">>> Installing NVIDIA Container Toolkit..."
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
        | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
    curl -sL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
        | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
        | tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
    apt-get update -qq
    apt-get install -y nvidia-container-toolkit
fi
nvidia-ctk runtime configure --runtime=docker
systemctl restart docker

# Quick GPU-in-container sanity check
echo ">>> Verifying GPU is visible in Docker..."
docker run --rm --gpus all ubuntu:22.04 nvidia-smi -L

# Verify the toolkit now injects the graphics + codec libs into the container
echo ">>> Verifying graphics + codec libs are injected into the container..."
docker run --rm --gpus all -e NVIDIA_DRIVER_CAPABILITIES=all \
    --entrypoint bash ubuntu:22.04 -c \
    'ldconfig -p | grep -E "libGLX_nvidia|libnvidia-encode|libnvcuvid"' \
    || echo "    WARNING: not all graphics/codec libs were injected — check toolkit + caps."
echo ""

# === 3. Pull base image ===================================================
echo ">>> Pulling nvcr.io/nvidia/isaac-lab:2.3.2 (may take 10-20 min, ~15 GB)..."
docker pull nvcr.io/nvidia/isaac-lab:2.3.2
echo ""

# === 4. Build leisaac image ===============================================
echo ">>> Building leisaac image..."
mkdir -p "$WORK_DIR"

LEISAAC_REPO="${LEISAAC_REPO:-https://github.com/LightwheelAI/leisaac.git}"
LEISAAC_BRANCH="${LEISAAC_BRANCH:-}"

docker build \
    --build-arg LEISAAC_REPO="${LEISAAC_REPO}" \
    --build-arg LEISAAC_BRANCH="${LEISAAC_BRANCH}" \
    -t leisaac:latest \
    "$WORK_DIR"
echo ">>> Image built: leisaac:latest"
echo ""

# === 5. Download USD assets to host ======================================
# Assets are mounted into the container at runtime — no GPU or Isaac Sim
# needed here; just plain Python + huggingface_hub on the host.
ASSETS_DIR="${WORK_DIR}/leisaac/assets"
EXPECTED_ASSET="${ASSETS_DIR}/scenes/kitchen_with_orange/scene.usd"

if [ ! -f "${EXPECTED_ASSET}" ]; then
    echo ">>> Downloading LeIsaac assets from HuggingFace (host Python)..."
    REAL_USER="${SUDO_USER:-$USER}"
    mkdir -p "${WORK_DIR}/leisaac"
    chown -R "${REAL_USER}:${REAL_USER}" "${WORK_DIR}"
    sudo apt-get install -y python3-pip -qq 2>/dev/null || true
    python3 -m pip install -q huggingface_hub
    sudo -u "${REAL_USER}" HF_HOME=/tmp/hf_cache python3 -c "
from huggingface_hub import snapshot_download
snapshot_download(
    repo_id='LightwheelAI/leisaac_env',
    repo_type='model',
    local_dir='${WORK_DIR}/leisaac'
)
print('Assets downloaded.')
"
else
    echo ">>> Assets already present — skipping download."
fi

if [ ! -f "${EXPECTED_ASSET}" ]; then
    echo "ERROR: Asset not found after download: ${EXPECTED_ASSET}"
    echo "Layout under leisaac/:"
    find "$WORK_DIR/leisaac" -maxdepth 4 -type d 2>/dev/null | head -20
    exit 1
fi
echo ">>> Assets OK."
echo ""

# === 6. Copy remaining bundle scripts =====================================
cp "$SCRIPT_DIR"/*.sh "$WORK_DIR/" 2>/dev/null || true
chmod +x "$WORK_DIR"/*.sh

echo "================================================================"
echo "Setup complete."
echo ""
echo "Run the smoke test:"
echo "    bash $WORK_DIR/test-isaac.sh"
echo "================================================================"