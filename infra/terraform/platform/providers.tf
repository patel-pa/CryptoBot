locals {
  # On every AWS resource Terraform creates here. default_tags cannot reach what a launch
  # template starts (node servers, their disks, primary network cards), so eks.tf passes
  # them on too: changing them makes a new launch template version, which replaces the nodes.
  tags = {
    Project   = "cryptobot"
    Layer     = "platform"
    ManagedBy = "terraform"
  }
}

# Credentials come from the environment, never from this file:
# AWS_PROFILE on a laptop, OIDC role credentials in GitHub Actions.
provider "aws" {
  region = var.region

  default_tags {
    tags = local.tags
  }
}

# Both talk to the new cluster with a short-lived token from the same AWS credentials.
provider "helm" {
  kubernetes = {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.region]
    }
  }
}

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.region]
  }
}
