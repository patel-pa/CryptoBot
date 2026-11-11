# Terraform platform layer

Created at the start of a work session and **destroyed at the end**: it costs money every
hour it exists. The state lives in the bootstrap layer's bucket under `platform/`, so
destroying this layer never touches the bootstrap layer. It reads the bootstrap layer's
outputs (the CI role ARNs and the log group names) from that layer's state, read-only.

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
| AWS Load Balancer Controller | Helm chart 3.6.2, `kube-system`, own Pod Identity role | Turns the dashboard's Ingress into one ALB |
| External Secrets | Helm chart 2.14.0, `external-secrets`, own Pod Identity role | Copies each environment's database passwords from Secrets Manager into Kubernetes |
| CloudWatch observability add-on | v7.0.1, container logs only (Fluent Bit; no CloudWatch agent pods), own Pod Identity role | Container logs into the bootstrap layer's log groups (7 days); its metrics features are off |

Subnet tags tell the AWS Load Balancer Controller where to put load balancers:
`kubernetes.io/role/elb` (public) and `kubernetes.io/role/internal-elb` (private).

Every AWS resource Terraform creates in this layer carries `Project=cryptobot`, `Layer=platform`
and `ManagedBy=terraform` (the provider's `default_tags`). Those do not reach what the node
group's launch template starts, so the launch template passes them on to the node servers, their
disks and their primary network cards, plus `Name=cryptobot-node`. Changing these tags therefore
makes a new launch template version, and EKS replaces both nodes one by one (~10–15 min). The
ALBs, target groups and security groups the Load Balancer Controller creates carry
`Project=cryptobot` and `ManagedBy=aws-load-balancer-controller`. Only AWS's own tags are on the
extra network cards the VPC CNI attaches for pod addresses and on the security group EKS creates
for the cluster; both are free and disappear with the nodes and the cluster.

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
namespace, plus a Role that allows `ExternalSecret` objects there. `edit` deliberately
gives **no write rights** on External Secrets' resources (see the next section).

## How dev is kept from reading prod's passwords

With Pod Identity, External Secrets has one identity for the whole cluster
(`cryptobot-external-secrets`). That role may only assume, and tag, the per-environment roles
`cryptobot-dev-external-secrets` and `cryptobot-prod-external-secrets` (envs layers). Which
role a namespace uses, and with which session tags, is set in its **SecretStore**. Two locks:

1. **Kubernetes:** deploy jobs may create `ExternalSecret` objects ("I need this secret") but
   may not create or change `SecretStore` objects ("read it with this role and these tags"):
   `edit` gives no write rights on External Secrets' resources (`rbac.aggregateToEdit =
   false`; reading them stays possible and is harmless, a store holds no secret values). The
   SecretStore of each namespace is created by the envs layer, which only the owner applies,
   with that environment's role and `sessionTagsPolicy: Simple`.
2. **AWS:** each environment role trusts the controller only when the session tag
   `esoNamespace` names its own namespace and `esoStoreKind` is `SecretStore`. With
   `sessionTagsPolicy: Simple`, External Secrets sets those tags from the store.

Lock 1 is needed: with the default policy `None`, a SecretStore may list any session tags by
hand (External Secrets 2.14.0), including `esoNamespace=prod`.

## One work session

```bash
cd infra/terraform/platform
terraform init
terraform plan -out=tfplan                     # have it reviewed before applying
terraform apply tfplan
# then apply envs/dev (its README) ... work ... destroy envs/dev FIRST, then:
terraform plan -destroy -out=destroy.tfplan    # have it reviewed before destroying
terraform apply destroy.tfplan
```

The envs layers build on this one: apply them after it and destroy them before it. Their
databases sit in this VPC and their security groups refer to the nodes' security group, so
while they exist the destroy of this layer fails (after ~20 minutes of retries) with the
cluster already gone and the databases still running.

## Teardown: what Terraform did not create

First destroy `envs/dev` (and later `envs/prod`) with their own plan and apply (see above).

The AWS Load Balancer Controller creates an **ALB** (and its security groups) for every
Ingress, outside Terraform. Remove it before destroying this layer, or it keeps running and
blocks deleting the VPC:

```bash
kubectl delete ingress --all -A              # the controller deletes the ALBs
aws elbv2 describe-load-balancers --query "LoadBalancers[].LoadBalancerName"   # until empty
```

Then plan and apply the destroy (above). The container log groups belong to the bootstrap
layer and stay (7 days). No PersistentVolumeClaims, so no EBS volumes are left behind.

## Pod budget

A t3.medium node runs at most 17 pods (VPC CNI without prefix delegation): 34 in the cluster.
This layer uses about 15: per node aws-node, kube-proxy, the Pod Identity agent and Fluent Bit
(4 × 2), once CoreDNS ×2, the CloudWatch operator, the Load Balancer Controller and External
Secrets ×3 (7). That leaves about 19 for the apps (dev 3, prod 4, a few Job pods) and the
monitoring stack of Week 4. If that gets tight: VPC CNI prefix delegation raises the limit.

## Cost while it exists (Frankfurt list prices)

| Item | Per hour |
|---|---|
| EKS control plane | $0.10 |
| 2× t3.medium nodes + their disks | 2 × $0.048 + ~$0.005 |
| NAT gateway + its public IPv4 address | $0.052 + $0.005 |
| **Total** | **≈ $0.26** |
| Data through the NAT gateway | $0.052 per GB (S3 traffic is free through the endpoint) |
| Container logs | $0.63 per GB ingested |
| ALB, once an Ingress exists | ≈ $0.027 + its public IPv4 addresses |

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
