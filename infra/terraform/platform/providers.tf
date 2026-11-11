# Credentials come from the environment, never from this file:
# AWS_PROFILE on a laptop, OIDC role credentials in GitHub Actions.
provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = "cryptobot"
      Layer     = "platform"
      ManagedBy = "terraform"
    }
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
