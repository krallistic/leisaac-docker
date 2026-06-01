#!/bin/bash
# 03-train-lavact.sh — Train LAV-ACT (Language-Augmented Visual ACT) on all
# converted training cases.
#
# LAV-ACT conditions action prediction on language via Voltron v-cond visual
# language representations and FiLM-modulates the ResNet image features.
# Uses PLAIN datasets (same as ACT baseline) — language conditioning substitutes
# for explicit concept supervision, so no concept-labeled datasets are needed.
#
# The task description stored in each episode drives the language conditioning.
# Sim datasets record the env's default task_description:
#   "Pick up the object and place it in the correct box."
# For richer language conditioning, update the description at collection time
# or re-label episodes before training.
#
# DEPENDENCY: voltron-robotics must be installed in lerobot:latest.
# The standard Dockerfile.train (.[smolvla]) does not include it.
# Add it to the image before running this script:
#   docker run --rm lerobot:latest pip install voltron-robotics
# or rebuild with: RUN /opt/venv/bin/pip install voltron-robotics
#
# Checkpoint naming: lavact_lr{LR}_seed{SEED}
#
# Key overrideable env vars:
#   SEEDS            space-separated list of seeds (default: "42 123 456")
#   STEPS            training steps (default: 50000)
#   BATCH_SIZE       (default: 8)
#   LR               base learning rate (default: 3e-5)
#   VOLTRON_MODEL    Voltron variant: v-cond|v-dual|v-gen (default: v-cond)
#   FILM_HIDDEN_DIM  hidden dim of FiLM γ/β networks (default: 512)
#   VOLTRON_FREEZE   true = freeze Voltron weights during training (default: true)
#   WANDB_ENABLE     1 = enable W&B logging (default: 0)
#   WANDB_PROJECT    (default: sorting-experiment-sim)
#   FORCE            1 = retrain even if checkpoint exists (default: 0)

set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

SEEDS="${SEEDS:-42 123 456}"
STEPS="${STEPS:-50000}"
BATCH_SIZE="${BATCH_SIZE:-8}"
LR="${LR:-3e-5}"
VOLTRON_MODEL="${VOLTRON_MODEL:-v-cond}"
FILM_HIDDEN_DIM="${FILM_HIDDEN_DIM:-512}"
VOLTRON_FREEZE="${VOLTRON_FREEZE:-true}"
WANDB_ENABLE="${WANDB_ENABLE:-0}"
WANDB_PROJECT="${WANDB_PROJECT:-sorting-experiment-sim}"
FORCE="${FORCE:-0}"

mkdir -p "${CHECKPOINTS_DIR}"

# ── Check voltron is available in the image ───────────────────────────────────
if ! docker run --rm "$LEROBOT_IMAGE" python -c "import voltron" >/dev/null 2>&1; then
    echo "ERROR: voltron-robotics is not installed in ${LEROBOT_IMAGE}."
    echo "       Install it before training:"
    echo "         docker run --rm ${LEROBOT_IMAGE} pip install voltron-robotics"
    echo "       Or rebuild the image with voltron-robotics added to Dockerfile.train."
    exit 1
fi

# ── Build plain dataset list ──────────────────────────────────────────────────
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

echo "=== LAV-ACT training ==="
echo "  Datasets      : ${DATASET_LIST}"
echo "  Steps         : ${STEPS}  batch=${BATCH_SIZE}  lr=${LR}"
echo "  Voltron model : ${VOLTRON_MODEL}  frozen=${VOLTRON_FREEZE}  film_dim=${FILM_HIDDEN_DIM}"
echo "  Seeds         : ${SEEDS}"
echo "  Checkpoints   : ${CHECKPOINTS_DIR}"
echo ""

# ── Training loop ─────────────────────────────────────────────────────────────
for seed in $SEEDS; do
    job="lavact_lr${LR}_seed${seed}"
    ckpt_dir="${CHECKPOINTS_DIR}/${job}"

    if [ -d "${ckpt_dir}/checkpoints/last" ] && [ "$FORCE" != "1" ]; then
        echo "  [skip] ${job}  (checkpoint exists)"
        continue
    fi

    echo "────────────────────────────────────────────────────────"
    echo ">>> Training: ${job}"
    echo ""
    mkdir -p "${ckpt_dir}"

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
        --policy.type=lavact \
        --policy.device=cuda \
        --policy.optimizer_lr="${LR}" \
        --policy.n_heads=16 \
        --policy.voltron_model="${VOLTRON_MODEL}" \
        --policy.film_hidden_dim="${FILM_HIDDEN_DIM}" \
        --policy.voltron_freeze="${VOLTRON_FREEZE}" \
        --output_dir="/workspace/checkpoints/${job}" \
        --job_name="${job}" \
        --steps="${STEPS}" \
        --batch_size="${BATCH_SIZE}" \
        --num_workers=2 \
        --save_checkpoint=true \
        --save_freq="${STEPS}" \
        --seed="${seed}" \
        $wandb_flags

    echo ">>> Done: ${ckpt_dir}"
    echo ""
done

echo "=== LAV-ACT training complete ==="
