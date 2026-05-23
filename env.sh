#!/usr/bin/env bash
# env.sh  — source this in every script.
# Local (laptop) configuration for the leisaac GCP deployment.
# Copy to your project directory and fill in GCP_PROJECT.

# ── GCP project & location ────────────────────────────────────────────────
export GCP_PROJECT="uni-ulm-compute-stuff"       # fill in: gcloud config get-value project
export GCP_REGION="us-east1"
                                           # automatically if one zone is out of stock.
                                           # Other EU options: europe-west4 (NL),
                                           #                   europe-west3 (Frankfurt)
export GCP_INSTANCE_NAME="leisaac-dev"
export GCP_MACHINE_TYPE="g2-standard-4"
                                           # NOTE: NVIDIA recommends g2-standard-4+
                                           # for Isaac Sim; bump if you see OOM.

# ── SSH ───────────────────────────────────────────────────────────────────
export GCP_SSH_ALIAS="leisaac"             # shortname in ~/.ssh/config
export GCP_SSH_KEY="$HOME/.ssh/google_compute_engine"
export GCP_SSH_USER="$USER"               # GCP sets up an account with your local username

# ── Filled in automatically by create-gcp-instance.sh / setup-ssh.sh ─────
export GCP_EXTERNAL_IP="35.231.57.203"

# ── WebRTC ports (direct — no remapping on GCP, opened via firewall rule) ─
export SIGNAL_PORT="49100"     # TCP — Isaac Sim WebRTC signaling
export MEDIA_PORT="47998"      # UDP — Isaac Sim WebRTC media
export WEBRTC_FIREWALL_TAG="leisaac-webrtc"

# ── LeIsaac source ────────────────────────────────────────────────────────
export LEISAAC_REPO="https://github.com/LightwheelAI/leisaac.git"
export LEISAAC_BRANCH=""       # leave empty for default branch; or pin e.g. "main"

# ── Remote paths (on the GCP instance) ───────────────────────────────────
export REMOTE_CONDA="/opt/miniconda3"
export REMOTE_PYTHON="$REMOTE_CONDA/envs/leisaac/bin/python"
export REMOTE_WORK="/workspace"

export GCP_ZONE="us-east1-b"
