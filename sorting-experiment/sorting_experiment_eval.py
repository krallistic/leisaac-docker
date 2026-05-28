"""Structured evaluation script for the sorting experiment.

Extends policy_inference.py with per-episode 0-3 scoring and JSON output.

Scoring (matches real-world cact_scripts/eval.py):
  3 = complete success: object placed in the CORRECT area
  2 = object placed in the WRONG area (sort failed)
  1 = object was lifted but not placed in either area (place failed)
  0 = object was never lifted (pick failed)

The correct target area is encoded in the Isaac Sim task name and enforced by
the env's own termination condition (object_in_box).  This script queries the
same env scene objects to determine the wrong-area placement for score 2 and
tracks object height to distinguish scores 0 and 1.

Must be run with /isaac-sim/python.sh inside the leisaac:latest container.
AppLauncher MUST be created before any isaaclab/omni imports.

Usage (from 04-eval.sh via docker run):
    /isaac-sim/python.sh /workspace/sorting_experiment_eval.py \\
        --task LeIsaac-SO101-SortObject-CubeRed-v0 \\
        --case cube_red \\
        --checkpoint_name act_lr3e-5_seed42 \\
        --policy_type lerobot-act \\
        --policy_host localhost --policy_port 5555 \\
        --policy_checkpoint_path /workspace/checkpoints/.../pretrained_model \\
        --eval_rounds 10 --step_hz 30 \\
        --output_json /workspace/eval/act_lr3e-5_seed42/cube_red/results.json \\
        --device cuda --headless --enable_cameras \\
        --livestream 2 --kit_args "..."
"""

import multiprocessing

if multiprocessing.get_start_method() != "spawn":
    multiprocessing.set_start_method("spawn", force=True)

import argparse
import datetime
import json
import time
from pathlib import Path

from isaaclab.app import AppLauncher

# ── CLI ───────────────────────────────────────────────────────────────────────
parser = argparse.ArgumentParser(description="Sorting experiment structured evaluation.")
parser.add_argument("--task",        required=True, help="Isaac Sim task name, e.g. LeIsaac-SO101-SortObject-CubeRed-v0")
parser.add_argument("--case",        required=True, help="Case name matching common.sh, e.g. cube_red")
parser.add_argument("--checkpoint_name", default="", help="Human-readable checkpoint label for JSON metadata")
parser.add_argument("--policy_type", default="lerobot-act", help="Policy type: lerobot-<model_type>")
parser.add_argument("--policy_host", default="localhost")
parser.add_argument("--policy_port", type=int, default=5555)
parser.add_argument("--policy_timeout_ms",    type=int,   default=15000)
parser.add_argument("--policy_action_horizon", type=int,  default=16)
parser.add_argument("--policy_checkpoint_path", default=None)
parser.add_argument("--policy_language_instruction", default=None)
parser.add_argument("--eval_rounds", type=int, default=10)
parser.add_argument("--step_hz",     type=int, default=30)
parser.add_argument("--episode_length_s", type=float, default=60.0)
parser.add_argument("--seed",        type=int, default=None)
parser.add_argument("--output_json", default=None, help="Path to write results JSON (printed to stdout if omitted)")
AppLauncher.add_app_launcher_args(parser)
args_cli = parser.parse_args()

app_launcher = AppLauncher(vars(args_cli))
simulation_app = app_launcher.app

# ── Post-launch imports ───────────────────────────────────────────────────────
import carb
import gymnasium as gym
import omni
import torch
from isaaclab.assets import RigidObject
from isaaclab.envs import ManagerBasedRLEnv
from isaaclab_tasks.utils import parse_env_cfg

import leisaac  # noqa: F401  — registers all task envs
from leisaac.utils.env_utils import dynamic_reset_gripper_effort_limit_sim, get_task_type

# ── Sorting rule ──────────────────────────────────────────────────────────────
# Must match _SORTING_TABLE in leisaac/tasks/sort_object/sort_object_env_cfg.py.

_SORTING_TABLE: dict[tuple[str, str], str] = {
    ("cube",      "red"):    "box",   # Area A
    ("cube",      "green"):  "box",   # Area A
    ("cube",      "yellow"): "box2",  # Area B
    ("rectangle", "red"):    "box2",  # Area B
    ("rectangle", "blue"):   "box2",  # Area B
    ("rectangle", "green"):  "box2",  # Area B
    ("rectangle", "yellow"): "box2",  # Area B
    ("cylinder",  "red"):    "box2",  # Area B
    ("cylinder",  "blue"):   "box",   # Area A
    ("cylinder",  "green"):  "box2",  # Area B
}

_BOX_TO_AREA = {"box": "A", "box2": "B"}

