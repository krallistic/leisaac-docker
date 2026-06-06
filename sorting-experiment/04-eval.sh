#!/bin/bash
# 04-eval.sh — Evaluate trained sorting-experiment policies that now live in GCS
# (pushed by runpod/train-and-sync.sh) in the IsaacLab simulation, on an L4 GCP
# instance.
#
# WHAT CHANGED vs the old local-disk version: training moved to RunPod and every
# checkpoint is synced to GCS, so this script no longer reads checkpoints from
# /data. Instead it:
#   1. lists the checkpoint jobs under  gs://<bucket>/checkpoints/
#   2. for each job, skips it if  gs://<bucket>/eval/<job>/  already has results
#      for every test case (set FORCE=1 to re-eval)
#   3. downloads ONLY the latest step's pretrained_model to a host staging dir
#   4. reads the policy type from the checkpoint's config.json ("type")
#   5. runs the two-container gRPC eval via docker compose (docker-compose.eval.yml)
#   6. uploads each results.json to  gs://<bucket>/eval/<job>/<case>/results.json
#
# CHECKPOINT PATH NOTE: train.py writes checkpoints/last/ as a SYMLINK to the
# latest step dir, and symlinks are NOT synced to GCS. So under each job there is
#   gs://<bucket>/checkpoints/<job>/checkpoints/<STEP>/pretrained_model/
# (no "last/"). We pick the highest-numbered <STEP>.
#
# POLICY TYPE: taken from pretrained_model/config.json ("type" = act |
# concept_act | diffusion | lavact) and passed to the eval client as
# lerobot-<type>. No name parsing.
#
# Architecture (docker-compose.eval.yml):
#   policy-server  lerobot:latest   gRPC policy server (one fresh server per job)
#   eval-client    leisaac:latest   sorting_experiment_eval.py (one run per case)
# Both use network_mode: host.
#
# Per-episode scoring (see sorting_experiment_eval.py):
#   3 = success (correct area)  2 = wrong area  1 = lifted not placed  0 = never lifted
# Sorting rule (matches sort_object_env_cfg.py _SORTING_TABLE):
#   Area A: (cube ∧ {red,green}) ∨ (cylinder ∧ blue);  Area B: everything else
#   Test cases: cube_red → A,  rectangle_yellow → B
#
# Key overrideable env vars:
#   GCS_BUCKET        gs://...                  (default gs://leisaac-training-<project>)
#   GCP_KEY_FILE      SA key activated for GCS  (default ../runpod/runpod-sa-key.json)
#   SKIP_GCS_AUTH=1   don't activate the SA key (use ambient gcloud creds)
#   CHECKPOINT_GLOB   job-name glob to select a subset of jobs (default *)
#   EVAL_ROUNDS       episodes per test case (default 10)
#   STEP_HZ           env stepping rate Hz (default 30)
#   EPISODE_LENGTH_S  max seconds per episode (default 30, matches the env design)
#   RENDER_INTERVAL   render+refresh cameras every N steps (speed); unset = every step.
#                     Try 16 (= policy_action_horizon). Obs goes N-steps stale — A/B-validate.
#   POLICY_PORT       gRPC port (default 5555)
#   FORCE=1           re-evaluate even if results exist in GCS (overwrites)
#   APPEND=1          accumulate: add EVAL_ROUNDS more episodes onto the existing
#                     GCS results.json (merged + re-aggregated). Implies a re-run.
#   LIVESTREAM        0 = headless (default); 2 = WebRTC stream (needs Tailscale)
#   CLEANUP_STAGING   delete the downloaded checkpoint after each job (default 1,
#                     so /data doesn't fill up over a 144-job sweep); set 0 to keep
#   LAVACT_INSTRUCTION_TEMPLATE  language template for lavact ({color}/{shape}/{area})
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

# ── Config ────────────────────────────────────────────────────────────────────
GCS_BUCKET="${GCS_BUCKET:-gs://leisaac-training-${GCP_PROJECT:-uni-ulm-compute-stuff}}"
GCP_KEY_FILE="${GCP_KEY_FILE:-${SCRIPT_DIR}/../runpod/runpod-sa-key.json}"
SKIP_GCS_AUTH="${SKIP_GCS_AUTH:-0}"
CHECKPOINT_GLOB="${CHECKPOINT_GLOB:-*}"
EVAL_ROUNDS="${EVAL_ROUNDS:-5}"
STEP_HZ="${STEP_HZ:-30}"
EPISODE_LENGTH_S="${EPISODE_LENGTH_S:-20}"   # matches the env's own design value
POLICY_PORT="${POLICY_PORT:-5555}"
FORCE="${FORCE:-0}"
APPEND="${APPEND:-0}"
LIVESTREAM="${LIVESTREAM:-0}"
CLEANUP_STAGING="${CLEANUP_STAGING:-1}"   # default: delete each checkpoint after its job (avoid filling /data); set 0 to keep

