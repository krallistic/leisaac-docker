#!/bin/bash
# test-3-stream-scene.sh — streaming with a real rendered scene, via IsaacLab's
# AppLauncher --livestream 2 path (the SAME livestream extension teleop uses),
# but with the trivial cuboid tutorial: no leisaac, no kitchen USD, no ZMQ.
#
# This is the key isolation step: if test-2 (bare runheadless) behaved
# differently, this confirms the AppLauncher --livestream 2 transport renders
# and streams a scene. You should see a single cuboid in the client.
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

echo ">>> Test 3: Headless streaming with a scene (cuboid tutorial)."
build_kit_args
echo ""

docker run "${COMMON_FLAGS[@]}" \
    --entrypoint /isaac-sim/python.sh \
    "$IMAGE" \
    /workspace/isaaclab/scripts/tutorials/00_sim/launch_app.py \
    --livestream 2 \
    --kit_args="${KIT_ARGS}"