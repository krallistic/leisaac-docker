# RunPod training (off-GCP, A100)

GCP capped this project at one L4 (`GPUS_ALL_REGIONS=1`, A100 quota denied), so
training runs on rented RunPod A100s. **GCS is the hub**: datasets up, checkpoints
back — feeding straight into the existing GCP eval pipeline.

```
  GCP disk (/data)              GCS bucket                    RunPod A100 pod
  lerobot_datasets/  ──upload──▶ <bucket>/lerobot_datasets ──pull──▶ train
  checkpoints/       ◀──pull──── <bucket>/checkpoints       ◀──sync── (per job)
```

## Pieces

| File | Where it runs | What it does |
|---|---|---|
| `01-setup-gcs.sh` | GCP box (once) | Create bucket + scoped SA + key; upload datasets |
| `.github/workflows/docker-train.yml` | GitHub Actions | Build `Dockerfile.train` → `ghcr.io/<owner>/lerobot:latest` |
| `gcs-entrypoint.sh` | in image | Decode `$GCP_SA_KEY_B64` → GCS auth, then exec CMD (no secret baked) |
| `train-and-sync.sh` | in pod (default CMD) | Pull datasets → train POLICIES×SEEDS → sync each checkpoint |
| `start-runpod.sh` | laptop | `runpodctl` launch with the right env/secret |

## One-time setup

1. **Build & publish the image.** Push to `main` (touching `Dockerfile.train` or the
   `runpod/` scripts) or run the *Build and push lerobot (train) image* workflow
   manually. Then make the GHCR package **public**, or add a GitHub PAT
   (`read:packages`) as a Container Registry credential in RunPod so it can pull.

2. **GCS bucket + key** (on the GCP box, where `/data` is mounted):
   ```bash
   bash runpod/01-setup-gcs.sh
   ```
   Creates `gs://leisaac-training-<project>`, a bucket-scoped service account, a
   key (`runpod-sa-key.json` + `.b64`), and uploads the datasets.

3. **RunPod secret.** Create a secret named `gcp_key` from the contents of
   `runpod/runpod-sa-key.json.b64` (Console → Settings → Secrets). This keeps the
   key out of the image *and* out of the pod config.

## Run the sweep

```bash
# one pod, the concept-ACT (transformer_ce) variant, 3 seeds
GCS_BUCKET=gs://leisaac-training-<project> RUNPOD_SECRET_NAME=gcp_key \
  POLICIES="concept_act_tce" SEEDS="42 123 456" STEPS=50000 \
  bash runpod/start-runpod.sh
```

Parallelize by launching one pod per policy (each call = one pod):
```bash
for P in act concept_act_tce concept_act_ph; do
  GCS_BUCKET=gs://leisaac-training-<project> RUNPOD_SECRET_NAME=gcp_key \
    POLICIES="$P" SEEDS="42 123 456" NAME="train-$P" bash runpod/start-runpod.sh
done
```

Each pod is idempotent: a job already in `<bucket>/checkpoints/<job>/checkpoints/last/`
is skipped, so a reclaimed spot pod resumes the rest after re-launch. Pods exit
when done (billing stops); set `KEEP_ALIVE=1` to keep one up for inspection.

## Quick timing benchmark

A separate, fast run that measures **wall-clock latency** (no training, no
checkpoints) for each policy: the time for one train step (forward + backward +
`optimizer.step`) and the average inference time (one full action-chunk, batch
size 1). Models built untrained from one case's dataset — only the timings matter.

```bash
# all six models on an A100, results → <bucket>/timing/<EXPERIMENT_NAME>/
RUNPOD_SECRET_NAME=gcp_key bash runpod/run_timing_experiment.sh

# subset / bigger train batch
POLICIES="act diffusion" BATCH_SIZE=8 RUNPOD_SECRET_NAME=gcp_key \
  bash runpod/run_timing_experiment.sh
```

It rides the same launch path as the sweeps: `run_timing_experiment.sh` sets
`RUN_MODE=timing`, which makes the image CMD (`train-and-sync.sh`) hand off to
`benchmark-and-sync.sh`. That pulls one case (plain + with_concepts), runs
`cact_scripts/timing_benchmark.py` per policy, and syncs a combined
`timing_results.csv` (+ per-policy JSON with raw samples) to
`<bucket>/timing/<EXPERIMENT_NAME>/`.

- **Default policies:** `act concept_act_tce concept_act_ph concept_act_cbm diffusion lavact`.
- **`lavact`** works out of the box — `voltron-robotics` is baked into the image
  (`Dockerfile.train`). The scripts still skip it gracefully if a build somehow lacks it.
- **Knobs:** `CASE` (default `cube_green`), `BATCH_SIZE` (32), `BENCH_INFER_BS` (1),
  `BENCH_WARMUP`/`BENCH_ITERS` (train, 5/30), `BENCH_INFER_WARMUP`/`BENCH_INFER_ITERS`
  (inference, 10/50). Since the python harness and the two baked shell scripts ride
  the image, changing any of them needs a `Dockerfile.train` rebuild.

Pull the results locally:
```bash
gcloud storage cat gs://leisaac-training-<project>/timing/<EXPERIMENT_NAME>/timing_results.csv
```

## Pull results back for eval (on GCP)

```bash
gcloud storage rsync -r gs://leisaac-training-<project>/checkpoints \
    /data/sorting-experiment/checkpoints
# then: EVAL_ROUNDS=20 bash sorting-experiment/04-eval.sh
```

## Notes / caveats

- **`lavact`** works out of the box — `voltron-robotics` is installed in the image
  (`Dockerfile.train`, in the lerobot install layer before the grpcio/protobuf pin).
- **`runpodctl` flags vary by version** — verify with `runpodctl create pod --help`
  and adjust `start-runpod.sh` (e.g. `--gpuType` string, `--communityCloud`).
- **Security:** `runpod-sa-key.json*` is git-ignored. The SA is scoped to the one
  bucket. Delete it when finished:
  `gcloud iam service-accounts delete runpod-training@<project>.iam.gserviceaccount.com`.
