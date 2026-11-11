# The Kubernetes cluster: AWS runs the control plane, two t3.medium nodes run the pods.

locals {
  # The settings that decide cost and security, in one place (the tests check them).
  cluster = {
    kubernetes_version = "1.37"
    support_type       = "STANDARD" # never slips into paid extended support (6x the price)

    # Public so GitHub-hosted runners can deploy; every call still needs IAM credentials.
    endpoint_public_access  = true
    endpoint_private_access = true

    # Who may use the cluster: access entries only (no aws-auth ConfigMap).
    authentication_mode = "API"

    # No control-plane logs: not required, and their log group would never expire.
    enabled_log_types = []

    instance_types = ["t3.medium"]
    node_count     = 2
  }
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "21.29.0"

  name               = var.cluster_name
  kubernetes_version = local.cluster.kubernetes_version
  upgrade_policy = {
    support_type = local.cluster.support_type
  }

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  endpoint_public_access  = local.cluster.endpoint_public_access
  endpoint_private_access = local.cluster.endpoint_private_access

  # The identity that applies this layer becomes cluster admin.
  authentication_mode                      = local.cluster.authentication_mode
  enable_cluster_creator_admin_permissions = true

  # Pods get AWS rights through EKS Pod Identity, so no IRSA OIDC provider is created.
  enable_irsa = false

  # EKS already encrypts Kubernetes data with an AWS-owned key; an own KMS key would
  # cost $1 per month and outlive every teardown.
  create_kms_key    = false
  encryption_config = null

  enabled_log_types           = local.cluster.enabled_log_types
  create_cloudwatch_log_group = false

  # Versions recommended by AWS for Kubernetes 1.37 (aws eks describe-addon-versions).
  # The network add-ons must run before the nodes start.
  addons = {
    vpc-cni = {
      addon_version  = "v1.22.4-eksbuild.14"
      before_compute = true
    }
    eks-pod-identity-agent = {
      addon_version  = "v1.4.1-eksbuild.3"
      before_compute = true
    }
    kube-proxy = {
      addon_version = "v1.37.0-eksbuild.39"
    }
    coredns = {
      addon_version = "v1.14.7-eksbuild.35"
    }
  }

  eks_managed_node_groups = {
    default = {
      ami_type       = "AL2023_x86_64_STANDARD"
      instance_types = local.cluster.instance_types
      min_size       = local.cluster.node_count
      max_size       = local.cluster.node_count
      desired_size   = local.cluster.node_count
    }
  }

  # The CD job of each environment signs in with its CI role (bootstrap layer) and is
  # mapped to a Kubernetes group; kubernetes.tf allows that group to change only its
  # own namespace.
  access_entries = {
    for env in ["dev", "prod"] : "deploy-${env}" => {
      principal_arn     = local.ci_role_arns["deploy-${env}"]
      kubernetes_groups = ["cryptobot-deploy-${env}"]
    }
  }
}
