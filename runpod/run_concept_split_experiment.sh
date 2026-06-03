#!/bin/bash
# run_concept_split_experiment.sh — which concepts matter?
#
# Trains with only a subset of the concepts supervised, one pod per group, under one
# EXPERIMENT_NAME and the same percents × seeds, so the only difference is *which*
# concepts the model is asked to learn:
#   object — concept_color + concept_shape (perceptual object attributes)
#   rule   — concept_dropoff (the target / sorting-rule concept)
# Checkpoints get a _grp<G> suffix, directly comparable to your full (all-concepts) runs.
#
# Required: a GCS key — RUNPOD_SECRET_NAME (preferred) or GCP_KEY_FILE.
#           start-runpod.sh has local defaults for GCS_BUCKET + GCP_KEY_FILE.
#
# Override any of these on the command line, e.g.
#   GROUPS="object" bash runpod/run_concept_split_experiment.sh         # only object concepts
#   GROUPS="all object rule" bash runpod/run_concept_split_experiment.sh # include the full baseline
#   METHOD=ph   bash runpod/run_concept_split_experiment.sh             # prediction-head instead of transformer_ce
#   METHOD=flat bash runpod/run_concept_split_experiment.sh             # flat_transformer
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export EXPERIMENT_NAME="${EXPERIMENT_NAME:-conceptsplit}"
export PERCENTS="${PERCENTS:-0.2 0.4 0.6 0.8 1.0}"
export SEEDS="${SEEDS:-42 123 456}"

# GROUPS: which concept subsets to launch — one pod each (default: object + rule).
GROUPS="${GROUPS:-object rule}"
# METHOD: tce (transformer_ce, default) | ph (prediction_head) | flat (flat_transformer)
METHOD="${METHOD:-tce}"

case "$METHOD" in
    tce)  WRAPPER=train-concept-act.sh ;;
    ph)   WRAPPER=train-prediction-head.sh ;;
    flat) WRAPPER=train-flat-transformer.sh ;;
    *)    echo "ERROR: METHOD must be tce | ph | flat (got '$METHOD')"; exit 1 ;;
esac

echo ">>> concept-split experiment: experiment=${EXPERIMENT_NAME}  method=${METHOD}"
echo "    groups=[${GROUPS}]  percents=[${PERCENTS}]  seeds=[${SEEDS}]"

for g in $GROUPS; do
    case "$g" in all|object|rule) ;; *) echo "ERROR: group must be all|object|rule (got '$g')"; exit 1 ;; esac
    echo "=== launching group=${g} ==="
    CONCEPT_GROUP="$g" NAME="${EXPERIMENT_NAME}-${METHOD}-${g}-$(date +%H%M%S)" \
        bash "$SCRIPT_DIR/$WRAPPER"
done
