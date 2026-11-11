# Credentials come from the environment, never from this file:
# AWS_PROFILE on a laptop, OIDC role credentials in GitHub Actions.
provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project     = "cryptobot"
      Layer       = "envs"
      Environment = local.env
      ManagedBy   = "terraform"
    }
  }
}

# Talks to the platform's cluster with a short-lived token from the same AWS credentials
# (the identity that applied the platform is cluster admin).
provider "kubernetes" {
  host                   = data.aws_eks_cluster.this.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.this.certificate_authority[0].data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", local.platform.cluster_name, "--region", var.region]
  }
}
