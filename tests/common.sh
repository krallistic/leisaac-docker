#!/bin/bash
# common.sh — shared setup sourced by the test-*.sh scripts in this tests/ dir.
# Not meant to be run directly. Source it:  source "$SCRIPT_DIR/common.sh"
#
# Layout: this file lives in <bundle>/tests/ ; env.sh, keys.sh and the leisaac
# assets live one level up in <bundle>/. BUNDLE_DIR resolves that parent.
#
# Key facts (apply to all tests):
#  - The container ENTRYPOINT starts the streaming app; override with --entrypoint.
#  - python.sh boots the full Kit runtime (needed for pxr / gymnasium env registration).
#  - /workspace/leisaac/ shadows the real package as a namespace; PYTHONPATH fix required.
#  - --network=host is REQUIRED for WebRTC (host IP unreachable from a bridged netns).
#  - The container runs as user 'kiosk', so cache dirs live under /isaac-sim/...
#    (NOT /root/...). We persist ALL FIVE caches on the host so startup doesn't
#    recompile shaders every run: kit + ov + glcache + computecache + pip.
#    Missing the kit/glcache mounts is the usual cause of slow re-launches.
#  - All runs share a fixed --name ($CONTAINER_NAME) so you can stop/kill from
#    another shell:  docker stop leisaac   (or: docker kill leisaac).
#  - STREAMING IS ALWAYS OVER TAILSCALE. Isaac Sim's UDP media (47998) does not
#    traverse public-internet NAT, so the streaming tests advertise the VM's
#    tailnet IP and refuse to run if Tailscale is not up. There is no public-IP
#    fallback. The live `tailscale ip -4` is preferred over env.sh's STREAM_IP
#    so a changed tailnet IP is picked up automatically.

# This file's dir (tests/), and the bundle root one level up.
COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE_DIR="$(cd "$COMMON_DIR/.." && pwd)"
source "$BUNDLE_DIR/env.sh" 2>/dev/null || true

WORK_DIR="${REMOTE_WORK:-/workspace}"
SIGNAL="${SIGNAL_PORT:-49100}"
PYTHON="/isaac-sim/kit/python/bin/python3.11"
LEISAAC_SRC="/workspace/leisaac/source/leisaac"
IMAGE="${LEISAAC_IMAGE:-leisaac:latest}"
CONTAINER_NAME="${CONTAINER_NAME:-leisaac}"

# Always stream over Tailscale. Prefer the live tailnet IP (handles a changed
# IP after re-up); fall back to the STREAM_IP recorded in env.sh by
# setup-tailscale.sh. Never use the public GCP IP for streaming.
TS_LIVE_IP="$(command -v tailscale >/dev/null 2>&1 && tailscale ip -4 2>/dev/null | head -1)"
STREAM_IP="${TS_LIVE_IP:-${STREAM_IP:-}}"

# --- Persistent cache dirs on the data disk ----------------------------------
# All five Isaac Sim caches live on the persistent disk so shader compilation
# survives VM recreation (only pays the cost once per disk lifetime).
# WORK_DIR is /data (from REMOTE_WORK in env.sh), so these paths resolve to
# /data/docker/leisaac/cache/* and /data/docker/leisaac/logs.
CACHE_ROOT="${WORK_DIR}/docker/leisaac/cache"
mkdir -p "$CACHE_ROOT"/{kit,ov,glcache,computecache,pip}
mkdir -p "${WORK_DIR}/docker/leisaac/logs"

# Remove a stale container of the same name left by an unclean exit (SIGKILL,
# daemon restart) so re-runs don't hit "name already in use". Plain `docker rm`
# (no -f) only removes a STOPPED container — a still-running session is left
# alone, so the docker run below will fail loudly if one is already up, which
# is what you want (stop it first: docker stop $CONTAINER_NAME).
docker rm "$CONTAINER_NAME" >/dev/null 2>&1 || true

# Docker flags shared by every container run.
COMMON_FLAGS=(
    --rm --name "$CONTAINER_NAME" --gpus all --network=host
    -e ACCEPT_EULA=Y
    -e PRIVACY_CONSENT=Y
    -e NVIDIA_DRIVER_CAPABILITIES=all
    # Prepend real leisaac source so Python finds the proper package, not the
    # /workspace/leisaac namespace-package shadow.
    -e PYTHONPATH="${LEISAAC_SRC}"
    -v "${WORK_DIR}/leisaac/assets:/workspace/leisaac/assets"
    # --- all five caches (container runs as 'kiosk' -> /isaac-sim paths) ---
    -v "${CACHE_ROOT}/kit:/isaac-sim/kit/cache:rw"
    -v "${CACHE_ROOT}/ov:/isaac-sim/.cache/ov:rw"
    -v "${CACHE_ROOT}/glcache:/isaac-sim/.cache/nvidia/GLCache:rw"
    -v "${CACHE_ROOT}/computecache:/isaac-sim/.nv/ComputeCache:rw"
    -v "${CACHE_ROOT}/pip:/isaac-sim/.cache/pip:rw"
    -v "${WORK_DIR}/docker/leisaac/logs:/isaac-sim/.nvidia-omniverse/logs:rw"
    -v /usr/share/vulkan/icd.d:/usr/share/vulkan/icd.d:ro
)

# Hard requirement for the streaming tests: a tailnet IP must be available.
# (The import-only test does not call this, so it runs without Tailscale.)
require_tailscale() {
    if [ -n "$STREAM_IP" ]; then
        return 0
    fi
    echo "ERROR: these tests stream only over Tailscale, but no tailnet IP is available."
    if command -v tailscale >/dev/null 2>&1; then
        echo "       Tailscale is installed but not up. Bring it up:"
        echo "           sudo tailscale up"
    else
        echo "       Tailscale is not installed. Run:"
        echo "           sudo bash $BUNDLE_DIR/setup-tailscale.sh"
    fi
    echo "       (setup-tailscale.sh installs it, brings it up, and records STREAM_IP in env.sh.)"
    exit 1
}

# Build the KIT_ARGS string for livestream runs and print the endpoint banner.
# Enforces Tailscale and sets the globals KIT_ARGS and PUBLIC_IP.
build_kit_args() {
    require_tailscale
    PUBLIC_IP="$STREAM_IP"
    KIT_ARGS="--/app/livestream/publicEndpointAddress=${STREAM_IP} --/app/livestream/port=${SIGNAL} --/rtx/verifyDriverVersion/enabled=false"
    echo ">>> WebRTC endpoint (Tailscale): ${STREAM_IP}:${SIGNAL}"
    echo ">>> Connect the Isaac Sim WebRTC client to: ${STREAM_IP}"
    echo ">>> Container name: ${CONTAINER_NAME}  (stop from another shell: docker stop ${CONTAINER_NAME})"
    echo ">>> First launch warms the shader cache (slow); later launches reuse ${CACHE_ROOT}."
}