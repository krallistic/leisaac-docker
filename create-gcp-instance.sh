#!/bin/bash
# create-gcp-instance.sh
# Run locally. Creates a GPU VM on GCP, cycling through EU regions/zones and
# GPU types (L4 first, then T4) until one has capacity. Retries the full
# search up to MAX_RETRIES times with a short pause between attempts.
# Opens WebRTC firewall ports, writes the winning config back into env.sh,
# and runs setup-ssh.sh.
#
# Prerequisites (run once):
#   gcloud auth login
#   gcloud config set project YOUR_PROJECT_ID
#   gcloud services enable compute.googleapis.com

set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKIP_ENV_CHECK=1 source "$SCRIPT_DIR/env.sh"

if [ "$GCP_PROJECT" = "YOUR_PROJECT_ID" ]; then
    echo "ERROR: Set GCP_PROJECT in env.sh first."
    exit 1
fi

MAX_RETRIES=5
RETRY_WAIT=30   # seconds between full retry attempts

# === 1. Firewall rule for WebRTC ==========================================
echo ">>> Ensuring WebRTC firewall rule exists..."
if ! gcloud compute firewall-rules describe "${WEBRTC_FIREWALL_TAG}" \
        --project "$GCP_PROJECT" &>/dev/null; then
    gcloud compute firewall-rules create "${WEBRTC_FIREWALL_TAG}" \
        --project "$GCP_PROJECT" \
        --direction INGRESS \
        --action ALLOW \
        --rules "tcp:${SIGNAL_PORT},udp:${MEDIA_PORT}" \
        --source-ranges "0.0.0.0/0" \
        --target-tags "${WEBRTC_FIREWALL_TAG}" \
        --description "Isaac Sim WebRTC signaling (TCP ${SIGNAL_PORT}) + media (UDP ${MEDIA_PORT})"
    echo ">>> Firewall rule created."
else
    echo ">>> Firewall rule '${WEBRTC_FIREWALL_TAG}' already exists — skipping."
fi
echo ""

# === 2. Create the VM =====================================================
echo ">>> Creating instance '${GCP_INSTANCE_NAME}'..."
echo "    Project:  $GCP_PROJECT"
echo "    Disk:     100 GB pd-ssd"
echo "    Image:    common-cu129-ubuntu-2204-nvidia-580 (GCP Deep Learning VM)"
echo ""
echo "    GPU priority:  L4 (g2-standard-4) → T4 (n1-standard-8)"
echo "    Zone order:    GCP_REGION (${GCP_REGION}) → europe-west1/2/3/4/6, europe-central2, us-east1/4, us-central1"
echo "    Max retries:   $MAX_RETRIES"
echo ""
echo ">>> Creating in 5 seconds... (Ctrl+C to cancel)"
sleep 5

# GPU configs tried in order: L4 first (faster, more VRAM), T4 as fallback.
# Format: "accelerator_type|machine_type|label"
GPU_CONFIGS=(
    "nvidia-l4|g2-standard-4|L4 (g2-standard-4)"
    #"nvidia-tesla-t4|n1-standard-8|T4 (n1-standard-8)"
)

# GCP_REGION tried first, then remaining EU regions.
FALLBACK_REGIONS="europe-west2 europe-west4 europe-west1 europe-west3 europe-west6 europe-central2 us-east1 us-east4 us-central1"
REGIONS_TO_TRY="$GCP_REGION"
for r in $FALLBACK_REGIONS; do
    [ "$r" != "$GCP_REGION" ] && REGIONS_TO_TRY="$REGIONS_TO_TRY $r"
done

# Build a flat, ordered zone list: existing disk zone first (so VM and disk are always
# co-located), then all region zones. GCP cannot attach a disk across zones.
DISK_ZONE_HINT=""
if [ -n "${GCP_DISK_ZONE:-}" ] && \
   gcloud compute disks describe "$GCP_DISK_NAME" \
       --project "$GCP_PROJECT" \
       --zone "$GCP_DISK_ZONE" &>/dev/null 2>&1; then
    DISK_ZONE_HINT="$GCP_DISK_ZONE"
    echo ">>> Found existing disk '${GCP_DISK_NAME}' in ${DISK_ZONE_HINT} — trying that zone first."
