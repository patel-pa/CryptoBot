# Terraform platform layer

Created at the start of a work session and **destroyed at the end**: it costs money every
hour it exists. The state lives in the bootstrap layer's bucket under `platform/`, so
destroying this layer never touches the bootstrap layer.

| Resource | Details | Why |
|---|---|---|
| VPC `cryptobot` | `10.0.0.0/16`, zones `eu-central-1a` and `-1b` | EKS and the AWS databases need two zones |
| 2 private subnets | `10.0.0.0/19`, `10.0.32.0/19` | Nodes and databases; large, because every pod gets an address of its subnet |
| 2 public subnets | `10.0.128.0/24`, `10.0.129.0/24` | Only the load balancer and the NAT gateway are public |
| 1 NAT gateway | in one public subnet | Private subnets reach the internet (Binance, image pulls) |
| S3 gateway endpoint | private route tables | Free direct path to S3, so ECR image layers and the model skip the NAT's per-GB fee |

Subnet tags tell the AWS Load Balancer Controller where to put load balancers:
`kubernetes.io/role/elb` (public) and `kubernetes.io/role/internal-elb` (private).

## Prerequisites

- The bootstrap layer is applied (state bucket, CI roles, log groups).
- Terraform 1.14 or newer (1.14.9 or newer with `aws login` credentials), AWS CLI v2.
- `AWS_PROFILE` set to a profile with administrator rights (see the bootstrap README).

## One work session

```bash
cd infra/terraform/platform
terraform init
terraform plan -out=tfplan                     # have it reviewed before applying
terraform apply tfplan
# ... work ...
terraform plan -destroy -out=destroy.tfplan    # have it reviewed before destroying
terraform apply destroy.tfplan
```

## Cost while it exists (Frankfurt list prices)

| Item | Per hour |
|---|---|
| NAT gateway + its public IPv4 address | $0.052 + $0.005 |
| Data through the NAT gateway | $0.052 per GB (S3 traffic is free through the endpoint) |

## Checks (offline, no AWS account needed)

```bash
terraform fmt -check -recursive
terraform init -backend=false
terraform validate
terraform test          # tests/*.tftest.hcl, against mock providers
```

## Deliberately not enabled

- **A NAT gateway per zone:** survives a zone outage, at twice the NAT cost.
- **VPC flow logs:** useful for network forensics, but every log line costs ingestion.
- **Module sources pinned by commit hash:** registry modules are pinned to an exact version.
