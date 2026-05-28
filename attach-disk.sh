#!/bin/bash
# attach-disk.sh — Attach the persistent data disk to the running VM.
# Run locally (from your laptop), after create-gcp-instance.sh OR after
# recreating the VM when the disk already exists.
#
# The disk is attached with --no-auto-delete so VM deletion does NOT destroy it.
# Device name is set to $GCP_DISK_NAME so the VM sees it at a predictable path:
#   /dev/disk/by-id/google-<GCP_DISK_NAME>
#
# Idempotent: if the disk is already attached to this instance, nothing changes.
#
# Usage:
#   bash attach-disk.sh

set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env.sh"

ZONE="${GCP_DISK_ZONE:-${GCP_ZONE}}"

if [ -z "$ZONE" ]; then
    echo "ERROR: GCP_DISK_ZONE not set. Run create-disk.sh first."
    exit 1
fi

echo ">>> Attaching disk '${GCP_DISK_NAME}' to '${GCP_INSTANCE_NAME}'..."
echo "    project  : $GCP_PROJECT"
echo "    zone     : $ZONE"
echo ""

# Check if the disk is already attached to this instance.
# `gcloud compute disks describe --format value(users)` lists instance URLs.
USERS=$(gcloud compute disks describe "$GCP_DISK_NAME" \
    --project "$GCP_PROJECT" \
    --zone "$ZONE" \
    --format "value(users)" 2>/dev/null || true)

if echo "$USERS" | grep -q "/${GCP_INSTANCE_NAME}$"; then
    echo ">>> Disk '${GCP_DISK_NAME}' is already attached to '${GCP_INSTANCE_NAME}' — skipping."
else
    gcloud compute instances attach-disk "$GCP_INSTANCE_NAME" \
        --project "$GCP_PROJECT" \
        --zone "$ZONE" \
        --disk "$GCP_DISK_NAME" \
        --device-name "$GCP_DISK_NAME"
    gcloud compute instances set-disk-auto-delete "$GCP_INSTANCE_NAME" \
        --project "$GCP_PROJECT" \
        --zone "$ZONE" \
        --disk "$GCP_DISK_NAME" \
        --no-auto-delete
    echo ">>> Disk attached (auto-delete=false — disk survives VM deletion)."
fi

echo ""
echo "Next: on the VM, run:  sudo bash /workspace/setup-instance.sh"
echo "      (It will detect the disk, format if new, mount at ${GCP_DISK_MOUNT}, and create dirs.)"
