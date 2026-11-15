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
| Managed node group | 3× t3.medium (Amazon Linux 2023), private subnets | Runs every pod of both environments and the monitoring stack |
| EKS add-ons | VPC CNI, Pod Identity agent, kube-proxy, CoreDNS (pinned versions) | Pod networking, pod AWS rights, service routing, DNS |
| Namespaces | `dev`, `prod` | Two environments in one cluster |
| Access | the applying identity = cluster admin; `deploy-dev` / `deploy-prod` = `edit` in their own namespace only | CD can change its environment and nothing else |
| AWS Load Balancer Controller | Helm chart 3.6.2, `kube-system`, own Pod Identity role | Turns the dashboard's Ingress into one ALB |
| External Secrets | Helm chart 2.14.0, `external-secrets`, own Pod Identity role | Copies each environment's database passwords from Secrets Manager into Kubernetes |
| CloudWatch observability add-on | v7.0.1, container logs only (Fluent Bit; no CloudWatch agent pods), own Pod Identity role | Container logs into the bootstrap layer's log groups (7 days); its metrics features are off |
| Monitoring | Helm chart kube-prometheus-stack 93.3.0, `monitoring`, settings from `monitoring/values.yaml`; our dashboards and alert rule as ConfigMaps, built from `monitoring/kustomization.yaml` (`monitoring.tf`) | Prometheus and Grafana: dashboards and the failed-job alert, the same as on kind. No AWS rights, no disks, no load balancer (see `monitoring/README.md`) |

Subnet tags tell the AWS Load Balancer Controller where to put load balancers:
`kubernetes.io/role/elb` (public) and `kubernetes.io/role/internal-elb` (private).

Every AWS resource Terraform creates in this layer carries `Project=cryptobot`, `Layer=platform`
and `ManagedBy=terraform` (the provider's `default_tags`). Those do not reach what the node
group's launch template starts, so the launch template passes them on to the node servers, their
disks and their primary network cards, plus `Name=cryptobot-node`. Changing these tags therefore
makes a new launch template version, and EKS replaces the three nodes one by one (~15–20 min). The
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
# then apply envs/dev and/or envs/prod (their READMEs) and deploy the app ... work ...
# Grafana: kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80
#          (password and dashboards: monitoring/README.md)
# remove the app (its ALB, see Teardown below), destroy envs/dev and envs/prod, then:
terraform plan -destroy -out=destroy.tfplan    # have it reviewed before destroying
terraform apply destroy.tfplan
```

The envs layers build on this one: apply them after it and destroy them before it. Their
databases sit in this VPC and their security groups refer to the nodes' security group, so
while they exist the destroy of this layer fails (after ~20 minutes of retries) with the
cluster already gone and the databases still running.

## Teardown: what Terraform did not create

The AWS Load Balancer Controller creates an **ALB** (and its security groups) for every
Ingress, outside Terraform. Remove them **first**, before any destroy, or they keep running and
block deleting the VPC. Normally by removing the app (from the repository root:
`kubectl delete -k k8s/overlays/dev --ignore-not-found`, and the same for `k8s/overlays/prod`;
see the README there); this catches any Ingress left anywhere:

```bash
kubectl delete ingress --all -A              # the controller deletes the ALBs
aws elbv2 describe-load-balancers --region eu-central-1 \
  --query "LoadBalancers[].LoadBalancerName"   # until empty
```

A safety net, not a replacement for that step: the destroy deletes the `dev` and `prod`
namespaces first, and the controller is removed only after them and before the NAT gateway and
routes, so it can still delete the ALB of an Ingress forgotten in them (not in any other
namespace). Check afterwards that no ALB is left.

Then destroy `envs/dev` and `envs/prod` with their own plan and apply (`envs/prod` in two
steps, and its final snapshots stay on purpose: see its README), and then this layer (see above). The container log groups belong to the bootstrap
layer and stay (7 days). No PersistentVolumeClaims, so no EBS volumes are left behind (the
monitoring stack keeps its data on the pods' own disks, and Grafana is reached through
`kubectl port-forward`, not a load balancer).

## Pod budget

A t3.medium node runs at most 17 pods (VPC CNI without prefix delegation): 51 with three nodes.
This layer uses about 26: per node aws-node, kube-proxy, the Pod Identity agent, Fluent Bit and
node-exporter (5 × 3), once CoreDNS ×2, the CloudWatch operator, the Load Balancer Controller,
External Secrets ×3, and Prometheus, Grafana, kube-state-metrics and the Prometheus Operator
(11). The apps need 7 (dev 3, prod 4), and a deploy adds a few for a moment: `init-db`, a new
API and dashboard pod before the old ones stop, and the Job pods of `ingest` and `retrain`
(finished pods don't count). With two nodes that peak was 33 of 34 pods (35 at 03:00 UTC,
when `retrain` runs too), hence the third node. Memory: the monitoring stack requests about 1.3 GiB (Grafana with its three loaders
~0.7, Prometheus ~0.4) and the apps about 1.8 GiB, of roughly 9.7 GiB the three nodes offer
to pods (4 GiB each minus what EKS reserves for the kubelet and the system; the exact value is
"Allocatable" in `kubectl describe node`). VPC CNI prefix delegation would raise the pod limit
at no cost, but it adds no memory or CPU: up to 110 pods would share each node's memory, with
the kubelet's reservation still sized for 17.

## Cost while it exists (Frankfurt list prices)

| Item | Per hour |
|---|---|
| EKS control plane | $0.10 |
| 3× t3.medium nodes + their disks | 3 × $0.048 + ~$0.008 |
| NAT gateway + its public IPv4 address | $0.052 + $0.005 |
| **Total** | **≈ $0.31** |
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
