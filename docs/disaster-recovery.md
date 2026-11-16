# Disaster recovery

How CryptoBot keeps its data, what happens when a part fails, and how to bring everything back.
The design rule behind all of it: **pods hold no state.** Data lives only in the two managed
databases and in S3; everything else (cluster, pods, monitoring, secrets) can be rebuilt from Git
and Terraform at any time. The AWS environments are in fact destroyed and rebuilt at the end and
start of every work session, so the recovery path below is used routinely, not only in an
emergency.

| What can fail | Recovery | Time | Details |
|---|---|---|---|
| A container crashes or hangs | Kubernetes restarts it (restart policy; liveness probes catch a hung API or dashboard; a hung scheduled job is stopped after 30 min) | seconds | [1](#1-a-container-or-a-node-fails) |
| A node dies | Pods move to the other nodes; EKS starts a replacement node | ~30 s (pods), ~1.5 min (new node) | [1](#1-a-container-or-a-node-fails) |
| A scheduled job fails | Retries, then the next scheduled run; Grafana alert | `ingest` ≤ 15 min, `retrain` next day | [1](#1-a-container-or-a-node-fails) |
| Prod database lost or damaged | Restore from a snapshot with Terraform | ~20 min | [2](#2-backups-and-restore) |
| Cluster or whole platform lost | Rebuild from Terraform, redeploy with CD | ~1 h | [3](#3-redeploy-the-infrastructure-from-iac) |
| A bad release | Redeploy the previous image with CD | ~1 min | [4](#4-roll-back-to-a-previous-version) |

---

## 1. A container or a node fails

| Failure | What recovers it | Configured in |
|---|---|---|
| API process stops answering | liveness probe `/health` (every 20 s) fails 3 times in a row → the kubelet restarts the container | `k8s/base/api.yaml` |
| API can't reach a database | readiness probe `/ready` fails → the pod gets no traffic until both databases answer again; it is not restarted (a restart would not fix the database) | `k8s/base/api.yaml` |
| Dashboard hangs | liveness probe on Streamlit's `/_stcore/health` → restart | `k8s/base/dashboard.yaml` |
| Any pod deleted or evicted | its Deployment (ReplicaSet) creates a new one at once | `k8s/base/*.yaml` |
| One prod API pod down | the second pod keeps serving: prod runs 2 API pods, spread over the nodes, and a PodDisruptionBudget keeps at least one during node maintenance | `k8s/overlays/prod/` |
| Streamer down | Recreated by its Deployment; on start it reconnects to Binance. Candles closed while it was down are missing in DocumentDB (the forecast history has a gap), but PostgreSQL gets them from the next `ingest` run | `k8s/base/streamer.yaml` |
| Streamer connection stalls | keepalive pings (every 20 s, 10 s timeout) find a dead Binance connection, and it reconnects after 5 s. It has no liveness probe (it serves no HTTP): a process stuck in another way is not restarted and raises no alert; it shows as forecasts stopping on the API dashboard (`POST /predict` panels) | `src/collection/stream_live.py` |
| A database starts slowly or restarts | at start, `init-db`, the `ingest` and `retrain` jobs and the streamer wait for their databases (bounded retries, about 3 min) before failing, and Kubernetes then restarts or retries them. The API does not wait: it keeps running and only reports not ready (row above). A running streamer tries a candle write 3 times, otherwise it skips that candle (the next `ingest` still fills PostgreSQL) | `src/utils/retry.py`, `src/storage/`, `src/collection/stream_live.py` |
| `ingest` or `retrain` fails | `ingest` is retried once (`backoffLimit: 1`) and runs again within 15 min; `retrain` is retried twice (`backoffLimit: 2`), then runs again the next day at 03:00 UTC; the Grafana alert *Scheduled job failed* fires until a run succeeds; `ingest` fills any gap by itself (it continues from the newest stored candle) | `k8s/base/cronjobs.yaml`, `monitoring/alerts/` |
| A node fails | EKS removes the node object, the scheduler starts its pods on the remaining nodes, and the managed node group (an Auto Scaling group with min = max = 3) launches a replacement. Three nodes leave room for the pods of one lost node (README of the platform layer: pod budget) | `infra/terraform/platform/eks.tf` |
| One availability zone fails | Partly covered, on purpose. The nodes run in two zones, so the scheduler moves pods to the other zone, and the node group starts replacement nodes there (with 3 nodes over 2 zones, losing the zone with 2 nodes leaves 17 pod slots until they arrive). But there is only **one NAT gateway** (half the cost of one per zone): if its zone (always `eu-central-1a`, the first public subnet) fails, the pods lose their way to the internet (Binance, ECR, Secrets Manager) until that zone is back; applying the platform again would place the NAT gateway in the same zone, so moving it means changing `vpc.tf`. The databases run one instance each (Multi-AZ doubles their price). DocumentDB keeps its data in three zones whatever the instance count, so a new instance in the other private subnet is enough. PostgreSQL needs a point-in-time restore from its automated backups into the other zone (manual, section 2 "Restore an older state"); that creates a new endpoint, so the endpoint secret in Secrets Manager must be updated. Otherwise, wait until the zone is back | `infra/terraform/platform/vpc.tf`, `modules/environment` |

**Tested on EKS, 15 Nov 2026** (a recorder checked every ~14 s: nodes, prod API endpoints, the
prod streamer, dev's API and the prod dashboard's HTTP answer through its ALB):

| Time (UTC) | Event |
|---|---|
| 16:29:10 | The EC2 instance of the node running prod's streamer, one of prod's two API pods and dev's only API pod is terminated |
| 16:29:10 | Prod still serves from its second API pod; the prod dashboard answers HTTP 200 |
| 16:29:24 | Dev's API is back (new pod on another node, 14 s) |
| 16:29:38 | Prod has two API pods again and the streamer runs on another node (28 s) |
| 16:29:53 | The node group launches the replacement instance by itself |
| 16:30:34 | The new node is Ready: three nodes again (84 s) |
| 16:32:19 | One prod API pod deleted by hand: its replacement starts at once and is Ready ~20 s later; prod never has 0 API pods |

The prod dashboard answered HTTP 200 on every check, and DocumentDB has every 1-minute candle of
that period (the old streamer had saved the 16:28 candle; the new one ran before the 16:29 candle
closed). A failed `ingest` run in `dev` (an invalid setting) made the alert fire at 16:07:30; it
cleared at 16:11:30, about a minute after a successful run.

---

## 2. Backups and restore

### What is backed up

| Data | Backup | Kept | Where configured |
|---|---|---|---|
| PostgreSQL (RDS) | automated daily backups with point-in-time restore | dev 1 day, prod 7 days, **while the database exists** | `infra/terraform/envs/*/main.tf` → `modules/environment` |
| DocumentDB | automated daily backups with point-in-time restore | dev 1 day, prod 7 days, **while the database exists** | as above |
| Prod databases at teardown | **final snapshot** of each database (`cryptobot-prod-<db>-final-<date>-<time>`) | until deleted by hand | `modules/environment/snapshots.tf` |
| Model file | S3 bucket with **versioning**; every retrain adds a version, older versions kept 90 days | outside the create/destroy cycle (bootstrap layer) | `infra/terraform/bootstrap/s3_buckets.tf` |
| Terraform state | S3 bucket with versioning, older versions kept 90 days | bootstrap layer | same file |
| Application images | ECR, immutable tags = commit SHA; the newest 30 images and the newest 10 prod tags | bootstrap layer | `infra/terraform/bootstrap/ecr.tf` |
| Container logs | CloudWatch Logs | 7 days | `infra/terraform/bootstrap/cloudwatch_logs.tf` |
| Code, manifests, dashboards, alert rule | Git (GitHub) | – | this repository |

The automated backups are deleted together with the database at every teardown, so they only
cover the running session. **Between sessions, the final snapshots are what carries prod's data.**

Not backed up, on purpose: Prometheus metrics (2 days on the pod's own disk; losing them loses only
recent graphs), Grafana's own database (dashboards and the alert rule are loaded from `monitoring/`
at every start), the database passwords (Terraform generates new ones and Secrets Manager holds
them), and the dev databases (dev starts empty and reloads the last day from Binance). The
databases are encrypted at rest with AWS-managed keys, both S3 buckets with S3-managed keys.

### Restore prod from its final snapshots (the normal session start)

`terraform apply` in `infra/terraform/envs/prod` finds the newest manual final snapshot of each
database and creates the databases from it; a second plan and apply then sends the restored
DocumentDB its new password. The steps are in `infra/terraform/envs/prod/README.md`
("One work session"). Rules that protect the data:

- Never apply a plan that **replaces** a prod database (`-/+`): the new database would start empty.
- Destroying prod needs two steps (deletion protection off and final-snapshot names set, then
  destroy), so a single command can never delete prod without a snapshot.
- Never delete the newest final snapshot of a database: the next create restores it.

### Restore an older state

To go back to an earlier snapshot (for example before a bad data change): destroy prod as usual
(this adds a new final snapshot, so nothing is lost), then create it with the older snapshots named
in `restore_snapshots` (`infra/terraform/envs/prod/README.md`, "Restore an older snapshot"),
followed by the same second plan and apply as after every restore (it sends the restored
DocumentDB its new password). During a session, a point-in-time restore from the automated
backups is also possible (AWS console or CLI, into a new database); it is not automated here
because the backups end with the session.

**Tested:** 13 Nov 2026 (rehearsal): prod destroyed with final snapshots and restored from them;
PostgreSQL 62,387 candles before, 62,475 after (the next `ingest` filled the gap, 0 missing
minutes), DocumentDB 9 → 11 candles, 5 → 6 forecasts, the API loaded the same S3 model version.
That run found that a restored DocumentDB kept the snapshot's old password; the fix (a second
apply after every restore) is in the module since then.

**Tested again on 15 Nov 2026, with the fix:** prod was created from the 13 Nov final snapshots
(`…-2026-11-13-0924`) in a newly built VPC (RDS events: "Restored from snapshot" 15:34 UTC, "Reset
master credentials" 15:39). The second plan showed exactly one change (the DocumentDB password
version, 2 → 3); after its apply, the deploy's `init-db` connected to DocumentDB at once.
PostgreSQL held 62,475 candles, exactly as at the snapshot; the next `ingest` run fetched the 3,285
minutes since then (65,760 candles from 1 Oct, **0 missing minutes**). DocumentDB grew from 11 to 17
candles and from 6 to 11 forecasts; the API loaded the S3 model version trained on 13 Nov. The
teardown left the new final snapshots `…-2026-11-15-1654`.

---

## 3. Redeploy the infrastructure from IaC

Everything except the bootstrap layer is destroyed after every work session and rebuilt at the
next one, in this order:

| Step | Command (details in each folder's README) | Time |
|---|---|---|
| 0. Bootstrap (once per account; kept) | `infra/terraform/bootstrap`: the first time in an account, the README's "First run" (local state, `terraform plan -out=tfplan`, `terraform apply tfplan`, then `terraform init -migrate-state` into S3); later changes: `terraform plan -out=tfplan`, `terraform apply tfplan` | – |
| 1. Platform | `infra/terraform/platform`: `terraform plan -out=tfplan`, `terraform apply tfplan` | ~20 min |
| 2. Environments (in parallel) | `infra/terraform/envs/dev` and `envs/prod`: plan + apply; prod: plan + apply once more after the restore | ~20 min |
| 3. Deploy dev | `gh workflow run cd.yml --ref dev` | ~2 min |
| 4. Deploy prod | `gh workflow run cd.yml --ref main` (or a merge to `main`), then approve | ~2 min |
| 5. Dev data | one `retrain` run by hand (README, "Deploy to dev on EKS"): loads the last day, trains | ~1 min |

Every plan is reviewed before it is applied. The teardown runs the same layers backwards:
remove the apps (their Ingresses own the load balancers), destroy `envs/dev` and `envs/prod`
(prod in two steps, leaving its final snapshots), then the platform; see the READMEs in
`infra/terraform/` and "Teardown: what Terraform did not create" in the platform README.

**Tested:** every work session since 11 Nov 2026. Measured on 15 Nov 2026 (3 nodes, dev and prod,
monitoring):

| Step | Time |
|---|---|
| Platform apply (77 resources, incl. the monitoring stack) | ~20 min |
| `envs/dev` and `envs/prod` applies in parallel (prod restored from snapshots), second prod apply | ~20 min |
| Deploy dev (CD, manual start) / prod (merge + approval) | 46 s / 52 s |
| **From the first apply to both environments running** | **~55 min** |
| Teardown: apps (ALBs), then `envs/dev` and `envs/prod` in parallel (prod in two steps, final snapshots), then the platform | ~40 min |

Afterwards, a check of every billable resource type found nothing left but the bootstrap layer and
the final snapshots. A session like this costs about $0.60 per hour.

---

## 4. Roll back to a previous version

**Application (the usual case).** Every image in ECR is tagged with its commit SHA, and a manual
CD run deploys any of them again together with that commit's manifests (the pair that was tested
together), without rebuilding or rescanning: `gh workflow run cd.yml --ref dev -f image_sha=<commit>`
for dev, and `--ref main` with an older merge on `main` for prod, which again waits for approval.
How to list the candidates and the exact commands: README, "Deploy to dev on EKS" and "Deploy to
prod on EKS" (sections "With CD").

Going forward again is the same command without `image_sha` (the newest commit). A rollback does
not delete objects that only newer commits added (`kubectl apply` deletes nothing).

**Infrastructure.** Terraform code is versioned like the app: revert the commit, then plan
(review it) and apply. Data rollback: section 2.

**Tested:** 12 Nov 2026 in dev (rolled back to an older image and forward again); 15 Nov 2026 in
prod: rolled back to the previous release (merge `bbfa1e1`, image built from `e2452bd`) after
approval, deploy 65 s; forward again to the newest release (`96d2abf`), deploy 53 s. Each time all
three Deployments ran the expected image digest.