# Object is considered "lifted" once its env-local z rises above this threshold.
# Table surface ≈ 0.04 m; object spawn ≈ 0.062 m; box top ≈ 0.096 m.
_LIFT_THRESHOLD_M = 0.12

# Same footprint tolerances as the env's object_in_box termination.
_BOX_X_RANGE = (-0.065, 0.065)
_BOX_Y_RANGE = (-0.065, 0.065)
_BOX_HEIGHT_THRESHOLD = 0.10


# ── Helpers ───────────────────────────────────────────────────────────────────

class RateLimiter:
    def __init__(self, hz: int):
        self.sleep_duration = 1.0 / hz
        self.render_period  = min(0.0166, self.sleep_duration)
        self.last_time = time.time()

    def sleep(self, env):
        target = self.last_time + self.sleep_duration
        while time.time() < target:
            time.sleep(self.render_period)
            env.sim.render()
        self.last_time += self.sleep_duration
        if self.last_time < time.time():
            while self.last_time < time.time():
                self.last_time += self.sleep_duration


def object_local_z(env: ManagerBasedRLEnv, object_name: str) -> float:
    obj: RigidObject = env.scene[object_name]
    return (obj.data.root_pos_w[0, 2] - env.scene.env_origins[0, 2]).item()


def check_in_box(env: ManagerBasedRLEnv, object_name: str, box_name: str) -> bool:
    """Replicates the object_in_box termination check for a single env instance."""
    box: RigidObject = env.scene[box_name]
    obj: RigidObject = env.scene[object_name]

    box_x = (box.data.root_pos_w[0, 0] - env.scene.env_origins[0, 0]).item()
    box_y = (box.data.root_pos_w[0, 1] - env.scene.env_origins[0, 1]).item()
    obj_x = (obj.data.root_pos_w[0, 0] - env.scene.env_origins[0, 0]).item()
    obj_y = (obj.data.root_pos_w[0, 1] - env.scene.env_origins[0, 1]).item()
    obj_z = (obj.data.root_pos_w[0, 2] - env.scene.env_origins[0, 2]).item()

    in_x = (box_x + _BOX_X_RANGE[0]) < obj_x < (box_x + _BOX_X_RANGE[1])
    in_y = (box_y + _BOX_Y_RANGE[0]) < obj_y < (box_y + _BOX_Y_RANGE[1])
    return in_x and in_y and obj_z < _BOX_HEIGHT_THRESHOLD


def preprocess_obs(obs_dict: dict, language_instruction: str) -> dict:
    obs_dict["task_description"] = language_instruction
    return obs_dict


# ── Main ──────────────────────────────────────────────────────────────────────

