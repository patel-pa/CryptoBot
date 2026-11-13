# Cluster add-ons that need AWS rights. Each gets its own IAM role through EKS Pod
# Identity, tied to exactly one Kubernetes service account.

locals {
  # Chart values and add-on settings in one place (the tests check them).
  lb_controller_values = {
    clusterName  = module.eks.cluster_name
    region       = var.region
    vpcId        = module.vpc.vpc_id # set, so the controller never needs the node's metadata
    replicaCount = 1
    # Only ALBs from Ingresses are used. This webhook would intercept every Service in the
    # cluster and, with failurePolicy Fail, reject them all while its single pod is down.
    enableServiceMutatorWebhook = false
    serviceAccount              = { name = "aws-load-balancer-controller" }
    # On every ALB, target group and security group it creates (outside Terraform), so a
    # forgotten one is easy to find and to attribute.
    defaultTags = {
      Project   = local.tags.Project
      ManagedBy = "aws-load-balancer-controller"
    }
  }

  external_secrets_values = {
    installCRDs    = true
    serviceAccount = { name = "external-secrets" }
    # "edit" may not create or change SecretStore & co. (see kubernetes.tf).
    rbac = { aggregateToEdit = false }
  }

  # Keys checked against the configuration schema of v7.0.1-eksbuild.1
  # (aws eks describe-addon-configuration); unknown keys are rejected.
  cloudwatch_addon_config = {
    containerLogs         = { enabled = true } # Fluent Bit: container logs
    agents                = []                 # no CloudWatch agent pods: they would collect nothing
    containerInsights     = { enabled = false }
    applicationSignals    = { enabled = false }
    otelContainerInsights = { enabled = false }
    kubeStateMetrics      = { enabled = false }
    nodeExporter          = { enabled = false }
    dcgmExporter          = { enabled = false }
    neuronMonitor         = { enabled = false }
  }
}

# --- AWS Load Balancer Controller: turns the dashboard's Ingress into one ALB ---

module "aws_lb_controller_pod_identity" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "2.10.0"

  name                            = "${var.cluster_name}-aws-lb-controller"
  use_name_prefix                 = false
  attach_aws_lb_controller_policy = true
  aws_lb_controller_policy_name   = "${var.cluster_name}-aws-lb-controller" # not the generic module name

  associations = {
    controller = {
      cluster_name    = module.eks.cluster_name
      namespace       = "kube-system"
      service_account = "aws-load-balancer-controller"
    }
  }
}

resource "helm_release" "aws_lb_controller" {
  name       = "aws-load-balancer-controller"
  namespace  = "kube-system"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = "3.6.2"

  values = [yamlencode(local.lb_controller_values)]

  # The network too, so that on destroy the controller is removed BEFORE the NAT gateway
  # and the routes: while the namespaces are deleted (kubernetes.tf) it must still reach
  # the AWS API to remove the ALB of a forgotten Ingress.
  depends_on = [module.eks, module.aws_lb_controller_pod_identity, module.vpc, aws_vpc_endpoint.s3]
}

# --- External Secrets: copies each environment's database passwords from Secrets
# Manager into Kubernetes Secrets. With Pod Identity the controller has ONE identity for
# the whole cluster, so that identity may do nothing but assume the per-environment roles
# cryptobot-dev-external-secrets / cryptobot-prod-external-secrets (envs layers).
# Two locks keep dev from reading prod's passwords:
# 1. Kubernetes: deploy jobs cannot create or change SecretStores (kubernetes.tf); the
#    envs layers create one per namespace, with that environment's role and
#    sessionTagsPolicy Simple, so ESO sets esoNamespace and esoStoreKind from the store.
# 2. AWS: each environment role trusts the controller only when esoNamespace names its
#    own namespace and esoStoreKind is SecretStore. ---

data "aws_iam_policy_document" "external_secrets" {
  statement {
    sid       = "AssumeEnvironmentRoles"
    actions   = ["sts:AssumeRole", "sts:TagSession"]
    resources = ["arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:role/${var.cluster_name}-*-external-secrets"]
  }
}

module "external_secrets_pod_identity" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "2.10.0"

  name                    = "${var.cluster_name}-external-secrets"
  use_name_prefix         = false
  attach_custom_policy    = true
  source_policy_documents = [data.aws_iam_policy_document.external_secrets.json]

  associations = {
    controller = {
      cluster_name    = module.eks.cluster_name
      namespace       = "external-secrets"
      service_account = "external-secrets"
    }
  }
}

resource "helm_release" "external_secrets" {
  name             = "external-secrets"
  namespace        = "external-secrets"
  create_namespace = true
  repository       = "https://charts.external-secrets.io"
  chart            = "external-secrets"
  version          = "2.14.0"

  values = [yamlencode(local.external_secrets_values)]

  # After the Load Balancer Controller, so nothing races with its webhooks.
  depends_on = [module.eks, module.external_secrets_pod_identity, helm_release.aws_lb_controller]
}

# --- CloudWatch observability add-on: container logs only (Fluent Bit), into the log
# groups the bootstrap layer created with 7-day retention. Its metrics features are off:
# Prometheus and Grafana cover metrics (Week 4). ---

module "cloudwatch_pod_identity" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "2.10.0"

  name            = "${var.cluster_name}-cloudwatch-agent"
  use_name_prefix = false

  # Only what Fluent Bit needs (the module's ready-made option would add X-Ray too).
  additional_policy_arns = {
    CloudWatchAgentServerPolicy = "arn:${data.aws_partition.current.partition}:iam::aws:policy/CloudWatchAgentServerPolicy"
  }
}

resource "aws_eks_addon" "cloudwatch_observability" {
  cluster_name         = module.eks.cluster_name
  addon_name           = "amazon-cloudwatch-observability"
  addon_version        = "v7.0.1-eksbuild.1"
  configuration_values = jsonencode(local.cloudwatch_addon_config)

  # Fluent Bit runs as this service account.
  pod_identity_association {
    role_arn        = module.cloudwatch_pod_identity.iam_role_arn
    service_account = "cloudwatch-agent"
  }

  lifecycle {
    precondition {
      condition     = contains(data.terraform_remote_state.bootstrap.outputs.container_log_groups, "/aws/containerinsights/${var.cluster_name}/application")
      error_message = "The bootstrap layer has no log groups for the cluster \"${var.cluster_name}\" (apply it first, with the same eks_cluster_name). Otherwise the add-on would create log groups that never expire."
    }
  }

  depends_on = [module.eks, helm_release.aws_lb_controller]
}
