# Terraform platform layer

Created at the start of a work session and **destroyed at the end**: it costs money every
hour it exists. The state lives in the bootstrap layer's bucket under `platform/`, so
destroying this layer never touches the bootstrap layer. It reads the bootstrap layer's
outputs (the CI role ARNs) from that layer's state, read-only.

| Resource | Details | Why |
|---|---|---|
| VPC `cryptobot` | `10.0.0.0/16`, zones `eu-central-1a` and `-1b` | EKS and the AWS databases need two zones |
| 2 private subnets | `10.0.0.0/19`, `10.0.32.0/19` | Nodes and databases; large, because every pod gets an address of its subnet |
| 2 public subnets | `10.0.128.0/24`, `10.0.129.0/24` | Only the load balancer and the NAT gateway are public |
| 1 NAT gateway | in one public subnet | Private subnets reach the internet (Binance, image pulls) |
| S3 gateway endpoint | private route tables | Free direct path to S3, so ECR image layers and the model skip the NAT's per-GB fee |
| EKS cluster `cryptobot` | Kubernetes 1.37, standard support only | AWS runs the control plane; never slips into paid extended support |
| Managed node group | 2× t3.medium (Amazon Linux 2023), private subnets | Runs every pod of both environments |
| EKS add-ons | VPC CNI, Pod Identity agent, kube-proxy, CoreDNS (pinned versions) | Pod networking, pod AWS rights, service routing, DNS |
| Namespaces | `dev`, `prod` | Two environments in one cluster |
| Access | the applying identity = cluster admin; `deploy-dev` / `deploy-prod` = `edit` in their own namespace only | CD can change its environment and nothing else |

Subnet tags tell the AWS Load Balancer Controller where to put load balancers:
`kubernetes.io/role/elb` (public) and `kubernetes.io/role/internal-elb` (private).

## Prerequisites

- The bootstrap layer is applied (state bucket, CI roles, log groups).
- Terraform 1.14 or newer (1.14.9 or newer with `aws login` credentials), AWS CLI v2.
- `AWS_PROFILE` set to a profile with administrator rights (see the bootstrap README).
- `kubectl`, pointed at the cluster after the apply: run the command that
  `terraform output -raw kubeconfig_command` prints.

## Who may do what in the cluster

Access entries only (no `aws-auth` ConfigMap). The CI roles `cryptobot-github-deploy-dev` and
`-deploy-prod` (bootstrap layer) are mapped to the Kubernetes groups `cryptobot-deploy-dev` /
`-prod`; a RoleBinding gives each group the built-in ClusterRole `edit` in its own
namespace.

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
| EKS control plane | $0.10 |
| 2× t3.medium nodes + their disks | 2 × $0.048 + ~$0.005 |
| NAT gateway + its public IPv4 address | $0.052 + $0.005 |
| **Total** | **≈ $0.26** |
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
- **An own KMS key for Kubernetes secrets:** EKS already encrypts all Kubernetes data with an
  AWS-owned key; an own key costs $1 per month and outlives every teardown. (Scanners report
  "secret encryption not enabled" because they cannot see the default.)
- **A private-only API endpoint:** GitHub-hosted runners deploy over the internet; every call
  still needs IAM credentials. A runner inside the VPC would cost extra. (Scanners report
  "public cluster access" and "0.0.0.0/0".)
- **Restricted egress for nodes:** pods must reach Binance, ECR and AWS APIs; inbound stays
  closed. (Scanners report "unrestricted egress".)
- **Control-plane logs:** not needed; their log group would never expire.
