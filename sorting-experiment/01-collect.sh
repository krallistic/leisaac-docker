#!/bin/bash
# 01-collect.sh — Collect SO-101 leader teleop demonstrations for every
# sort-object case that is not yet marked complete.
#
# CASE STATUS:  /data/sorting-experiment/demos/{case}/.complete
#   Missing = still needs demos. Present = enough successes collected.
#   Written by this script when the operator confirms a case is done.
#
# Each case launches a separate Docker container with WebRTC streaming.
# Operator teleoperates in the streamed viewport:
#   b   = start an episode
#   N   = end episode + SUCCESS (kept by converter)
#   R   = end episode + FAILURE (dropped by converter)
# After NUM_DEMOS total episodes (success + fail) the app auto-exits.
# The operator is then asked whether the case is complete.
#
# Usage:
#   bash 01-collect.sh [--include-test-cases] [--resume] [case ...]
#
#   --include-test-cases   also collect held-out test cases
#   --resume               append into an existing dataset.hdf5
#   case ...               collect only the named cases (e.g. cube_green)
#
# Key overrideable env vars:
#   NUM_DEMOS        total episodes per case (aim for ≥10 successes; default 15)
#   STEP_HZ          env stepping rate in Hz (default 60)
#   TELEOP_DEVICE    so101leader|keyboard (default so101leader)
#   REMOTE_ENDPOINT  ZMQ endpoint for SO-101 leader (default tcp://localhost:5556)

set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

NUM_DEMOS="${NUM_DEMOS:-15}"
STEP_HZ="${STEP_HZ:-60}"
TELEOP_DEVICE="${TELEOP_DEVICE:-so101leader}"
REMOTE_ENDPOINT="${REMOTE_ENDPOINT:-tcp://localhost:5556}"
INCLUDE_TEST=0
RESUME=0
EXPLICIT_CASES=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --include-test-cases) INCLUDE_TEST=1 ;;
        --resume)             RESUME=1 ;;
        --*)                  echo "Unknown flag: $1"; exit 1 ;;
        *)                    EXPLICIT_CASES+=("$1") ;;
    esac
    shift
done

if [ ${#EXPLICIT_CASES[@]} -gt 0 ]; then
    CASES=("${EXPLICIT_CASES[@]}")
elif [ "$INCLUDE_TEST" = "1" ]; then
    CASES=("${ALL_CASES[@]}")
else
    CASES=("${TRAINING_CASES[@]}")
fi

# ── Status summary ────────────────────────────────────────────────────────────
echo "=== Sort-object demo collection ==="
echo "  Demos dir : ${DEMOS_DIR}"
echo "  Episodes  : ${NUM_DEMOS} per case (N=success kept, R=fail dropped)"
echo "  Teleop    : ${TELEOP_DEVICE}  endpoint=${REMOTE_ENDPOINT}"
echo ""
echo "Case status:"
PENDING=()
for case in "${CASES[@]}"; do
    shape="$(case_shape "$case")"; color="$(case_color "$case")"
    dropoff="$(determine_dropoff "$color" "$shape")"
    hdf5="${DEMOS_DIR}/${case}/dataset.hdf5"
    size=""
    [ -f "$hdf5" ] && size=" ($(du -sh "$hdf5" 2>/dev/null | cut -f1))"
    if is_complete "$case"; then
        echo "  [done]    ${case}  → dropoff ${dropoff}${size}"
    else
        echo "  [pending] ${case}  → dropoff ${dropoff}${size}"
        PENDING+=("$case")
    fi
done

echo ""
if [ ${#PENDING[@]} -eq 0 ]; then
    echo "All cases are complete. Nothing to do."
    exit 0
fi
echo "${#PENDING[@]} case(s) still need demos."
echo ""

build_kit_args
echo ""

# ── Collect each pending case ─────────────────────────────────────────────────
for case in "${PENDING[@]}"; do
    shape="$(case_shape "$case")"; color="$(case_color "$case")"
    dropoff="$(determine_dropoff "$color" "$shape")"
    TASK="$(case_to_task "$case")"
    CASE_DIR="${DEMOS_DIR}/${case}"
    CONTAINER="leisaac-collect-${case}"

    mkdir -p "$CASE_DIR"
    docker rm "$CONTAINER" >/dev/null 2>&1 || true

    echo "────────────────────────────────────────────────────────"
    echo ">>> Case     : ${case}  (shape=${shape}  color=${color}  dropoff=→${dropoff})"
    echo ">>> Task     : ${TASK}"
    echo ">>> Output   : ${CASE_DIR}/dataset.hdf5"
    echo ">>> Episodes : ${NUM_DEMOS}  (b=start  N=success  R=fail)"
    echo ""

    RESUME_FLAG=()
    if [ "$RESUME" = "1" ] && [ -f "${CASE_DIR}/dataset.hdf5" ]; then
        RESUME_FLAG=(--resume)
        echo ">>> Resuming into existing dataset."
    fi

    docker run --rm --name "$CONTAINER" \
        "${SORT_FLAGS[@]}" \
        -v "${CASE_DIR}:/workspace/leisaac/datasets/${case}" \
        --entrypoint /isaac-sim/python.sh \
        "$IMAGE" \
        /workspace/leisaac/scripts/environments/teleoperation/teleop_se3_agent.py \
        --task="${TASK}" \
        --teleop_device="${TELEOP_DEVICE}" \
        --remote_endpoint="${REMOTE_ENDPOINT}" \
        --num_envs=1 --device=cuda --headless --enable_cameras \
        --record \
        --dataset_file="/workspace/leisaac/datasets/${case}/dataset.hdf5" \
        --num_demos="${NUM_DEMOS}" \
        --step_hz="${STEP_HZ}" \
        "${RESUME_FLAG[@]}" \
        --livestream 2 \
        --kit_args="${KIT_ARGS}" || true   # don't abort the loop on container exit

    echo ""
    echo "Container exited."
    read -r -p "Mark '${case}' as complete (≥10 successful demos inside)? [y/N] " ans
    if [[ "$ans" =~ ^[Yy]$ ]]; then
        mark_complete "$case"
        echo ">>> Marked complete: ${case}"
    else
        echo ">>> Not marked — will retry on the next run."
    fi
    echo ""
done

echo "=== Collection pass finished ==="
echo "Pending cases can be retried by running this script again."