def main():
    # ── Parse case into shape + color ────────────────────────────────────────
    parts  = args_cli.case.split("_", 1)
    shape, color = parts[0], parts[1]
    if (shape, color) not in _SORTING_TABLE:
        raise ValueError(f"Unknown case '{args_cli.case}'. Valid cases: {list(_SORTING_TABLE)}")

    correct_box  = _SORTING_TABLE[(shape, color)]
    wrong_box    = "box2" if correct_box == "box" else "box"
    correct_area = _BOX_TO_AREA[correct_box]
    wrong_area   = _BOX_TO_AREA[wrong_box]

    language_instruction = (
        args_cli.policy_language_instruction
        or f"Pick up the {color} {shape} and place it in the correct box."
    )

    print(f"[SortEval] Case          : {args_cli.case}  (shape={shape}  color={color})")
    print(f"[SortEval] Correct area  : {correct_area}  (box prim: {correct_box})")
    print(f"[SortEval] Checkpoint    : {args_cli.checkpoint_name}")
    print(f"[SortEval] Eval rounds   : {args_cli.eval_rounds}")
    print()

    # ── Build env ────────────────────────────────────────────────────────────
    env_cfg = parse_env_cfg(args_cli.task, device=args_cli.device, num_envs=1)
    task_type = get_task_type(args_cli.task)
    env_cfg.use_teleop_device(task_type)
    env_cfg.seed = args_cli.seed if args_cli.seed is not None else int(time.time())
    env_cfg.episode_length_s = args_cli.episode_length_s
    env_cfg.recorders = None

    env: ManagerBasedRLEnv = gym.make(args_cli.task, cfg=env_cfg).unwrapped

    # ── Build policy client ───────────────────────────────────────────────────
    from isaaclab.sensors import Camera
    from leisaac.policy import LeRobotServicePolicyClient

    policy_model = args_cli.policy_type.split("-", 1)[1]  # "lerobot-act" → "act"
    policy = LeRobotServicePolicyClient(
        host=args_cli.policy_host,
        port=args_cli.policy_port,
        timeout_ms=args_cli.policy_timeout_ms,
        camera_infos={
            key: sensor.image_shape
            for key, sensor in env.scene.sensors.items()
            if isinstance(sensor, Camera)
        },
        task_type=task_type,
        policy_type=policy_model,
        pretrained_name_or_path=args_cli.policy_checkpoint_path,
        actions_per_chunk=args_cli.policy_action_horizon,
        device=args_cli.device,
    )

    rate_limiter = RateLimiter(args_cli.step_hz)
    obs_dict, _ = env.reset()

    # ── Episode loop ──────────────────────────────────────────────────────────
    episode_records: list[dict] = []
    ep = 0

    while ep < args_cli.eval_rounds:
        ep += 1
        print(f"[SortEval] Episode {ep}/{args_cli.eval_rounds} ...")

        success   = False
        time_out  = False
        max_obj_z = object_local_z(env, shape)  # track lift height

        while simulation_app.is_running():
            with torch.inference_mode():
                processed = preprocess_obs(dict(obs_dict["policy"]), language_instruction)
                actions = policy.get_action(processed).to(env.device)

                for i in range(min(args_cli.policy_action_horizon, actions.shape[0])):
                    action = actions[i, :, :]
                    if env.cfg.dynamic_reset_gripper_effort_limit:
                        dynamic_reset_gripper_effort_limit_sim(env, task_type)

                    obs_dict, _, terminated, timed_out, _ = env.step(action)

                    # Update height tracker
                    z = object_local_z(env, shape)
                    if z > max_obj_z:
                        max_obj_z = z

                    if terminated[0]:
                        success = True
                        break
                    if timed_out[0]:
                        time_out = True
                        break
                    if rate_limiter:
                        rate_limiter.sleep(env)

            if success or time_out:
                break

        # ── Score the episode ─────────────────────────────────────────────────
        object_lifted = max_obj_z > _LIFT_THRESHOLD_M

        if success:
            # Env's termination fired: object is in the correct box.
            area_placed = correct_area
            score = 3
        else:
            # Check if object ended up in the wrong box.
            in_wrong = check_in_box(env, shape, wrong_box)
            if in_wrong:
                area_placed = wrong_area
                score = 2
            elif object_lifted:
                area_placed = None
                score = 1
            else:
                area_placed = None
                score = 0

        outcome = {3: "success", 2: "wrong_area", 1: "place_failed", 0: "pick_failed"}[score]
        print(f"[SortEval]   score={score} ({outcome})  lifted={object_lifted}  placed={area_placed or 'none'}")

        episode_records.append({
            "episode":       ep,
            "score":         score,
            "object_lifted": object_lifted,
            "area_placed":   area_placed,
            "expected_area": correct_area,
            "timed_out":     time_out,
        })

        # Reset for next episode.
        obs_dict, _ = env.reset()

    # ── Aggregate results ─────────────────────────────────────────────────────
    scores = [r["score"] for r in episode_records]
    dist   = {str(k): scores.count(k) for k in range(4)}
    success_rate = scores.count(3) / len(scores) if scores else 0.0
    avg_score    = sum(scores) / len(scores) if scores else 0.0

    results = {
        "metadata": {
            "checkpoint":   args_cli.checkpoint_name,
            "case":         args_cli.case,
            "shape":        shape,
            "color":        color,
            "expected_area": correct_area,
            "task":         args_cli.task,
            "eval_rounds":  args_cli.eval_rounds,
            "step_hz":      args_cli.step_hz,
            "policy_type":  args_cli.policy_type,
            "date":         datetime.datetime.now().isoformat(),
            "scoring_system": {
                "0": "pick failed (object never lifted)",
                "1": "place failed (object lifted but not placed in any area)",
                "2": "wrong sort (placed in wrong area)",
                "3": "complete success (placed in correct area)",
            },
        },
        "episodes": episode_records,
        "aggregated": {
            "success_rate":   success_rate,
            "average_score":  avg_score,
            "total_episodes": len(scores),
            "score_distribution": {
                "score_0_pick_failed":   dist["0"],
                "score_1_place_failed":  dist["1"],
                "score_2_wrong_sort":    dist["2"],
                "score_3_success":       dist["3"],
            },
        },
    }

    print()
    print(f"[SortEval] ── Results ──────────────────────────────────────")
    print(f"[SortEval]  Success rate  : {success_rate:.1%}  [{scores.count(3)}/{len(scores)}]")
    print(f"[SortEval]  Average score : {avg_score:.2f}")
    print(f"[SortEval]  Distribution  : {dist}")
    print(f"[SortEval] ────────────────────────────────────────────────")

    json_str = json.dumps(results, indent=2)
    if args_cli.output_json:
        out = Path(args_cli.output_json)
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(json_str)
        print(f"[SortEval] Results written to: {out}")
    else:
        print(json_str)

    env.close()
    simulation_app.close()


if __name__ == "__main__":
    main()
