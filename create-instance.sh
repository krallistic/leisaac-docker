#!/bin/bash
# create-instance.sh
# Run locally. Searches for the cheapest matching Vast.ai offer (RTX 4090,
# EU+Nordics datacenter, verified, reliable, CUDA 13+), then creates an
# instance from it. Parses the new instance ID, writes it into env.sh, waits
# for the instance to come up, and configures SSH.
#
# CUDA 13 / driver 580+ is required because we now target Isaac Sim 5.1 via
# the isaac-lab:2.3.2 base image. The CUDA filter is applied client-side in
# Python because the Vast CLI's '<' / '<=' on cuda_vers has been flaky.
#
# Override the auto-pick by passing an offer ID:
#   bash create-instance.sh 12345678

set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKIP_ENV_CHECK=1 source "$SCRIPT_DIR/env.sh"

# === 1. Find an offer =====================================================
# If user passed an offer ID, skip the search.
if [ -n "$1" ]; then
    OFFER_ID="$1"
    echo ">>> Using offer ID from argument: $OFFER_ID (skipping auto-search)"
    echo ""
else
    # NOTE: cuda_vers filter is intentionally NOT in the CLI query (parser
    # has issues with < / <= on this field). We filter in Python below.
    # NOTE: datacenter=true is dropped — the Vast UI's "datacenter" label is
    # looser than the API filter, and Isaac Sim doesn't care about
    # hosting_type as long as the GPU and driver are good. Reliability filter
    # carries the uptime guarantee.
    # Make sure VAST_GEO in env.sh includes Nordics + Iceland for supply:
    #   export VAST_GEO="[DE,FR,NL,BE,AT,CH,IT,ES,SE,FI,NO,IS,EE,DK,IE,PL,CZ,SK,HU,GB]"
    QUERY="gpu_name=RTX_4090 \
num_gpus=1 \
direct_port_count>=1 \
disk_space>=80 \
reliability>0.98 \
verified=true \
geolocation in $VAST_GEO \
rentable=true"

    echo ">>> Searching for offers..."
    echo "    RTX 4090 x1, EU+Nordics, verified, reliability>98%, 80GB+ disk"
    echo "    Client-side filter: CUDA 13+ (Isaac Sim 5.1 requirement)"
    echo ""

    OFFER_JSON=$(vastai search offers "$QUERY" --raw -o 'dph_total' 2>/dev/null || echo "[]")

    # Filter to CUDA 13+ in Python and pick the cheapest, pulling display
    # fields out of the chosen offer.
    PICKED=$(echo "$OFFER_JSON" | python3 -c "
import sys, json
offers = json.load(sys.stdin)
# Isaac Sim 5.1 requires CUDA 13+. Driver 580+ is recommended on Linux.
offers = [o for o in offers if o.get('cuda_max_good', 0) >= 13.0]
if not offers:
    sys.exit(1)
best = offers[0]   # already sorted by dph_total asc
print('|'.join([
    str(best['id']),
    f\"{best['dph_total']:.3f}\",
    str(best.get('geolocation', '?')),
    str(best.get('machine_id', '?')),
    f\"{best.get('reliability2', 0):.3f}\",
    str(best.get('gpu_ram', '?')),
    str(best.get('disk_space', '?')),
    str(best.get('cuda_max_good', '?')),
    str(best.get('driver_version', '?')),
]))
" 2>/dev/null || echo "")

    if [ -z "$PICKED" ]; then
        echo "ERROR: No matching offers found. Try:"
        echo "  - widening VAST_GEO in env.sh (add more countries)"
        echo "  - lowering reliability filter in QUERY (0.95 instead of 0.98)"
        echo "  - relaxing the CUDA filter in the Python block if you want"
        echo "    to fall back to Isaac Sim 4.5 (but then also swap the"
        echo "    Dockerfile FROM line back to isaac-lab:2.1.0)"
        exit 1
    fi

    IFS='|' read -r OFFER_ID PRICE GEO HOST RELIABILITY VRAM DISK CUDA DRIVER <<< "$PICKED"

    echo ">>> Cheapest match:"
    echo "    offer ID:    $OFFER_ID"
    echo "    price:       \$$PRICE/hr"
    echo "    location:    $GEO"
    echo "    host:        $HOST (reliability $RELIABILITY)"
    echo "    GPU memory:  ${VRAM} GB"
    echo "    disk avail:  ${DISK} GB"
    echo "    CUDA:        $CUDA"
    echo "    driver:      $DRIVER"
    echo ""

    # Sanity check on price. RTX 4090 on CUDA 13 hosts seems to land
    # $0.40-0.90/hr; anything wildly above that means something odd.
    if python3 -c "import sys; sys.exit(0 if float('$PRICE') > 1.0 else 1)"; then
        echo "WARNING: price >\$1.00/hr is high for RTX 4090. Continue? (Ctrl+C to cancel)"
    fi

    echo ">>> Creating instance in 5 seconds... (Ctrl+C to cancel)"
    sleep 5
    echo ""
fi

# === 2. Create the instance ==============================================
PORT_MAPPING="-p 49100:49100/tcp -p 47998:47998/udp"

echo ">>> Creating instance from offer $OFFER_ID..."
echo "    Image:     $GHCR_IMAGE"
echo "    Disk:      80 GB"
echo "    Ports:     $PORT_MAPPING"
echo ""

RAW_OUTPUT=$(vastai create instance "$OFFER_ID" \
    --image "$GHCR_IMAGE" \
    --disk 80 \
    --ssh \
    --direct \
    --env "$PORT_MAPPING" \
    --label "leisaac-dev" 2>&1)

echo "$RAW_OUTPUT"
echo ""

# === 3. Parse the new instance ID ========================================
# vastai typically prints: "Started. {'success': True, 'new_contract': 12345678, ...}"
# We pull the {...} block and ast.literal_eval it. The Python block emits an
# empty string on any parse failure rather than exiting non-zero, so set -e
# doesn't kill us before we can report what went wrong.
NEW_ID=$(RAW_OUTPUT="$RAW_OUTPUT" python3 <<'PYEOF'
import os, re, ast
text = os.environ['RAW_OUTPUT']
match = re.search(r'\{.*\}', text, re.DOTALL)
if not match:
    print('No Match')
    sys.exit(0)
try:
    data = ast.literal_eval(match.group(0))
    print(data.get('new_contract', ''))
except Exception as e:
    print('Exception', e)
PYEOF
)

if [ -z "$NEW_ID" ]; then
    echo "ERROR: Could not parse new instance ID from vastai output."
    echo ""
    echo "--- Raw output from vastai create instance ---"
    echo "$RAW_OUTPUT"
    echo "--- end ---"
    echo ""
    echo "If the dict format looks different from {'success': True, 'new_contract': N, ...}"
    echo "share this output and we'll fix the parser."
    echo "Otherwise, set VAST_INSTANCE_ID in env.sh manually and re-run setup-ssh.sh."
    exit 1
fi

echo ">>> New instance ID: $NEW_ID"

# === 4. Write ID back into env.sh ========================================
sed -i.bak "s|^export VAST_INSTANCE_ID=.*$|export VAST_INSTANCE_ID=\"$NEW_ID\"|" "$SCRIPT_DIR/env.sh"
echo ">>> Wrote VAST_INSTANCE_ID=$NEW_ID to env.sh"
echo ""

SKIP_ENV_CHECK=1 source "$SCRIPT_DIR/env.sh"

# === 5. Wait for the instance to come up =================================
echo ">>> Waiting for instance to reach 'running' (image pull takes 5-10 min)..."
STATUS=""
for i in $(seq 1 120); do
    sleep 10
    STATUS=$(vastai show instance "$VAST_INSTANCE_ID" --raw 2>/dev/null | \
        python3 -c "import sys,json; print(json.load(sys.stdin).get('actual_status',''))" 2>/dev/null || echo "")
    if [ "$STATUS" = "running" ]; then
        echo ">>> Instance is running."
        break
    fi
    echo "    status=$STATUS, waiting... ($i/120)"
done

if [ "$STATUS" != "running" ]; then
    echo "WARNING: Instance didn't reach 'running' within 20 minutes."
    echo "         Check: vastai show instance $VAST_INSTANCE_ID"
    echo "         When it's up, run: bash setup-ssh.sh"
    exit 1
fi

# === 6. Configure SSH ====================================================
echo ""
echo ">>> Configuring SSH..."
bash "$SCRIPT_DIR/setup-ssh.sh"

echo ""
echo "================================================================"
echo "Instance is ready."
echo ""
echo "Next steps:"
echo "    1. Copy the bundle to the instance:"
echo "         scp -r ./* $VAST_SSH_ALIAS:/workspace/"
echo "    2. SSH in and install your forks:"
echo "         ssh $VAST_SSH_ALIAS"
echo "         cd /workspace && bash setup-instance.sh"
echo "    3. Smoke test:"
echo "         bash test-isaac.sh"
echo "================================================================"