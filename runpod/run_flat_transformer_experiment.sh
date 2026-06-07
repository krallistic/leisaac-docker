#!/bin/bash
# run_flat_transformer_experiment.sh — flat-transformer (class-structure) ablation.
#
# Trains ConceptACT with concept_method=flat_transformer: a single NON-class-aware
# concept transformer supervised with per-entry BCE on the concatenated concept
# vector — no class structure in the architecture OR the loss. Compare against the
# class-aware transformer_ce runs (run_classaware_ablation.sh ARM=tce, or
# run_concept_split_experiment.sh METHOD=tce) to test whether the class-aware
# structure is what matters. One pod sweeps PERCENTS × SEEDS.
#
# Required: a GCS key — RUNPOD_SECRET_NAME (preferred) or GCP_KEY_FILE.
#           start-runpod.sh has local defaults for GCS_BUCKET + GCP_KEY_FILE.
# Uses the with_concepts datasets (which have meta/tasks.jsonl).
#
# NOTE: flat_transformer is recent code baked into the image. If you've never run
# it, build a fresh image and launch on the immutable :<sha> tag, NOT :latest
# (a stale :latest would skip it as an unknown policy or lack flat in the fork):
#   docker build -f Dockerfile.train --build-arg CACHEBUST=$(date +%s) -t ...:<sha> .
#   IMAGE=ghcr.io/krallistic/lerobot:<sha> bash runpod/run_flat_transformer_experiment.sh
#
# Override on the command line, e.g.
#   PERCENTS="1.0" SEEDS=42 bash runpod/run_flat_transformer_experiment.sh
#   CONCEPT_GROUP=object bash runpod/run_flat_transformer_experiment.sh   # flat BCE on object concepts only
#
# (Equivalent to ARM=flat bash runpod/run_classaware_ablation.sh, but standalone with
#  its own EXPERIMENT_NAME so the checkpoints group under 'flat'.)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export EXPERIMENT_NAME="${EXPERIMENT_NAME:-flat}"
export PERCENTS="${PERCENTS:-0.2 0.4 0.6 0.8 1.0}"
export SEEDS="${SEEDS:-42 123 456}"

echo ">>> flat-transformer ablation: experiment=${EXPERIMENT_NAME}"
echo "    percents=[${PERCENTS}]  seeds=[${SEEDS}]  group=${CONCEPT_GROUP:-all}"

bash "$SCRIPT_DIR/train-flat-transformer.sh"
