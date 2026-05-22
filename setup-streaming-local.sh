#!/bin/bash
# setup-streaming-local.sh
# Run on the LAPTOP.
# Fetches the instance's public IP + external WebRTC ports straight from
# Vast (re-verifies env.sh isn't stale), runs reachability tests for both
# the TCP signaling port and the UDP media port, and prints the endpoint
# to paste into the Isaac Sim WebRTC Streaming Client AppImage.

set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKIP_ENV_CHECK=1 source "$SCRIPT_DIR/env.sh"

: "${VAST_INSTANCE_ID:?Not set in env.sh}"

# === 1. Re-fetch port mapping from Vast (authoritative) ===================
echo ">>> Fetching current port mapping from Vast..."
PORT_INFO=$(vastai show instance "$VAST_INSTANCE_ID" --raw 2>/dev/null | python3 -c "
import sys, json
d = json.load(sys.stdin)
ports = d.get('ports') or {}
def ext(internal):
    entries = ports.get(internal) or []
    return entries[0]['HostPort'] if entries else ''
print('|'.join([
    d.get('public_ipaddr', ''),
    ext('49100/tcp'),
    ext('47998/udp'),
    d.get('actual_status', ''),
]))
")

IFS='|' read -r PUBLIC_IP SIGNAL_PORT MEDIA_PORT STATUS <<< "$PORT_INFO"

if [ "$STATUS" != "running" ]; then
    echo "ERROR: instance status is '$STATUS' (expected 'running')."
    exit 1
fi
if [ -z "$PUBLIC_IP" ] || [ -z "$SIGNAL_PORT" ] || [ -z "$MEDIA_PORT" ]; then
    echo "ERROR: Couldn't get port mapping. Check 'vastai show instance $VAST_INSTANCE_ID'."
    exit 1
fi

echo "    Public IP:    $PUBLIC_IP"
echo "    Signal port:  $SIGNAL_PORT (TCP -> container 49100)"
echo "    Media port:   $MEDIA_PORT (UDP -> container 47998)"
echo ""

# Drift check
if [ "$PUBLIC_IP" != "$VAST_PUBLIC_IP" ] || [ "$SIGNAL_PORT" != "$VAST_SIGNAL_PORT" ] || \
   [ "$MEDIA_PORT" != "$VAST_MEDIA_PORT" ]; then
    echo "WARNING: env.sh is stale. Re-running create-instance.sh's sed block"
    echo "         locally to update — or just paste the fresh values above."
    echo ""
fi

# === 2. TCP signaling reachability ========================================
echo ">>> TCP $SIGNAL_PORT (signaling)..."
if nc -z -G 5 "$PUBLIC_IP" "$SIGNAL_PORT" 2>/dev/null || \
   nc -z -w 5 "$PUBLIC_IP" "$SIGNAL_PORT" 2>/dev/null; then
    echo "    OK"
else
    echo "    closed — expected if Isaac Sim isn't running yet."
    echo "    Re-test once you've started test-isaac.sh on the instance."
fi

# === 3. UDP media reachability ============================================
echo ">>> UDP $MEDIA_PORT (media)..."
if nc -u -z -G 5 "$PUBLIC_IP" "$MEDIA_PORT" 2>/dev/null || \
   nc -u -z -w 5 "$PUBLIC_IP" "$MEDIA_PORT" 2>/dev/null; then
    echo "    OK (best-effort UDP probe; only meaningful while teleop is running)"
else
    echo "    UDP path looks blocked. Common causes:"
    echo "      - corporate firewall on the laptop side"
    echo "      - Vast host's UDP forwarding is broken (rare)"
    echo "    Falls back to TURN relay if Isaac Sim's ICE config has one;"
    echo "    by default it doesn't, so you'll get connect-then-grey-screen."
fi
echo ""

# === 4. Endpoint string ===================================================
echo "================================================================"
echo "AppImage endpoint:"
echo ""
echo "    $PUBLIC_IP:$SIGNAL_PORT"
echo ""
echo "Then on the instance:"
echo "    ssh $VAST_SSH_ALIAS"
echo "    cd /workspace && bash test-isaac.sh"
echo "================================================================"