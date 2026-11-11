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
