# Terraform environment layer: prod

The prod databases, their passwords, how the `prod` namespace may read them, and the prod pods'
AWS rights: the shared module [`modules/environment`](../../modules/environment/README.md) with
prod's values (`main.tf`), the same code as dev. Created after the platform layer and
**destroyed before it**, like dev, but prod **keeps its data**: destroy saves a final snapshot of
each database, and the next create restores the newest one. The state lives in the bootstrap
layer's bucket under `envs/prod/`.

## Prod's values (next to dev's)

| Setting | dev | prod |
|---|---|---|
| PostgreSQL | `cryptobot-dev-postgres`, `db.t4g.micro` (1 GB RAM) | `cryptobot-prod-postgres`, `db.t4g.small` (2 GB RAM) |
| DocumentDB | `cryptobot-dev-mongo`, one `db.t4g.medium` | `cryptobot-prod-mongo`, one `db.t4g.medium` (the smallest DocumentDB offers) |
| Automatic backups | 1 day | 7 days |
| Deletion protection | off | **on**; teardown in two steps |
| On destroy | everything is gone | **final snapshot** of each database |
| On create | empty | **restored from the newest final snapshot**; only the very first create starts empty |
| Secrets | `cryptobot/dev/*` | `cryptobot/prod/*` (new passwords at every create; after a restore, DocumentDB takes its new one only in the second apply, below) |
| External Secrets role | `cryptobot-dev-external-secrets` | `cryptobot-prod-external-secrets` (reads only `cryptobot/prod/*`) |
| Pod roles | `dev/*` in the model bucket | `cryptobot-prod-api` (reads), `cryptobot-prod-retrain` (writes) `prod/*` |

How the snapshots, the restore and the password after a restore work: module README, "What
happens to the data". Passwords, the two locks between the environments and the pods' AWS
rights: the other sections of the module README.

## The three switches (command line only)

| Switch | Default | When |
|---|---|---|
| `-var first_create=true` | `false` | **once**: the very first create, when no final snapshot exists yet; the databases start empty |
| `-var deletion_protection=false` | `true` | **teardown step 1**: protection off, and the final snapshots get their names |
| `restore_snapshots` | `{}` | to restore an older snapshot instead of the newest (below) |

They live on the command line, never in a file: a plain `terraform plan` is always the normal,
safe case. Every plan prints the output `snapshots`: `restore_from` (what each database is created
from in this run) and `final_on_destroy` (the name its final snapshot will get). **Read it in
every plan.**

## Prerequisites

As for dev (its README): bootstrap and platform applied, Terraform 1.17 or newer, `AWS_PROFILE`
with administrator rights. And once, before the first apply: `terraform init` in this folder.

## One work session

```bash
# after the platform layer:
cd infra/terraform/envs/prod
terraform init

# create: restores the newest final snapshots (check snapshots.restore_from in the plan)
terraform plan -out=tfplan                     # have it reviewed before applying
terraform apply tfplan                         # ~15-25 min (a restore is slower than an empty create)
# NEVER apply a plan that replaces a prod database (-/+, "must be replaced"): the new one would
# start EMPTY (see "When something goes wrong")
# ONLY the very first time (no final snapshot exists yet; the plan stops with
# "Your query returned no results" otherwise): terraform plan -var first_create=true -out=tfplan

# after a restore, plan and apply ONCE MORE before deploying: a restored DocumentDB keeps the
# snapshot's old password, and this apply sends it the new one (module README, "The password
# after a restore"). The plan must show exactly "1 to change": master_password_wo_version
# 2 × password_version -> 2 × password_version + 1 (2 -> 3 while password_version = 1) on
# module.environment.aws_docdb_cluster.mongo, and the output snapshots.restore_from changing
# to null. (After the very first create it shows "No changes".) If it also creates the
# DocumentDB instance (the restore apply failed before it), see "When something goes wrong".
terraform plan -out=tfplan                     # have it reviewed before applying
terraform apply tfplan

# deploy the app (README in the repository root: "Deploy to prod on EKS") ... work ...

# remove the app FIRST (merge nothing to main and start no CD run on main until this layer is
# destroyed, else CD deploys it again); from the repository root:
# kubectl delete -k k8s/overlays/prod --ignore-not-found, then wait until no load balancer is left

# teardown step 1: protection off, final snapshot names set (see final_on_destroy in the plan)
terraform plan -var deletion_protection=false -out=tfplan
terraform apply tfplan
# teardown step 2: AWS saves the final snapshots, then deletes the databases (~10-15 min)
terraform plan -destroy -out=destroy.tfplan    # have it reviewed before destroying
terraform apply destroy.tfplan
# then destroy the platform layer (or keep it, e.g. to create prod again from the snapshots)
```

In PowerShell, quote an argument that starts with `-` and contains a dot:
`terraform plan -destroy '-out=destroy.tfplan'`.

**Order matters**, as for dev: destroy this layer **before** the platform layer. If the platform
was destroyed first anyway, do not try to delete the databases by hand: apply the platform again,
then do the normal teardown above (step 1 needs the cluster; without step 1 the databases cannot
be deleted with a final snapshot).

## Final snapshots

After a destroy, the final snapshots are no longer in any Terraform state: they are AWS
resources that the teardown leaves behind **on purpose**, the only ones (a leftover check after
a prod teardown must expect them). Each teardown adds two. They cost a few cents per month (backup storage for a few hundred MB).

