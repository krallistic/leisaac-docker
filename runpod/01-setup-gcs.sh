#!/bin/bash
# runpod/01-setup-gcs.sh — one-time GCS setup for off-GCP (RunPod) training.
#
# Best run ON THE GCP BOX (where /data and the LeRobot datasets live, so the
# dataset upload is a free same-region GCE→GCS transfer). Needs gcloud auth.
#
# Creates the hub bucket (datasets in, checkpoints out), a service account
# scoped to JUST that bucket, a JSON key + its base64 form for the RunPod secret,
# and uploads the datasets.
#
# Env overrides:
#   GCP_PROJECT            (from ../env.sh)
#   LOCATION              GCS bucket region            (default europe-west4)
#   BUCKET                gs://...                      (default gs://leisaac-training-<project>)
#   SA_NAME               service account id            (default runpod-training)
#   KEY_FILE              local key path                (default ./runpod-sa-key.json)
#   LEROBOT_DATASETS_DIR  datasets to upload            (default /data/sorting-experiment/lerobot_datasets)
#   SKIP_UPLOAD=1         create resources but don't upload datasets
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../env.sh" 2>/dev/null || true

: "${GCP_PROJECT:?set GCP_PROJECT (or fill ../env.sh)}"
LOCATION="${LOCATION:-europe-west4}"
BUCKET="${BUCKET:-gs://leisaac-training-${GCP_PROJECT}}"
SA_NAME="${SA_NAME:-runpod-training}"
SA_EMAIL="${SA_NAME}@${GCP_PROJECT}.iam.gserviceaccount.com"
KEY_FILE="${KEY_FILE:-${SCRIPT_DIR}/runpod-sa-key.json}"
LEROBOT_DATASETS_DIR="${LEROBOT_DATASETS_DIR:-/data/sorting-experiment/lerobot_datasets}"

echo ">>> project=${GCP_PROJECT}  bucket=${BUCKET}  location=${LOCATION}"

# 1. bucket ------------------------------------------------------------------
if gcloud storage buckets describe "$BUCKET" --project "$GCP_PROJECT" &>/dev/null; then
    echo ">>> bucket exists — skipping create."
else
    gcloud storage buckets create "$BUCKET" --project "$GCP_PROJECT" \
        --location "$LOCATION" --uniform-bucket-level-access
    echo ">>> bucket created."
fi

# 2. service account ---------------------------------------------------------
if ! gcloud iam service-accounts describe "$SA_EMAIL" --project "$GCP_PROJECT" &>/dev/null; then
    gcloud iam service-accounts create "$SA_NAME" --project "$GCP_PROJECT" \
        --display-name "RunPod training GCS I/O"
    echo ">>> service account ${SA_EMAIL} created."
fi
# scope it to JUST this bucket (object read/write, nothing else)
gcloud storage buckets add-iam-policy-binding "$BUCKET" \
    --member="serviceAccount:${SA_EMAIL}" --role="roles/storage.objectAdmin" >/dev/null
echo ">>> granted objectAdmin on ${BUCKET} to ${SA_EMAIL}."

# 3. key + base64 ------------------------------------------------------------
if [ -f "$KEY_FILE" ]; then
    echo ">>> key file ${KEY_FILE} already exists — reusing."
else
    gcloud iam service-accounts keys create "$KEY_FILE" --iam-account "$SA_EMAIL"
    echo ">>> key written to ${KEY_FILE}."
fi
chmod 600 "$KEY_FILE"
base64 < "$KEY_FILE" | tr -d '\n' > "${KEY_FILE}.b64"     # portable (macOS + Linux)
echo ">>> base64 key written to ${KEY_FILE}.b64"

# 4. upload datasets ---------------------------------------------------------
if [ "${SKIP_UPLOAD:-0}" = "1" ]; then
    echo ">>> SKIP_UPLOAD=1 — not uploading datasets."
elif [ -d "$LEROBOT_DATASETS_DIR" ]; then
    echo ">>> uploading ${LEROBOT_DATASETS_DIR} → ${BUCKET}/lerobot_datasets ..."
    gcloud storage rsync -r "$LEROBOT_DATASETS_DIR" "${BUCKET}/lerobot_datasets"
    echo ">>> datasets uploaded."
else
    echo "WARNING: ${LEROBOT_DATASETS_DIR} not found — skipping upload."
    echo "         Re-run on the GCP box, or set LEROBOT_DATASETS_DIR."
fi

cat <<EOF

================================================================
GCS setup complete.

  Bucket : ${BUCKET}
  SA     : ${SA_EMAIL}  (objectAdmin on this bucket only)
  Key    : ${KEY_FILE}  (+ .b64)

Next:
  1. Create a RunPod Secret named 'gcp_key' with the contents of:
         ${KEY_FILE}.b64
     (RunPod Console → Settings → Secrets, or: runpodctl create secret ...)
  2. Launch training:
         GCS_BUCKET=${BUCKET} RUNPOD_SECRET_NAME=gcp_key bash ${SCRIPT_DIR}/start-runpod.sh
  3. Pull results back to GCP for eval:
         gcloud storage rsync -r ${BUCKET}/checkpoints /data/sorting-experiment/checkpoints

SECURITY: ${KEY_FILE}* is a real credential — do NOT commit it.
          Delete the SA when finished:
            gcloud iam service-accounts delete ${SA_EMAIL} --project ${GCP_PROJECT}
================================================================
EOF
