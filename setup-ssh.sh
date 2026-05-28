#!/bin/bash
# setup-ssh.sh
# Run locally.
# Writes/updates the SSH alias for the GCP instance in ~/.ssh/config and
# copies the workspace bundle to the VM. Re-run after stop/start cycles if
# the external IP changes (use --address to reserve a static IP to avoid this).
#
# Unlike Vast.ai, GCP doesn't remap ports on the fly, so there's no
# port-mapping lookup here. WebRTC ports are opened in the firewall by
# create-gcp-instance.sh and remain fixed at SIGNAL_PORT / MEDIA_PORT.

set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env.sh"

# === 1. Refresh external IP (in case instance was stopped/started) ========
echo ">>> Looking up external IP for instance '${GCP_INSTANCE_NAME}'..."
EXTERNAL_IP=$(gcloud compute instances describe "$GCP_INSTANCE_NAME" \
    --project "$GCP_PROJECT" \
    --zone "$GCP_ZONE" \
    --format "get(networkInterfaces[0].accessConfigs[0].natIP)" 2>/dev/null || echo "")

if [ -z "$EXTERNAL_IP" ]; then
    echo "ERROR: Could not retrieve external IP."
    echo "       Is the instance running?"
    echo "       Check: gcloud compute instances list --project $GCP_PROJECT"
    exit 1
fi

echo "    IP: $EXTERNAL_IP"

# Update env.sh if the IP changed (stop/start gives a new ephemeral IP)
if [ "$EXTERNAL_IP" != "$GCP_EXTERNAL_IP" ]; then
    sed -i.bak "s|^export GCP_EXTERNAL_IP=.*$|export GCP_EXTERNAL_IP=\"$EXTERNAL_IP\"|" \
        "$SCRIPT_DIR/env.sh"
    echo "    (updated GCP_EXTERNAL_IP in env.sh)"
fi

# === 2. Write SSH config ==================================================
SSH_CONFIG="$HOME/.ssh/config"
mkdir -p "$HOME/.ssh"
touch "$SSH_CONFIG"
chmod 600 "$SSH_CONFIG"

# Idempotent: remove existing block for our alias before rewriting.
if grep -q "^Host ${GCP_SSH_ALIAS}$" "$SSH_CONFIG"; then
    # Remove the old block (from "Host ALIAS" to the next "Host " line)
    python3 - "$SSH_CONFIG" "$GCP_SSH_ALIAS" <<'PYEOF'
import sys
path, alias = sys.argv[1], sys.argv[2]
with open(path) as f:
    lines = f.readlines()
out, skip = [], False
for line in lines:
    if line.strip() == f"Host {alias}":
        skip = True
    elif skip and line.startswith("Host "):
        skip = False
    if not skip:
        out.append(line)
with open(path, 'w') as f:
    f.writelines(out)
PYEOF
fi

cat >> "$SSH_CONFIG" <<EOF

Host ${GCP_SSH_ALIAS}
    HostName ${EXTERNAL_IP}
    Port 22
    User ${GCP_SSH_USER}
    IdentityFile ${GCP_SSH_KEY}
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
    ServerAliveInterval 60
    ServerAliveCountMax 3
    # WebRTC viewer: open http://localhost:8211/streaming/webrtc-client/
    # in your browser while SSH'd in.
    LocalForward 8211 localhost:8211
    # TensorBoard
    LocalForward 6006 localhost:6006
    # SO-101 leader arm publisher: cloud-side teleop connects to
    # tcp://localhost:5556, tunnelled back to your laptop where
    # so101_joint_state_server.py is running.
    RemoteForward 5556 localhost:5556
EOF

echo ""
echo ">>> Wrote SSH alias '${GCP_SSH_ALIAS}' to ${SSH_CONFIG}"

# === 3. Wait for SSH ======================================================
echo ""
echo ">>> Waiting for SSH to accept connections..."
SSH_READY=0
for i in $(seq 1 12); do
    if ssh -o BatchMode=yes -o ConnectTimeout=5 \
           "${GCP_SSH_ALIAS}" true 2>/dev/null; then
        SSH_READY=1
        echo ">>> SSH ready."
        break
    fi
    echo "    not ready yet ($i/12), retrying in 5s..."
    sleep 5
done

if [ "$SSH_READY" != "1" ]; then
    echo ""
    echo "WARNING: SSH didn't come up within 60s."
    exit 0
fi

# === 4. Copy bundle to instance ===========================================
echo ""
echo ">>> Copying bundle to ${GCP_SSH_ALIAS}:/workspace/ ..."
ssh "${GCP_SSH_ALIAS}" "sudo mkdir -p /workspace && sudo chown \$USER:\$USER /workspace"
# -r so the tests/ subdir is recursed into (plain scp skips directories).
# The /* glob brings env.sh, keys.sh (if present), *.sh, Dockerfile and tests/.
scp -rq \
    "$SCRIPT_DIR"/* \
    "${GCP_SSH_ALIAS}":/workspace/
ssh "${GCP_SSH_ALIAS}" "chmod +x /workspace/*.sh /workspace/tests/*.sh 2>/dev/null || true"
echo ">>> Bundle copied."
echo ""
echo "Next:"
echo "    ssh ${GCP_SSH_ALIAS}"
echo "    sudo bash /workspace/setup-drivers.sh"