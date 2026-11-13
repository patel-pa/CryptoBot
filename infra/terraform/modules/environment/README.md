# Terraform module: environment

One environment's databases, their passwords, how its Kubernetes namespace may read them, and
its pods' AWS rights. The layers `envs/dev` and `envs/prod` both call this module, each with its
own values: **one code, two environments**, so dev tests exactly what prod runs, and a fix (for
example to a trust policy) is made once for both.

The module has no backend and no provider settings of its own: the calling layer keeps the state,
configures the AWS and Kubernetes providers and reads the platform and bootstrap layers' outputs.

## Inputs

| Input | What it decides | dev | prod |
|---|---|---|---|
| `env` | namespace, secret path `cryptobot/<env>/`, model prefix `<env>/`, names `cryptobot-<env>-…`; only `dev` or `prod` | `dev` | `prod` |
| `region` | where the databases and secrets live | `eu-central-1` | `eu-central-1` |
| `platform` | the platform layer's network, cluster and External Secrets controller role (`applied = false` while it is destroyed) | from its state | from its state |
| `model_bucket` | the bootstrap layer's model bucket | from its state | from its state |
| `postgres` | instance size, days of automatic backups | `db.t4g.micro`, 1 | `db.t4g.small`, 7 |
| `mongo` | DocumentDB instance size, days of automatic backups | `db.t4g.medium`, 1 | `db.t4g.medium`, 7 |
| `deletion_protection` | AWS refuses to delete either database while true | `false` | `true` (teardown step 1: `false`) |
| `keep_data` | final snapshot on destroy, restore on create (below) | `false` | `true` |
| `first_create` | the very first create starts empty (no snapshot exists yet) | – | `false` (`true` once) |
| `restore_snapshots` | restore these snapshots instead of the newest | – | `{}` |
| `password_version` | raise by one for new passwords (below); DocumentDB's own version number is derived from it (`2 × password_version + 1`, or `2 × password_version` in a run that restores it) | `1` | `1` |

Everything else is fixed here for every environment: PostgreSQL 18, DocumentDB 8.0.2 (the same
majors as docker compose and the kind overlay: `postgres:18`, `mongo:8.0`; change them together),
20 GB gp3, the ports, the database and user names, one zone, encryption, the firewall rules and
every IAM policy.

## What it creates

| Resource | Details | Why |
|---|---|---|
| RDS PostgreSQL `cryptobot-<env>-postgres` | PostgreSQL 18, 20 GB gp3, one zone, encrypted | The batch pipeline's database |
| DocumentDB `cryptobot-<env>-mongo` | 8.0, one instance, encrypted | The stream's database (MongoDB-compatible) |
| 2 subnet groups | the platform's two private subnets | Databases are never reachable from the internet |
| 2 security groups | inbound only from the EKS nodes' security group, on 5432 / 27017; no outbound rules | Only pods in the cluster can connect |
| 4 Secrets Manager secrets | `cryptobot/<env>/postgres`, `…/postgres-endpoint`, `…/mongo`, `…/mongo-endpoint` | The app's connection settings, read by External Secrets |
| IAM role `cryptobot-<env>-external-secrets` | trusted by the External Secrets controller only for a SecretStore in `<env>`; may only read `cryptobot/<env>/*` | One environment can never read the other's secrets |
| SecretStore `aws-secrets-manager` | in the `<env>` namespace, uses that role, `sessionTagsPolicy: Simple` | What the overlay's ExternalSecrets refer to |
| IAM roles `cryptobot-<env>-api`, `cryptobot-<env>-retrain` + Pod Identity associations | `api` may read, `retrain` may write `<env>/*` in the model bucket | The model moves through S3, never between environments |

## What happens to the data (`snapshots.tf`)

**`keep_data = false` (dev):** nothing is kept. Destroy deletes the databases together with their
automatic backups, and every create starts empty.

**`keep_data = true` (prod):**

- **Destroy saves a final snapshot** of each database before deleting it. AWS needs a new name for
  every snapshot, so the name is set by **teardown step 1**: an apply with
  `deletion_protection = false` turns the protection off and names the snapshots after the time of
  that plan, for example `cryptobot-prod-postgres-final-2026-11-20-1730` and
  `cryptobot-prod-mongo-final-2026-11-20-1730`. Step 2 is the destroy. Without step 1 the destroy
  stops before deleting a database: AWS refuses while the protection is on, and Terraform has no
  snapshot name (`final_snapshot_identifier is required`). Nothing is lost then; run step 1 and
  destroy again.
- **Creating a database restores the newest final snapshot.** Terraform first asks AWS whether the
  database exists (`aws_db_instances`, `aws_rds_clusters`: an empty list, never an error). Only if
  it does not, which means this run creates it, does it look up the newest **manual** snapshot of
  that database (`aws_db_snapshot`, `aws_db_cluster_snapshot`, `most_recent`). Final snapshots are
  manual ones; the daily automatic backups are not, and AWS deletes those together with the
  database here (`delete_automated_backups`). So a running environment never needs a snapshot,
  and teardown and destroy also work in the very first session, when none exists yet.
