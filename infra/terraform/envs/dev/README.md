# Terraform environment layer: dev

The dev databases, their passwords, and how the `dev` namespace may read them. Created after
the platform layer at the start of a work session and **destroyed before it** at the end: the
databases sit in the platform's network, and the SecretStore in its cluster.
Dev starts empty in every session; the backfill Job reloads the history from Binance. The state
lives in the bootstrap layer's bucket under `envs/dev/`.

| Resource | Details | Why |
|---|---|---|
| RDS PostgreSQL `cryptobot-dev-postgres` | PostgreSQL 18, `db.t4g.micro`, 20 GB gp3, one zone, encrypted | The batch pipeline's database; the smallest size |
| DocumentDB `cryptobot-dev-mongo` | 8.0, one `db.t4g.medium` instance, encrypted | The stream's database (MongoDB-compatible) |
| 2 subnet groups | the platform's two private subnets | Databases are never reachable from the internet |
| 2 security groups | inbound only from the EKS nodes' security group, on 5432 / 27017; no outbound rules | Only pods in the cluster can connect |
| 4 Secrets Manager secrets | `cryptobot/dev/postgres`, `…/postgres-endpoint`, `…/mongo`, `…/mongo-endpoint` | The app's connection settings, read by External Secrets |
| IAM role `cryptobot-dev-external-secrets` | trusted by the External Secrets controller only for a SecretStore in `dev`; may only read `cryptobot/dev/*` | Dev can never read prod's secrets |
| SecretStore `aws-secrets-manager` | in the `dev` namespace, uses that role, `sessionTagsPolicy: Simple` | What the dev overlay's ExternalSecrets refer to |

Both databases: backups kept 1 day, no deletion protection, no final snapshot, no Performance
Insights, no enhanced monitoring, no log exports. PostgreSQL gets minor version updates
automatically; DocumentDB never applies minor updates on its own (8.0.2 stays 8.0.2). TLS is enforced by
AWS's default parameter groups (`rds.force_ssl = 1` for PostgreSQL 18, `tls = tls1.2+` for
DocumentDB 8.0). The major versions match docker compose and the kind overlay (`postgres:18`,
`mongo:8.0`); change them together.

## Passwords: never in the Terraform state

Per database there are two secrets:

1. **Credentials** (`cryptobot/dev/postgres`: `username`, `password`), written first. AWS
   generates the password at apply time (`ephemeral "aws_secretsmanager_random_password"`,
   letters and digits only) and Terraform writes it with a write-only argument
   (`secret_string_wo`): it appears in neither the state nor the plan.
2. **Endpoint** (`cryptobot/dev/postgres-endpoint`: `host`, `port`, `dbname`), written after the
   database exists. Not secret, but this way no account-specific host name lives in the public
   repository.

The databases read their passwords back from exactly the secret versions just written
(`password_wo`, `master_password_wo`), so both get the same password, even when a first apply
fails half-way. External Secrets merges both secrets of a database into one Kubernetes Secret.

**New passwords:** raise `password_version` in `secrets.tf` and apply. The secrets get new values
first, then the databases read them back. Running pods keep the old password until they restart.
If AWS rejects the database change (for example because the instance is busy), the secret
already holds the new password while the database keeps the old one, and Terraform cannot see
the difference (AWS never reports a password): raise `password_version` once more.

Anyone who runs `plan` on this layer reads the dev passwords (the read-back runs at every plan),
so a future CI plan role needs `secretsmanager:GetSecretValue` on `cryptobot/dev/*` and gets the
passwords with it.

The secrets are deleted at once on destroy (`recovery_window_in_days = 0`), so the next session
can create the same names again.

## How the dev namespace reads its secrets (and never prod's)

External Secrets has one AWS identity for the whole cluster (the platform's
`cryptobot-external-secrets`, through Pod Identity). That identity may only assume roles named
`cryptobot-*-external-secrets`, and which one a namespace uses is set in its SecretStore. Two
locks:

1. **Kubernetes:** only this layer creates the SecretStore of `dev`. Deploy jobs may create
   `ExternalSecret`s there ("I need this secret"), never `SecretStore`s ("read with this role")
   (platform layer RBAC). The store says `sessionTagsPolicy: Simple`, so External Secrets tags
   every sign-in with the store's namespace and kind (`esoNamespace`, `esoStoreKind`, also
   `esoStoreName`) and ignores hand-written tags.
2. **AWS:** the role trusts the controller only when the request carries `esoNamespace = dev`
   and `esoStoreKind = SecretStore`, on `sts:AssumeRole` itself (a sign-in without tags is
   refused too). Its only permission is `secretsmanager:GetSecretValue` on `cryptobot/dev/*`.

The trust policy names the controller's role by ARN; AWS resolves that to the role's internal
ID when the policy is saved. A re-created controller role (new platform) is a different role,
so this layer must be re-created after the platform, which the session order does anyway.

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
terraform init
terraform plan -out=tfplan                     # have it reviewed before applying
terraform apply tfplan                         # ~10-15 min (DocumentDB is the slow part)
# ... work ...
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
terraform state rm kubernetes_manifest.secret_store
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
terraform test          # tests/*.tftest.hcl, against a mock provider; Terraform 1.17+
```

## Deliberately not enabled

- **Multi-AZ, read replicas, more DocumentDB instances:** a standby doubles the cost; dev can be
  rebuilt in minutes.
- **Deletion protection and a final snapshot:** dev holds no data that cannot be reloaded from
  Binance. (Prod keeps both.)
- **A separate, less privileged database user for the app:** the app uses the master user.
- **An own KMS key:** the AWS-managed keys encrypt storage and secrets for free; an own key costs
  $1 per month and outlives every teardown.
- **Automatic password rotation:** a rotation would break running pods until they restart.
- **Performance Insights, enhanced monitoring, log exports:** cost, and log groups that never
  expire.
- **IAM database authentication:** the app signs in with the password from Secrets Manager; IAM
  tokens would need app changes and expire every 15 minutes.
- **Longer backups:** 1 day is enough for data that can be reloaded (prod keeps 7).

Scanners (Trivy, Checkov) report exactly these choices: no customer-managed KMS key, no
rotation, no Multi-AZ, no deletion protection, short backups, no logs or monitoring, no IAM
authentication. Trivy finds nothing HIGH or CRITICAL.
