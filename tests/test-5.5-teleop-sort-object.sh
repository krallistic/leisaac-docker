#!/bin/bash
# test-5.5-teleop-sort-object.sh — SO-101 leader teleop in the custom SortObject
# environment with WebRTC streaming.
#
# This combines test-4.5 (SortObject scene, baked-in assets) with test-5
# (SO-101 leader teleop over ZMQ). Run test-4.5 first to confirm the scene
# loads cleanly; the only new variable here is the SO-101 leader teleop path.
#
# NOTE: `connect_to localhost port 5556: failed` lines are the SO-101 ZMQ
# leader endpoint and are EXPECTED until a leader is connected — they do not
# affect streaming. The leader publisher (so101_joint_state_server.py) runs on
# your laptop and reaches the VM via the RemoteForward 5556 SSH tunnel (or
# directly over Tailscale). Press `b` in the streamed view to start teleoperation.
#
# Usage:
#   bash test-5.5-teleop-sort-object.sh [VARIANT]
#
#   VARIANT  shape-color pair (case-insensitive).  Examples:
#              cube-red  cube-green  cube-yellow
#              rectangle-red  rectangle-blue  rectangle-green  rectangle-yellow
#              cylinder-red   cylinder-blue   cylinder-green
#            Defaults to cube-red.
#
#   The TASK env var still works as a full override:
#     TASK=LeIsaac-SO101-SortObject-CylinderGreen-v0 bash test-5.5-teleop-sort-object.sh
#
# Override the endpoint/device with env vars:
#   REMOTE_ENDPOINT=tcp://localhost:5556
#   TELEOP_DEVICE=so101leader
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

TELEOP_DEVICE="${TELEOP_DEVICE:-so101leader}"
REMOTE_ENDPOINT="${REMOTE_ENDPOINT:-tcp://localhost:5556}"
SECOND_VIEWPORT="${SECOND_VIEWPORT:-}"   # e.g. "front" or "wrist"; empty = single viewport

_VALID_VARIANTS=(
    cube-red cube-green cube-yellow
    rectangle-red rectangle-blue rectangle-green rectangle-yellow
    cylinder-red cylinder-blue cylinder-green
)

# ── Variant → TASK resolution ──────────────────────────────────────────────
if [ -n "${TASK:-}" ]; then
    echo ">>> [debug] TASK override from env: ${TASK}"
else
    VARIANT="${1:-cube-red}"
    echo ">>> [debug] raw arg: '${1:-<none>}'  →  using variant: '${VARIANT}'"
    VARIANT_LOWER="$(echo "$VARIANT" | tr '[:upper:]' '[:lower:]')"

    _VALID=0
    for v in "${_VALID_VARIANTS[@]}"; do
        [ "$v" = "$VARIANT_LOWER" ] && _VALID=1 && break
    done
    if [ "$_VALID" -eq 0 ]; then
        echo "ERROR: unknown variant '${VARIANT}'"
        echo "Valid variants: ${_VALID_VARIANTS[*]}"
        exit 1
    fi

    # "rectangle-green"  →  "RectangleGreen"
    VARIANT_TITLE="$(echo "$VARIANT_LOWER" | awk -F- 'BEGIN{OFS=""} {for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) substr($i,2); print}')"
    TASK="LeIsaac-SO101-SortObject-${VARIANT_TITLE}-v0"
    echo ">>> [debug] derived TASK: ${TASK}"
fi

echo ">>> Test 5.5: SortObject teleop (SO-101 leader) — ${TASK}"
echo ">>> Remote endpoint: ${REMOTE_ENDPOINT}"
build_kit_args
echo ""

# The sort_object assets are baked into the image (from the git clone) but NOT
# in the HuggingFace download mounted by COMMON_FLAGS. Omit the host assets
# mount so the container uses its own baked-in copy.
docker run \
    --rm --name "$CONTAINER_NAME" --gpus all --network=host \
    -e ACCEPT_EULA=Y \
    -e PRIVACY_CONSENT=Y \
    -e NVIDIA_DRIVER_CAPABILITIES=all \
    -e PYTHONPATH="${LEISAAC_SRC}" \
    -v "${CACHE_ROOT}/kit:/isaac-sim/kit/cache:rw" \
    -v "${CACHE_ROOT}/ov:/isaac-sim/.cache/ov:rw" \
    -v "${CACHE_ROOT}/glcache:/isaac-sim/.cache/nvidia/GLCache:rw" \
    -v "${CACHE_ROOT}/computecache:/isaac-sim/.nv/ComputeCache:rw" \
    -v "${CACHE_ROOT}/pip:/isaac-sim/.cache/pip:rw" \
    -v "${WORK_DIR}/docker/leisaac/logs:/isaac-sim/.nvidia-omniverse/logs:rw" \
    -v /usr/share/vulkan/icd.d:/usr/share/vulkan/icd.d:ro \
    --entrypoint /isaac-sim/python.sh \
    "$IMAGE" \
    /workspace/leisaac/scripts/environments/teleoperation/teleop_se3_agent.py \
    --task="${TASK}" \
    --teleop_device="${TELEOP_DEVICE}" \
    --remote_endpoint="${REMOTE_ENDPOINT}" \
    --num_envs=1 --device=cuda --headless --enable_cameras \
    ${SECOND_VIEWPORT:+--second_viewport="${SECOND_VIEWPORT}"} \
    --livestream 2 \
    --kit_args="${KIT_ARGS}"
