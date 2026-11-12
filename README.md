# CryptoBot — Real-Time & Batch Data Pipeline for Crypto Market Data

An end-to-end data engineering platform that ingests Binance BTC/USDT market data through **two independent pipelines** — a batch pipeline for historical candles and a real-time streaming pipeline for live ticks — stores each in a fit-for-purpose database, trains an ML model to forecast the next candle, and serves everything through a REST API and a live Streamlit dashboard. The full stack is containerized and covered by CI.

> Built solo as the capstone Data Engineering project for the DataScientest / Liora Data Engineer programme — designed, implemented, and delivered end-to-end.

## v2 in progress

The AWS/EKS deployment is being built on the `dev` branch. The finished Data Engineering version is release [v1.0-data-engineering](https://github.com/patel-pa/CryptoBot/releases/tag/v1.0-data-engineering).

---

## Architecture

Two pipelines that converge at a single serving layer (FastAPI + Streamlit):

```
Binance REST API   ──► clean ──► PostgreSQL (ohlcv_data) ──► ML training ──► model.pkl
                                                         └──► FastAPI /charts ──► dashboard

Binance WebSocket  ──► Path A (every tick) ─────────────────► FastAPI /stream ──► live chart
                   └─► Path B (on candle close) ──► MongoDB (closed_candles) ──► ML predict ──► FastAPI /predict
```

**Why two databases?** The two sources are fundamentally different, so they get different storage:

| | REST API (historical) | WebSocket (live) |
|---|---|---|
| Shape | Fixed 12-field candles, stable schema | High-frequency, semi-structured messages |
| Cadence | Batch (daily top-ups) | ~1 message/second, pushed |
| Store | **PostgreSQL** — schema enforcement, `NUMERIC(18,8)` exact prices, ordered time-series queries | **MongoDB** — high write throughput, flexible JSON, no migrations |

---

## Tech stack

**Languages & core:** Python 3.11
**Ingestion:** Binance REST API, Binance WebSocket (`websocket-client`, `websockets`)
**Storage:** PostgreSQL (SQLAlchemy 2.0, psycopg2), MongoDB (PyMongo)
**Serving:** FastAPI + Uvicorn
**Dashboard:** Streamlit + Plotly
**ML:** scikit-learn, pandas, joblib
**Scheduling:** two commands, `python -m src.cli ingest` and `retrain`, run as Kubernetes CronJobs in v2 (in progress); v1.0 used Apache Airflow
**Infra & CI/CD:** Docker, docker-compose, Terraform on AWS (in progress), GitHub Actions (CI: flake8 + pytest + image build; CD: tests, Trivy scan, push to Amazon ECR via OIDC, deploy to the dev namespace on EKS; manual deploy or rollback by SHA)
**Testing:** pytest

---

## Key engineering features

- **Idempotent ingestion** — the batch pipeline uses `ON CONFLICT (symbol, open_time) DO NOTHING`; the stream pipeline uses a unique index on `(symbol, kline_start_time)` + upsert. Re-runs and overlapping ranges never create duplicates.
- **Incremental / resumable loading** — before fetching, the collector reads `MAX(close_time)` from PostgreSQL and resumes 1 ms after the last stored candle, so the same script serves both the initial backfill and scheduled top-ups.
- **Pagination** — handles Binance's 1,000-candle-per-request limit by advancing `startTime` until a partial page signals the present has been reached.
- **Scheduled jobs** — two commands keep the system current: `python -m src.cli ingest` re-runs the idempotent collector, and `python -m src.cli retrain` catches the data up and retrains the model. On Kubernetes they will run as CronJobs, every 15 minutes and daily (v2, in progress); in docker compose, `historical` runs `ingest` on every `up` and `retrain` is run by hand. The API picks up a newer model by itself (S3 on AWS, a local file in docker compose), no restart needed. Each command's exit code tells the scheduler whether it failed.
- **Verified data quality** — **~240,000+** one-minute BTC/USDT candles loaded with **0 gaps** (and growing with every ingest run), confirmed by a verification notebook (`open_time[n+1] == close_time[n] + 1 ms`).
- **Predicted-vs-actual tracking** — every `/predict` call is persisted, so `/predictions` can join each forecast against the candle's real close for later evaluation.
- **CI on every push** — GitHub Actions runs flake8 (fails on syntax/undefined-name errors), the pytest suite, and a Docker image build.
- **CD on every push to `dev`** — the image is tested (ruff + pytest), scanned with Trivy (any CRITICAL vulnerability stops it) and pushed to Amazon ECR under the commit SHA, then deployed to the `dev` namespace on EKS (skipped while no cluster runs); started by hand, it deploys or rolls back to any image already in ECR without rebuilding. GitHub signs in to AWS with short-lived OIDC credentials, no stored keys.

---

## Repository structure

```
src/
├── cli.py          # scheduled jobs: python -m src.cli ingest | retrain
├── collection/     # fetch_historical.py (REST→PG), stream_live.py (WS→Mongo)
├── storage/        # postgres.py, mongo.py, schema.sql, init_db.py, *_writer.py
├── features/       # build_features.py
├── models/         # train_model.py, predict_model.py
├── api/            # main.py (FastAPI: /charts, /stream, /predict, /predictions, /health, /ready, /metrics), metrics.py
├── visualization/  # app.py (Streamlit dashboard: historical + live + predictions)
├── params/         # constants, enums
└── utils/          # time / url / dataframe helpers
k8s/                # Kubernetes manifests (Kustomize): base/ + overlays/local (kind), overlays/dev and overlays/prod (EKS)
infra/terraform/    # AWS infrastructure: bootstrap/ (created once, kept), platform/, envs/dev/ and envs/prod/ (destroyed after every session; prod leaves a final snapshot and is restored from it); modules/environment/ = the databases, secrets and roles of one environment, shared by envs/dev and envs/prod
tests/              # pytest suite
notebooks/          # exploration + verification (to re-run: pip install -r requirements-docker.txt ipykernel)
.github/workflows/  # CI (python-app.yml); CD (cd.yml): every push to dev → tests, image, Trivy scan, push to ECR, deploy to dev; every merge of dev into main → approval → the same image to prod (by digest); deploys skip while no cluster runs; by hand: deploy or roll back
docker-compose.yml  # full stack: postgres, mongo, init, historical, streamer, api, dashboard
```

---

## Getting started

**Prerequisites:** Docker and docker-compose.

### 1. Configure environment

Copy the template and set your own passwords (`.env.example` lists every variable):

```bash
cp .env.example .env
```

### 2. Launch the full stack

```bash
docker compose up --build
```

That single command brings up everything and wires the pipelines together automatically:

| Service | Role | URL |
|---|---|---|
| `postgres` / `mongodb` | Databases | — |
| `init` | One-shot: create the Postgres table + Mongo indexes, then exit | — |
| `historical` | One-shot: backfill / catch up historical candles (idempotent), then exit | — |
| `streamer` | Always-on: live Binance WebSocket → MongoDB | — |
| `api` | Always-on: FastAPI | http://localhost:8000/docs |
| `dashboard` | Always-on: Streamlit live chart + predictions | http://localhost:8501 |

Because `historical` runs idempotently in the background, the dashboard is usable while the database catches up. There is no scheduler in docker compose: train the model once (and whenever you want a fresh one) with `retrain` below. To run a step manually:

```bash
docker compose run --rm api python -m src.storage.init_db          # schema + indexes
docker compose run --rm api python -m src.cli ingest               # backfill / catch up
docker compose run --rm api python -m src.cli retrain              # catch up, then train the model
```

---

## Run on Kubernetes locally (kind)

The same image and manifests as on AWS, in a local test cluster: `k8s/overlays/local` adds in-cluster Postgres and MongoDB and keeps the model on a local disk instead of S3. Needs Docker, [kind](https://kind.sigs.k8s.io/) and kubectl.

```bash
kind create cluster --name cryptobot
docker build --target runtime -t cryptobot-app:local .
kind load docker-image cryptobot-app:local --name cryptobot

cp k8s/overlays/local/postgres.env.example k8s/overlays/local/postgres.env   # then set passwords
cp k8s/overlays/local/mongo.env.example    k8s/overlays/local/mongo.env
kubectl apply -k k8s/overlays/local

kubectl -n cryptobot get pods                                   # wait until Running / Completed
kubectl -n cryptobot create job --from=cronjob/ingest  ingest-now     # don't wait for the schedule
kubectl -n cryptobot create job --from=cronjob/retrain retrain-now
kubectl -n cryptobot port-forward svc/dashboard 8501:8501       # http://localhost:8501

kind delete cluster --name cryptobot                            # removes the cluster and its data
```

The `ingest` (every 15 min) and `retrain` (daily) CronJobs also run on their own. After a code change: build and `kind load` again, then `kubectl -n cryptobot rollout restart deployment`.

- **Set the passwords before the first apply.** Postgres and MongoDB take them only when their data disk is empty; to change them later, `kind delete cluster --name cryptobot` and start again.
- **Applying again within 10 minutes** (while the finished `init-db` Job still exists) fails with `field is immutable` if anything it uses changed. Delete it first: `kubectl -n cryptobot delete job init-db --ignore-not-found`.

---

## Deploy to dev on EKS

The same manifests in the `dev` namespace of the EKS cluster: `k8s/overlays/dev` adds the database connection details from AWS Secrets Manager (External Secrets), TLS to RDS and DocumentDB, the model in S3, and the dashboard behind an ALB. Needs the Terraform layers `platform` and then `envs/dev` applied (see their READMEs; pods get their AWS rights only if `envs/dev` exists when they start), the app image in ECR (the CD workflow pushes it after a successful run on `dev`, tagged with the full commit SHA), and kubectl within one minor version of the cluster (1.36–1.38).

### With CD (the normal way)

Every push to `dev` runs `.github/workflows/cd.yml`: after the image job (tests, build, Trivy scan, push to ECR) the deploy job signs in as `cryptobot-github-deploy-dev` (may change only the `dev` namespace) and deploys that commit, then waits until `init-db` has finished and the API, streamer and dashboard run. **Without a running cluster** (between work sessions) it skips with a notice and stays green; a cluster without `envs/dev` (no SecretStore) makes it fail.

Started by hand, the workflow only deploys: no build, no new scan. The image must already be in ECR, i.e. that commit's CD run passed (ECR keeps the newest 30 images). Start it only when no CD run is waiting: GitHub keeps one waiting run per branch and cancels an older one.

```bash
gh run list --workflow cd.yml --limit 3                    # nothing "queued" or "in_progress"?
gh workflow run cd.yml --ref dev                           # deploys the newest commit on dev, e.g. after a session's applies
gh run list --workflow cd.yml --limit 1                    # its run ID; follow it with: gh run watch <run ID>

# Rollback: the newest images in ECR (tag = full commit SHA), then deploy one of them
aws ecr describe-images --region eu-central-1 --repository-name cryptobot --query "reverse(sort_by(imageDetails[?imageTags],&imagePushedAt))[:5].[imagePushedAt,join(',',imageTags)]" --output text
gh workflow run cd.yml --ref dev -f image_sha=<full SHA from that list>
```

The "Run workflow" button in GitHub's Actions tab appears only once `cd.yml` is on the default branch (`main`); until then, use `gh workflow run`.

A **rollback** deploys the old commit as a whole: its manifests together with its image, the pair that was tested together. Objects that only newer commits have (e.g. a new CronJob) stay, because `kubectl apply` deletes nothing. It does not run the tests or Trivy again, so a vulnerability published since then cannot block it.

After the first deploy of a session (dev starts empty), from your laptop:

```bash
aws eks update-kubeconfig --name cryptobot --region eu-central-1   # = terraform output -raw kubeconfig_command
kubectl -n dev create job --from=cronjob/retrain retrain-now       # loads the last day, trains, uploads the model
kubectl -n dev get ingress dashboard -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'   # open http://<that name> (DNS: 1-3 min)
```

### By hand (fallback)

```bash
aws eks update-kubeconfig --name cryptobot --region eu-central-1   # = terraform output -raw kubeconfig_command

# The image address contains the AWS account ID, so it goes into a file Git ignores (k8s/deploy/):
REGISTRY=$(aws ecr describe-repositories --region eu-central-1 --repository-names cryptobot \
  --query "repositories[0].repositoryUri" --output text)
TAG=$(git rev-parse origin/dev)          # the newest pushed commit; its CD run must be green:
aws ecr describe-images --region eu-central-1 --repository-name cryptobot \
  --image-ids imageTag="$TAG" --query "imageDetails[0].imagePushedAt"   # an error = no image yet
mkdir -p k8s/deploy/dev
cat > k8s/deploy/dev/kustomization.yaml <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ../../overlays/dev
images:
  - name: cryptobot-app
    newName: ${REGISTRY}
    newTag: ${TAG}
EOF

kubectl -n dev delete job init-db --ignore-not-found          # a finished Job can only be replaced
kubectl apply -k k8s/deploy/dev
kubectl -n dev get externalsecrets                            # STATUS SecretSynced, READY True
kubectl -n dev get pods                                       # wait until Running / Completed
kubectl -n dev create job --from=cronjob/retrain retrain-now  # loads the last day, trains, uploads the model
kubectl -n dev get ingress dashboard \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'    # open http://<that name> (DNS: 1-3 min)
```

Until the first `retrain` has uploaded a model, `POST /predict` answers 503 and the API logs `AccessDenied` for `dev/model.pkl` (S3 says so for a missing file when the role may not list the bucket).

**Before destroying the infrastructure, remove the app.** Its Ingress owns an ALB that Terraform did not create; it keeps costing money and blocks deleting the VPC. First make sure no CD run can deploy it again: no push to `dev` from now until `envs/dev` is destroyed, and no CD run waiting or running.

```bash
gh run list --workflow cd.yml --limit 3                       # nothing "queued" or "in_progress"
kubectl delete -k k8s/overlays/dev --ignore-not-found         # the Load Balancer Controller deletes the ALB
aws elbv2 describe-load-balancers --region eu-central-1 \
  --query "LoadBalancers[].LoadBalancerName"                  # repeat until []
```

Then destroy `envs/dev`, then `platform` (their READMEs).

---

## API endpoints

| Endpoint | Type | Source | Purpose |
|---|---|---|---|
| `/health` | GET | — | Liveness: the API process is up (no database calls) |
| `/ready` | GET | PostgreSQL + MongoDB | Readiness: 200 if both databases answer, else 503 |
| `/charts` | GET | PostgreSQL | Historical OHLCV for charting |
| `/predict` | POST | MongoDB + model | Forecasts the next candle's close and stores it; the streamer calls it after each closed candle |
| `/predictions` | GET | MongoDB | Stored forecasts joined with actual closes (predicted-vs-actual) |
| `/stream` | WebSocket | Binance (live) | Real-time tick feed relayed to the browser |
| `/metrics` | GET | — | Prometheus metrics: requests and durations per route and status, plus Python/process stats (for monitoring, not listed in `/docs`) |

Interactive docs: http://localhost:8000/docs

---

## Testing

Lint and tests run in the Dockerfile's `test` stage (the production packages plus ruff and pytest), so the result is the same on every machine:

```bash
docker build --target test -t cryptobot-test .
docker run --rm cryptobot-test        # ruff check . + pytest
```

Without Docker (Python 3.11): `pip install -r requirements-docker.txt -r requirements-dev.txt`, then `ruff check .` and `pytest`.

CI runs the same pytest suite plus flake8 linting (ruff replaces it in CI later) and a Docker image build on every push (see `.github/workflows/python-app.yml`).
