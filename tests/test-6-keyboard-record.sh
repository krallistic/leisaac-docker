#!/bin/bash
# test-6-record-keyboard.sh — STEP 1: keyboard teleop + RECORDING to HDF5,
# streamed over Tailscale. Runs in the lean leisaac:latest image (no lerobot).
#
# WHY HDF5 (not the LeRobot recorder): the reverted leisaac:latest has no
# lerobot, so --use_lerobot_recorder is unavailable. We use the built-in
# StreamingRecorderManager path, which writes a single dataset.hdf5.
#
# SUCCESS-ONLY: the HDF5 path is hardwired to EXPORT_ALL (it keeps failed
# episodes too) — there is no success-only mode here. That's fine: the
# converter (test-7) drops every episode whose `success` flag is false, so
# only successful demos end up in the LeRobot dataset. Record freely; filter
# at conversion time.
#
# RECORDING LOOP (drive from the WebRTC client's keyboard):
#   - Connect client, focus viewport, press 'b' to START an episode.
#   - Drive with the keyboard.
#   - End each episode with a reset key:
#       N = reset + mark SUCCESS  (kept by the converter)
#       R = reset + mark FAILURE  (dropped by the converter)
#   - With --num_demos=N the app auto-exits after N RECORDED episodes
#     (success or fail — it counts episodes, not successes). Set 0 for infinite.
#
# Output: $HOST_DATASETS/dataset.hdf5 on the HOST (survives the --rm container);
# this is the input to test-7-convert-lerobot.sh.
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

TASK="${TASK:-LeIsaac-SO101-PickOrange-v0}"
NUM_DEMOS="${NUM_DEMOS:-5}"                          # 0 = record until you exit
STEP_HZ="${STEP_HZ:-60}"
RESUME="${RESUME:-0}"                                # 1 = append into existing dataset.hdf5

# Persist datasets on the HOST so they survive the --rm container.
HOST_DATASETS="${HOST_DATASETS:-${WORK_DIR}/leisaac/datasets}"
DATASET_FILE="${DATASET_FILE:-dataset.hdf5}"
mkdir -p "$HOST_DATASETS"

RESUME_FLAG=()
[ "$RESUME" = "1" ] && RESUME_FLAG=( --resume )

echo ">>> Test 6: keyboard teleop + RECORDING to HDF5 — ${TASK}"
echo ">>> Dataset (host): ${HOST_DATASETS}/${DATASET_FILE}"
echo ">>> num_demos=${NUM_DEMOS} (0=infinite), step_hz=${STEP_HZ}, resume=${RESUME}"
echo ">>> In the client: focus viewport, 'b' to start, N=end+success, R=end+fail."
build_kit_args
echo ""

docker run "${COMMON_FLAGS[@]}" \
    -v "${HOST_DATASETS}:/workspace/leisaac/datasets" \
    --entrypoint /isaac-sim/python.sh \
    "$IMAGE" \
    /workspace/leisaac/scripts/environments/teleoperation/teleop_se3_agent.py \
    --task="${TASK}" \
    --teleop_device=keyboard \
    --num_envs=1 --device=cuda --enable_cameras --headless \
    --record \
    --dataset_file="/workspace/leisaac/datasets/${DATASET_FILE}" \
    --num_demos="${NUM_DEMOS}" \
    --step_hz="${STEP_HZ}" \
    "${RESUME_FLAG[@]}" \
    --livestream 2 \
    --kit_args="${KIT_ARGS}"