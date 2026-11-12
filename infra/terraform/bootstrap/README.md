# Terraform bootstrap layer

Created once and **kept**: everything the other layers (`platform`, `envs/dev`, `envs/prod`)
and the CI/CD pipeline need before they can run. It is never destroyed at the end of a
work session.

| Resource | Name | Why |
|---|---|---|
| S3 bucket | `cryptobot-tfstate-patel-pa` | Terraform state of every layer, one key per layer (`bootstrap/`, `platform/`, …). Locking with an S3 lock file (`use_lockfile`), no DynamoDB table. |
| S3 bucket | `cryptobot-models-patel-pa` | The trained model, one key per environment (`dev/model.pkl`, `prod/model.pkl`). The retrain job uploads, the API downloads; versioning keeps earlier models. |
| ECR repository | `cryptobot` | The one application image. Tags are git commit SHAs and **immutable**; scanned on push. Kept for rollbacks: the newest 10 images promoted to prod (second tag `prod-<main SHA>`), however many dev pushes follow, and the newest 30 tagged images overall (prod images count toward the 30 but are never expired by that rule). |
| CloudWatch log groups | `/aws/containerinsights/cryptobot/application`, `/dataplane`, `/host` | Container logs of the EKS cluster (sent by the CloudWatch observability add-on). Created here so they outlive every cluster teardown; kept 7 days, so they never grow forever. |
| IAM OIDC provider | `token.actions.githubusercontent.com` | GitHub Actions gets short-lived AWS credentials; no AWS key is stored in GitHub. |
| IAM roles | `cryptobot-github-build`, `-deploy-dev`, `-deploy-prod` | One role per CI job, each with only what that job needs (below). |

| Role | Who may assume it (token `sub`) | May do |
|---|---|---|
| `build` | a job on the `dev` branch without a GitHub environment | log in to ECR, push the image |
| `deploy-dev` | a job on the `dev` branch without a GitHub environment | look up an image's digest, describe the EKS cluster |
| `deploy-prod` | a job in the GitHub environment `production` | as `deploy-dev`, plus add the tag `prod-<main SHA>` to an existing image |

A job that sets `environment:` gets the subject `…:environment:<name>` instead of the
branch, so the dev jobs must not use a GitHub environment (or the trust must change).

The workflows (`.github/workflows/cd.yml` uses `build` and `deploy-dev`) build each role's
ARN from the repository secret `AWS_ACCOUNT_ID` (GitHub: Settings → Secrets and variables →
Actions), so the account ID is in no file and GitHub hides it in the public logs. Set it once, with
`AWS_PROFILE` set as in Prerequisites (check first that `aws sts get-caller-identity` shows the
right account):
`gh secret set AWS_ACCOUNT_ID --body "$(aws sts get-caller-identity --query Account --output text)"`.

Inside Kubernetes the deploy roles get rights through EKS access entries (platform layer):
`deploy-dev` only in the `dev` namespace, `deploy-prod` only in `prod`.

Not managed here: the AWS Budgets alerts (created by hand in the console before any
Terraform code existed).

Every bucket is private (public access blocked, no ACLs), encrypted at rest, HTTPS-only,
versioned (old versions deleted after 90 days) and protected by `prevent_destroy`.

## Prerequisites

- Terraform 1.14 or newer (1.14.9 or newer if your credentials come from `aws login`: the S3
  state backend of older versions cannot read them), AWS CLI v2.
- An AWS CLI profile with administrator rights in the target account, for example through
  IAM Identity Center (`aws configure sso`, then `aws sso login --profile <name>`).
  Terraform reads it from the environment:

  ```bash
  export AWS_PROFILE=<name>          # PowerShell: $env:AWS_PROFILE = "<name>"
  aws sts get-caller-identity        # the expected account?
  ```

## First run (once): local state, then move it into S3

The state bucket is created by this layer, so it cannot hold this layer's state before it
exists. The first apply keeps the state in a local file; afterwards it moves into S3.

```bash
cd infra/terraform/bootstrap
cp first_run_override.tf.example first_run_override.tf   # backend "local" for now
terraform init
terraform plan -out=tfplan                                # read it before applying
terraform apply tfplan
rm first_run_override.tf                                  # back to backend "s3"
terraform init -migrate-state                             # answer "yes"
terraform state list                                      # now read from S3
rm terraform.tfstate*                                     # local copy, no longer needed
rm tfplan
```

## GitHub settings this layer relies on

The `deploy-prod` role trusts every job that runs in the GitHub environment `production`,
so the environment itself must be protected (repository Settings → Environments →
`production`):

- **Required reviewers:** the repository owner (every prod deploy waits for approval).
- **Deployment branches and tags:** selected branches only, `main`.

`terraform output ci_role_arns` prints the role ARNs the CD workflow assumes.

## Every later change

```bash
terraform init
terraform plan -out=tfplan
terraform apply tfplan
```

## Checks (offline, no AWS account needed)

```bash
terraform fmt -check -recursive
terraform init -backend=false
terraform validate
terraform test          # tests/*.tftest.hcl, against a mock AWS provider
```

## Never destroyed

Every bucket and the ECR repository have `prevent_destroy`, so `terraform destroy` (or a
change that would replace one of them) stops with an error by design. The images in ECR are
the rollback history; AWS also refuses to delete a repository that still holds images.

## Deliberately not enabled (cost over extra protection)

Security scanners (Trivy, Checkov) report these; they are accepted on purpose:

- **KMS customer-managed keys (S3, ECR, CloudWatch Logs):** AWS-managed encryption already
  protects the data at rest; a KMS key costs about $1 per month plus requests.
- **Log retention of a year or more:** 7 days is enough to debug a session; longer retention
  only adds storage cost.
- **S3 access logging, event notifications:** need another bucket or a consumer; CloudTrail
  already records who changed a bucket.
- **Cross-region replication:** doubles storage and adds a second region; versioning already
  protects against overwrites and deletes.
