#!/usr/bin/env bash
# env.sh  — source this in every script.
# Local (laptop) configuration for the leisaac GCP deployment.
# Copy to your project directory and fill in GCP_PROJECT.

# ── GCP project & location ────────────────────────────────────────────────
export GCP_PROJECT="uni-ulm-compute-stuff"       # fill in: gcloud config get-value project
export GCP_REGION="europe-west4"
                                           # automatically if one zone is out of stock.
                                           # Other EU options: europe-west4 (NL),
                                           #                   europe-west3 (Frankfurt)
export GCP_INSTANCE_NAME="leisaac-dev"
export GCP_MACHINE_TYPE="g2-standard-4"
                                           # NOTE: NVIDIA recommends g2-standard-4+
                                           # for Isaac Sim; bump if you see OOM.

# ── SSH ───────────────────────────────────────────────────────────────────
export GCP_SSH_ALIAS="leisaac"             # shortname in ~/.ssh/config
export GCP_SSH_USER="jakobkaralus"
export GCP_SSH_KEY="$HOME/.ssh/google_compute_engine"    # the key you registered            # GCP sets up an account with your local username

# ── Filled in automatically by create-gcp-instance.sh / setup-ssh.sh ─────
export GCP_EXTERNAL_IP="34.34.79.190"

# ── WebRTC ports (direct — no remapping on GCP, opened via firewall rule) ─
export SIGNAL_PORT="49100"     # TCP — Isaac Sim WebRTC signaling
export MEDIA_PORT="47998"      # UDP — Isaac Sim WebRTC media
export WEBRTC_FIREWALL_TAG="leisaac-webrtc"

# ── LeIsaac source ────────────────────────────────────────────────────────
export LEISAAC_REPO="https://github.com/LightwheelAI/leisaac.git"
export LEISAAC_BRANCH=""       # leave empty for default branch; or pin e.g. "main"

# ── Persistent data disk ─────────────────────────────────────────────────
# One pd-balanced disk per project, shared across VM recreations.
# The disk survives instance deletion (auto-delete=false at attach time).
# Zone is written here by create-gcp-instance.sh; must match the VM zone.
export GCP_DISK_NAME="leisaac-data"
export GCP_DISK_SIZE="200"                 # GB; resize online with gcloud compute disks resize
export GCP_DISK_TYPE="pd-balanced"         # pd-ssd for higher IOPS, pd-standard cheaper
export GCP_DISK_MOUNT="/data"              # mount point on the VM
export GCP_DISK_ZONE="europe-west4-a"

# ── Remote paths (on the GCP instance) ───────────────────────────────────
export REMOTE_CONDA="/opt/miniconda3"
export REMOTE_PYTHON="$REMOTE_CONDA/envs/leisaac/bin/python"
export REMOTE_WORK="${GCP_DISK_MOUNT}"     # all data lives on the persistent disk

export GCP_ZONE="europe-west4-c"
