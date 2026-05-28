#!/bin/bash
# test-8-train-lerobot.sh — Train a LeRobot policy on the converted dataset
# (produced by test-7) using the pure-lerobot image (lerobot:latest).
#
# The lerobot train.py uses a draccus config system; policy type, dataset,
# and output directory are passed as CLI overrides.
#
# INPUT:  $HOST_LEROBOT_DATASETS/$REPO_ID  (LeRobot dataset from test-7)
# OUTPUT: $HOST_CHECKPOINTS/$JOB_NAME      (checkpoint saved on the host)
#
# Key variables (override via env):
#   POLICY_TYPE   lerobot policy name (act / diffusion / smolvla / ...)
#   REPO_ID       LeRobot dataset repo-id (must match test-7)
#   STEPS         Training steps
#   BATCH_SIZE    Batch size
#   HOST_LEROBOT_DATASETS  Directory containing the LeRobot dataset
#   HOST_CHECKPOINTS       Directory to write checkpoints into
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

POLICY_TYPE="${POLICY_TYPE:-act}"
REPO_ID="${REPO_ID:-local/so101_pick_orange}"
STEPS="${STEPS:-50000}"
BATCH_SIZE="${BATCH_SIZE:-8}"
JOB_NAME="${JOB_NAME:-lerobot_${POLICY_TYPE}}"

HOST_LEROBOT_DATASETS="${HOST_LEROBOT_DATASETS:-${WORK_DIR}/leisaac/lerobot_datasets}"
HOST_CHECKPOINTS="${HOST_CHECKPOINTS:-${WORK_DIR}/leisaac/checkpoints}"

LEROBOT_IMAGE="${LEROBOT_IMAGE:-lerobot:latest}"
TRAIN_CONTAINER="lerobot-train"

mkdir -p "$HOST_CHECKPOINTS"
docker rm "$TRAIN_CONTAINER" >/dev/null 2>&1 || true

echo ">>> Test 8: LeRobot training"
echo ">>> Dataset   : ${HOST_LEROBOT_DATASETS}/${REPO_ID}"
echo ">>> Policy    : ${POLICY_TYPE}  steps=${STEPS}  batch_size=${BATCH_SIZE}"
echo ">>> Checkpoint: ${HOST_CHECKPOINTS}/${JOB_NAME}"
echo ""

docker run --rm \
    --name "$TRAIN_CONTAINER" \
    --gpus all \
    --ipc=host \
    -e HF_LEROBOT_HOME="/workspace/lerobot_datasets" \
    -v "${HOST_LEROBOT_DATASETS}:/workspace/lerobot_datasets" \
    -v "${HOST_CHECKPOINTS}:/workspace/checkpoints" \
    "$LEROBOT_IMAGE" \
    python -m lerobot.scripts.train \
        --dataset.repo_id="${REPO_ID}" \
        --policy.type="${POLICY_TYPE}" \
        --output_dir="/workspace/checkpoints/${JOB_NAME}" \
        --job_name="${JOB_NAME}" \
        --epochs=1 \
        --batch_size="${BATCH_SIZE}" \
        --save_checkpoint=true \
        --save_freq="${STEPS}" \
        --wandb.enable=false

echo ""
echo ">>> Test 8 passed. Checkpoint at ${HOST_CHECKPOINTS}/${JOB_NAME}"
