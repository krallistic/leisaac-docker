#!/bin/bash
# create-disk.sh — Create the GCP persistent data disk for leisaac.
# Run locally (from your laptop).
#
# The disk is ZONAL (cheaper than regional). It survives VM deletion because
# gcloud attaches it with auto-delete=false. It can be reattached to a new VM
# in the same zone — see attach-disk.sh.
#
# Idempotent: no-op if the disk already exists in GCP_DISK_ZONE (or GCP_ZONE).
#
# Optional: set DISK_SOURCE_SNAPSHOT to restore the disk from a snapshot instead
# of creating it empty (used by create-training-gcp-instance.sh to materialise
# the data disk in whatever zone the GPU VM lands). The requested --size must be
# >= the snapshot's source disk size.
#
# Usage:
#   bash create-disk.sh                     # uses GCP_DISK_ZONE / GCP_ZONE from env.sh
#   GCP_DISK_ZONE=us-east1-b bash create-disk.sh
#   DISK_SOURCE_SNAPSHOT=leisaac-data-snap GCP_DISK_ZONE=us-central1-a bash create-disk.sh

set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env.sh"

ZONE="${GCP_DISK_ZONE:-${GCP_ZONE}}"

if [ -z "$ZONE" ]; then
    echo "ERROR: Set GCP_DISK_ZONE (or GCP_ZONE) in env.sh first."
    exit 1
fi

echo ">>> Ensuring data disk '${GCP_DISK_NAME}' exists..."
echo "    project : $GCP_PROJECT"
echo "    zone    : $ZONE"
echo "    size    : ${GCP_DISK_SIZE} GB"
echo "    type    : $GCP_DISK_TYPE"
echo ""

if gcloud compute disks describe "$GCP_DISK_NAME" \
        --project "$GCP_PROJECT" \
        --zone "$ZONE" &>/dev/null; then
    EXISTING_SIZE=$(gcloud compute disks describe "$GCP_DISK_NAME" \
        --project "$GCP_PROJECT" \
        --zone "$ZONE" \
        --format "value(sizeGb)")
    echo ">>> Disk '${GCP_DISK_NAME}' already exists (${EXISTING_SIZE} GB) — skipping creation."
else
    CREATE_ARGS=(
        "$GCP_DISK_NAME"
        --project "$GCP_PROJECT"
        --zone "$ZONE"
        --size "${GCP_DISK_SIZE}GB"
        --type "$GCP_DISK_TYPE"
        --labels "project=leisaac,managed-by=create-disk-sh"
    )
    if [ -n "${DISK_SOURCE_SNAPSHOT:-}" ]; then
        echo ">>> Creating disk from snapshot '${DISK_SOURCE_SNAPSHOT}'..."
        CREATE_ARGS+=( --source-snapshot "$DISK_SOURCE_SNAPSHOT" )
    else
        echo ">>> Creating empty disk..."
    fi
    gcloud compute disks create "${CREATE_ARGS[@]}"
    echo ">>> Disk '${GCP_DISK_NAME}' created (${GCP_DISK_SIZE} GB, ${GCP_DISK_TYPE})."
fi

# Write the zone back into env.sh so attach-disk.sh / setup-instance.sh know it.
if grep -q "^export GCP_DISK_ZONE=" "$SCRIPT_DIR/env.sh"; then
    sed -i.bak "s|^export GCP_DISK_ZONE=.*$|export GCP_DISK_ZONE=\"${ZONE}\"|" \
        "$SCRIPT_DIR/env.sh"
else
    echo "export GCP_DISK_ZONE=\"${ZONE}\"" >> "$SCRIPT_DIR/env.sh"
fi
echo ">>> Wrote GCP_DISK_ZONE=${ZONE} to env.sh"
echo ""
echo "Next: bash attach-disk.sh   (attaches the disk to the running VM)"
