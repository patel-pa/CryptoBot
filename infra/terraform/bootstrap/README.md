# Terraform bootstrap layer

Created once and **kept**: everything the other layers (`platform`, `envs/dev`, `envs/prod`)
and the CI/CD pipeline need before they can run. It is never destroyed at the end of a
work session.

| Resource | Name | Why |
|---|---|---|
| S3 bucket | `cryptobot-tfstate-patel-pa` | Terraform state of every layer, one key per layer (`bootstrap/`, `platform/`, …). Locking with an S3 lock file (`use_lockfile`), no DynamoDB table. |
| S3 bucket | `cryptobot-models-patel-pa` | The trained model, one key per environment (`dev/model.pkl`, `prod/model.pkl`). The retrain job uploads, the API downloads; versioning keeps earlier models. |
| ECR repository | `cryptobot` | The one application image. Tags are git commit SHAs and **immutable**; scanned on push. Kept for rollbacks: the newest 10 images promoted to prod (second tag `prod-<main SHA>`), however many dev pushes follow, and the newest 30 tagged images overall (prod images count toward the 30 but are never expired by that rule). |

Not managed here: the AWS Budgets alerts (created by hand in the console before any
Terraform code existed).

Every bucket is private (public access blocked, no ACLs), encrypted at rest, HTTPS-only,
versioned (old versions deleted after 90 days) and protected by `prevent_destroy`.

## Prerequisites

- Terraform 1.10 or newer, AWS CLI v2.
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

Every bucket here has `prevent_destroy`, so `terraform destroy` stops with an error by
design. The ECR repository cannot be deleted while it still holds images.

## Deliberately not enabled (cost over extra protection)

Security scanners (Trivy, Checkov) report these; they are accepted on purpose:

- **KMS customer-managed keys (S3, ECR):** AWS-managed AES-256 encryption already protects
  the data at rest; a KMS key costs about $1 per month plus requests.
- **S3 access logging, event notifications:** need another bucket or a consumer; CloudTrail
  already records who changed a bucket.
- **Cross-region replication:** doubles storage and adds a second region; versioning already
  protects against overwrites and deletes.
