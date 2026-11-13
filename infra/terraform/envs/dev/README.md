# Terraform environment layer: dev

The dev databases, their passwords, how the `dev` namespace may read them, and the dev pods'
AWS rights: the shared module [`modules/environment`](../../modules/environment/README.md) with
dev's values (`main.tf`). Created after the platform layer at the start of a work session and
**destroyed before it** at the end: the databases sit in the platform's network, and the
SecretStore and the Pod Identity associations in its cluster. The state lives in the bootstrap
layer's bucket under `envs/dev/`.

## Dev's values

Dev holds nothing that cannot be reloaded from Binance: it starts empty in every session, and
the ingest job reloads the last day.

| Setting | dev |
|---|---|
| PostgreSQL `cryptobot-dev-postgres` | `db.t4g.micro` (the smallest) |
| DocumentDB `cryptobot-dev-mongo` | one `db.t4g.medium` (the smallest DocumentDB offers) |
| Automatic backups | 1 day |
| Deletion protection | off |
| Final snapshot on destroy | none |
| Secrets | `cryptobot/dev/postgres`, `…/postgres-endpoint`, `…/mongo`, `…/mongo-endpoint` |
| External Secrets role | `cryptobot-dev-external-secrets` (reads only `cryptobot/dev/*`) |
| Pod roles | `cryptobot-dev-api` (reads), `cryptobot-dev-retrain` (writes) `dev/*` in the model bucket |

What each resource is and why, the passwords, the two locks that keep dev from prod's secrets,
and the pods' AWS rights: see the [module README](../../modules/environment/README.md).
**New passwords:** raise `password_version` in `main.tf` and apply (module README, "New passwords").

## Prerequisites

- The bootstrap and platform layers are applied. Without the platform's outputs, the plan stops
  with "apply the platform layer first". The plan also talks to the cluster (the SecretStore is
  a Kubernetes object), with a token from the same AWS credentials (`aws eks get-token`).
- **Terraform 1.17 or newer** (the other layers accept 1.14). The tests mock an ephemeral
  resource (`mock_ephemeral`), and `terraform init` already reads the test files, so older
  versions stop at once with "does not support Terraform version".
- `AWS_PROFILE` set to a profile with administrator rights (see the bootstrap README).

## One work session

```bash
# after the platform layer:
cd infra/terraform/envs/dev
terraform init                                 # again after a change of the module's location or providers
terraform plan -out=tfplan                     # have it reviewed before applying
terraform apply tfplan                         # ~10-15 min (DocumentDB is the slow part)
# deploy the app (README in the repository root: "Deploy to dev on EKS") ... work ...
# remove the app FIRST (and push nothing to dev until this layer is destroyed: CD would deploy it again):
# from the repository root, kubectl delete -k k8s/overlays/dev --ignore-not-found
# (deletes the dashboard's ALB), then wait until no load balancer is left
terraform plan -destroy -out=destroy.tfplan    # have it reviewed before destroying
terraform apply destroy.tfplan
# then destroy the platform layer
```

In PowerShell, quote an argument that starts with `-` and contains a dot:
`terraform plan -destroy '-out=destroy.tfplan'`.

**Order matters:** destroy this layer **before** the platform layer. Its security groups refer to
the nodes' security group and sit in the platform's VPC, which cannot be deleted while they exist,
and its SecretStore can only be deleted while the cluster still runs.

**If the platform was destroyed first anyway** (its destroy then stops with the cluster gone and
the databases still running): the normal destroy plan of this layer fails too, because it reads
the cluster (`couldn't find resource`). The SecretStore is already gone with the cluster, so
forget it and plan without re-reading anything:

```bash
terraform state rm module.environment.kubernetes_manifest.secret_store
terraform plan -destroy -refresh=false -out=destroy.tfplan   # have it reviewed
terraform apply destroy.tfplan
# then run the platform's destroy again
```

## Cost while it exists (Frankfurt list prices)

| Item | Per hour |
|---|---|
| RDS `db.t4g.micro` | $0.019 |
| RDS 20 GB gp3 ($0.137 per GB-month) | ~$0.004 |
| DocumentDB `db.t4g.medium` | $0.089 |
| DocumentDB storage ($0.119 per GB-month) and I/O ($0.22 per million) | cents |
| 4 secrets ($0.40 each per month) | ~$0.002 |
| **Total** | **≈ $0.11** (on top of the platform's ≈ $0.26) |

## Checks (offline, no AWS account needed)

```bash
terraform fmt -check -recursive
terraform init -backend=false
terraform validate
terraform test          # tests/*.tftest.hcl: dev passes its values in; Terraform 1.17+
```

The module has its own, larger test suite (module README, "Checks"). Run `init -backend=false`
in a fresh copy of the folder, or in a folder that was never initialised with the S3 backend:
in a folder that was, `init` still tries to reach the backend and asks for AWS credentials.

## Deliberately not enabled (dev only)

- **Deletion protection and a final snapshot:** dev holds no data that cannot be reloaded from
  Binance. (Prod keeps both.)
- **Longer backups:** 1 day is enough for data that can be reloaded (prod keeps 7).
- Everything both environments leave off: module README, "Deliberately not enabled".
