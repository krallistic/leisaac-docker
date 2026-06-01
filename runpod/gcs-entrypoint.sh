#!/bin/bash
# gcs-entrypoint.sh — image ENTRYPOINT. Contains NO secret; safe to bake/commit.
#
# If $GCP_SA_KEY_B64 is present (injected at runtime, e.g. from a RunPod Secret),
# decode it to a key file and configure Google Cloud auth so `gcloud storage`
# works. Then exec the container command. With the env var absent (e.g. the
# eval/server use of this image), this is a transparent passthrough.
set -e

if [ -n "${GCP_SA_KEY_B64:-}" ]; then
    mkdir -p /workspace
    if ! echo "$GCP_SA_KEY_B64" | base64 -d > /workspace/sa-key.json 2>/dev/null; then
        echo "ERROR: failed to base64-decode \$GCP_SA_KEY_B64." >&2
        echo "       Encode with:  base64 < key.json | tr -d '\\n'" >&2
        exit 1
    fi
    chmod 600 /workspace/sa-key.json
    export GOOGLE_APPLICATION_CREDENTIALS=/workspace/sa-key.json
    gcloud auth activate-service-account --key-file=/workspace/sa-key.json --quiet || true
    echo ">>> GCS auth configured ($(gcloud config get-value account 2>/dev/null))."
fi

exec "$@"
