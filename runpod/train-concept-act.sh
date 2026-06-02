#!/bin/bash
# train-concept-act.sh — launch ONE RunPod pod training ConceptACT (transformer_ce
# + class-aware) across PERCENTS × SEEDS. Thin wrapper over start-runpod.sh.
#
# Required env: GCS_BUCKET, EXPERIMENT_NAME, and a key (RUNPOD_SECRET_NAME or GCP_KEY_FILE).
# Optional:     SEEDS PERCENTS EPOCHS BATCH_SIZE LR CONCEPT_WEIGHT NUM_WORKERS MIN_CUDA GPU_TYPE
#
# Example:
#   EXPERIMENT_NAME=simsort GCS_BUCKET=gs://leisaac-training-uni-ulm-compute-stuff \
#   GCP_KEY_FILE=runpod/runpod-sa-key.json bash runpod/train-concept-act.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export POLICIES="concept_act_tce"
export NAME="${NAME:-${EXPERIMENT_NAME:-exp}-concept-act-$(date +%H%M%S)}"
exec bash "$SCRIPT_DIR/start-runpod.sh"
