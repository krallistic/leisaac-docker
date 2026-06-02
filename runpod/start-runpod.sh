#!/bin/bash
# runpod/start-runpod.sh — launch a RunPod GPU pod that runs the training sweep.
# Run locally. Requires runpodctl (https://github.com/runpod/runpodctl) configured:
#   runpodctl config --apiKey <YOUR_RUNPOD_API_KEY>
#
# The pod pulls datasets from GCS, trains POLICIES × SEEDS, and syncs each
# checkpoint back to GCS (see train-and-sync.sh, the image's default CMD).
#
# GCS auth — provide the SA key ONE of two ways:
#   (preferred)  RUNPOD_SECRET_NAME=gcp_key   → injects {{ RUNPOD_SECRET_gcp_key }}
#                (create the secret first from runpod-sa-key.json.b64)
#   (fallback)   GCP_KEY_FILE=./runpod-sa-key.json → base64'd into a plain env var
#                (works everywhere, but the value lands in the pod config)
#
# Parallelism: this launches ONE pod per call. To shard the sweep across pods,
# call it several times with different POLICIES / SEEDS (e.g. one pod per policy).
#
# Env:
#   GCS_BUCKET   gs://...   (required)
#   IMAGE        (default ghcr.io/krallistic/lerobot:latest)
#   GPU_TYPE     (default "NVIDIA A100 80GB PCIe")   GPU_COUNT (default 1)
#   DISK_GB      container disk GB (default 60)
#   NAME         pod name (default leisaac-train-<ts>)
#   POLICIES SEEDS STEPS EPOCHS BATCH_SIZE LR CONCEPT_WEIGHT NUM_WORKERS  (passed through)
set -euo pipefail

: "${GCS_BUCKET:?set GCS_BUCKET=gs://...}"
IMAGE="${IMAGE:-ghcr.io/krallistic/lerobot:latest}"
GPU_TYPE="${GPU_TYPE:-NVIDIA A100-SXM4-80GB}"
GPU_COUNT="${GPU_COUNT:-1}"
DISK_GB="${DISK_GB:-60}"
# Host must have a driver new enough for the image's PyTorch CUDA build, else
# torch falls back to CPU ("NVIDIA driver too old"). cu128 torch needs >= 12.8.
MIN_CUDA="${MIN_CUDA:-12.8}"
NAME="${NAME:-leisaac-train-$(date +%H%M%S)}"

command -v runpodctl >/dev/null 2>&1 || {
    echo "ERROR: runpodctl not found. Install: https://github.com/runpod/runpodctl"; exit 1; }

# --- assemble the GCS key env value -----------------------------------------
if [ -n "${RUNPOD_SECRET_NAME:-}" ]; then
    KEY_ENV="{{ RUNPOD_SECRET_${RUNPOD_SECRET_NAME} }}"
    echo ">>> GCS key via RunPod secret: ${RUNPOD_SECRET_NAME}"
elif [ -n "${GCP_KEY_FILE:-}" ]; then
    [ -f "$GCP_KEY_FILE" ] || { echo "ERROR: GCP_KEY_FILE not found: $GCP_KEY_FILE"; exit 1; }
    KEY_ENV="$(base64 < "$GCP_KEY_FILE" | tr -d '\n')"
    echo ">>> GCS key inlined from ${GCP_KEY_FILE} (consider RUNPOD_SECRET_NAME instead)"
else
    echo "ERROR: set RUNPOD_SECRET_NAME (preferred) or GCP_KEY_FILE."; exit 1
fi

echo ">>> launching pod '${NAME}'"
echo "    image=${IMAGE}  gpu=${GPU_TYPE} x${GPU_COUNT}  disk=${DISK_GB}GB"
echo "    policies=[${POLICIES:-concept_act_tce}]  seeds=[${SEEDS:-42 123 456}]  steps=${STEPS:-50000}"

# This runpodctl version wants --env as a SINGLE JSON object (not repeated
# --env KEY=VALUE). Build it with python3 so values are JSON-escaped correctly.
ENV_JSON=$(
    GCP_SA_KEY_B64="$KEY_ENV" \
    GCS_BUCKET="$GCS_BUCKET" \
    POLICIES="${POLICIES:-concept_act_tce}" \
    SEEDS="${SEEDS:-42 123 456}" \
    EPOCHS="${EPOCHS:-5}" \
    BATCH_SIZE="${BATCH_SIZE:-32}" \
    LR="${LR:-3e-5}" \
    CONCEPT_WEIGHT="${CONCEPT_WEIGHT:-0.2}" \
    NUM_WORKERS="${NUM_WORKERS:-4}" \
    python3 -c 'import json,os; ks="GCP_SA_KEY_B64 GCS_BUCKET POLICIES SEEDS EPOCHS BATCH_SIZE LR CONCEPT_WEIGHT NUM_WORKERS".split(); print(json.dumps({k: os.environ[k] for k in ks}))'
)

# We do NOT pass --docker-args: the image's ENTRYPOINT + CMD run train-and-sync.sh.
# Verify the GPU id with `runpodctl gpu list`.
# Private GHCR image? add:  --registry-auth-id <id>   (runpodctl registry list/create)
runpodctl pod create \
    --name "$NAME" \
    --image "$IMAGE" \
    --gpu-id "$GPU_TYPE" \
    --gpu-count "$GPU_COUNT" \
    --container-disk-in-gb "$DISK_GB" \
    --min-cuda-version "$MIN_CUDA" \
    --env "$ENV_JSON"

echo ""
echo ">>> launched. Watch:  runpodctl pod list   (then the RunPod web log viewer)"
echo ">>> when the sweep finishes the container exits; TERMINATE the pod to stop billing:"
echo ">>>   runpodctl pod stop <id>   &&   runpodctl pod remove <id>"
echo ">>> pull results:  gcloud storage rsync -r ${GCS_BUCKET}/checkpoints /data/sorting-experiment/checkpoints"
