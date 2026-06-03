#!/bin/bash
# train-flat-transformer.sh — launch ONE RunPod pod training the flat_transformer
# ablation: a single (non-class-aware) concept transformer with per-entry BCE loss
# on the concatenated concept vector — no class structure in the architecture OR the
# loss. Compare against train-concept-act.sh (transformer_ce + class-aware) to test
# whether the class-aware structure is needed. Thin wrapper over start-runpod.sh.
#
# Required env: GCS_BUCKET, EXPERIMENT_NAME, and a key (RUNPOD_SECRET_NAME or GCP_KEY_FILE).
# Optional:     SEEDS PERCENTS EPOCHS BATCH_SIZE LR CONCEPT_WEIGHT CONCEPT_NOISES NUM_WORKERS MIN_CUDA GPU_TYPE
#
# Example:
#   EXPERIMENT_NAME=classaware_ablation GCS_BUCKET=gs://leisaac-training-uni-ulm-compute-stuff \
#   GCP_KEY_FILE=runpod/runpod-sa-key.json bash runpod/train-flat-transformer.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export POLICIES="concept_act_flat"
export NAME="${NAME:-${EXPERIMENT_NAME:-exp}-flat-$(date +%H%M%S)}"
exec bash "$SCRIPT_DIR/start-runpod.sh"
