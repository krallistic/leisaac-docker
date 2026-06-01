#!/bin/bash
# test-6.5-teleop-record.sh — SO-101 leader teleop + HDF5 recording in the
# custom SortObject environment, streamed over Tailscale.
#
# Combines test-5.5 (SortObject baked-in assets) with recording (test-6).
# Uses StreamingRecorderManager (no lerobot required in this image).
#
# RECORDING WORKFLOW:
#   Teleop starts immediately on launch.
#   auto-termination fires (object placed in either box, or dropped
#     elsewhere after being lifted) = episode saved as SUCCEEDED, env
#     resets, teleop pauses → reset arm to home, press N to start next.
#   R = discard current episode, env resets, teleop pauses → press N.
#   N while paused = start next demo.
#   N mid-episode = manual success override (fallback; auto-terminations
#     handle the normal case so this is rarely needed).
#
#   With --num_demos=N the app auto-exits after N *succeeded* episodes.
#   Set to 0 for infinite recording.
#
# Usage:
#   bash test-6.5-teleop-record.sh [VARIANT]
#
#   VARIANT  shape-color pair (case-insensitive).  Examples:
#              cube-red  cube-green  cube-yellow
#              rectangle-red  rectangle-blue  rectangle-green  rectangle-yellow
#              cylinder-red   cylinder-blue   cylinder-green
#            Defaults to cube-red.
#
#   Override env vars:
#     TASK=LeIsaac-SO101-SortObject-CylinderGreen-v0  (full task name)
#     TELEOP_DEVICE=so101leader
#     REMOTE_ENDPOINT=tcp://localhost:5556
#     SECOND_VIEWPORT=wrist          (or 'front'; empty = single viewport)
#     NUM_DEMOS=10                    (0 = infinite)
#     STEP_HZ=60
#     RESUME=1                        (append into existing dataset.hdf5)
#     HOST_DATASETS=/path/on/host
#     DATASET_FILE=dataset.hdf5
#
# Output: $HOST_DATASETS/$DATASET_FILE on the HOST (survives --rm container).
# This is the input to test-7-convert-lerobot.sh.
#
# NOTE: sort_object USD assets are baked into leisaac:latest — the host assets
# volume from COMMON_FLAGS is intentionally NOT mounted here, so the container
# uses its own copy. If you rebuild the image, make sure the assets are committed.
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

TELEOP_DEVICE="${TELEOP_DEVICE:-so101leader}"
REMOTE_ENDPOINT="${REMOTE_ENDPOINT:-tcp://localhost:5556}"
SECOND_VIEWPORT="${SECOND_VIEWPORT:-}"

NUM_DEMOS="${NUM_DEMOS:-5}"
STEP_HZ="${STEP_HZ:-60}"
RESUME="${RESUME:-0}"

HOST_DATASETS="${HOST_DATASETS:-${WORK_DIR}/test-recordings}"
DATASET_FILE="${DATASET_FILE:-dataset.hdf5}"
mkdir -p "$HOST_DATASETS"

RESUME_FLAG=()
[ "$RESUME" = "1" ] && RESUME_FLAG=( --resume )

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

echo ">>> Test 6.5: SortObject teleop + recording — ${TASK}"
echo ">>> Remote endpoint: ${REMOTE_ENDPOINT}"
echo ">>> Dataset (host): ${HOST_DATASETS}/${DATASET_FILE}"
echo ">>> num_demos=${NUM_DEMOS} (0=infinite), step_hz=${STEP_HZ}, resume=${RESUME}"
echo ">>> Workflow: teleop starts immediately | auto-term=save+pause | R=discard+pause | N-while-paused=start next"
build_kit_args
echo ""

docker run \
    --rm --name "$CONTAINER_NAME" --gpus all --network=host \
    -e ACCEPT_EULA=Y \
    -e PRIVACY_CONSENT=Y \
    -e NVIDIA_DRIVER_CAPABILITIES=all \
    -e PYTHONPATH="${LEISAAC_SRC}" \
    -v "${HOST_DATASETS}:/workspace/leisaac/datasets" \
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
    --num_envs=1 --device=cuda --enable_cameras --headless \
    ${SECOND_VIEWPORT:+--second_viewport="${SECOND_VIEWPORT}"} \
    --record \
    --dataset_file="/workspace/leisaac/datasets/${DATASET_FILE}" \
    --num_demos="${NUM_DEMOS}" \
    --step_hz="${STEP_HZ}" \
    "${RESUME_FLAG[@]}" \
    --livestream 2 \
    --kit_args="${KIT_ARGS}"
