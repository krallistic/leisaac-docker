#!/bin/bash
# test-4.5-scene-sort-object.sh — Smoke-test the custom SortObject environment
# with WebRTC streaming, keyboard device (no teleop rig required).
#
# The SortObject scene is a custom env added to the leisaac fork; its USD assets
# live inside the Docker image (baked via the git clone in the Dockerfile) but
# NOT in the HuggingFace leisaac_env download that setup-instance.sh pulls.
#
# To bridge this gap we extract the sort_object assets from the image onto the
# host asset mount the first time this test runs (idempotent — skipped if
# already present). The extracted files then survive across container restarts
# because they land on the persistent data disk.
#
# Usage:
#   bash test-4.5-scene-sort-object.sh [VARIANT]
#
#   VARIANT  shape-color pair (case-insensitive).  Examples:
#              cube-red  cube-green  cube-yellow
#              rectangle-red  rectangle-blue  rectangle-green  rectangle-yellow
#              cylinder-red   cylinder-blue   cylinder-green
#            Defaults to cube-red (backward-compatible).
#
#   The TASK env var still works as a full override:
#     TASK=LeIsaac-SO101-SortObject-CylinderGreen-v0 bash test-4.5-scene-sort-object.sh
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

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

echo ">>> Test 4.5: SortObject custom env, no teleop — ${TASK}"
build_kit_args
echo ">>> [debug] image:      ${IMAGE}"
echo ">>> [debug] PYTHONPATH: ${LEISAAC_SRC}"
echo ">>> [debug] WORK_DIR:   ${WORK_DIR}"
echo ">>> [debug] CACHE_ROOT: ${CACHE_ROOT}"
echo ""

# The sort_object assets are baked into the image (from the git clone) but NOT
# in the HuggingFace download that COMMON_FLAGS mounts over /workspace/leisaac/assets.
# Omit the host assets mount so the container uses its own baked-in copy.
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
    --teleop_device=keyboard \
    --num_envs=1 --device=cuda --headless --enable_cameras \
    --livestream 2 \
    --kit_args="${KIT_ARGS}"
