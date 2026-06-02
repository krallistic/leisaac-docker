#!/bin/bash
# train-prediction-head.sh — launch ONE RunPod pod training ConceptACT with MLP
# prediction heads (concept_method=prediction_head) across PERCENTS × SEEDS.
# Thin wrapper over start-runpod.sh.
#
# Required env: GCS_BUCKET, EXPERIMENT_NAME, and a key (RUNPOD_SECRET_NAME or GCP_KEY_FILE).
# Optional:     SEEDS PERCENTS EPOCHS BATCH_SIZE LR CONCEPT_WEIGHT CONCEPT_DIM NUM_WORKERS MIN_CUDA GPU_TYPE
#
# Example:
#   EXPERIMENT_NAME=simsort GCS_BUCKET=gs://leisaac-training-uni-ulm-compute-stuff \
#   GCP_KEY_FILE=runpod/runpod-sa-key.json bash runpod/train-prediction-head.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export POLICIES="concept_act_ph"
export NAME="${NAME:-${EXPERIMENT_NAME:-exp}-ph-$(date +%H%M%S)}"
exec bash "$SCRIPT_DIR/start-runpod.sh"
