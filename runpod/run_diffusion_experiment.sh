#!/bin/bash
# run_diffusion_experiment.sh — LeRobot Diffusion Policy run (baseline, no concepts).
#
# Trains the built-in DiffusionPolicy on the plain datasets. One pod sweeps PERCENTS × SEEDS.
# crop_shape defaults to "null" (full 480x640 image, like ACT); the diffusion default
# (84,84) would crop peripheral objects out, so we override it. Uses DIFFUSION_LR (1e-4).
# Diffusion trains for a fixed DIFFUSION_STEPS (default 20000) — it runs in STEPS mode, not
# epochs, because of its LR scheduler (see train-and-sync.sh). The step budget is the same
# across data percents (not data-scaled like the epoch-based ACT runs).
#
# Required: a GCS key — RUNPOD_SECRET_NAME (preferred) or GCP_KEY_FILE.
#           start-runpod.sh has local defaults for GCS_BUCKET + GCP_KEY_FILE.
# NOTE: uses the PLAIN datasets — make sure their meta/tasks.jsonl exists in GCS (same
#       prerequisite as the ACT baseline).
#
# Override on the command line, e.g.
#   PERCENTS="1.0" SEEDS=42 bash runpod/run_diffusion_experiment.sh
#   DIFFUSION_LR=1e-4 DIFFUSION_CROP="[240,320]" bash runpod/run_diffusion_experiment.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export EXPERIMENT_NAME="${EXPERIMENT_NAME:-diffusion}"
export PERCENTS="${PERCENTS:-0.2 0.4 0.6 0.8 1.0}"
export SEEDS="${SEEDS:-42 123 456}"

echo ">>> diffusion experiment: experiment=${EXPERIMENT_NAME}"
echo "    percents=[${PERCENTS}]  seeds=[${SEEDS}]  lr=${DIFFUSION_LR:-1e-4}  crop=${DIFFUSION_CROP:-null}  steps=${DIFFUSION_STEPS:-20000}"

bash "$SCRIPT_DIR/train-diffusion.sh"
