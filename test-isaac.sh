#!/bin/bash
# test-isaac.sh
# Run ON THE GCP INSTANCE.
#
# Key facts:
#  - The container ENTRYPOINT starts the streaming app; override with --entrypoint.
#  - python.sh sets up the full Kit runtime (needed for pxr / gymnasium env registration).
#  - /workspace/leisaac/ shadows the real package as a namespace; PYTHONPATH fix required.
#  - Vulkan fails on T4 (RTX renderer unusable) but Kit still starts and runs physics/sim.

set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env.sh" 2>/dev/null || true

WORK_DIR="${REMOTE_WORK:-/workspace}"
PUBLIC_IP="${GCP_EXTERNAL_IP:-}"
SIGNAL="${SIGNAL_PORT:-49100}"
PYTHON="/isaac-sim/kit/python/bin/python3.11"
LEISAAC_SRC="/workspace/leisaac/source/leisaac"

mkdir -p ~/docker/leisaac/cache/ov
mkdir -p ~/docker/leisaac/cache/computecache
mkdir -p ~/docker/leisaac/logs

# Common docker flags
BASE_FLAGS=(
    --rm --gpus all --network=host
    --entrypoint bash
    -e ACCEPT_EULA=Y
    -e PRIVACY_CONSENT=Y
    -e NVIDIA_DRIVER_CAPABILITIES=all
    # Prepend real leisaac source so Python finds the proper package, not the
    # /workspace/leisaac namespace-package shadow.
    -e PYTHONPATH=${LEISAAC_SRC}
    -v "${WORK_DIR}/leisaac/assets:/workspace/leisaac/assets"
    -v ~/docker/leisaac/cache/ov:/isaac-sim/.cache:rw
    -v ~/docker/leisaac/cache/computecache:/isaac-sim/.nv/ComputeCache:rw
    -v ~/docker/leisaac/logs:/isaac-sim/.nvidia-omniverse/logs:rw
    -v /usr/share/vulkan/icd.d:/usr/share/vulkan/icd.d:ro
)

# --- Stage 1: lightweight import check (no Kit runtime needed) ---------------
echo ">>> Stage 1: Import check..."
docker run "${BASE_FLAGS[@]}" leisaac:latest -c "
export PYTHONPATH=${LEISAAC_SRC}:\$PYTHONPATH
source /isaac-sim/setup_python_env.sh
$PYTHON - << 'PYEOF'
import sys
print(f'Python: {sys.version.split()[0]}')

import torch
print(f'PyTorch: {torch.__version__}, CUDA: {torch.cuda.is_available()}')
if torch.cuda.is_available():
    print(f'  GPU:  {torch.cuda.get_device_name(0)}')
    print(f'  VRAM: {torch.cuda.get_device_properties(0).total_memory/1e9:.1f} GB')

import leisaac
print(f'LeIsaac path: {leisaac.__file__}')
# pxr (USD) is only available with Kit runtime, so tasks can not register here.
# That is expected — registration is verified implicitly in stage 2.
print()
print('Stage 1 OK.')
PYEOF
"

echo ""
echo ">>> Stage 1 passed."
echo ""

# --- Stage 2: full teleop with Kit runtime ------------------------------------
# Uses python.sh as entrypoint, which boots the full Kit/Isaac Sim runtime.
# Kit provides pxr, which allows leisaac.tasks to register gymnasium envs.
echo ">>> Stage 2: Launching LeIsaac-SO101-PickOrange-v0 with WebRTC"
echo ">>> First launch: 2-5 min for shader cache warmup."
if [ -n "$PUBLIC_IP" ]; then
    echo ">>> WebRTC endpoint: ${PUBLIC_IP}:${SIGNAL}"
else
    echo ">>> GCP_EXTERNAL_IP not set — use SSH tunnel:"
    echo "    http://localhost:8211/streaming/webrtc-client/"
fi
echo ""

KIT_ARGS="--/rtx/verifyDriverVersion/enabled=false"
if [ -n "$PUBLIC_IP" ]; then
    KIT_ARGS="--/app/livestream/publicEndpointAddress=${PUBLIC_IP} --/app/livestream/port=${SIGNAL} ${KIT_ARGS}"
fi

docker run --rm --gpus all --network=host \
    --entrypoint /isaac-sim/python.sh \
    -e ACCEPT_EULA=Y \
    -e PRIVACY_CONSENT=Y \
    -e NVIDIA_DRIVER_CAPABILITIES=all \
    -e PYTHONPATH=${LEISAAC_SRC} \
    -v "${WORK_DIR}/leisaac/assets:/workspace/leisaac/assets" \
    -v ~/docker/leisaac/cache/ov:/isaac-sim/.cache:rw \
    -v ~/docker/leisaac/cache/computecache:/isaac-sim/.nv/ComputeCache:rw \
    -v ~/docker/leisaac/logs:/isaac-sim/.nvidia-omniverse/logs:rw \
    -v /usr/share/vulkan/icd.d:/usr/share/vulkan/icd.d:ro \
    leisaac:latest \
    /workspace/leisaac/scripts/environments/teleoperation/teleop_se3_agent.py \
        --task=LeIsaac-SO101-PickOrange-v0 \
        --teleop_device=so101leader \
        --remote_endpoint=tcp://localhost:5556 \
        --num_envs=1 --device=cuda --headless --enable_cameras \
        --livestream 1 \
        --kit_args="${KIT_ARGS}"