#!/bin/bash
# benchmark-and-sync.sh — runs INSIDE lerobot:latest on RunPod when RUN_MODE=timing.
#
# A *quick timing* run (no training, no checkpoints): for each policy it builds an
# UNTRAINED model from one case's dataset and measures
#   - train step:  wall-clock for forward + backward + optimizer.step on one batch
#   - inference:   wall-clock for one full action-chunk (averaged over many calls)
# via cact_scripts/timing_benchmark.py, then syncs the combined CSV/JSON to GCS.
#
# Dispatched from train-and-sync.sh (the image CMD) when RUN_MODE=timing, so it
# launches through the exact same start-runpod.sh path as the training sweeps.
#
# Required env:
#   GCS_BUCKET      gs://...   (auth set up by gcs-entrypoint.sh from $GCP_SA_KEY_B64)
#   EXPERIMENT_NAME prefix for the results path in GCS
# Optional env:
#   POLICIES        space-separated subset of:
#                     act concept_act_tce concept_act_ph concept_act_cbm diffusion lavact
#                   (default: all six listed above)
#   CASE            dataset case to load (default cube_green — a training case that
#                   exists as both plain and with_concepts)
#   BATCH_SIZE      train-step batch size (default 32, matches the real sweeps)
#   BENCH_INFER_BS  inference batch size (default 1 — single-robot deployment)
#   BENCH_WARMUP / BENCH_ITERS / BENCH_INFER_WARMUP / BENCH_INFER_ITERS  (see python)
#   CONCEPT_WEIGHT (0.2)  CONCEPT_DIM (128)  NUM_WORKERS (4)
#   KEEP_ALIVE      1 = sleep after the run (inspect the pod); default 0 = exit
set -euo pipefail

: "${GCS_BUCKET:?set GCS_BUCKET=gs://...}"
: "${EXPERIMENT_NAME:?set EXPERIMENT_NAME (prefixes the results path)}"
POLICIES="${POLICIES:-act concept_act_tce concept_act_ph concept_act_cbm diffusion lavact}"
CASE="${CASE:-cube_green}"
BATCH_SIZE="${BATCH_SIZE:-32}"
CONCEPT_WEIGHT="${CONCEPT_WEIGHT:-0.2}"
CONCEPT_DIM="${CONCEPT_DIM:-128}"
NUM_WORKERS="${NUM_WORKERS:-4}"
LEROBOT_DIR="${LEROBOT_DIR:-/lerobot}"

# Forwarded to the python harness (all have defaults there too).
export BENCH_INFER_BS="${BENCH_INFER_BS:-1}"
export BENCH_WARMUP="${BENCH_WARMUP:-5}"
export BENCH_ITERS="${BENCH_ITERS:-30}"
export BENCH_INFER_WARMUP="${BENCH_INFER_WARMUP:-10}"
export BENCH_INFER_ITERS="${BENCH_INFER_ITERS:-50}"

export HF_LEROBOT_HOME=/workspace/lerobot_datasets
RESULTS_DIR="/workspace/timing/${EXPERIMENT_NAME}"
mkdir -p "$HF_LEROBOT_HOME" "$RESULTS_DIR"
export BENCH_CSV="${RESULTS_DIR}/timing_results.csv"

# ── Pull just the one case (plain + with_concepts) ────────────────────────────
PLAIN_REPO="sim/sort_object_${CASE}"
CONCEPT_REPO="sim/sort_object_with_concepts_${CASE}"
echo ">>> pulling datasets for case '${CASE}' from ${GCS_BUCKET}/lerobot_datasets ..."
gcloud storage rsync -r "${GCS_BUCKET}/lerobot_datasets/${PLAIN_REPO}"   "${HF_LEROBOT_HOME}/${PLAIN_REPO}"
gcloud storage rsync -r "${GCS_BUCKET}/lerobot_datasets/${CONCEPT_REPO}" "${HF_LEROBOT_HOME}/${CONCEPT_REPO}"

