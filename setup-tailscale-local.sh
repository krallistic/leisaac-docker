#!/bin/bash
# setup-tailscale-local.sh
# Run on the LAPTOP.
# Verifies your laptop is on the tailnet, fetches the instance's Tailscale IP,
# and runs reachability tests (TCP signaling + UDP media) so you know the
# WebRTC stream will actually work before you launch Isaac Sim.
#
# Exits cleanly even if things aren't ready yet — just tells you what's wrong.

set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKIP_ENV_CHECK=1 source "$SCRIPT_DIR/env.sh"

# === 1. Local Tailscale install ===========================================
if ! command -v tailscale >/dev/null 2>&1; then
    echo "ERROR: tailscale not installed on this machine."
    echo ""
    echo "Install:"
    echo "  macOS:   brew install --cask tailscale   (or download from tailscale.com/download)"
    echo "  Linux:   curl -fsSL https://tailscale.com/install.sh | sh"
    echo "  Windows: https://tailscale.com/download/windows"
    exit 1
fi

# === 2. Local Tailscale login =============================================
if ! tailscale status >/dev/null 2>&1; then
    echo "Tailscale daemon not running or you're not logged in."
    echo "Run: tailscale up"
    echo "(macOS GUI app: launch Tailscale and sign in.)"
    exit 1
fi

LOCAL_TS_IP=$(tailscale ip -4 2>/dev/null | head -1)
echo ">>> Laptop is on the tailnet."
echo "    Laptop TS IP: $LOCAL_TS_IP"
echo ""

# === 3. Instance reachability via SSH =====================================
if [ -z "$VAST_SSH_ALIAS" ]; then
    echo "ERROR: VAST_SSH_ALIAS not set in env.sh."
    exit 1
fi

echo ">>> Checking SSH to instance ($VAST_SSH_ALIAS)..."
if ! ssh -o ConnectTimeout=10 -o BatchMode=yes "$VAST_SSH_ALIAS" 'true' 2>/dev/null; then
    echo "ERROR: Can't SSH to $VAST_SSH_ALIAS."
    echo "       Run: bash setup-ssh.sh  (and confirm the instance is up)"
    exit 1
fi

# === 4. Fetch instance's Tailscale IP =====================================
echo ">>> Fetching instance's Tailscale IP..."
TS_IP=$(ssh "$VAST_SSH_ALIAS" 'tailscale ip -4 2>/dev/null | head -1' || true)
if [ -z "$TS_IP" ]; then
    echo "ERROR: Instance has no Tailscale IP yet."
    echo "       Either setup-instance.sh hasn't run, or tailscaled failed."
    echo "       Check on instance: tailscale status; tail -50 /var/log/tailscaled.log"
    exit 1
fi
echo "    Instance TS IP: $TS_IP"
echo ""

# === 5. Reachability tests ================================================
echo ">>> Ping (basic ICMP reachability)..."
if ping -c 3 -W 3 "$TS_IP" >/dev/null 2>&1; then
    echo "    OK"
else
    echo "    FAILED — tailnet routing isn't working. Check 'tailscale status' both sides."
    exit 1
fi

echo ">>> TCP 49100 (WebRTC signaling)..."
# nc -z for TCP; works on both macOS and Linux. Brief timeout to fail fast.
if nc -z -G 5 "$TS_IP" 49100 2>/dev/null || nc -z -w 5 "$TS_IP" 49100 2>/dev/null; then
    echo "    OK — signaling port reachable."
else
    echo "    closed (expected if teleop isn't running yet — re-test once Isaac Sim is up)"
fi

echo ">>> UDP 47998 (WebRTC media)..."
# UDP test is best-effort: nc -u -z reports OK if no ICMP unreachable comes back.
# Run only while teleop is actually streaming for a meaningful result.
if nc -u -z -G 5 "$TS_IP" 47998 2>/dev/null || nc -u -z -w 5 "$TS_IP" 47998 2>/dev/null; then
    echo "    OK (no ICMP-unreachable — best-effort test)"
else
    echo "    UDP path looks blocked."
    echo "    Most common cause: container started with userspace networking instead"
    echo "    of /dev/net/tun. Check on instance: ip link show tailscale0"
    echo "    If missing, this Vast host can't do kernel-mode tailscale. Re-provision."
fi
echo ""

# === 6. Hand off the endpoint =============================================
echo "================================================================"
echo "Ready. In the Isaac Sim WebRTC Streaming Client AppImage, enter:"
echo ""
echo "    $TS_IP:49100"
echo ""
echo "Then start the sim on the instance:"
echo "    ssh $VAST_SSH_ALIAS"
echo "    cd /workspace && bash test-isaac.sh"
echo "================================================================"