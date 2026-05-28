#!/bin/bash
# test-2-stream-empty.sh — streaming transport check, NO scene, NO leisaac.
# Launches Isaac Sim's bare runheadless app and serves WebRTC. An EMPTY
# viewport in the client is the success case here — it proves the pipe works
# before any scene/physics/teleop is involved.
#
# While it runs, in a second SSH session confirm the media socket binds during
# a client connect:   sudo ss -ulnp | grep -i kit   (look for udp 47998)
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

echo ">>> Test 2: Headless streaming, empty stage (no scene)."
build_kit_args
echo ""

# runheadless.sh is the bare streaming app; pass the livestream endpoint flags
# directly (no --kit_args wrapper, no AppLauncher).
RH_ARGS=()
if [ -n "$PUBLIC_IP" ]; then
    RH_ARGS+=( "--/app/livestream/publicEndpointAddress=${PUBLIC_IP}" "--/app/livestream/port=${SIGNAL}" )
fi

docker run "${COMMON_FLAGS[@]}" \
    --entrypoint /isaac-sim/runheadless.sh \
    "$IMAGE" \
    -v \
    "${RH_ARGS[@]}"