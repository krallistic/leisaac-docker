#!/bin/bash
# setup-tailscale.sh — run ON THE GCP INSTANCE (with sudo).
#
# Installs Tailscale, brings it up, and writes the VM's tailnet IP into env.sh
# as STREAM_IP — the publicEndpointAddress that test-isaac.sh advertises to the
# WebRTC client.
#
# WHY: Isaac Sim's WebRTC media (UDP 47998) does not traverse public-internet
# NAT (isaac-sim bug #308/#539). Putting the VM and the client on one Tailscale
# network and advertising the VM's tailnet IP makes the connection look local,
# which is the configuration that actually works.
#
# AUTH (non-interactive): generate an auth key (reusable + ephemeral is ideal
# for VMs that get recreated) at https://login.tailscale.com/admin/settings/keys
#     sudo TS_AUTHKEY=tskey-auth-xxxx bash setup-tailscale.sh
# Without TS_AUTHKEY it falls back to interactive login (prints a URL to open).
#
# IDEMPOTENT: re-running reuses the existing install/login and just refreshes
# STREAM_IP in env.sh.

set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/env.sh"
TS_HOSTNAME="${TS_HOSTNAME:-leisaac-dev}"

if [ "$EUID" -ne 0 ]; then
    echo "ERROR: run as root or with sudo: sudo bash $0"
    exit 1
fi

# --- 1. Install Tailscale (idempotent) ---------------------------------------
if ! command -v tailscale &>/dev/null; then
    echo ">>> Installing Tailscale..."
    curl -fsSL https://tailscale.com/install.sh | sh
else
    echo ">>> Tailscale already installed."
fi

# --- 2. Bring the tailnet up -------------------------------------------------
if [ -n "$(tailscale ip -4 2>/dev/null)" ]; then
    echo ">>> Tailscale already up."
elif [ -n "$TS_AUTHKEY" ]; then
    echo ">>> Bringing Tailscale up (auth key)..."
    tailscale up --authkey="$TS_AUTHKEY" --hostname="$TS_HOSTNAME"
else
    echo ">>> No TS_AUTHKEY set — interactive login. Open the URL it prints:"
    tailscale up --hostname="$TS_HOSTNAME"
fi

# --- 3. Capture the tailnet IPv4 ---------------------------------------------
STREAM_IP="$(tailscale ip -4 2>/dev/null | head -1)"
if [ -z "$STREAM_IP" ]; then
    echo "ERROR: could not determine Tailscale IPv4 address. Check: tailscale status"
    exit 1
fi
echo ">>> Tailnet IP: $STREAM_IP"

# --- 4. Write STREAM_IP into env.sh (idempotent) -----------------------------
if [ ! -f "$ENV_FILE" ]; then
    echo "ERROR: env.sh not found at $ENV_FILE"
    exit 1
fi
if grep -q '^export STREAM_IP=' "$ENV_FILE"; then
    sed -i.bak "s|^export STREAM_IP=.*$|export STREAM_IP=\"${STREAM_IP}\"|" "$ENV_FILE"
else
    echo "export STREAM_IP=\"${STREAM_IP}\"" >> "$ENV_FILE"
fi
echo ">>> Wrote STREAM_IP=${STREAM_IP} to ${ENV_FILE}"
echo ""
echo "Done. Streaming will advertise ${STREAM_IP} as the WebRTC endpoint."
echo "Connect the WebRTC client to ${STREAM_IP}, then: bash ${SCRIPT_DIR}/test-isaac.sh"