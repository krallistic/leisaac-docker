#!/bin/bash
# 03-train-act.sh — Train the baseline ACT policy on all converted training cases.
#
# Uses the plain (non-concept-labeled) LeRobot datasets.
# Checkpoint naming: act_lr{LR}_seed{SEED}
#
# A run is skipped if its checkpoints/last/ already exists. FORCE=1 to retrain.
#
# Key overrideable env vars:
#   SEEDS        space-separated list of seeds (default: "42 123 456")
#   STEPS        training steps (default: 50000)
#   BATCH_SIZE   (default: 8)
#   LR           learning rate (default: 3e-5)
#   WANDB_ENABLE 1 = enable W&B logging (default: 0)
#   WANDB_PROJECT  (default: sorting-experiment-sim)
#   FORCE        1 = retrain even if checkpoint exists (default: 0)

set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

SEEDS="${SEEDS:-42 123 456}"
STEPS="${STEPS:-50000}"
EPOCHS="${EPOCHS:-5}"
BATCH_SIZE="${BATCH_SIZE:-8}"
LR="${LR:-3e-5}"
WANDB_ENABLE="${WANDB_ENABLE:-0}"
WANDB_PROJECT="${WANDB_PROJECT:-sorting-experiment-sim}"
FORCE="${FORCE:-0}"

mkdir -p "${CHECKPOINTS_DIR}"

# ── Build dataset list ────────────────────────────────────────────────────────
DATASET_LIST=""
for case in "${TRAINING_CASES[@]}"; do
    if ! is_converted "$case"; then
        echo "WARNING: ${case} not yet converted — skipping. Run 02-convert.sh first."
        continue
    fi
    repo="$(case_to_repo_id "$case")"
    DATASET_LIST="${DATASET_LIST:+${DATASET_LIST},}${repo}"
done

if [ -z "$DATASET_LIST" ]; then
    echo "ERROR: No converted training datasets found. Run 02-convert.sh first."
    exit 1
fi

echo "=== ACT training ==="
echo "  Datasets   : ${DATASET_LIST}"
echo "  Epochs      : ${EPOCHS}  batch=${BATCH_SIZE}  lr=${LR}"
echo "  Seeds      : ${SEEDS}"
echo "  Checkpoints: ${CHECKPOINTS_DIR}"
echo ""

# ── Training loop ─────────────────────────────────────────────────────────────
for seed in $SEEDS; do
    job="act_lr${LR}_seed${seed}"
    ckpt_dir="${CHECKPOINTS_DIR}/${job}"

    if [ -d "${ckpt_dir}/checkpoints/last" ] && [ "$FORCE" != "1" ]; then
        echo "  [skip] ${job}  (checkpoint exists)"
        continue
    fi

    echo "────────────────────────────────────────────────────────"
    echo ">>> Training: ${job}"
    echo ""
    #mkdir -p "${ckpt_dir}"

    wandb_flags="--wandb.enable=false"
    if [ "$WANDB_ENABLE" = "1" ]; then
        wandb_flags="--wandb.enable=true --wandb.project=${WANDB_PROJECT} --wandb.run_id=${job} --wandb.disable_artifact=true"
    fi

    docker run --rm \
        --name "lerobot-train-${job}" \
        --gpus all --ipc=host \
        -e HF_LEROBOT_HOME="/workspace/lerobot_datasets" \
        -v "${LEROBOT_DIR}:/workspace/lerobot_datasets" \
        -v "${CHECKPOINTS_DIR}:/workspace/checkpoints" \
        "$LEROBOT_IMAGE" \
        python -m lerobot.scripts.train \
        --dataset.repo_id="${DATASET_LIST}" \
        --policy.type=act \
        --policy.device=cuda \
        --policy.optimizer_lr="${LR}" \
        --policy.n_heads=16 \
        --output_dir="/workspace/checkpoints/${job}" \
        --job_name="${job}" \
        --epochs="${EPOCHS}" \
        --batch_size="${BATCH_SIZE}" \
        --num_workers=2 \
        --seed="${seed}" \
        $wandb_flags

    echo ">>> Done: ${ckpt_dir}"
    echo ""
done

echo "=== ACT training complete ==="