COMPOSE_FILE="${SCRIPT_DIR}/docker-compose.eval.yml"
COMPOSE_PROJECT="sorting-eval"
EVAL_SCRIPT="${SCRIPT_DIR}/sorting_experiment_eval.py"
STAGING_DIR="${EXP_DIR}/eval-staging/checkpoints"   # EXP_DIR from common.sh
mkdir -p "$STAGING_DIR" "$EVAL_DIR"

# ── Env consumed by docker-compose.eval.yml (${VAR} interpolation) ────────────
export LEROBOT_IMAGE
export LEISAAC_IMAGE="$IMAGE"          # common.sh sets IMAGE to the leisaac image
export POLICY_PORT LEISAAC_SRC CACHE_ROOT WORK_DIR EVAL_SCRIPT
export HOST_CHECKPOINTS="$STAGING_DIR"
export HOST_EVAL="$EVAL_DIR"

COMPOSE=(docker compose -p "$COMPOSE_PROJECT" -f "$COMPOSE_FILE")

# ── GCS auth ──────────────────────────────────────────────────────────────────
# The L4 instance's default compute SA only has the read-only storage scope, so
# pushing results back would fail. Activate the bucket-scoped runpod SA key
# (objectAdmin) the way the RunPod side authenticates.
if [ "$SKIP_GCS_AUTH" != "1" ] && [ -f "$GCP_KEY_FILE" ]; then
    echo ">>> Activating GCS service account: ${GCP_KEY_FILE}"
    gcloud auth activate-service-account --key-file="$GCP_KEY_FILE" --quiet
elif [ "$SKIP_GCS_AUTH" != "1" ]; then
    echo ">>> No SA key at ${GCP_KEY_FILE} — using ambient gcloud credentials."
    echo "    (writing results to GCS needs read+write on ${GCS_BUCKET}.)"
fi

# ── Streaming / kit args ──────────────────────────────────────────────────────
if [ "$LIVESTREAM" != "0" ]; then
    build_kit_args                       # enforces Tailscale, sets KIT_ARGS + endpoint
    LIVESTREAM_FLAG=(--livestream "$LIVESTREAM")
else
    KIT_ARGS="--/rtx/verifyDriverVersion/enabled=false"
    LIVESTREAM_FLAG=()
fi

# Optional render throttle (speed): render + refresh cameras only every N steps
# instead of every step. ~85% of eval time is rendering, and the policy reads an
# obs only every policy_action_horizon steps, so RENDER_INTERVAL=16 can cut most
# of it. Makes obs up to N steps stale — A/B-validate scores before trusting it.
RENDER_FLAG=()
[ -n "${RENDER_INTERVAL:-}" ] && RENDER_FLAG=(--render_interval="$RENDER_INTERVAL")

# APPEND: accumulate eval rounds across runs. The existing GCS results.json is
# pre-downloaded per case (below) so the eval script prepends its episodes.
APPEND_FLAG=()
[ "$APPEND" = "1" ] && APPEND_FLAG=(--append)

cleanup() { "${COMPOSE[@]}" down --remove-orphans >/dev/null 2>&1 || true; }
trap cleanup EXIT
# Clear any stale stack from a crashed run (the fixed container_name would
# otherwise block `up`).
"${COMPOSE[@]}" down --remove-orphans >/dev/null 2>&1 || true

# ── GCS helpers ───────────────────────────────────────────────────────────────
gcs_has() { gcloud storage ls "$1" >/dev/null 2>&1; }

# Highest numeric step dir under <job>/checkpoints/  (no "last" symlink in GCS).
highest_step() {
    gcloud storage ls "${GCS_BUCKET}/checkpoints/$1/checkpoints/" 2>/dev/null \
        | sed -n 's#.*/checkpoints/\([0-9][0-9]*\)/$#\1#p' | sort -n | tail -1
}

