#!/usr/bin/env python3
"""Load all sorting-experiment eval results into a pandas DataFrame.

Each trained model (one checkpoint job, evaluated on up to two held-out test
cases) becomes ONE row. Hyperparameters are parsed out of the job name; columns
that don't apply to a given policy are left as None/NaN (e.g. concept_* for a
plain ACT or diffusion model).

GCS layout (written by 04-eval.sh):
    gs://<bucket>/eval/<job_name>/<case>/results.json

Job naming (train-and-sync.sh):
    <experiment>_<policy_base>_percent_<percent>_seed_<seed>
    policy_base:  act_lr<LR>
                  concept_act_{tce,ph,flat,cbm}_cw<CW>_lr<LR>[_grp<G>][_noise<N>]
                  diffusion_lr<LR>
                  lavact_lr<LR>

Usage:
    python load_eval_results.py                          # pull from GCS, print table
    python load_eval_results.py --out results.csv        # also write a CSV
    python load_eval_results.py --out results.parquet    # ... or Parquet (needs pyarrow)
    python load_eval_results.py --local-dir ./eval       # read an already-downloaded tree
    python load_eval_results.py --long                   # one row per (model, case) instead

Needs: pandas (+ pyarrow only for --out *.parquet), and gcloud authenticated for
the bucket unless --local-dir is given.
"""
import argparse
import json
import re
import subprocess
import sys
import tempfile
from pathlib import Path

import pandas as pd

DEFAULT_BUCKET = "gs://leisaac-training-uni-ulm-compute-stuff"
TEST_CASES = ["cube_red", "rectangle_yellow"]


def _to_float(x):
    try:
        return float(x)
    except (TypeError, ValueError):
        return None


def parse_job_name(job: str) -> dict:
    """<experiment>_<policy_base>_percent_<p>_seed_<s>  ->  structured fields.

    Fields that don't apply to a policy stay None (concept_* for act/diffusion/
    lavact; concept_group/concept_noise unless present in the name)."""
    d = dict(job_name=job, experiment=None, policy=None, concept_method=None,
             lr=None, concept_weight=None, concept_group=None, concept_noise=None,
             percent=None, seed=None)

    head = job
    m = re.search(r"_percent_([^_]+)_seed_([^_]+)$", job)
    if m:
        d["percent"] = _to_float(m.group(1))
        try:
            d["seed"] = int(m.group(2))
        except ValueError:
            d["seed"] = m.group(2)
        head = job[:m.start()]

    # Each pattern is anchored to the END of <experiment>_<policy_base>; the
    # non-greedy (?P<exp>.+?) absorbs the (arbitrary) experiment-name prefix.
    patterns = [
        (r"^(?P<exp>.+?)_concept_act_(?P<variant>tce|ph|flat|cbm)_cw(?P<cw>[^_]+)_lr(?P<lr>[^_]+)"
         r"(?:_grp(?P<grp>[^_]+))?(?:_noise(?P<noise>[^_]+))?$", "concept_act"),
        (r"^(?P<exp>.+?)_lavact_lr(?P<lr>[^_]+)$", "lavact"),
        (r"^(?P<exp>.+?)_diffusion_lr(?P<lr>[^_]+)$", "diffusion"),
        (r"^(?P<exp>.+?)_act_lr(?P<lr>[^_]+)$", "act"),
    ]
    for pat, policy in patterns:
        m = re.match(pat, head)
        if not m:
            continue
        g = m.groupdict()
        d["experiment"] = g["exp"]
        d["policy"] = policy
        d["concept_method"] = g.get("variant")          # None for non-concept policies
        d["lr"] = _to_float(g.get("lr"))
        d["concept_weight"] = _to_float(g.get("cw"))
        d["concept_group"] = g.get("grp")               # None unless _grp<G> in name
        d["concept_noise"] = _to_float(g.get("noise"))  # None unless _noise<N> in name
        break
    else:
        # Couldn't parse the policy base — keep the raw head so the row isn't lost.
        d["experiment"] = head
        print(f"[warn] could not parse policy base from job: {job}", file=sys.stderr)
    return d


_GRP_DISPLAY = {"all": "all", "object": "object", "rule": "target"}


def method_label(d: dict) -> str:
    """Canonical, human-readable condition label distinguishing every method
    variant: policy + concept_method + concept_group. A null/absent group is
    treated as 'all'; group 'rule' is the target/dropoff concept; cbm and flat
    are group-agnostic. Lets the CSV self-describe all 10 sorting conditions."""
    pol, cm = d.get("policy"), d.get("concept_method")
    grp = d.get("concept_group") or "all"
    if pol == "act":
        return "ACT"
    if pol == "diffusion":
        return "Diffusion"
    if pol == "concept_act":
        if cm == "cbm":
            return "ConceptACT-CBM"
        if cm == "flat":
            return "ConceptACT-Flat"
        base = {"tce": "ConceptACT-Transformer", "ph": "ConceptACT-Heads"}.get(
            cm, f"ConceptACT-{cm}")
        return f"{base} ({_GRP_DISPLAY.get(grp, grp)})"
    return pol or "unknown"


def _case_counts(res: dict) -> dict:
    """Score counts {0..3} for one case's results.json."""
    sd = res.get("aggregated", {}).get("score_distribution", {})
    return {
        0: sd.get("score_0_pick_failed", 0),
        1: sd.get("score_1_place_failed", 0),
        2: sd.get("score_2_wrong_sort", 0),
        3: sd.get("score_3_success", 0),
    }


