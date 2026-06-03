#!/bin/bash
# train-cbm.sh — launch ONE RunPod pod training ConceptACT as a Concept Bottleneck Model
# across PERCENTS × SEEDS. Concepts are predicted (prediction_head), projected to a single
# bottleneck token, and the action decoder attends ONLY to that token — so the only path
# from observation to action runs through the concept layer (VAE off). Crude by design.
# Thin wrapper over start-runpod.sh.
#
# Required env: GCS_BUCKET, EXPERIMENT_NAME, and a key (RUNPOD_SECRET_NAME or GCP_KEY_FILE).
# Optional:     SEEDS PERCENTS EPOCHS BATCH_SIZE LR CONCEPT_WEIGHT CONCEPT_DIM CONCEPT_GROUP NUM_WORKERS MIN_CUDA GPU_TYPE
#
# Example:
#   EXPERIMENT_NAME=cbm GCS_BUCKET=gs://leisaac-training-uni-ulm-compute-stuff \
#   GCP_KEY_FILE=runpod/runpod-sa-key.json bash runpod/train-cbm.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export POLICIES="concept_act_cbm"
export NAME="${NAME:-${EXPERIMENT_NAME:-exp}-cbm-$(date +%H%M%S)}"
exec bash "$SCRIPT_DIR/start-runpod.sh"
