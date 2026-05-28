#!/bin/bash
# 02-convert.sh — Convert collected HDF5 demos to LeRobot format, then add
# one-hot concept labels (color, shape, dropoff) for ConceptACT training.
#
# Step A — HDF5 → LeRobot (leisaac-convert:latest)
#   Input : /data/sorting-experiment/demos/{case}/dataset.hdf5
#   Output: /data/sorting-experiment/lerobot_datasets/sim/sort_object_{case}/
#   Sentinel: {lerobot_dir}/.converted
#
# Step B — add concept labels (lerobot:latest + add_sim_concepts.py)
#   Input : sim/sort_object_{case}
#   Output: sim/sort_object_with_concepts_{case}
#   Sentinel: {concept_dir}/.concepts_added
#
# Both steps are idempotent — skipped if the sentinel already exists.
# Set FORCE=1 to re-run regardless of sentinels.
#
# Key overrideable env vars:
#   TASK_TYPE   teleop source: so101leader|keyboard (default so101leader)
#   FPS         target frame rate (default 30)
#   FORCE       1 = redo even if sentinel exists (default 0)
#   SKIP_CONCEPTS  1 = skip concept label step (default 0)

set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

TASK_TYPE="${TASK_TYPE:-so101leader}"
FPS="${FPS:-30}"
FORCE="${FORCE:-0}"
SKIP_CONCEPTS="${SKIP_CONCEPTS:-0}"

echo "=== Sort-object dataset conversion ==="
echo "  Demos dir    : ${DEMOS_DIR}"
echo "  LeRobot dir  : ${LEROBOT_DIR}"
echo "  FPS          : ${FPS}  task_type=${TASK_TYPE}"
[ "$SKIP_CONCEPTS" = "1" ] && echo "  Concept step : SKIPPED"
echo ""

mkdir -p "${LEROBOT_DIR}"

# ── Status summary ────────────────────────────────────────────────────────────
echo "Case status:"
TO_CONVERT=(); TO_LABEL=()
for case in "${ALL_CASES[@]}"; do
    shape="$(case_shape "$case")"; color="$(case_color "$case")"
    dropoff="$(determine_dropoff "$color" "$shape")"
    tag="[${dropoff}]"

    if ! is_complete "$case"; then
        echo "  [no demos ] ${case} ${tag} — run 01-collect.sh first"
        continue
    fi

    conv_done="no";  [ "$FORCE" != "1" ] && is_converted    "$case" && conv_done="yes"
    label_done="no"; [ "$FORCE" != "1" ] && is_concepts_added "$case" && label_done="yes"
    echo "  conv=${conv_done}  labels=${label_done}  ${case} ${tag}"

    [ "$conv_done"  = "no" ] && TO_CONVERT+=("$case")
    [ "$label_done" = "no" ] && [ "$SKIP_CONCEPTS" != "1" ] && TO_LABEL+=("$case")
done

echo ""
if [ ${#TO_CONVERT[@]} -eq 0 ] && [ ${#TO_LABEL[@]} -eq 0 ]; then
    echo "Nothing to do."
    exit 0
fi
[ ${#TO_CONVERT[@]} -gt 0 ] && echo "${#TO_CONVERT[@]} case(s) to convert."
[ ${#TO_LABEL[@]}   -gt 0 ] && echo "${#TO_LABEL[@]} case(s) to label with concepts."
echo ""

# ── Step A: HDF5 → LeRobot ────────────────────────────────────────────────────
for case in "${TO_CONVERT[@]}"; do
    TASK="$(case_to_task "$case")"
    REPO_ID="$(case_to_repo_id "$case")"
    CONTAINER="leisaac-convert-${case}"

    docker rm "$CONTAINER" >/dev/null 2>&1 || true

    echo "────────────────────────────────────────────────────────"
    echo ">>> [A] Converting: ${case}"
    echo ">>>   Task    : ${TASK}"
    echo ">>>   Repo ID : ${REPO_ID}"
    echo ">>>   HDF5    : ${DEMOS_DIR}/${case}/dataset.hdf5"
    echo ""

    docker run --rm --name "$CONTAINER" \
        --gpus all \
        -e ACCEPT_EULA=Y -e PRIVACY_CONSENT=Y \
        -e NVIDIA_DRIVER_CAPABILITIES=all \
        -e PYTHONPATH="${LEISAAC_SRC}" \
        -e HF_LEROBOT_HOME="/workspace/lerobot_datasets" \
        -v "${DEMOS_DIR}/${case}:/workspace/leisaac/datasets/${case}" \
        -v "${LEROBOT_DIR}:/workspace/lerobot_datasets" \
        -v "${CACHE_ROOT}/kit:/isaac-sim/kit/cache:rw" \
        -v "${CACHE_ROOT}/ov:/isaac-sim/.cache/ov:rw" \
        -v "${CACHE_ROOT}/glcache:/isaac-sim/.cache/nvidia/GLCache:rw" \
        -v "${CACHE_ROOT}/computecache:/isaac-sim/.nv/ComputeCache:rw" \
        -v "${CACHE_ROOT}/pip:/isaac-sim/.cache/pip:rw" \
        -v /usr/share/vulkan/icd.d:/usr/share/vulkan/icd.d:ro \
        --entrypoint /isaac-sim/python.sh \
        "$CONVERT_IMAGE" \
        /workspace/leisaac/scripts/convert/isaaclab2lerobot.py \
        --task_name="${TASK}" \
        --task_type="${TASK_TYPE}" \
        --hdf5_root="/workspace/leisaac/datasets/${case}" \
        --hdf5_files="dataset.hdf5" \
        --repo_id="${REPO_ID}" \
        --fps="${FPS}" \
        --headless --enable_cameras --device cuda

    mark_converted "$case"
    echo ">>> Converted: ${LEROBOT_DIR}/${REPO_ID}"
    echo ""
done

# ── Step B: add concept labels ────────────────────────────────────────────────
for case in "${TO_LABEL[@]}"; do
    SRC_REPO="$(case_to_repo_id "$case")"
    DST_REPO="$(case_to_concept_repo_id "$case")"
    CONTAINER="lerobot-concepts-${case}"

    docker rm "$CONTAINER" >/dev/null 2>&1 || true

    echo "────────────────────────────────────────────────────────"
    echo ">>> [B] Adding concepts: ${case}"
    echo ">>>   Source : ${SRC_REPO}"
    echo ">>>   Target : ${DST_REPO}"
    echo ""

    docker run --rm --name "$CONTAINER" \
        --gpus all \
        -e HF_LEROBOT_HOME="/workspace/lerobot_datasets" \
        -v "${LEROBOT_DIR}:/workspace/lerobot_datasets" \
        -v "${SCRIPT_DIR}/add_sim_concepts.py:/workspace/add_sim_concepts.py:ro" \
        "$LEROBOT_IMAGE" \
        python /workspace/add_sim_concepts.py \
        --case="${case}" \
        --source-repo-id="${SRC_REPO}" \
        --target-repo-id="${DST_REPO}" \
        --root="/workspace/lerobot_datasets"

    mark_concepts_added "$case"
    echo ">>> Labels added: ${LEROBOT_DIR}/${DST_REPO}"
    echo ""
done

echo "=== Conversion complete ==="
echo "Run 03-train.sh to start training."