fi

ZONES_TO_TRY="${DISK_ZONE_HINT}"
for REGION in $REGIONS_TO_TRY; do
    for SUFFIX in a b c; do
        Z="${REGION}-${SUFFIX}"
        [ "$Z" != "$DISK_ZONE_HINT" ] && ZONES_TO_TRY="$ZONES_TO_TRY $Z"
    done
done

USED_ZONE=""
USED_REGION=""
USED_GPU=""
USED_MACHINE=""

for ATTEMPT in $(seq 1 $MAX_RETRIES); do
    echo ""
    echo "========================================"
    echo "Attempt $ATTEMPT / $MAX_RETRIES"
    echo "========================================"

    for GPU_CONFIG in "${GPU_CONFIGS[@]}"; do
        ACCEL_TYPE="${GPU_CONFIG%%|*}"
        REST="${GPU_CONFIG#*|}"
        MACHINE_TYPE="${REST%%|*}"
        GPU_LABEL="${REST#*|}"

        echo ""
        echo "--- Trying GPU: ${GPU_LABEL} ---"

        for CANDIDATE_ZONE in $ZONES_TO_TRY; do
            echo ">>> ${CANDIDATE_ZONE} / ${GPU_LABEL}..."
            if gcloud compute instances create "$GCP_INSTANCE_NAME" \
                    --project "$GCP_PROJECT" \
                    --zone "$CANDIDATE_ZONE" \
                    --machine-type "$MACHINE_TYPE" \
                    --maintenance-policy "TERMINATE" \
                    --accelerator "type=${ACCEL_TYPE},count=1" \
                    --image-family "common-cu129-ubuntu-2204-nvidia-580" \
                    --image-project "deeplearning-platform-release" \
                    --boot-disk-size "100" \
                    --boot-disk-type "pd-ssd" \
                    --tags "${WEBRTC_FIREWALL_TAG}" 2>&1; then
                USED_ZONE="$CANDIDATE_ZONE"
                USED_REGION="${CANDIDATE_ZONE%-*}"
                USED_GPU="$GPU_LABEL"
                USED_MACHINE="$MACHINE_TYPE"
                break 3   # break out of zone / gpu / attempt loops
            else
                echo "    no resources — trying next..."
            fi
        done
    done

    # If we broke out with a result, stop retrying
    [ -n "$USED_ZONE" ] && break

    if [ "$ATTEMPT" -lt "$MAX_RETRIES" ]; then
        echo ""
        echo ">>> All zones exhausted on attempt $ATTEMPT. Waiting ${RETRY_WAIT}s before retry..."
        sleep $RETRY_WAIT
    fi
done

if [ -z "$USED_ZONE" ]; then
    echo ""
    echo "ERROR: No capacity found after $MAX_RETRIES attempts."
    echo "  GPU types tried:"
    for GPU_CONFIG in "${GPU_CONFIGS[@]}"; do
        GPU_LABEL="${GPU_CONFIG##*|}"
        echo "    - ${GPU_LABEL}"
    done
    echo "  Regions tried:"
    for REGION in $REGIONS_TO_TRY; do
        echo "    - ${REGION}-a/b/c"
    done
    echo ""
    echo "Options:"
    echo "  - Wait longer and retry (GCP capacity fluctuates)"
    echo "  - Check availability: https://cloud.google.com/compute/docs/gpus/gpu-regions-zones"
    exit 1
fi

echo ""
echo ">>> Instance created: zone=${USED_ZONE}  gpu=${USED_GPU}  machine=${USED_MACHINE}"

