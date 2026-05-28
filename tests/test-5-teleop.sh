#!/bin/bash
# test-5-teleop.sh — full target workflow: leisaac SO-101 PickOrange scene with
# WebRTC streaming and SO-101 leader teleop over ZMQ.
#
# Run tests 1-4 first to isolate import / transport / cuboid scene / leisaac
# scene. If test-4 streamed the kitchen cleanly, the only new variable here is
# the SO-101 leader teleop path.
#
# NOTE: `connect_to localhost port 5556: failed` lines are the SO-101 ZMQ leader
# endpoint and are EXPECTED until a leader is connected — they do not affect
# streaming. The leader publisher (so101_joint_state_server.py) runs on your
# laptop and reaches the VM via the RemoteForward 5556 SSH tunnel (or directly
# over Tailscale). Press `b` in the streamed view to start teleoperation.
# Override the endpoint/device/task with the env vars below.
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

TASK="${TASK:-LeIsaac-SO101-PickOrange-v0}"
TELEOP_DEVICE="${TELEOP_DEVICE:-so101leader}"
REMOTE_ENDPOINT="${REMOTE_ENDPOINT:-tcp://localhost:5556}"

echo ">>> Test 5: Teleoperation — ${TASK}"
build_kit_args
echo ""

docker run "${COMMON_FLAGS[@]}" \
    --entrypoint /isaac-sim/python.sh \
    "$IMAGE" \
    /workspace/leisaac/scripts/environments/teleoperation/teleop_se3_agent.py \
    --task="${TASK}" \
    --teleop_device="${TELEOP_DEVICE}" \
    --remote_endpoint="${REMOTE_ENDPOINT}" \
    --num_envs=1 --device=cuda --headless --enable_cameras \
    --livestream 2 \
    --kit_args="${KIT_ARGS}"