# ── Evaluate one checkpoint job (all not-yet-done test cases) ─────────────────
eval_one_job() {
    local job="$1" step c
    step="$(highest_step "$job")"
    if [ -z "$step" ]; then
        echo "  [skip] ${job} — no numeric step checkpoint found in GCS"
        return 0
    fi

    # Which test cases still need an eval?
    local need=()
    for c in "${TEST_CASES[@]}"; do
        if [ "$FORCE" = "1" ] || [ "$APPEND" = "1" ] || ! gcs_has "${GCS_BUCKET}/eval/${job}/${c}/results.json"; then
            need+=("$c")
        fi
    done
    if [ ${#need[@]} -eq 0 ]; then
        echo "  [skip] ${job} — eval already in GCS for all test cases"
        return 0
    fi

    # Pull just the latest step's pretrained_model (idempotent rsync).
    local pm_gcs="${GCS_BUCKET}/checkpoints/${job}/checkpoints/${step}/pretrained_model"
    local pm_local="${STAGING_DIR}/${job}/checkpoints/${step}/pretrained_model"
    local ckpt_ctr="/workspace/checkpoints/${job}/checkpoints/${step}/pretrained_model"
    mkdir -p "$pm_local"
    echo ">>> [${job}] downloading checkpoint (step ${step}) ..."
    if ! gcloud storage rsync -r "$pm_gcs" "$pm_local"; then
        echo "  [fail] ${job} — could not download ${pm_gcs}"
        [ "$CLEANUP_STAGING" = "1" ] && rm -rf "${STAGING_DIR:?}/${job}"   # drop partial download
        return 1
    fi

    # Policy type from config.json: act | concept_act | diffusion | lavact.
    local ptype policy_type
    ptype="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['type'])" \
             "${pm_local}/config.json" 2>/dev/null)"
    if [ -z "$ptype" ]; then
        echo "  [warn] ${job} — could not read 'type' from config.json; defaulting to act"
        ptype="act"
    fi
    policy_type="lerobot-${ptype}"

    echo "════════════════════════════════════════════════════════"
    echo ">>> Job         : ${job}"
    echo ">>> Step        : ${step}"
    echo ">>> Policy type : ${policy_type}"
    echo ">>> Cases       : ${need[*]}"
    echo ""

    # Fresh policy server for THIS checkpoint (serves both its test cases).
    if ! "${COMPOSE[@]}" up -d --wait policy-server; then
        echo "  [fail] ${job} — policy server did not become healthy"
        "${COMPOSE[@]}" logs --tail 40 policy-server 2>/dev/null || true
        "${COMPOSE[@]}" down --remove-orphans >/dev/null 2>&1 || true
        return 1
    fi

    local rc=0
    for c in "${need[@]}"; do
        local task shape color area out_ctr out_host
        task="$(case_to_task "$c")"
        shape="$(case_shape "$c")"; color="$(case_color "$c")"
        area="$(determine_dropoff "$color" "$shape")"
        out_ctr="/workspace/eval/${job}/${c}/results.json"
        out_host="${EVAL_DIR}/${job}/${c}/results.json"

        # APPEND: seed the local file from GCS so the eval script (mounted at
        # out_ctr) can prepend the prior episodes and accumulate rounds.
        if [ "$APPEND" = "1" ] && gcs_has "${GCS_BUCKET}/eval/${job}/${c}/results.json"; then
            mkdir -p "$(dirname "$out_host")"
            gcloud storage cp "${GCS_BUCKET}/eval/${job}/${c}/results.json" "$out_host" >/dev/null 2>&1 || true
        fi

        # lavact needs a per-case language instruction; other policies ignore it.
        local lang=()
        if [[ "$policy_type" == *lavact* ]]; then
            local tmpl instr
            tmpl="${LAVACT_INSTRUCTION_TEMPLATE:-Pick up the {color} {shape} and place it in Area {area}}"
            instr="${tmpl//\{color\}/$color}"
            instr="${instr//\{shape\}/$shape}"
            instr="${instr//\{area\}/$area}"
            lang=(--policy_language_instruction="$instr")
        fi

        echo "──────────────────────────────────────────"
        echo ">>> Eval ${job} × ${c}  (task=${task}  expected_area=${area}  rounds=${EVAL_ROUNDS})"
        if ! "${COMPOSE[@]}" run --rm --no-deps eval-client \
                /workspace/sorting_experiment_eval.py \
                --task="$task" --case="$c" --checkpoint_name="$job" \
                --policy_type="$policy_type" \
                --policy_host=localhost --policy_port="$POLICY_PORT" \
                --policy_checkpoint_path="$ckpt_ctr" \
                --eval_rounds="$EVAL_ROUNDS" --step_hz="$STEP_HZ" \
                --episode_length_s="$EPISODE_LENGTH_S" \
                "${RENDER_FLAG[@]}" "${APPEND_FLAG[@]}" \
                --output_json="$out_ctr" \
                "${lang[@]}" \
                --device=cuda --headless --enable_cameras \
                "${LIVESTREAM_FLAG[@]}" \
                --kit_args="$KIT_ARGS"; then
            echo "  [fail] eval ${job} × ${c}"
            rc=1
            continue
        fi

        if [ -f "$out_host" ]; then
            echo ">>> syncing results → ${GCS_BUCKET}/eval/${job}/${c}/results.json"
            gcloud storage cp "$out_host" "${GCS_BUCKET}/eval/${job}/${c}/results.json" || rc=1
            python3 -c "
import json
a = json.load(open('${out_host}'))['aggregated']
print(f'    success={a[\"success_rate\"]:.1%}  avg={a[\"average_score\"]:.2f}  dist={a[\"score_distribution\"]}')" 2>/dev/null || true
        else
            echo "  [warn] no results.json produced for ${job} × ${c}"
            rc=1
        fi
    done

    "${COMPOSE[@]}" down --remove-orphans >/dev/null 2>&1 || true

    if [ "$CLEANUP_STAGING" = "1" ]; then
        echo ">>> cleaning up local checkpoint ${STAGING_DIR}/${job}"
        rm -rf "${STAGING_DIR:?}/${job}"
    fi
    return $rc
}

# ── Main ──────────────────────────────────────────────────────────────────────
echo "=== Sort-object evaluation from GCS ==="
echo "  Bucket      : ${GCS_BUCKET}"
echo "  Job filter  : ${CHECKPOINT_GLOB}"
echo "  Test cases  : ${TEST_CASES[*]}"
echo "  Eval rounds : ${EVAL_ROUNDS}  step_hz=${STEP_HZ}  episode_len=${EPISODE_LENGTH_S}s"
echo "  Streaming   : $([ "$LIVESTREAM" != 0 ] && echo "livestream ${LIVESTREAM}" || echo "headless")"
echo "  Scoring     : Area A = (cube∧{red,green}) ∨ (cylinder∧blue); else Area B"
echo ""

# Discover checkpoint jobs from GCS and apply the glob filter.
JOBS=()
while IFS= read -r j; do
    [ -z "$j" ] && continue
    case "$j" in $CHECKPOINT_GLOB) JOBS+=("$j") ;; esac
