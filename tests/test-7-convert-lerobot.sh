#!/bin/bash
# test-7-convert-lerobot.sh — Convert an IsaacLab HDF5 dataset (produced by
# test-6) into a LeRobot Dataset v2 stored on the HOST filesystem.
#
# Uses leisaac-convert:latest which bundles both the Isaac Kit runtime (for
# task registration / feature extraction) and the thin lerobot writer deps.
#
# INPUT:  $HOST_DATASETS/$DATASET_FILE    (HDF5 from test-6)
# OUTPUT: $HOST_LEROBOT_DATASETS/$REPO_ID (LeRobot dataset on the host)
#
# Dataset location is controlled by setting HF_LEROBOT_HOME inside the
# container. The converter calls LeRobotDataset.create(repo_id=...) which
# writes to $HF_LEROBOT_HOME/$REPO_ID, so we mount HOST_LEROBOT_DATASETS
# to /workspace/lerobot_datasets and set HF_LEROBOT_HOME to that path.
#
# Key variables (override via env):
#   TASK              Isaac Sim task name
#   TASK_TYPE         "keyboard" / "gamepad" / unset for leader teleop
#   REPO_ID           LeRobot repo-id / relative output folder name
#   FPS               Target frame rate for the converted dataset
#   HOST_DATASETS     Directory containing the source HDF5
#   HOST_LEROBOT_DATASETS  Parent directory for the output LeRobot dataset
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

TASK="${TASK:-LeIsaac-SO101-PickOrange-v0}"
TASK_TYPE="${TASK_TYPE:-keyboard}"
REPO_ID="${REPO_ID:-local/so101_pick_orange}"
FPS="${FPS:-30}"

HOST_DATASETS="${HOST_DATASETS:-${WORK_DIR}/leisaac/datasets}"
DATASET_FILE="${DATASET_FILE:-dataset.hdf5}"
HOST_LEROBOT_DATASETS="${HOST_LEROBOT_DATASETS:-${WORK_DIR}/leisaac/lerobot_datasets}"

CONVERT_IMAGE="${CONVERT_IMAGE:-leisaac-convert:latest}"
CONVERT_CONTAINER="leisaac-convert"

mkdir -p "$HOST_LEROBOT_DATASETS"
docker rm "$CONVERT_CONTAINER" >/dev/null 2>&1 || true

echo ">>> Test 7: HDF5 -> LeRobot Dataset conversion"
echo ">>> Source HDF5 : ${HOST_DATASETS}/${DATASET_FILE}"
echo ">>> Output dir  : ${HOST_LEROBOT_DATASETS}/${REPO_ID}"
echo ">>> task=${TASK}  task_type=${TASK_TYPE}  fps=${FPS}"
echo ""

docker run --rm \
    --name "$CONVERT_CONTAINER" \
    --gpus all \
    -e ACCEPT_EULA=Y \
    -e PRIVACY_CONSENT=Y \
    -e NVIDIA_DRIVER_CAPABILITIES=all \
    -e PYTHONPATH="${LEISAAC_SRC}" \
    -e HF_LEROBOT_HOME="/workspace/lerobot_datasets" \
    -v "${HOST_DATASETS}:/workspace/leisaac/datasets" \
    -v "${HOST_LEROBOT_DATASETS}:/workspace/lerobot_datasets" \
    -v "${WORK_DIR}/leisaac/assets:/workspace/leisaac/assets" \
    -v "${CACHE_ROOT}/kit:/isaac-sim/kit/cache:rw" \
    -v "${CACHE_ROOT}/ov:/isaac-sim/.cache/ov:rw" \
    -v "${CACHE_ROOT}/glcache:/isaac-sim/.cache/nvidia/GLCache:rw" \
    -v "${CACHE_ROOT}/computecache:/isaac-sim/.nv/ComputeCache:rw" \
    -v "${CACHE_ROOT}/pip:/isaac-sim/.cache/pip:rw" \
    -v ~/docker/leisaac/logs:/isaac-sim/.nvidia-omniverse/logs:rw \
    -v /usr/share/vulkan/icd.d:/usr/share/vulkan/icd.d:ro \
    --entrypoint /isaac-sim/python.sh \
    "$CONVERT_IMAGE" \
    /workspace/leisaac/scripts/convert/isaaclab2lerobot.py \
    --task_name="${TASK}" \
    --task_type="${TASK_TYPE}" \
    --hdf5_root="/workspace/leisaac/datasets" \
    --hdf5_files="${DATASET_FILE}" \
    --repo_id="${REPO_ID}" \
    --fps="${FPS}" \
    --headless \
    --enable_cameras \
    --device cuda

echo ""
echo ">>> Test 7 passed. LeRobot dataset at ${HOST_LEROBOT_DATASETS}/${REPO_ID}"