- **No snapshot at all** (the very first create) stops the plan with
  `Your query returned no results`. That is on purpose: an empty prod database must never be
  created by accident. `first_create = true` creates empty databases instead.
- **`restore_snapshots`** names a snapshot per database (keys `postgres`, `mongo`) to restore
  instead of the newest one: an older one after a bad change, or the fallback if a lookup ever
  finds nothing. DocumentDB runs on the RDS API, so the RDS lookups see its clusters and snapshots
  too.
- **A running database is never replaced because of a snapshot.** "Created from" can only be set
  when a database is created; if it changed later (for example a newer snapshot appeared during a
  restore test), Terraform would delete and re-create the database. `ignore_changes =
  [snapshot_identifier]` makes Terraform read it only at creation (tested: a mock create from one
  snapshot, then a plan naming a newer one, keeps the first).
- **The password after a restore: plan and apply once more, then deploy.** The snapshot still
  holds the password of the session it was taken in. Terraform writes a new one into the
  credentials secret, restores the database and then sets that password with a second AWS call
  (the provider does this for `password_wo` and `master_password_wo` after every restore; checked
  in its source, `internal/service/rds/instance.go` and `internal/service/docdb/cluster.go`).
  - **PostgreSQL** takes it at once: a restored RDS instance is the database server itself.
  - **DocumentDB does not.** A DocumentDB cluster is the storage (the data and the database
    users); the servers are its instances, and a restore creates the cluster without one. The
    provider's password call comes in that gap, before Terraform creates the instance (which
    depends on the cluster): AWS accepts it without an error but does not apply it, so the cluster
    keeps the snapshot's old password (found in the prod rehearsal on 13 Nov 2026, in CloudTrail;
    the same call sent while the instance ran worked at once).
  - So DocumentDB's password version is `2 × password_version` in the run that restores it and
    `2 × password_version + 1` in every other run (`databases.tf`). The **next plan after a
    restore** therefore shows exactly one change (`1 to change`) on `aws_docdb_cluster.mongo`:
    `master_password_wo_version` from `2 × password_version` to `2 × password_version + 1`
    (`2 -> 3` while `password_version` is 1). Its apply sends the same password again, from the
    unchanged secret, now that the instance runs. Until then the app's DocumentDB sign-in fails
    (`Authentication failed`). Creates without a restore (dev, and prod's very first create)
    set the password in the create call itself and start at `+ 1`, so their next plan shows no
    change.
  - One exception: if the restore apply failed before the instance existed, the next apply
    sends the password again *before* it creates the instance (the instance depends on the
    cluster), and AWS drops it the same way; afterwards the plan shows no change. Then raise
    `password_version` once the instance runs (below, "New passwords").

The output `snapshots` shows both in every plan: `restore_from` (the snapshot each database is
created from in this run; `null` = starts empty, or already exists) and `final_on_destroy` (the
name its final snapshot will get; `null` = no teardown step 1 yet). The plan after a restore
therefore also shows `restore_from` changing from the snapshot names to `null`: an output-only
change (the databases exist now), saved by that plan's apply.

Both databases: no Performance Insights, no enhanced monitoring, no log exports. PostgreSQL gets
minor version updates automatically; DocumentDB never applies minor updates on its own (8.0.2
stays 8.0.2). TLS is enforced by AWS's default parameter groups (`rds.force_ssl = 1` for
PostgreSQL 18, `tls = tls1.2+` for DocumentDB 8.0).

## Passwords: never in the Terraform state

Per database there are two secrets:

1. **Credentials** (`cryptobot/<env>/postgres`: `username`, `password`), written first. AWS
   generates the password at apply time (`ephemeral "aws_secretsmanager_random_password"`,
   letters and digits only) and Terraform writes it with a write-only argument
   (`secret_string_wo`): it appears in neither the state nor the plan.
2. **Endpoint** (`cryptobot/<env>/postgres-endpoint`: `host`, `port`, `dbname`), written after the
   database exists. Not secret, but this way no account-specific host name lives in the public
   repository.

The databases read their passwords back from exactly the secret versions just written
(`password_wo`, `master_password_wo`), so both get the same password, even when a first apply
fails half-way. External Secrets merges both secrets of a database into one Kubernetes Secret.

**New passwords:** raise `password_version` in the layer's `main.tf` (`envs/<env>/main.tf`) and
apply. The secrets get new values first, then the databases read them back (the plan shows
DocumentDB's derived number, for example `3 -> 5` for `password_version` 1 → 2). Running pods
keep the old password until they restart, and External Secrets copies the new one into
Kubernetes only at its next hourly refresh: force that first, then restart the pods (commands in
`k8s/overlays/<env>/external-secrets.yaml`). If AWS rejects the database change (for example
because the instance is busy), the secret already holds the new password while the database keeps
the old one, and Terraform cannot see the difference (AWS never reports a password): raise
`password_version` once more.

Anyone who runs `plan` on a layer that uses this module reads that environment's passwords (the
read-back runs at every plan), so a future CI plan role needs `secretsmanager:GetSecretValue` on
`cryptobot/<env>/*` and gets the passwords with it.