# Persist winning config into env.sh for all downstream scripts
sed -i.bak "s|^export GCP_REGION=.*$|export GCP_REGION=\"${USED_REGION}\"|" \
    "$SCRIPT_DIR/env.sh"
sed -i.bak "s|^export GCP_MACHINE_TYPE=.*$|export GCP_MACHINE_TYPE=\"${USED_MACHINE}\"|" \
    "$SCRIPT_DIR/env.sh"
if grep -q "^export GCP_ZONE=" "$SCRIPT_DIR/env.sh"; then
    sed -i.bak "s|^export GCP_ZONE=.*$|export GCP_ZONE=\"${USED_ZONE}\"|" \
        "$SCRIPT_DIR/env.sh"
else
    echo "export GCP_ZONE=\"${USED_ZONE}\"" >> "$SCRIPT_DIR/env.sh"
fi

# === 3. Fetch external IP =================================================
echo ">>> Fetching external IP..."
EXTERNAL_IP=$(gcloud compute instances describe "$GCP_INSTANCE_NAME" \
    --project "$GCP_PROJECT" \
    --zone "$USED_ZONE" \
    --format "get(networkInterfaces[0].accessConfigs[0].natIP)")

if [ -z "$EXTERNAL_IP" ]; then
    echo "ERROR: Could not retrieve external IP."
    echo "    gcloud compute instances describe $GCP_INSTANCE_NAME --zone $USED_ZONE"
    exit 1
fi

echo ">>> External IP: $EXTERNAL_IP"

sed -i.bak "s|^export GCP_EXTERNAL_IP=.*$|export GCP_EXTERNAL_IP=\"$EXTERNAL_IP\"|" \
    "$SCRIPT_DIR/env.sh"
echo ">>> Wrote GCP_EXTERNAL_IP=$EXTERNAL_IP, GCP_ZONE=$USED_ZONE to env.sh"
echo ""

SKIP_ENV_CHECK=1 source "$SCRIPT_DIR/env.sh"

# === 4. Wait for SSH ======================================================
echo ">>> Waiting for SSH to come up (may take 60-90s)..."
SSH_UP=0
for i in $(seq 1 18); do
    if ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
           -i "$GCP_SSH_KEY" "${GCP_SSH_USER}@${EXTERNAL_IP}" true 2>/dev/null; then
        echo ">>> SSH is up."
        SSH_UP=1
        break
    fi
    echo "    not ready yet ($i/18), retrying in 10s..."
    sleep 10
done

if [ "$SSH_UP" != "1" ]; then
    echo "WARNING: SSH didn't come up within 3 minutes."
    echo "         Once it's reachable, run: bash setup-ssh.sh"
    exit 1
fi

# === 5. Configure SSH and copy files ======================================
echo ""
echo ">>> Configuring SSH alias and copying bundle..."
bash "$SCRIPT_DIR/setup-ssh.sh"

# === 6. Create and attach the persistent data disk ========================
echo ""
echo ">>> Creating and attaching persistent data disk..."
bash "$SCRIPT_DIR/create-disk.sh"
bash "$SCRIPT_DIR/attach-disk.sh"

echo ""
echo "================================================================"
echo "Instance is ready."
echo "  Zone:    ${USED_ZONE}"
echo "  GPU:     ${USED_GPU}"
echo "  Machine: ${USED_MACHINE}"
echo "  IP:      $EXTERNAL_IP"
echo ""
echo "Next steps:"
echo "    1. SSH in and install the software stack (~30-60 min):"
echo "         ssh $GCP_SSH_ALIAS"
echo "         sudo bash /workspace/setup-instance.sh"
echo ""
echo "    2. Smoke test:"
echo "         ssh $GCP_SSH_ALIAS"
echo "         bash /workspace/test-isaac.sh"
echo ""
echo "    3. Stop when done to avoid charges:"
echo "         gcloud compute instances stop $GCP_INSTANCE_NAME \\"
echo "             --zone $USED_ZONE --project $GCP_PROJECT"
echo "================================================================"