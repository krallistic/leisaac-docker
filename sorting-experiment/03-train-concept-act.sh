#!/bin/bash
# 03-train-concept-act.sh — Train ConceptACT with the transformer-CE concept
# method and class-aware encoder layers.
#
# Uses the concept-labeled LeRobot datasets (sim/sort_object_with_concepts_*).
# The last encoder layer is replaced by a ClassAwareConceptACTEncoderLayer that
# produces concept predictions; cross-entropy loss is applied per concept class
# with label smoothing 0.1.  Concept head LR = 10× base LR; RBF layers 100×.
#
# Concept types (ConceptACTConfig defaults, matching the sim experiment):
#   concept_color   : 4 classes  (red, green, yellow, blue)
#   concept_shape   : 3 classes  (cube, rectangle, cylinder)
#   concept_dropoff : 2 classes  (A, B)
#
# Checkpoint naming: concept_act_tce_cw{CW}_lr{LR}_seed{SEED}
#
# Key overrideable env vars:
#   SEEDS          space-separated list of seeds (default: "42 123 456")
#   STEPS          training steps (default: 50000)
#   BATCH_SIZE     (default: 8)
#   LR             base learning rate (default: 3e-5)
#   CONCEPT_WEIGHT weight for concept loss relative to action L1 (default: 0.2)
#   WANDB_ENABLE   1 = enable W&B logging (default: 0)
#   WANDB_PROJECT  (default: sorting-experiment-sim)
#   FORCE          1 = retrain even if checkpoint exists (default: 0)

set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

SEEDS="${SEEDS:-42 123 456}"
STEPS="${STEPS:-50000}"
BATCH_SIZE="${BATCH_SIZE:-8}"
LR="${LR:-3e-5}"
CONCEPT_WEIGHT="${CONCEPT_WEIGHT:-0.2}"
WANDB_ENABLE="${WANDB_ENABLE:-0}"
WANDB_PROJECT="${WANDB_PROJECT:-sorting-experiment-sim}"
FORCE="${FORCE:-0}"

mkdir -p "${CHECKPOINTS_DIR}"

# ── Build concept-labeled dataset list ───────────────────────────────────────
DATASET_LIST=""
MISSING=()
for case in "${TRAINING_CASES[@]}"; do
    if ! is_concepts_added "$case"; then
        MISSING+=("$case")
        continue
    fi
    repo="$(case_to_concept_repo_id "$case")"
    DATASET_LIST="${DATASET_LIST:+${DATASET_LIST},}${repo}"
done

if [ ${#MISSING[@]} -gt 0 ]; then
    echo "WARNING: concept labels missing for: ${MISSING[*]}"
    echo "         Run 02-convert.sh (without SKIP_CONCEPTS=1) first."
fi
if [ -z "$DATASET_LIST" ]; then
    echo "ERROR: No concept-labeled datasets found. Run 02-convert.sh first."
    exit 1
fi

echo "=== ConceptACT training (transformer_ce + class-aware) ==="
echo "  Datasets      : ${DATASET_LIST}"
echo "  Steps         : ${STEPS}  batch=${BATCH_SIZE}  lr=${LR}"
echo "  Concept weight: ${CONCEPT_WEIGHT}  (concept head lr = 10×, RBF = 100×)"
echo "  Seeds         : ${SEEDS}"
echo "  Checkpoints   : ${CHECKPOINTS_DIR}"
echo ""

# ── Training loop ─────────────────────────────────────────────────────────────
for seed in $SEEDS; do
    job="concept_act_tce_cw${CONCEPT_WEIGHT}_lr${LR}_seed${seed}"
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
        --policy.type=concept_act \
        --policy.device=cuda \
        --policy.optimizer_lr="${LR}" \
        --policy.n_heads=16 \
        --policy.use_concept_learning=true \
        --policy.concept_method=transformer_ce \
        --policy.use_class_aware_concepts=true \
        --policy.concept_weight="${CONCEPT_WEIGHT}" \
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

echo "=== ConceptACT (transformer_ce) training complete ==="
