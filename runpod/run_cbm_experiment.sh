#!/bin/bash
# run_cbm_experiment.sh — Concept Bottleneck Model run.
#
# Trains ConceptACT as a CBM: concepts are predicted, projected to a single bottleneck
# token between encoder and decoder, and the decoder attends ONLY to that token — so the
# only observation->action path runs through the concepts (VAE off). One pod sweeps
# PERCENTS × SEEDS.
#
# Required: a GCS key — RUNPOD_SECRET_NAME (preferred) or GCP_KEY_FILE.
#           start-runpod.sh has local defaults for GCS_BUCKET + GCP_KEY_FILE.
# Uses the with_concepts datasets (which have meta/tasks.jsonl).
#
# Override on the command line, e.g.
#   PERCENTS="1.0" SEEDS=42 bash runpod/run_cbm_experiment.sh
#   CONCEPT_GROUP=object bash runpod/run_cbm_experiment.sh   # bottleneck on object concepts only
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export EXPERIMENT_NAME="${EXPERIMENT_NAME:-cbm}"
export PERCENTS="${PERCENTS:-0.2 0.4 0.6 0.8 1.0}"
export SEEDS="${SEEDS:-42 123 456}"

echo ">>> concept-bottleneck experiment: experiment=${EXPERIMENT_NAME}"
echo "    percents=[${PERCENTS}]  seeds=[${SEEDS}]  group=${CONCEPT_GROUP:-all}"

bash "$SCRIPT_DIR/train-cbm.sh"