The secrets are deleted at once on destroy (`recovery_window_in_days = 0`), so the next session
can create the same names again.

## How a namespace reads its secrets (and never the other environment's)

External Secrets has one AWS identity for the whole cluster (the platform's
`cryptobot-external-secrets`, through Pod Identity). That identity may only assume roles named
`cryptobot-*-external-secrets`, and which one a namespace uses is set in its SecretStore. Two
locks:

1. **Kubernetes:** only this module creates the SecretStore of `<env>`. Deploy jobs may create
   `ExternalSecret`s there ("I need this secret"), never `SecretStore`s ("read with this role")
   (platform layer RBAC). The store says `sessionTagsPolicy: Simple`, so External Secrets tags
   every sign-in with the store's namespace and kind (`esoNamespace`, `esoStoreKind`, also
   `esoStoreName`) and ignores hand-written tags.
2. **AWS:** the role trusts the controller only when the request carries `esoNamespace = <env>`
   and `esoStoreKind = SecretStore`, on `sts:AssumeRole` itself (a sign-in without tags is
   refused too). Its only permission is `secretsmanager:GetSecretValue` on `cryptobot/<env>/*`.

The trust policy names the controller's role by ARN; AWS resolves that to the role's internal
ID when the policy is saved. A re-created controller role (new platform) is a different role,
so the envs layers must be re-created after the platform, which the session order does anyway.

## AWS rights of the pods (EKS Pod Identity)

One IAM role per Kubernetes service account (`k8s/base/serviceaccounts.yaml`); the service
account `cryptobot` (all other pods) gets no AWS rights.

| Service account | Role | May do | Because the app calls |
|---|---|---|---|
| `api` | `cryptobot-<env>-api` | `s3:GetObject` on `<model bucket>/<env>/*` | `head_object`, `get_object` |
| `retrain` | `cryptobot-<env>-retrain` | `s3:PutObject` on `<model bucket>/<env>/*` | `put_object` |

Each role trusts only EKS Pod Identity, and only when its session tags (set by Pod Identity
itself) say cluster `cryptobot`, namespace `<env>` and the role's own service account. So even an
association to the wrong service account would get no credentials. The model bucket comes from
the bootstrap layer (one prefix per environment): dev can never read or overwrite prod's model.
The overlay sets `MODEL_S3_BUCKET` and `MODEL_S3_KEY=<env>/model.pkl` (output `model_s3`).

Without `s3:ListBucket`, S3 answers 403 instead of 404 while no model exists yet: until the
first retrain has run, the API logs
`no model at s3://…/<env>/model.pkl: AccessDenied('… when calling the GetObject operation: Access Denied')`.
That is expected, not a permission problem.

Pods get their credentials when they are created (EKS adds them to the pod at that moment).
So apply the layer **before** deploying the app; a pod that started earlier gets no AWS
credentials until it restarts (`kubectl -n <env> rollout restart deployment/api`). CronJob runs
are not affected: every run creates new pods.

## Checks (offline, no AWS account needed)

```bash
cd infra/terraform/modules/environment
terraform fmt -check -recursive
terraform init -backend=false
terraform validate
terraform test          # tests/*.tftest.hcl, against a mock provider; Terraform 1.17+
```

The tests run with dev's values, plus runs with `env = "prod"`: with other sizes, backup days,
protection and password version, every name, path and trust condition must follow the
environment and every setting its own input; and the data lifecycle (restore from the newest
manual snapshot only on create, never while running, empty on the first create, a named snapshot
wins, teardown step 1 names the snapshots, a newer snapshot never replaces a running database)
and the password after a restore (DocumentDB's version `2 × password_version` in the restoring
run, `+ 1` in the next, which changes nothing else; constant in dev; raising `password_version`
still changes both databases' passwords).
Each layer's own tests check that it passes its values in.

## Deliberately not enabled

- **Multi-AZ, read replicas, more DocumentDB instances:** a standby doubles the cost.
- **A separate, less privileged database user for the app:** the app uses the master user.
- **An own KMS key:** the AWS-managed keys encrypt storage and secrets for free; an own key costs
  $1 per month and outlives every teardown.
- **Automatic password rotation:** a rotation would break running pods until they restart.
- **Performance Insights, enhanced monitoring, log exports:** cost, and log groups that never
  expire.
- **IAM database authentication:** the app signs in with the password from Secrets Manager; IAM
  tokens would need app changes and expire every 15 minutes.

- **Keeping the automatic backups after a destroy** (`delete_automated_backups = false`): the
  final snapshot is what is kept; retained backups would cost money for 7 more days and are not
  needed to restore.
- **A recovery window for the secrets:** the next session creates the same names again, and a
  deleted secret holds nothing worth keeping (the data is in the snapshots, and the password is
  new at every create).

Scanners (Trivy, Checkov) report exactly these choices: no customer-managed KMS key, no
rotation, no Multi-AZ, no logs or monitoring, no IAM authentication (and, with dev's values,
no deletion protection and short backups). Trivy finds nothing HIGH or CRITICAL.
