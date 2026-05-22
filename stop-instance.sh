#!/bin/bash
# stop-instance.sh
# Run locally. Pauses the instance. Disk persists; GPU billing stops.

set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env.sh"

echo ">>> Stopping instance $VAST_INSTANCE_ID..."
vastai stop instance "$VAST_INSTANCE_ID"
echo ">>> Done. GPU billing stopped. Disk costs continue at ~\$0.10/GB/month."
echo "    To resume:  bash start-instance.sh"
echo "    To destroy: bash destroy-instance.sh   (PERMANENT, loses disk)"