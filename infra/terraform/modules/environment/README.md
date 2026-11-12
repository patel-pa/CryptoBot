# Terraform module: environment

One environment's databases, their passwords, how its Kubernetes namespace may read them, and
its pods' AWS rights. The layers `envs/dev` and `envs/prod` both call this module, each with its
own values: **one code, two environments**, so dev tests exactly what prod runs, and a fix (for
example to a trust policy) is made once for both.

The module has no backend and no provider settings of its own: the calling layer keeps the state,
configures the AWS and Kubernetes providers and reads the platform and bootstrap layers' outputs.

## Inputs

| Input | What it decides | dev |
|---|---|---|
| `env` | namespace, secret path `cryptobot/<env>/`, model prefix `<env>/`, names `cryptobot-<env>-…`; only `dev` or `prod` | `dev` |
| `region` | where the databases and secrets live | `eu-central-1` |
| `platform` | the platform layer's network, cluster and External Secrets controller role (`applied = false` while it is destroyed) | from its state |
| `model_bucket` | the bootstrap layer's model bucket | from its state |
| `postgres` | instance size, days of automatic backups | `db.t4g.micro`, 1 |
| `mongo` | DocumentDB instance size, days of automatic backups | `db.t4g.medium`, 1 |
| `deletion_protection` | AWS refuses to delete either database while true | `false` |
| `password_version` | raise by one for new passwords (below) | `1` |

Everything else is fixed here for every environment: PostgreSQL 18, DocumentDB 8.0.2 (the same
majors as docker compose and the kind overlay: `postgres:18`, `mongo:8.0`; change them together),
20 GB gp3, the ports, the database and user names, one zone, encryption, the firewall rules and
every IAM policy. For now also: no final snapshot on destroy (an input once prod keeps its data).

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
apply. The secrets get new values first, then the databases read them back. Running pods keep the
old password until they restart, and External Secrets copies the new one into Kubernetes only at
its next hourly refresh: force that first, then restart the pods (commands in
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

The tests run with dev's values, plus one run with `env = "prod"` and other sizes, backup days,
protection and password version: every name, path and trust condition must follow the
environment, and every setting its own input. Each layer's own tests check that it passes its
values in.

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

Scanners (Trivy, Checkov) report exactly these choices: no customer-managed KMS key, no
rotation, no Multi-AZ, no logs or monitoring, no IAM authentication (and, with dev's values,
no deletion protection and short backups). Trivy finds nothing HIGH or CRITICAL.
