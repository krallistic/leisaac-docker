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

## Pull results back for eval (on GCP)

```bash
gcloud storage rsync -r gs://leisaac-training-<project>/checkpoints \
    /data/sorting-experiment/checkpoints
# then: EVAL_ROUNDS=20 bash sorting-experiment/04-eval.sh
```

## Notes / caveats

- **`lavact`** needs `voltron-robotics` in the image — add `RUN /opt/venv/bin/pip
  install voltron-robotics` to `Dockerfile.train` before using `POLICIES=lavact`.
- **`runpodctl` flags vary by version** — verify with `runpodctl create pod --help`
  and adjust `start-runpod.sh` (e.g. `--gpuType` string, `--communityCloud`).
- **Security:** `runpod-sa-key.json*` is git-ignored. The SA is scoped to the one
  bucket. Delete it when finished:
  `gcloud iam service-accounts delete runpod-training@<project>.iam.gserviceaccount.com`.
