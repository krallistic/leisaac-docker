#!/bin/bash
# test-4-scene-leisaac.sh — the REAL leisaac scene (SO-101 PickOrange kitchen)
# with WebRTC streaming, but NO teleop rig. Uses the keyboard device, which
# (unlike so101leader) needs no ZMQ leader and no --remote_endpoint, so there's
# none of the `connect_to localhost port 5556` spam. The robot just sits idle —
# the point is to confirm the actual leisaac scene loads, renders, and streams
# before adding the SO-101 leader in test-5.
#
# This exercises the same task registration and USD assets as test-5, so if
# this streams cleanly the only remaining variable in test-5 is the teleop ZMQ.
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

TASK="${TASK:-LeIsaac-SO101-PickOrange-v0}"

echo ">>> Test 4: leisaac scene, no teleop — ${TASK}"
build_kit_args
echo ""

docker run "${COMMON_FLAGS[@]}" \
    --entrypoint /isaac-sim/python.sh \
    "$IMAGE" \
    /workspace/leisaac/scripts/environments/teleoperation/teleop_se3_agent.py \
    --task="${TASK}" \
    --teleop_device=keyboard \
    --num_envs=1 --device=cuda --headless --enable_cameras \
    --livestream 2 \
    --kit_args="${KIT_ARGS}"