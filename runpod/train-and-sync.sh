#!/bin/bash
# train-and-sync.sh — runs INSIDE lerobot:latest on RunPod (the image's default CMD).
#
# 1. Pull LeRobot datasets from GCS  (<bucket>/lerobot_datasets → $HF_LEROBOT_HOME)
# 2. Train POLICY × PERCENT × SEED   (mirrors sorting-experiment/03-train-*.sh)
# 3. Sync each finished checkpoint    (→ <bucket>/checkpoints/<job>)
#
# Checkpoint / job naming:
#   <EXPERIMENT_NAME>_<policy_base>_percent_<PERCENT>_seed_<SEED>
#   policy_base:  act_lr<LR>
#                 concept_act_tce_cw<CW>_lr<LR>[_grp<G>][_noise<N>]
#                 concept_act_ph_cw<CW>_lr<LR>[_grp<G>][_noise<N>]
#                 concept_act_flat_cw<CW>_lr<LR>[_grp<G>][_noise<N>]   (flat_transformer ablation)
#                 concept_act_cbm_cw<CW>_lr<LR>[_grp<G>][_noise<N>]    (concept bottleneck model)
#                 diffusion_lr<DIFFUSION_LR>                           (lerobot DiffusionPolicy)
#                 lavact_lr<LR>
#   _grp<G> appears only when CONCEPT_GROUP != all (object/rule concept-split ablation).
#   The _noise<N> suffix is added only when concept_noise > 0 (label-noise
#   robustness experiment), so baseline (noise=0) names are unchanged.
#
# IDEMPOTENT: a job whose checkpoints/last/ already exists in GCS is skipped, so a
# reclaimed spot pod simply resumes the remaining jobs after re-launch.
#
# Required env:
#   GCS_BUCKET      gs://...   (auth is set up by gcs-entrypoint.sh from $GCP_SA_KEY_B64)
#   EXPERIMENT_NAME prefix for every checkpoint/job name
# Optional env:
#   POLICIES        space-separated: act concept_act_tce concept_act_ph concept_act_flat
#                   concept_act_cbm diffusion lavact   (default "concept_act_tce")
#   PERCENTS        dataset-size fractions to sweep (default "0.2 0.4 0.6 0.8 1.0")
#   SEEDS           (default "42 123 456")
#   STEPS           save_freq in steps (default 50000)   EPOCHS (default 5)
#   BATCH_SIZE      (default 8)            LR      (default 3e-5)
#   CONCEPT_WEIGHT  (default 0.2)          CONCEPT_DIM (prediction_head, default 128)
#   CONCEPT_NOISES  per-class label-noise probs to sweep (default "0.0"); concept
#                   policies only — folded into the checkpoint name as _noise<N>
#   CONCEPT_GROUP   all | object (color+shape) | rule (dropoff); concept policies only
#                   — folded into the checkpoint name as _grp<G> when != all
#   DIFFUSION_LR    LR for the diffusion policy (default 1e-4)
#   DIFFUSION_CROP  crop_shape for diffusion: "null" = full image (default), or "[H,W]"
#   NUM_WORKERS     (default 4)            WANDB_ENABLE / WANDB_PROJECT
#   VOLTRON_MODEL/FILM_HIDDEN_DIM/VOLTRON_FREEZE  (lavact only)
#   KEEP_ALIVE      1 = sleep after the sweep (inspect the pod); default 0 = exit
set -euo pipefail

: "${GCS_BUCKET:?set GCS_BUCKET=gs://...}"
: "${EXPERIMENT_NAME:?set EXPERIMENT_NAME (prefixes every checkpoint name)}"
POLICIES="${POLICIES:-concept_act_tce}"
PERCENTS="${PERCENTS:-0.2 0.4 0.6 0.8 1.0}"
SEEDS="${SEEDS:-42 123 456}"
STEPS="${STEPS:-50000}"
EPOCHS="${EPOCHS:-5}"
BATCH_SIZE="${BATCH_SIZE:-32}"
LR="${LR:-3e-5}"
CONCEPT_WEIGHT="${CONCEPT_WEIGHT:-0.2}"
CONCEPT_DIM="${CONCEPT_DIM:-128}"
CONCEPT_NOISES="${CONCEPT_NOISES:-0.0}"
CONCEPT_GROUP="${CONCEPT_GROUP:-all}"
DIFFUSION_LR="${DIFFUSION_LR:-1e-4}"        # diffusion policy uses its own LR (not the ACT LR)
DIFFUSION_CROP="${DIFFUSION_CROP:-null}"    # null = no crop / full image (matches ACT)
NUM_WORKERS="${NUM_WORKERS:-4}"
WANDB_ENABLE="${WANDB_ENABLE:-0}"
WANDB_PROJECT="${WANDB_PROJECT:-sorting-experiment-sim}"

export HF_LEROBOT_HOME=/workspace/lerobot_datasets
CKPT_LOCAL=/workspace/checkpoints
mkdir -p "$HF_LEROBOT_HOME" "$CKPT_LOCAL"

