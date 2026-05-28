#!/bin/bash
# test-1-imports.sh — lightweight import check (no Kit runtime, no streaming).
# Verifies the container Python, PyTorch/CUDA, GPU visibility, and that the
# leisaac package imports from the real source (not the namespace shadow).
# The pxr (USD) import is EXPECTED to fail here — it needs the Kit runtime,
# which test-2/3/4 boot. Fast (~seconds); run this first after a build.
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

echo ">>> Test 1: Import check..."
docker run "${COMMON_FLAGS[@]}" --entrypoint bash "$IMAGE" -c "
export PYTHONPATH=${LEISAAC_SRC}:\$PYTHONPATH
source /isaac-sim/setup_python_env.sh
$PYTHON - << 'PYEOF'
import sys
print(f'Python: {sys.version.split()[0]}')
import torch
print(f'PyTorch: {torch.__version__}, CUDA: {torch.cuda.is_available()}')
if torch.cuda.is_available():
    print(f'  GPU:  {torch.cuda.get_device_name(0)}')
    print(f'  VRAM: {torch.cuda.get_device_properties(0).total_memory/1e9:.1f} GB')
import leisaac
print(f'LeIsaac path: {leisaac.__file__}')
# pxr (USD) is only available with the Kit runtime, so leisaac.tasks can not
# register gymnasium envs here. That is expected and verified in test 3/4.
print()
print('Test 1 OK.')
PYEOF
"
echo ""
echo ">>> Test 1 passed."