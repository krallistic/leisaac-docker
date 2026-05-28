#!/bin/bash
# 04-eval.sh — Evaluate trained policies on the held-out sort-object test cases
# in simulation using the two-container gRPC architecture.
#
# Architecture (mirrors tests/test-9-eval-lerobot.sh):
#   Container 1  lerobot:latest    — policy gRPC server
#   Container 2  leisaac:latest    — sorting_experiment_eval.py (Isaac Sim client)
# Both containers use --network=host. Streaming over Tailscale.
#
# Per-episode scoring (see sorting_experiment_eval.py):
#   3 = complete success: object in the correct area
#   2 = wrong sort: object placed in the wrong area
#   1 = place failed: object was lifted but not placed in any area
#   0 = pick failed: object was never lifted
#
# Sorting rule (matches sort_object_env_cfg.py _SORTING_TABLE):
#   Area A: (cube ∧ color∈{red,green}) ∨ (cylinder ∧ blue)
#   Area B: everything else
# Test cases: cube_red → A,  rectangle_yellow → B
#
# Output per checkpoint × test case:
#   /data/sorting-experiment/eval/{experiment_name}/{case}/results.json
#
# A run is skipped when results.json already exists. Set FORCE=1 to re-run.
#
# Key overrideable env vars:
#   EVAL_ROUNDS      episodes per test case per checkpoint (default: 10)
#   STEP_HZ          env stepping rate in Hz (default: 30)
#   POLICY_PORT      gRPC port for the policy server (default: 5555)
#   FORCE            1 = re-evaluate even if results.json exists (default: 0)
#   CHECKPOINT_GLOB  glob to select a subset of experiment dirs (default: *)
#   EPISODE_LENGTH_S max seconds per episode (default: 60)

set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

EVAL_ROUNDS="${EVAL_ROUNDS:-10}"
STEP_HZ="${STEP_HZ:-30}"
POLICY_PORT="${POLICY_PORT:-5555}"
FORCE="${FORCE:-0}"
CHECKPOINT_GLOB="${CHECKPOINT_GLOB:-*}"
EPISODE_LENGTH_S="${EPISODE_LENGTH_S:-60}"

# ── Discover trained checkpoints ──────────────────────────────────────────────
CHECKPOINTS=()
while IFS= read -r -d '' last_dir; do
    exp_name="$(basename "$(dirname "$(dirname "$last_dir")")")"
    CHECKPOINTS+=("$exp_name")
done < <(find "${CHECKPOINTS_DIR}" -path "*/${CHECKPOINT_GLOB}/checkpoints/last" -type d -print0 2>/dev/null | sort -z)

echo "=== Sort-object evaluation (structured) ==="
echo "  Checkpoints dir : ${CHECKPOINTS_DIR}"
echo "  Test cases      : ${TEST_CASES[*]}"
echo "  Scoring rule    : Area A = (cube∧{red,green}) ∨ (cylinder∧blue); else Area B"
echo "  Eval rounds     : ${EVAL_ROUNDS} per case  step_hz=${STEP_HZ}"
echo ""

