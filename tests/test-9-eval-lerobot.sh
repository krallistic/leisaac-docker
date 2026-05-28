#!/bin/bash
# test-9-eval-lerobot.sh — Evaluate a trained LeRobot policy in the IsaacLab
# simulation using two separate containers connected over gRPC:
#
#   Container 1  lerobot:latest  — policy server (AsyncInference gRPC)
#   Container 2  leisaac:latest  — IsaacLab env + eval client
#
# WHY TWO CONTAINERS: leisaac:latest is based on the Isaac Sim image (Python
# 3.11 + IsaacLab); lerobot:latest is a plain CUDA image (Python 3.10 +
# lerobot). The dependency sets are incompatible, so they cannot share a single
# image. Both containers use --network=host so they communicate over localhost.
#
# STARTUP ORDER:
#   1. Start the policy server in the background and poll until it responds.
#   2. Start the leisaac eval container in the foreground (interactive).
#   3. On exit (success or ctrl-c), stop the policy server container.
#
# INPUT:  $HOST_CHECKPOINTS/$JOB_NAME  (checkpoint from test-8)
# Key variables (override via env):
#   TASK             Isaac Sim task name
#   POLICY_TYPE      lerobot policy type passed to policy_inference.py,
#                    e.g. "lerobot-act", "lerobot-smolvla"
#   POLICY_PORT      gRPC port (default 5555)
#   CHECKPOINT_PATH  Path to the pretrained model INSIDE the lerobot container
#   EVAL_ROUNDS      Number of evaluation episodes (0 = run until manual exit)
#   STEP_HZ          Environment stepping rate in Hz
#   HOST_CHECKPOINTS Directory containing the checkpoint (mounted read-only)
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Set CONTAINER_NAME before sourcing so that COMMON_FLAGS uses "lerobot-eval"
# as the container name for the leisaac eval client.
export CONTAINER_NAME="${CONTAINER_NAME:-lerobot-eval}"
source "$SCRIPT_DIR/common.sh"

TASK="${TASK:-LeIsaac-SO101-PickOrange-v0}"
POLICY_TYPE="${POLICY_TYPE:-lerobot-act}"
POLICY_PORT="${POLICY_PORT:-5555}"
JOB_NAME="${JOB_NAME:-lerobot_act}"
CHECKPOINT_PATH="${CHECKPOINT_PATH:-/workspace/checkpoints/${JOB_NAME}/checkpoints/last/pretrained_model}"
EVAL_ROUNDS="${EVAL_ROUNDS:-10}"
STEP_HZ="${STEP_HZ:-30}"
POLICY_LANGUAGE_INSTRUCTION="${POLICY_LANGUAGE_INSTRUCTION:-pick the orange and place it in the bowl}"

HOST_CHECKPOINTS="${HOST_CHECKPOINTS:-${WORK_DIR}/leisaac/checkpoints}"

LEROBOT_IMAGE="${LEROBOT_IMAGE:-lerobot:latest}"
SERVER_CONTAINER="lerobot-server"
EVAL_CONTAINER="$CONTAINER_NAME"  # set above; already baked into COMMON_FLAGS

# Cleanup helper — called on EXIT to ensure the server is stopped.
cleanup() {
    echo ""
    echo ">>> Stopping policy server container..."
    docker stop "$SERVER_CONTAINER" >/dev/null 2>&1 || true
    docker rm   "$SERVER_CONTAINER" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# Remove stale containers.
docker rm "$SERVER_CONTAINER" >/dev/null 2>&1 || true
docker rm "$EVAL_CONTAINER"   >/dev/null 2>&1 || true

build_kit_args

echo ""
echo ">>> Test 9: LeRobot policy eval (two-container setup)"
echo ">>> Policy server : ${LEROBOT_IMAGE}  port=${POLICY_PORT}"
echo ">>> Eval client   : ${IMAGE}  task=${TASK}"
echo ">>> Checkpoint    : ${HOST_CHECKPOINTS}/${JOB_NAME}"
echo ">>> eval_rounds=${EVAL_ROUNDS}  step_hz=${STEP_HZ}"
echo ""

# ── Step 1: Start policy server container in the background. ─────────────────
echo ">>> Starting policy server..."
docker run -d \
    --name "$SERVER_CONTAINER" \
    --gpus all \
    --network=host \
    -v "${HOST_CHECKPOINTS}:/workspace/checkpoints:ro" \
    "$LEROBOT_IMAGE" \
    python -m lerobot.scripts.server.policy_server \
        --port "${POLICY_PORT}"

# Poll until the server port is reachable (up to 120 s).
echo ">>> Waiting for policy server on port ${POLICY_PORT}..."
MAX_WAIT=120
ELAPSED=0
until docker exec "$SERVER_CONTAINER" python -c \
    "import socket, sys; s=socket.socket(); s.settimeout(2); \
     r=s.connect_ex(('localhost', ${POLICY_PORT})); s.close(); sys.exit(r)" \
    >/dev/null 2>&1; do
    sleep 3
    ELAPSED=$((ELAPSED + 3))
    if [ "$ELAPSED" -ge "$MAX_WAIT" ]; then
        echo "ERROR: Policy server did not come up within ${MAX_WAIT} s."
        exit 1
    fi
    echo "  ... waiting (${ELAPSED}s)"
done
echo ">>> Policy server is up."
echo ""

# ── Step 2: Run the leisaac eval client in the foreground. ───────────────────
# COMMON_FLAGS already includes --rm --name "$EVAL_CONTAINER" --gpus all
# --network=host and all cache mounts; no need to repeat them.
docker run \
    "${COMMON_FLAGS[@]}" \
    --entrypoint /isaac-sim/python.sh \
    "$IMAGE" \
    /workspace/leisaac/scripts/evaluation/policy_inference.py \
    --task="${TASK}" \
    --policy_type="${POLICY_TYPE}" \
    --policy_host="localhost" \
    --policy_port="${POLICY_PORT}" \
    --policy_checkpoint_path="${CHECKPOINT_PATH}" \
    --policy_language_instruction="${POLICY_LANGUAGE_INSTRUCTION}" \
    --eval_rounds="${EVAL_ROUNDS}" \
    --step_hz="${STEP_HZ}" \
    --device=cuda --headless --enable_cameras \
    --livestream 2 \
    --kit_args="${KIT_ARGS}"

echo ""
echo ">>> Test 9 complete."