# ── Case registry (mirrors sorting-experiment/common.sh) ──────────────────────
ALL_CASES=(cube_red cube_green cube_yellow rectangle_red rectangle_blue
           rectangle_green rectangle_yellow cylinder_red cylinder_blue cylinder_green)
TEST_CASES=(cube_red rectangle_yellow)        # held out — never trained on
TRAINING_CASES=()
for c in "${ALL_CASES[@]}"; do
    is_test=0; for t in "${TEST_CASES[@]}"; do [ "$c" = "$t" ] && is_test=1; done
    [ "$is_test" = 0 ] && TRAINING_CASES+=("$c")
done

# ── Pull datasets (incremental; full only on a fresh pod) ─────────────────────
echo ">>> pulling datasets from ${GCS_BUCKET}/lerobot_datasets ..."
gcloud storage rsync -r "${GCS_BUCKET}/lerobot_datasets" "$HF_LEROBOT_HOME"

dataset_list() {   # $1 = repo prefix
    local prefix="$1" out=""
    for c in "${TRAINING_CASES[@]}"; do out="${out:+${out},}${prefix}${c}"; done
    echo "$out"
}

wandb_flags() {    # $1 = job name
    if [ "$WANDB_ENABLE" = "1" ]; then
        echo "--wandb.enable=true --wandb.project=${WANDB_PROJECT} --wandb.run_id=$1 --wandb.disable_artifact=true"
    else
        echo "--wandb.enable=false"
    fi
}

