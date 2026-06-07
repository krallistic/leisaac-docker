#!/bin/bash
# run_timing_experiment.sh — quick wall-clock TIMING run (no training, no checkpoints).
#
# Launches ONE RunPod pod that, for each policy, builds an UNTRAINED model from one
# case's dataset and measures:
#   - train step:  forward + backward + optimizer.step on one batch
#   - inference:   one full action-chunk (averaged over many calls, batch size 1)
# Results (CSV + per-policy JSON) are synced to <bucket>/timing/<EXPERIMENT_NAME>/.
#
# This rides the SAME launch path as the training sweeps: it just sets RUN_MODE=timing,
# which makes the image's CMD (train-and-sync.sh) hand off to benchmark-and-sync.sh.
#
# Policies measured by default: ACT, ConceptACT (transformer_ce), Prediction Heads (ph),
# ConceptACT-CBM, DiffusionPolicy, and LAV-ACT.
#   NOTE: lavact works out of the box — voltron-robotics is baked into the image
#   (Dockerfile.train). The benchmark still skips it gracefully if a build lacks it.
#
# Required: a GCS key — RUNPOD_SECRET_NAME (preferred) or GCP_KEY_FILE.
#           start-runpod.sh has local defaults for GCS_BUCKET + GCP_KEY_FILE.
#
# Override on the command line, e.g.
#   POLICIES="act diffusion" bash runpod/run_timing_experiment.sh
#   BATCH_SIZE=8 BENCH_INFER_BS=1 CASE=cube_green bash runpod/run_timing_experiment.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export RUN_MODE="timing"
export EXPERIMENT_NAME="${EXPERIMENT_NAME:-timing}"
export POLICIES="${POLICIES:-act concept_act_tce concept_act_ph concept_act_cbm diffusion lavact}"
export CASE="${CASE:-cube_green}"
export BATCH_SIZE="${BATCH_SIZE:-32}"
export BENCH_INFER_BS="${BENCH_INFER_BS:-1}"
export NAME="${NAME:-${EXPERIMENT_NAME}-timing-$(date +%H%M%S)}"

echo ">>> timing experiment: experiment=${EXPERIMENT_NAME}"
echo "    policies=[${POLICIES}]  case=${CASE}  batch_size=${BATCH_SIZE}  infer_bs=${BENCH_INFER_BS}"

exec bash "$SCRIPT_DIR/start-runpod.sh"