def aggregate_job(job: str, per_case: dict) -> dict:
    """One row per model: parsed params + per-case metrics + pooled overall."""
    row = parse_job_name(job)
    row["method"] = method_label(row)
    pooled = {k: 0 for k in range(4)}
    policy_type = None
    n_cases = 0

    for case in TEST_CASES:
        res = per_case.get(case)
        if res is None:
            row[f"{case}_success_rate"] = None
            row[f"{case}_avg_score"] = None
            row[f"{case}_n"] = None
            continue
        n_cases += 1
        agg = res.get("aggregated", {})
        counts = _case_counts(res)
        n = agg.get("total_episodes") or sum(counts.values())
        row[f"{case}_success_rate"] = agg.get("success_rate")
        row[f"{case}_avg_score"] = agg.get("average_score")
        row[f"{case}_n"] = n
        for k in range(4):
            pooled[k] += counts[k]
        policy_type = policy_type or res.get("metadata", {}).get("policy_type")

    total = sum(pooled.values())
    row["policy_type"] = policy_type
    row["n_cases"] = n_cases
    row["n_episodes"] = total or None
    row["success_rate"] = (pooled[3] / total) if total else None
    row["avg_score"] = (sum(k * pooled[k] for k in range(4)) / total) if total else None
    for k in range(4):
        row[f"n_score_{k}"] = pooled[k]
    return row


def long_rows(job: str, per_case: dict) -> list:
    """One row per (model, case) — handy for groupby / seaborn."""
    base = parse_job_name(job)
    base["method"] = method_label(base)
    out = []
    for case in TEST_CASES:
        res = per_case.get(case)
        if res is None:
            continue
        agg = res.get("aggregated", {})
        counts = _case_counts(res)
        r = dict(base)
        r["case"] = case
        r["success_rate"] = agg.get("success_rate")
        r["avg_score"] = agg.get("average_score")
        r["n_episodes"] = agg.get("total_episodes") or sum(counts.values())
        for k in range(4):
            r[f"n_score_{k}"] = counts[k]
        r["policy_type"] = res.get("metadata", {}).get("policy_type")
        out.append(r)
    return out


def load_results_tree(root: Path) -> dict:
    """root/<job>/<case>/results.json  ->  {job: {case: parsed_json}}"""
    tree = {}
    for rj in sorted(root.glob("*/*/results.json")):
        case, job = rj.parent.name, rj.parent.parent.name
        try:
            tree.setdefault(job, {})[case] = json.loads(rj.read_text())
        except (ValueError, OSError) as e:
            print(f"[warn] skipping {rj}: {e}", file=sys.stderr)
    return tree


def sync_gcs(bucket: str, prefix: str, dest: Path) -> None:
    src = f"{bucket.rstrip('/')}/{prefix}"
    print(f">>> rsync {src} -> {dest}", file=sys.stderr)
    subprocess.run(["gcloud", "storage", "rsync", "-r", src, str(dest)], check=True)


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--bucket", default=DEFAULT_BUCKET)
    ap.add_argument("--eval-prefix", default="eval", help="folder under the bucket (default: eval)")
    ap.add_argument("--local-dir", default=None, help="read an existing eval/ tree instead of GCS")
    ap.add_argument("--cache-dir", default=None, help="where to rsync GCS into (default: temp dir)")
    ap.add_argument("--out", default=None, help="write the table to .csv or .parquet")
    ap.add_argument("--long", action="store_true", help="one row per (model, case) instead of per model")
    args = ap.parse_args()

    if args.local_dir:
        root = Path(args.local_dir)
    else:
        root = Path(args.cache_dir) if args.cache_dir else Path(tempfile.mkdtemp(prefix="eval_"))
        root.mkdir(parents=True, exist_ok=True)
        sync_gcs(args.bucket, args.eval_prefix, root)

    tree = load_results_tree(root)
    if not tree:
        print(f"No results.json found under {root}", file=sys.stderr)
        sys.exit(1)

    if args.long:
        rows = [r for job, pc in sorted(tree.items()) for r in long_rows(job, pc)]
    else:
        rows = [aggregate_job(job, pc) for job, pc in sorted(tree.items())]
    df = pd.DataFrame(rows)

    # Put the identifying / hyperparameter columns first for readability.
    front = ["job_name", "experiment", "policy", "concept_method", "concept_group",
             "method", "case",
             "percent", "seed", "lr", "concept_weight", "concept_noise",
             "n_cases", "n_episodes", "success_rate", "avg_score",
             "n_score_0", "n_score_1", "n_score_2", "n_score_3", "policy_type"]
    cols = [c for c in front if c in df.columns] + [c for c in df.columns if c not in front]
    df = df[cols]

    if args.out:
        if args.out.endswith(".parquet"):
            df.to_parquet(args.out, index=False)
        else:
            df.to_csv(args.out, index=False)
        print(f">>> wrote {len(df)} rows to {args.out}", file=sys.stderr)

    # Console preview + a tiny breakdown.
    with pd.option_context("display.max_columns", None, "display.width", 220):
        print(df.to_string(index=False))
    print(f"\n{len(df)} rows | policies: "
          + ", ".join(f"{p}={n}" for p, n in df['policy'].value_counts().items()), file=sys.stderr)
    return df


if __name__ == "__main__":
    main()
