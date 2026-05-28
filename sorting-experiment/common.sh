#!/bin/bash
# common.sh — shared config for all sorting-experiment scripts.
# Source this file; do not run it directly.
#
# Directory layout on the persistent data disk (/data):
#   /data/sorting-experiment/
#     demos/{case}/dataset.hdf5       raw HDF5 recordings
#     demos/{case}/.complete           sentinel: enough successes collected
#     lerobot_datasets/sim/sort_object_{case}/          LeRobot dataset
#     lerobot_datasets/sim/sort_object_with_concepts_{case}/  + concept labels
#     checkpoints/{experiment_name}/checkpoints/last/   trained checkpoint
#     eval/{experiment_name}/{case}/results.log         eval output

# ── Resolve paths ─────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"   # leisaac-docker root

source "$BUNDLE_DIR/env.sh" 2>/dev/null || true

WORK_DIR="${REMOTE_WORK:-/data}"
LEISAAC_SRC="/workspace/leisaac/source/leisaac"

# ── Docker images ─────────────────────────────────────────────────────────────
IMAGE="${LEISAAC_IMAGE:-leisaac:latest}"
CONVERT_IMAGE="${CONVERT_IMAGE:-leisaac-convert:latest}"
LEROBOT_IMAGE="${LEROBOT_IMAGE:-lerobot:latest}"

# ── Experiment directories ────────────────────────────────────────────────────
EXP_DIR="${WORK_DIR}/sorting-experiment"
DEMOS_DIR="${EXP_DIR}/demos"
LEROBOT_DIR="${EXP_DIR}/lerobot_datasets"
CHECKPOINTS_DIR="${EXP_DIR}/checkpoints"
EVAL_DIR="${EXP_DIR}/eval"

# ── Sorting rule ──────────────────────────────────────────────────────────────
# Area A: (cube AND color∈{red,green}) OR (cylinder AND blue)
# Area B: everything else
# Matches _SORTING_TABLE in leisaac/tasks/sort_object/sort_object_env_cfg.py.
determine_dropoff() {
    local color="$1" shape="$2"
    if [ "$shape" = "cube" ] && { [ "$color" = "red" ] || [ "$color" = "green" ]; }; then
        echo "A"; return
    fi
    if [ "$shape" = "cylinder" ] && [ "$color" = "blue" ]; then
        echo "A"; return
    fi
    echo "B"
}

# ── Case inventory ────────────────────────────────────────────────────────────
# Matches the real-world experiment in cact_scripts/cases.sh.
# Format: {shape}_{color}
ALL_CASES=(
    cube_red cube_green cube_yellow
    rectangle_red rectangle_blue rectangle_green rectangle_yellow
    cylinder_red cylinder_blue cylinder_green
)

# Held-out test cases (used for eval, not for training)
TEST_CASES=(cube_red rectangle_yellow)

TRAINING_CASES=()
for _c in "${ALL_CASES[@]}"; do
    _is_test=0
    for _t in "${TEST_CASES[@]}"; do [ "$_c" = "$_t" ] && _is_test=1 && break; done
    [ "$_is_test" = "0" ] && TRAINING_CASES+=("$_c")
done

# ── Naming helpers ────────────────────────────────────────────────────────────

# "cube_red" → "LeIsaac-SO101-SortObject-CubeRed-v0"
case_to_task() {
    local case="$1"
    local title
    title="$(echo "$case" | awk -F_ 'BEGIN{OFS=""} {for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) substr($i,2); print}')"
    echo "LeIsaac-SO101-SortObject-${title}-v0"
}

# "cube_red" → "sim/sort_object_cube_red"
case_to_repo_id()          { echo "sim/sort_object_${1}"; }
# "cube_red" → "sim/sort_object_with_concepts_cube_red"
case_to_concept_repo_id()  { echo "sim/sort_object_with_concepts_${1}"; }

# "cube_red" → shape=cube, color=red
case_shape() { echo "${1%%_*}"; }
case_color() { echo "${1#*_}"; }

# ── Isaac Sim cache mounts (shared by all containers) ─────────────────────────
CACHE_ROOT="${WORK_DIR}/docker/leisaac/cache"
mkdir -p "${CACHE_ROOT}"/{kit,ov,glcache,computecache,pip}
mkdir -p "${WORK_DIR}/docker/leisaac/logs"

# Docker flags for the sort-object env.
# IMPORTANT: the sort_object USD assets are BAKED INTO the leisaac image (not
# in the HuggingFace leisaac_env download). We do NOT mount the host assets dir
# so the container uses its own copy — see tests/test-4.5-scene-sort-object.sh.
SORT_FLAGS=(
    --gpus all --network=host
    -e ACCEPT_EULA=Y -e PRIVACY_CONSENT=Y
    -e NVIDIA_DRIVER_CAPABILITIES=all
    -e PYTHONPATH="${LEISAAC_SRC}"
    -v "${CACHE_ROOT}/kit:/isaac-sim/kit/cache:rw"
    -v "${CACHE_ROOT}/ov:/isaac-sim/.cache/ov:rw"
    -v "${CACHE_ROOT}/glcache:/isaac-sim/.cache/nvidia/GLCache:rw"
    -v "${CACHE_ROOT}/computecache:/isaac-sim/.nv/ComputeCache:rw"
    -v "${CACHE_ROOT}/pip:/isaac-sim/.cache/pip:rw"
    -v "${WORK_DIR}/docker/leisaac/logs:/isaac-sim/.nvidia-omniverse/logs:rw"
    -v /usr/share/vulkan/icd.d:/usr/share/vulkan/icd.d:ro
)

# ── Streaming ─────────────────────────────────────────────────────────────────
SIGNAL="${SIGNAL_PORT:-49100}"
TS_LIVE_IP="$(command -v tailscale >/dev/null 2>&1 && tailscale ip -4 2>/dev/null | head -1)"
STREAM_IP="${TS_LIVE_IP:-${STREAM_IP:-}}"

require_tailscale() {
    [ -n "$STREAM_IP" ] && return 0
    echo "ERROR: streaming requires Tailscale. Run setup-tailscale.sh or bring Tailscale up."
    exit 1
}

build_kit_args() {
    require_tailscale
    KIT_ARGS="--/app/livestream/publicEndpointAddress=${STREAM_IP} --/app/livestream/port=${SIGNAL} --/rtx/verifyDriverVersion/enabled=false"
    echo ">>> WebRTC endpoint (Tailscale): ${STREAM_IP}:${SIGNAL}"
}

# ── Sentinel helpers ──────────────────────────────────────────────────────────
mark_complete()       { touch "${DEMOS_DIR}/${1}/.complete"; }
is_complete()         { [ -f "${DEMOS_DIR}/${1}/.complete" ]; }

mark_converted()      { touch "${LEROBOT_DIR}/$(case_to_repo_id "$1")/.converted"; }
is_converted()        { [ -f "${LEROBOT_DIR}/$(case_to_repo_id "$1")/.converted" ]; }

mark_concepts_added() { touch "${LEROBOT_DIR}/$(case_to_concept_repo_id "$1")/.concepts_added"; }
is_concepts_added()   { [ -f "${LEROBOT_DIR}/$(case_to_concept_repo_id "$1")/.concepts_added" ]; }