if [ ${#CHECKPOINTS[@]} -eq 0 ]; then
    echo "No checkpoints found in ${CHECKPOINTS_DIR}. Run 03-train.sh first."
    exit 1
fi

echo "Found ${#CHECKPOINTS[@]} checkpoint(s):"
for exp in "${CHECKPOINTS[@]}"; do
    echo "  ${exp}"
done
echo ""

build_kit_args
echo ""

# ── Main eval loop ────────────────────────────────────────────────────────────
for exp_name in "${CHECKPOINTS[@]}"; do
    CKPT_PATH_HOST="${CHECKPOINTS_DIR}/${exp_name}/checkpoints/last/pretrained_model"
    CKPT_PATH_CTR="/workspace/checkpoints/${exp_name}/checkpoints/last/pretrained_model"
    SERVER_CONTAINER="lerobot-server-${exp_name}"

    # Infer policy type from experiment name prefix
    if [[ "$exp_name" == concept_act* ]]; then
        POLICY_TYPE="lerobot-concept_act"
    elif [[ "$exp_name" == lavact* ]]; then
        POLICY_TYPE="lerobot-lavact"
    else
        POLICY_TYPE="lerobot-act"
    fi

    echo "════════════════════════════════════════════════════════"
    echo ">>> Checkpoint : ${exp_name}"
    echo ">>> Policy type: ${POLICY_TYPE}"
    echo ""

    # Skip entirely if all test cases are already evaluated
    all_done=1
    for case in "${TEST_CASES[@]}"; do
        result="${EVAL_DIR}/${exp_name}/${case}/results.json"
        if [ ! -f "$result" ] || [ "$FORCE" = "1" ]; then
            all_done=0; break
        fi
    done
    if [ "$all_done" = "1" ]; then
        echo "  [skip] all test cases already have results.json."
        echo ""
        continue
    fi

    # ── Start policy server ───────────────────────────────────────────────────
    docker rm "$SERVER_CONTAINER" >/dev/null 2>&1 || true

    echo ">>> Starting policy server (port ${POLICY_PORT})..."
    docker run -d \
        --name "$SERVER_CONTAINER" \
        --gpus all --network=host \
        -v "${CHECKPOINTS_DIR}:/workspace/checkpoints:ro" \
        "$LEROBOT_IMAGE" \
        python -m lerobot.scripts.server.policy_server \
        --port "${POLICY_PORT}"

    # Poll until the server is reachable (up to 120 s)
    MAX_WAIT=120; ELAPSED=0
    until docker exec "$SERVER_CONTAINER" python -c \
        "import socket,sys; s=socket.socket(); s.settimeout(2); r=s.connect_ex(('localhost',${POLICY_PORT})); s.close(); sys.exit(r)" \
        >/dev/null 2>&1; do
        sleep 3; ELAPSED=$((ELAPSED + 3))
        if [ "$ELAPSED" -ge "$MAX_WAIT" ]; then
            echo "ERROR: policy server did not start within ${MAX_WAIT}s."
            docker stop "$SERVER_CONTAINER" >/dev/null 2>&1 || true
            exit 1
        fi
        echo "  ... waiting for server (${ELAPSED}s)"
    done
    echo ">>> Policy server is up."
    echo ""

    cleanup_server() {
        echo ">>> Stopping policy server..."
        docker stop "$SERVER_CONTAINER" >/dev/null 2>&1 || true
        docker rm   "$SERVER_CONTAINER" >/dev/null 2>&1 || true
    }
    trap cleanup_server EXIT

    # ── Evaluate each test case ───────────────────────────────────────────────
    for case in "${TEST_CASES[@]}"; do
        TASK="$(case_to_task "$case")"
        shape="$(case_shape "$case")"; color="$(case_color "$case")"
        expected_area="$(determine_dropoff "$color" "$shape")"
        RESULT_DIR="${EVAL_DIR}/${exp_name}/${case}"
        RESULT_JSON="${RESULT_DIR}/results.json"
        EVAL_CONTAINER="lerobot-eval-${exp_name}-${case}"

        if [ -f "$RESULT_JSON" ] && [ "$FORCE" != "1" ]; then
            echo "  [skip] ${case} — results.json already exists."
            continue
        fi

        mkdir -p "$RESULT_DIR"
        docker rm "$EVAL_CONTAINER" >/dev/null 2>&1 || true

        # Result JSON will be written inside the container at this path.
        RESULT_JSON_CTR="/workspace/eval/${exp_name}/${case}/results.json"

        # For LAVact: provide a per-case language instruction so the model can
        # condition on the specific object and target area.
        # Override LAVACT_INSTRUCTION_TEMPLATE to change the format; use the
        # variables {color}, {shape}, {area} which are substituted below.
        LANG_FLAGS=()
        if [[ "$POLICY_TYPE" == *lavact* ]]; then
            template="${LAVACT_INSTRUCTION_TEMPLATE:-Pick up the {color} {shape} and place it in Area {area}}"
            instruction="${template//\{color\}/$color}"
            instruction="${instruction//\{shape\}/$shape}"
            instruction="${instruction//\{area\}/$expected_area}"
            LANG_FLAGS=(--policy_language_instruction="${instruction}")
        fi

        echo "────────────────────────────────────────────────────────"
        echo ">>> Eval: ${exp_name} × ${case}"
        echo ">>>   Task         : ${TASK}"
        echo ">>>   Expected area: ${expected_area}"
        echo ">>>   Rounds       : ${EVAL_ROUNDS}"
        if [ ${#LANG_FLAGS[@]} -gt 0 ]; then
            echo ">>>   Language instr: ${LANG_FLAGS[0]#*=}"
        fi
        echo ">>>   Output JSON  : ${RESULT_JSON}"
        echo ""

        # The sort_object assets are BAKED INTO the image; do NOT mount the
        # host assets directory (would shadow the baked-in sort_object USD).
        docker run --rm --name "$EVAL_CONTAINER" \
            --gpus all --network=host \
            -e ACCEPT_EULA=Y -e PRIVACY_CONSENT=Y \
            -e NVIDIA_DRIVER_CAPABILITIES=all \
            -e PYTHONPATH="${LEISAAC_SRC}" \
            -v "${CHECKPOINTS_DIR}:/workspace/checkpoints:ro" \
            -v "${EVAL_DIR}:/workspace/eval" \
            -v "${SCRIPT_DIR}/sorting_experiment_eval.py:/workspace/sorting_experiment_eval.py:ro" \
            -v "${CACHE_ROOT}/kit:/isaac-sim/kit/cache:rw" \
            -v "${CACHE_ROOT}/ov:/isaac-sim/.cache/ov:rw" \
            -v "${CACHE_ROOT}/glcache:/isaac-sim/.cache/nvidia/GLCache:rw" \
            -v "${CACHE_ROOT}/computecache:/isaac-sim/.nv/ComputeCache:rw" \
            -v "${CACHE_ROOT}/pip:/isaac-sim/.cache/pip:rw" \
            -v "${WORK_DIR}/docker/leisaac/logs:/isaac-sim/.nvidia-omniverse/logs:rw" \
            -v /usr/share/vulkan/icd.d:/usr/share/vulkan/icd.d:ro \
            --entrypoint /isaac-sim/python.sh \
            "$IMAGE" \
            /workspace/sorting_experiment_eval.py \
            --task="${TASK}" \
            --case="${case}" \
            --checkpoint_name="${exp_name}" \
            --policy_type="${POLICY_TYPE}" \
            --policy_host="localhost" \
            --policy_port="${POLICY_PORT}" \
            --policy_checkpoint_path="${CKPT_PATH_CTR}" \
            --eval_rounds="${EVAL_ROUNDS}" \
            --step_hz="${STEP_HZ}" \
            --episode_length_s="${EPISODE_LENGTH_S}" \
            --output_json="${RESULT_JSON_CTR}" \
            "${LANG_FLAGS[@]}" \
            --device=cuda --headless --enable_cameras \
            --livestream 2 \
            --kit_args="${KIT_ARGS}"

        echo ""
        if [ -f "$RESULT_JSON" ]; then
            # Print a one-line summary from the JSON
            python3 -c "
import json, sys
with open('${RESULT_JSON}') as f: d = json.load(f)
a = d['aggregated']
print(f'  success_rate={a[\"success_rate\"]:.1%}  avg_score={a[\"average_score\"]:.2f}  dist={a[\"score_distribution\"]}')
" 2>/dev/null || true
        fi
        echo ""
    done

    cleanup_server
    trap - EXIT
    echo ""
done

# ── Cross-checkpoint summary ──────────────────────────────────────────────────
echo "=== Evaluation summary ==="
for exp_name in "${CHECKPOINTS[@]}"; do
    for case in "${TEST_CASES[@]}"; do
        result="${EVAL_DIR}/${exp_name}/${case}/results.json"
        if [ -f "$result" ]; then
            python3 -c "
import json
with open('${result}') as f: d = json.load(f)
a = d['aggregated']
m = d['metadata']
print(f'  {m[\"checkpoint\"]:50s}  {m[\"case\"]:20s}  '
      f'success={a[\"success_rate\"]:5.1%}  avg={a[\"average_score\"]:.2f}  '
      f'[3:{a[\"score_distribution\"][\"score_3_success\"]} '
      f'2:{a[\"score_distribution\"][\"score_2_wrong_sort\"]} '
      f'1:{a[\"score_distribution\"][\"score_1_place_failed\"]} '
      f'0:{a[\"score_distribution\"][\"score_0_pick_failed\"]}]')
" 2>/dev/null || echo "  ${exp_name} / ${case} — [parse error]"
        fi
    done
done
echo ""
echo "All results in: ${EVAL_DIR}"
