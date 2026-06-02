#!/bin/bash
# run_concept_noise_experiment.sh — launch the concept label-noise robustness sweep.
#
# Trains ConceptACT while corrupting the concept targets with per-class label
# noise (config.concept_noise, applied inside the policy during training only).
# One pod sweeps every noise level × seed; the noise level is folded into each
# checkpoint name as _noise<N> (noise 0.0 keeps the plain baseline name).
#
# Required: a GCS key — RUNPOD_SECRET_NAME (preferred) or GCP_KEY_FILE.
#           start-runpod.sh has local defaults for GCS_BUCKET + GCP_KEY_FILE.
#
# Override any of these on the command line, e.g.
#   CONCEPT_NOISES="0.0 0.25 0.5" SEEDS=42 bash runpod/run_concept_noise_experiment.sh
#   METHOD=ph bash runpod/run_concept_noise_experiment.sh        # prediction-head instead of transformer_ce
#   METHOD=both bash runpod/run_concept_noise_experiment.sh      # one pod per method
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export EXPERIMENT_NAME="${EXPERIMENT_NAME:-noiserobust}"
export CONCEPT_NOISES="${CONCEPT_NOISES:-0.05 0.1 0.2}"
export PERCENTS="${PERCENTS:-0.2 0.4 0.6 0.8 1.0}"
export SEEDS="${SEEDS:-42 123 456}"

# METHOD: tce (transformer_ce, default) | ph (prediction_head) | both
METHOD="${METHOD:-tce}"

echo ">>> concept-noise experiment: experiment=${EXPERIMENT_NAME}"
echo "    noises=[${CONCEPT_NOISES}]  percents=[${PERCENTS}]  seeds=[${SEEDS}]  method=${METHOD}"

case "$METHOD" in
    tce)  bash "$SCRIPT_DIR/train-concept-act.sh" ;;
    ph)   bash "$SCRIPT_DIR/train-prediction-head.sh" ;;
    both)
        bash "$SCRIPT_DIR/train-concept-act.sh"
        bash "$SCRIPT_DIR/train-prediction-head.sh" ;;
    *)    echo "ERROR: METHOD must be tce | ph | both (got '$METHOD')"; exit 1 ;;
esac