bench_one() {   # $1 = policy
    local policy="$1" repo label
    local -a pol
    case "$policy" in
        act)
            label="act"; repo="$PLAIN_REPO"
            pol=( --policy.type=act ) ;;
        concept_act_tce)
            label="concept_act_tce"; repo="$CONCEPT_REPO"
            pol=( --policy.type=concept_act --policy.use_concept_learning=true
                  --policy.concept_method=transformer_ce --policy.use_class_aware_concepts=true
                  --policy.concept_weight="$CONCEPT_WEIGHT" ) ;;
        concept_act_ph)
            label="concept_act_ph"; repo="$CONCEPT_REPO"
            pol=( --policy.type=concept_act --policy.use_concept_learning=true
                  --policy.concept_method=prediction_head
                  --policy.concept_weight="$CONCEPT_WEIGHT" --policy.concept_dim="$CONCEPT_DIM" ) ;;
        concept_act_cbm)
            label="concept_act_cbm"; repo="$CONCEPT_REPO"
            pol=( --policy.type=concept_act --policy.use_concept_learning=true
                  --policy.concept_method=prediction_head --policy.use_concept_bottleneck=true
                  --policy.use_vae=false --policy.concept_dim="$CONCEPT_DIM"
                  --policy.concept_weight="$CONCEPT_WEIGHT" ) ;;
        diffusion)
            label="diffusion"; repo="$PLAIN_REPO"
            # crop_shape=null = full image (matches the diffusion training runs).
            pol=( --policy.type=diffusion --policy.crop_shape=null ) ;;
        lavact)
            if ! python -c "import voltron" 2>/dev/null; then
                echo "  [skip] lavact — voltron-robotics not in image (add it to Dockerfile.train)"; return
            fi
            label="lavact"; repo="$PLAIN_REPO"
            pol=( --policy.type=lavact --policy.voltron_model="${VOLTRON_MODEL:-v-cond}"
                  --policy.film_hidden_dim="${FILM_HIDDEN_DIM:-512}"
                  --policy.voltron_freeze="${VOLTRON_FREEZE:-true}" ) ;;
        *)  echo "  [skip] unknown POLICY=$policy"; return ;;
    esac

    # ACT-family uses n_heads=16 (as in the real sweeps); diffusion has no attention heads.
    if [ "$policy" != "diffusion" ]; then
        pol+=( --policy.n_heads=16 )
    fi

    echo "──────────────────────────────────────────────"
    echo ">>> timing ${label}  (dataset=${repo}, batch_size=${BATCH_SIZE})"
    BENCH_LABEL="$label" python "${LEROBOT_DIR}/cact_scripts/timing_benchmark.py" \
        --dataset.repo_id="$repo" \
        --policy.device=cuda \
        "${pol[@]}" \
        --batch_size="$BATCH_SIZE" --num_workers="$NUM_WORKERS" \
        --steps=1
}

echo "=== timing: experiment=${EXPERIMENT_NAME}  policies=[${POLICIES}]  case=${CASE}  batch_size=${BATCH_SIZE}  infer_bs=${BENCH_INFER_BS} ==="
FAILED=()
for policy in $POLICIES; do
    if ! bench_one "$policy"; then
        echo "!!! FAILED: ${policy} — continuing"
        FAILED+=("$policy")
    fi
done

echo ">>> syncing results → ${GCS_BUCKET}/timing/${EXPERIMENT_NAME}"
gcloud storage rsync -r "$RESULTS_DIR" "${GCS_BUCKET}/timing/${EXPERIMENT_NAME}"

if [ -f "$BENCH_CSV" ]; then
    echo "=== results ==="
    cat "$BENCH_CSV"
fi
if [ ${#FAILED[@]} -gt 0 ]; then
    echo "=== timing finished with FAILURES: ${FAILED[*]} ==="
else
    echo "=== timing complete — results in ${GCS_BUCKET}/timing/${EXPERIMENT_NAME} ==="
fi
if [ "${KEEP_ALIVE:-0}" = "1" ]; then
    echo ">>> KEEP_ALIVE=1 — sleeping; terminate the pod manually when done."
    sleep infinity
fi
