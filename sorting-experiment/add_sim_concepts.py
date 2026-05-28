#!/usr/bin/env python3
"""Add one-hot concept labels to a simulation LeRobot dataset.

Concept values are derived from the case name (shape_color) rather than from
episode task descriptions, because the sim records the env's default task string
rather than the formatted "Pickup X at Y and drop it in Z" string used by the
real-world add_features_from_metadata.py.

Concepts added:
  concept_color    one-hot over [red, green, yellow, blue]
  concept_shape    one-hot over [cube, rectangle, cylinder]
  concept_dropoff  one-hot over [A, B]  (derived from the sorting rule)

Usage (inside the lerobot:latest container):
    python add_sim_concepts.py \\
        --case cube_green \\
        --source-repo-id sim/sort_object_cube_green \\
        --target-repo-id sim/sort_object_with_concepts_cube_green \\
        --root /workspace/lerobot_datasets
"""

import argparse
from pathlib import Path

import numpy as np
import tqdm


ALL_COLORS   = ["red", "green", "yellow", "blue"]
ALL_SHAPES   = ["cube", "rectangle", "cylinder"]
ALL_DROPOFFS = ["A", "B"]


def determine_dropoff(color: str, shape: str) -> str:
    """Area A: (cube ∧ color∈{red,green}) ∨ (cylinder ∧ blue). Area B: otherwise.
    Must match _SORTING_TABLE in leisaac/tasks/sort_object/sort_object_env_cfg.py."""
    if shape == "cube" and color in ("red", "green"):
        return "A"
    if shape == "cylinder" and color == "blue":
        return "A"
    return "B"


def one_hot(values: list, target: str) -> np.ndarray:
    return np.array([1 if v == target else 0 for v in values], dtype=np.int64)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--case",            required=True,  help="e.g. cube_green")
    parser.add_argument("--source-repo-id",  required=True,  help="e.g. sim/sort_object_cube_green")
    parser.add_argument("--target-repo-id",  required=True,  help="e.g. sim/sort_object_with_concepts_cube_green")
    parser.add_argument("--root",            type=Path, default=None, help="HF_LEROBOT_HOME path")
    args = parser.parse_args()

    # Parse case name: first segment = shape, remainder = color
    # Handles both "cube_green" and "cylinder_red" etc.
    parts   = args.case.split("_", 1)
    shape   = parts[0]
    color   = parts[1]
    dropoff = determine_dropoff(color, shape)

    print(f"Case: {args.case}  →  shape={shape}  color={color}  dropoff={dropoff}")

    concept_vectors = {
        "concept_color":   one_hot(ALL_COLORS,   color),
        "concept_shape":   one_hot(ALL_SHAPES,   shape),
        "concept_dropoff": one_hot(ALL_DROPOFFS, dropoff),
    }
    feature_configs = {
        "concept_color":   {"dtype": "int64", "shape": (len(ALL_COLORS),),   "names": [f"concept_color_{c}"   for c in ALL_COLORS]},
        "concept_shape":   {"dtype": "int64", "shape": (len(ALL_SHAPES),),   "names": [f"concept_shape_{s}"   for s in ALL_SHAPES]},
        "concept_dropoff": {"dtype": "int64", "shape": (len(ALL_DROPOFFS),), "names": [f"concept_dropoff_{d}" for d in ALL_DROPOFFS]},
    }

    from lerobot.common.datasets.lerobot_dataset import LeRobotDataset
    from torchvision.transforms.v2 import Compose, ToPILImage

    print(f"Loading source dataset: {args.source_repo_id}")
    source = LeRobotDataset(args.source_repo_id, root=args.root)
    source.image_transforms = Compose([ToPILImage()])

    features = {**source.meta.features}
    for name, cfg in feature_configs.items():
        features[name] = {k: v for k, v in cfg.items()}

    print(f"Creating target dataset: {args.target_repo_id}")
    target = LeRobotDataset.create(
        repo_id=args.target_repo_id,
        fps=source.meta.fps,
        root=args.root,
        robot_type=source.meta.robot_type,
        features=features,
        use_videos=True,
        image_writer_threads=4,
    )

    target.start_image_writer(4)
    for ep_idx in tqdm.trange(source.meta.total_episodes, desc="Episodes"):
        from_idx = source.episode_data_index["from"][ep_idx].item()
        to_idx   = source.episode_data_index["to"][ep_idx].item()
        ep_meta  = source.meta.episodes[ep_idx]
        tasks_ep = ep_meta.get("tasks", [f"sort {color} {shape} to {dropoff}"])

        for i in range(from_idx, to_idx):
            frame = source[i]
            for name, vec in concept_vectors.items():
                frame[name] = vec
            for key in ("index", "frame_index", "task_index", "episode_index", "timestamp"):
                frame.pop(key, None)
            task_str = frame.pop("task", tasks_ep[0] if tasks_ep else "sort object")
            target.add_frame(frame, task=task_str)

        target.save_episode()

    target.stop_image_writer()
    print(f"Done. Dataset written to: {args.target_repo_id}")


if __name__ == "__main__":
    main()
