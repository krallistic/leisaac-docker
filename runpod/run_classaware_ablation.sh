#!/bin/bash
# run_classaware_ablation.sh — does the class-aware concept transformer help?
#
# Launches the two arms of the ablation under one EXPERIMENT_NAME, same
# percents × seeds, so the only difference is the concept structure:
#   concept_act_tce  — class-aware transformer + per-class softmax CE   (baseline)
#   concept_act_flat — single non-class-aware transformer + flat per-entry BCE (ablation)
# One pod per arm (each call is a separate runpodctl pod create).
#
# Required: a GCS key — RUNPOD_SECRET_NAME (preferred) or GCP_KEY_FILE.
#           start-runpod.sh has local defaults for GCS_BUCKET + GCP_KEY_FILE.
#
# Override any of these on the command line, e.g.
#   PERCENTS="1.0" SEEDS=42 bash runpod/run_classaware_ablation.sh
#   ARM=flat bash runpod/run_classaware_ablation.sh    # only the ablation arm
#   ARM=tce  bash runpod/run_classaware_ablation.sh    # only the baseline arm
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export EXPERIMENT_NAME="${EXPERIMENT_NAME:-classaware_ablation}"
export PERCENTS="${PERCENTS:-0.2 0.4 0.6 0.8 1.0}"
export SEEDS="${SEEDS:-42 123 456}"

# ARM: both (default) | tce (class-aware baseline only) | flat (ablation only)
ARM="${ARM:-both}"

echo ">>> class-aware ablation: experiment=${EXPERIMENT_NAME}"
echo "    percents=[${PERCENTS}]  seeds=[${SEEDS}]  arm=${ARM}"

case "$ARM" in
    tce)  bash "$SCRIPT_DIR/train-concept-act.sh" ;;
    flat) bash "$SCRIPT_DIR/train-flat-transformer.sh" ;;
    both)
        bash "$SCRIPT_DIR/train-concept-act.sh"
        bash "$SCRIPT_DIR/train-flat-transformer.sh" ;;
    *)    echo "ERROR: ARM must be both | tce | flat (got '$ARM')"; exit 1 ;;
esac
