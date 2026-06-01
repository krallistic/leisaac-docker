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
GPU_TYPE="${GPU_TYPE:-NVIDIA A100 80GB PCIe}"
GPU_COUNT="${GPU_COUNT:-1}"
DISK_GB="${DISK_GB:-60}"
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

# NOTE: runpodctl flag names vary by version — verify with `runpodctl create pod --help`.
# We do NOT pass a start command: the image's ENTRYPOINT + CMD run train-and-sync.sh.
runpodctl create pod \
    --name "$NAME" \
    --imageName "$IMAGE" \
    --gpuType "$GPU_TYPE" \
    --gpuCount "$GPU_COUNT" \
    --containerDiskSize "$DISK_GB" \
    --env "GCP_SA_KEY_B64=${KEY_ENV}" \
    --env "GCS_BUCKET=${GCS_BUCKET}" \
    --env "POLICIES=${POLICIES:-concept_act_tce}" \
    --env "SEEDS=${SEEDS:-42 123 456}" \
    --env "STEPS=${STEPS:-50000}" \
    --env "EPOCHS=${EPOCHS:-5}" \
    --env "BATCH_SIZE=${BATCH_SIZE:-8}" \
    --env "LR=${LR:-3e-5}" \
    --env "CONCEPT_WEIGHT=${CONCEPT_WEIGHT:-0.2}" \
    --env "NUM_WORKERS=${NUM_WORKERS:-4}"

echo ""
echo ">>> launched. Watch logs:  runpodctl get pod    (then the RunPod web log viewer)"
echo ">>> the pod stops itself when the sweep finishes (KEEP_ALIVE=0)."
echo ">>> pull results:  gcloud storage rsync -r ${GCS_BUCKET}/checkpoints /data/sorting-experiment/checkpoints"