```bash
# list them, newest last
aws rds describe-db-snapshots --snapshot-type manual --region eu-central-1 \
  --query "sort_by(DBSnapshots,&SnapshotCreateTime)[].[DBSnapshotIdentifier,SnapshotCreateTime,Status]" --output table
aws docdb describe-db-cluster-snapshots --snapshot-type manual --region eu-central-1 \
  --query "sort_by(DBClusterSnapshots,&SnapshotCreateTime)[].[DBClusterSnapshotIdentifier,SnapshotCreateTime,Status]" --output table
# delete an old one (never the newest of each database: the next create restores it)
aws rds delete-db-snapshot --db-snapshot-identifier cryptobot-prod-postgres-final-2026-11-20-1730 --region eu-central-1
aws docdb delete-db-cluster-snapshot --db-cluster-snapshot-identifier cryptobot-prod-mongo-final-2026-11-20-1730 --region eu-central-1
```

(In PowerShell, write each command on one line: the `\` at the end of a line is Bash.)

**Restore an older snapshot** (for example the one before a bad change): destroy prod as usual
(that adds a new final snapshot, so nothing is lost), then create it with the older ones named.
In PowerShell, the map goes through an environment variable (PowerShell 5.1 drops the quotes
inside a `-var` argument):

```powershell
$env:TF_VAR_restore_snapshots = '{postgres="cryptobot-prod-postgres-final-2026-11-20-1730", mongo="cryptobot-prod-mongo-final-2026-11-20-1730"}'
terraform plan -out=tfplan                     # snapshots.restore_from must show these names
terraform apply tfplan
Remove-Item Env:TF_VAR_restore_snapshots       # the next plan uses the newest again
```

## When something goes wrong

| What you see | Why | What to do |
|---|---|---|
| plan stops: `Your query returned no results` | no final snapshot of that database exists | the very first create: `-var first_create=true`. Otherwise check the list above and name the snapshot (`restore_snapshots`) |
| plan stops: `reading RDS DB Snapshots: ... DBInstanceNotFound` or `reading RDS DB Cluster Snapshots: ... DBClusterNotFoundFault` | AWS refuses to list the snapshots of a database that no longer exists by its name (its API documents that; first proven or disproven in the rehearsal) | name the newest snapshot of each database from the list above (`restore_snapshots`) |
| the same, in the very first session, while prod **runs** (e.g. teardown step 1) | the "does it exist?" lookup did not see the running database (expected not to happen; the DocumentDB one is first proven in the rehearsal) | add `-var first_create=true` to that command too: it only skips the snapshot lookup, a running database is not changed |
| after a restore and a deploy: `init-db` fails, the streamer restarts again and again, the API is not Ready; the logs show `Authentication failed` for MongoDB (PostgreSQL works) | the second apply after the restore was skipped: the restored DocumentDB still has the snapshot's old password | plan and apply once more (exactly "1 to change", see "One work session"), then deploy again (`gh workflow run cd.yml --ref main`, with approval). The Kubernetes Secrets already hold the right password (the secret did not change), so no sync is needed; a pod that is still not Ready: `kubectl -n prod rollout restart deployment`. **But** if that plan shows "No changes", or it also creates the DocumentDB instance (`aws_docdb_cluster_instance.mongo[0]`, after a restore apply that failed before it), the password is sent again before the instance exists and is lost the same way: after that apply, raise `password_version` in `main.tf`, plan and apply, then force the sync and restart the pods (commands in `k8s/overlays/prod/external-secrets.yaml`: the secret changes this time) |
| a plan wants to **replace** a prod database (`-/+`, `must be replaced`, often after `tainted`) | a create or restore failed half-way (e.g. a timeout, or the follow-up call that sets the password, backup days and version was refused); Terraform then marks the database as broken | **never apply it**: the new database would start EMPTY. Run `terraform untaint module.environment.aws_db_instance.postgres` (or `module.environment.aws_docdb_cluster.mongo`) and plan again; if the password may not have been set (always so for a DocumentDB restore that failed before its instance existed: row above), raise `password_version` in `main.tf` once both databases run |
| destroy stops: `final_snapshot_identifier is required when skip_final_snapshot is false`, `DocumentDB Cluster FinalSnapshotIdentifier is required when a final snapshot is required` or `Cannot delete protected DB Instance` / `DB Cluster` | teardown step 1 was skipped | run step 1 (if its plan replaces a database, see the row above), then destroy again; nothing is lost (some small parts, e.g. roles, may already be gone: step 1 re-creates them) |
| destroy stops: snapshot `already exists` | a final snapshot name from an earlier step 1 was used before | run step 1 again (a new plan, a new name), then destroy |

## Cost while it exists (Frankfurt list prices)

| Item | Per hour |
|---|---|
| RDS `db.t4g.small` | ≈ $0.04 |
| RDS 20 GB gp3 ($0.137 per GB-month) | ~$0.004 |
| DocumentDB `db.t4g.medium` | $0.089 |
| DocumentDB storage and I/O | cents |
| 4 secrets ($0.40 each per month) | ~$0.002 |
| **Total** | **≈ $0.13** (on top of the platform's ≈ $0.26) |

Backups within 7 days are free up to the database's size. Between sessions only the final
snapshots remain (a few cents per month).

## Checks (offline, no AWS account needed)

```bash
terraform fmt -check -recursive
terraform init -backend=false
terraform validate
terraform test          # tests/*.tftest.hcl: prod passes its values and switches in; Terraform 1.17+
```

The module has its own, larger test suite (module README, "Checks"). As for dev: run
`init -backend=false` in a fresh copy of the folder, or before the folder was ever initialised
with the S3 backend.

## Deliberately not enabled (prod)

- **Multi-AZ:** a standby doubles the database cost, and prod exists only during work sessions;
  the final snapshots, not a standby, carry its data from one session to the next.
- **Keeping the automatic backups after a destroy, copying snapshots to another region, AWS
  Backup:** the final snapshots are the copy that is kept.
- Everything both environments leave off: module README, "Deliberately not enabled".