train_one() {      # $1 = policy, $2 = percent, $3 = seed, $4 = concept_noise
    local policy="$1" percent="$2" seed="$3" noise="${4:-0.0}" base job ds nsuf="" gsuf=""
    local -a pol
    # Label noise / concept subset only affect concept policies; tag the name so
    # variants don't collide (and the idempotent skip doesn't drop one).
    if [ "$noise" != "0.0" ] && [ "$noise" != "0" ]; then nsuf="_noise${noise}"; fi
    if [ "$CONCEPT_GROUP" != "all" ]; then gsuf="_grp${CONCEPT_GROUP}"; fi
    case "$policy" in
        act|lavact|diffusion)
            if [ -n "${nsuf}${gsuf}" ]; then
                echo "  [skip] ${policy} — concept_noise/concept_group has no effect on a non-concept policy"; return
            fi ;;
    esac
    case "$policy" in
        act)
            base="act_lr${LR}"
            ds="$(dataset_list 'sim/sort_object_')"
            pol=( --policy.type=act --epochs="$EPOCHS" ) ;;
        concept_act_tce)
            base="concept_act_tce_cw${CONCEPT_WEIGHT}_lr${LR}${gsuf}${nsuf}"
            ds="$(dataset_list 'sim/sort_object_with_concepts_')"
            pol=( --policy.type=concept_act --policy.use_concept_learning=true
                  --policy.concept_method=transformer_ce --policy.use_class_aware_concepts=true
                  --policy.concept_weight="$CONCEPT_WEIGHT" --policy.concept_noise="$noise"
                  --policy.concept_group="$CONCEPT_GROUP"
                  --epochs="$EPOCHS" --save_checkpoint=true --save_freq="$STEPS" ) ;;
        concept_act_ph)
            base="concept_act_ph_cw${CONCEPT_WEIGHT}_lr${LR}${gsuf}${nsuf}"
            ds="$(dataset_list 'sim/sort_object_with_concepts_')"
            pol=( --policy.type=concept_act --policy.use_concept_learning=true
                  --policy.concept_method=prediction_head
                  --policy.concept_weight="$CONCEPT_WEIGHT" --policy.concept_dim="$CONCEPT_DIM"
                  --policy.concept_noise="$noise" --policy.concept_group="$CONCEPT_GROUP"
                  --epochs="$EPOCHS" --save_checkpoint=true --save_freq="$STEPS" ) ;;
        concept_act_flat)
            # Ablation: single non-class-aware concept transformer + flat per-entry BCE.
            base="concept_act_flat_cw${CONCEPT_WEIGHT}_lr${LR}${gsuf}${nsuf}"
            ds="$(dataset_list 'sim/sort_object_with_concepts_')"
            pol=( --policy.type=concept_act --policy.use_concept_learning=true
                  --policy.concept_method=flat_transformer --policy.use_class_aware_concepts=false
                  --policy.concept_weight="$CONCEPT_WEIGHT" --policy.concept_noise="$noise"
                  --policy.concept_group="$CONCEPT_GROUP"
                  --epochs="$EPOCHS" --save_checkpoint=true --save_freq="$STEPS" ) ;;
        concept_act_cbm)
            # Concept Bottleneck Model: actions flow ONLY through the predicted concepts
            # (prediction_head concepts -> single bottleneck token -> decoder). VAE off so
            # the only obs->action path is through the concepts.
            base="concept_act_cbm_cw${CONCEPT_WEIGHT}_lr${LR}${gsuf}${nsuf}"
            ds="$(dataset_list 'sim/sort_object_with_concepts_')"
            pol=( --policy.type=concept_act --policy.use_concept_learning=true
                  --policy.concept_method=prediction_head --policy.use_concept_bottleneck=true
                  --policy.use_vae=false --policy.concept_dim="$CONCEPT_DIM"
                  --policy.concept_weight="$CONCEPT_WEIGHT" --policy.concept_noise="$noise"
                  --policy.concept_group="$CONCEPT_GROUP"
                  --epochs="$EPOCHS" --save_checkpoint=true --save_freq="$STEPS" ) ;;
        diffusion)
            # LeRobot's built-in Diffusion Policy (plain datasets, no concepts). crop_shape
            # defaults to "null" = full 480x640 image (matches ACT; default (84,84) would
            # crop peripheral objects out). Uses its own LR (DIFFUSION_LR, default 1e-4).
            base="diffusion_lr${DIFFUSION_LR}"
            ds="$(dataset_list 'sim/sort_object_')"
            pol=( --policy.type=diffusion --policy.optimizer_lr="$DIFFUSION_LR"
                  --policy.crop_shape="$DIFFUSION_CROP"
                  --epochs="$EPOCHS" --save_checkpoint=true --save_freq="$STEPS" ) ;;
        lavact)
            if ! python -c "import voltron" 2>/dev/null; then
                echo "  [skip] lavact — voltron-robotics not in image (add it to Dockerfile.train)"; return
            fi
            base="lavact_lr${LR}"
            ds="$(dataset_list 'sim/sort_object_')"
            pol=( --policy.type=lavact --policy.voltron_model="${VOLTRON_MODEL:-v-cond}"
                  --policy.film_hidden_dim="${FILM_HIDDEN_DIM:-512}"
                  --policy.voltron_freeze="${VOLTRON_FREEZE:-true}"
                  --epochs="$EPOCHS" --save_checkpoint=true --save_freq="$STEPS" ) ;;
        *)  echo "  [skip] unknown POLICY=$policy"; return ;;
    esac

    # ACT-family shares the experiment LR + n_heads=16; diffusion has no attention heads
    # and sets its own LR above, so it must NOT receive these.
    if [ "$policy" != "diffusion" ]; then
        pol+=( --policy.optimizer_lr="$LR" --policy.n_heads=16 )
    fi

    # NAMING: <experiment>_<policy_base>_percent_<percent>_seed_<seed>
    job="${EXPERIMENT_NAME}_${base}_percent_${percent}_seed_${seed}"

    if gcloud storage ls "${GCS_BUCKET}/checkpoints/${job}/checkpoints/last/" &>/dev/null; then
        echo "  [skip] ${job} — already in GCS"; return
    fi

    echo "──────────────────────────────────────────────"
    echo ">>> training ${job}  (dataset_percent=${percent})"
    echo "    datasets: ${ds}"
    # shellcheck disable=SC2046
    python -m lerobot.scripts.train \
        --dataset.repo_id="$ds" \
        --policy.device=cuda \
        "${pol[@]}" \
        --dataset_percent="$percent" \
        --batch_size="$BATCH_SIZE" --num_workers="$NUM_WORKERS" \
        --output_dir="${CKPT_LOCAL}/${job}" --job_name="${job}" --seed="$seed" \
        $(wandb_flags "$job")

    echo ">>> syncing ${job} → ${GCS_BUCKET}/checkpoints/${job}"
    gcloud storage rsync -r "${CKPT_LOCAL}/${job}" "${GCS_BUCKET}/checkpoints/${job}"
    echo ">>> done ${job}"
}

echo "=== sweep: experiment=${EXPERIMENT_NAME}  policies=[${POLICIES}]  group=${CONCEPT_GROUP}  percents=[${PERCENTS}]  noises=[${CONCEPT_NOISES}]  seeds=[${SEEDS}] ==="
FAILED_JOBS=()
for policy in $POLICIES; do
    for noise in $CONCEPT_NOISES; do
        for percent in $PERCENTS; do
            for seed in $SEEDS; do
                # `set -e` would abort the WHOLE sweep if one run errors; catch it so
                # the remaining jobs still run (and still get synced).
                if ! train_one "$policy" "$percent" "$seed" "$noise"; then
                    echo "!!! FAILED: ${policy} noise=${noise} percent=${percent} seed=${seed} — continuing"
                    FAILED_JOBS+=("${policy}:noise${noise}:${percent}:${seed}")
                fi
            done
        done
    done
done

if [ ${#FAILED_JOBS[@]} -gt 0 ]; then
    echo "=== sweep finished with FAILURES: ${FAILED_JOBS[*]} ==="
else
    echo "=== sweep complete — all checkpoints in ${GCS_BUCKET}/checkpoints ==="
fi
if [ "${KEEP_ALIVE:-0}" = "1" ]; then
    echo ">>> KEEP_ALIVE=1 — sleeping; terminate the pod manually when done."
    sleep infinity
fi
