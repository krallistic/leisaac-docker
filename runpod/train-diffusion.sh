#!/bin/bash
# train-diffusion.sh — launch ONE RunPod pod training LeRobot's built-in Diffusion Policy
# across PERCENTS × SEEDS, on the plain (no-concept) datasets. Mostly stock lerobot — the
# only non-default is crop_shape=null (full 480x640 image, like ACT; the (84,84) default
# would crop peripheral objects out). Thin wrapper over start-runpod.sh.
#
# Required env: GCS_BUCKET, EXPERIMENT_NAME, and a key (RUNPOD_SECRET_NAME or GCP_KEY_FILE).
# Optional:     SEEDS PERCENTS EPOCHS BATCH_SIZE DIFFUSION_LR DIFFUSION_CROP NUM_WORKERS MIN_CUDA GPU_TYPE
#
# Example:
#   EXPERIMENT_NAME=diffusion GCS_BUCKET=gs://leisaac-training-uni-ulm-compute-stuff \
#   GCP_KEY_FILE=runpod/runpod-sa-key.json bash runpod/train-diffusion.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export POLICIES="diffusion"
export NAME="${NAME:-${EXPERIMENT_NAME:-exp}-diffusion-$(date +%H%M%S)}"
exec bash "$SCRIPT_DIR/start-runpod.sh"
