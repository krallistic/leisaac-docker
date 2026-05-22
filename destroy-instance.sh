#!/bin/bash
# destroy-instance.sh
# Run locally. Logs the instance out of Tailscale (removes the device from
# your tailnet), destroys the Vast instance, and clears VAST_INSTANCE_ID in
# env.sh. Idempotent: safe to re-run.

set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKIP_ENV_CHECK=1 source "$SCRIPT_DIR/env.sh"

if [ -z "$VAST_INSTANCE_ID" ]; then
    echo "No VAST_INSTANCE_ID set in env.sh. Nothing to destroy."
    exit 0
fi

echo ">>> Logging instance $VAST_INSTANCE_ID out of Tailscale..."
# Best-effort: instance may already be unreachable. tailscale logout removes
# the device from the admin console; it won't reappear on next provision
# since each instance gets a unique hostname.
ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new \
    "$VAST_SSH_ALIAS" "tailscale logout" 2>/dev/null \
    || echo "    (couldn't reach instance over SSH; will rely on Vast destroy)"

echo ""
echo ">>> Destroying Vast instance $VAST_INSTANCE_ID..."
vastai destroy instance "$VAST_INSTANCE_ID"

echo ""
echo ">>> Clearing VAST_INSTANCE_ID in env.sh..."
sed -i.bak 's|^export VAST_INSTANCE_ID=.*$|export VAST_INSTANCE_ID=""|' "$SCRIPT_DIR/env.sh"

echo ""
echo ">>> Done. If 'tailscale logout' failed above, double-check"
echo "    https://login.tailscale.com/admin/machines and remove the device"
echo "    manually so it doesn't count against your 100-device free limit."