done < <(gcloud storage ls "${GCS_BUCKET}/checkpoints/" 2>/dev/null \
         | sed -n 's#.*/checkpoints/\([^/][^/]*\)/$#\1#p' | sort)

if [ ${#JOBS[@]} -eq 0 ]; then
    echo "No checkpoint jobs found in ${GCS_BUCKET}/checkpoints matching '${CHECKPOINT_GLOB}'."
    echo "(Has training synced yet? Check: gcloud storage ls ${GCS_BUCKET}/checkpoints/)"
    exit 1
fi

echo "Found ${#JOBS[@]} checkpoint job(s) to consider:"
printf '  %s\n' "${JOBS[@]}"
echo ""

FAILED=()
for job in "${JOBS[@]}"; do
    if ! eval_one_job "$job"; then
        FAILED+=("$job")
        echo "!!! issues evaluating ${job} — continuing"
    fi
    echo ""
done

# ── Summary (jobs evaluated this run; everything also lives in GCS eval/) ─────
echo "=== Evaluation summary ==="
for job in "${JOBS[@]}"; do
    for c in "${TEST_CASES[@]}"; do
        r="${EVAL_DIR}/${job}/${c}/results.json"
        [ -f "$r" ] || continue
        python3 -c "
import json
d = json.load(open('${r}')); a = d['aggregated']; m = d['metadata']
sd = a['score_distribution']
print(f'  {m[\"checkpoint\"]:54s} {m[\"case\"]:18s} '
      f'success={a[\"success_rate\"]:5.1%} avg={a[\"average_score\"]:.2f} '
      f'[3:{sd[\"score_3_success\"]} 2:{sd[\"score_2_wrong_sort\"]} '
      f'1:{sd[\"score_1_place_failed\"]} 0:{sd[\"score_0_pick_failed\"]}]')" 2>/dev/null \
        || echo "  ${job} / ${c} — [parse error]"
    done
done
echo ""
echo "Results in GCS: ${GCS_BUCKET}/eval/   (local copies under ${EVAL_DIR})"
if [ ${#FAILED[@]} -gt 0 ]; then
    echo "FAILURES: ${FAILED[*]}"
    exit 1
fi
echo "All done."
