# Outputs of the bootstrap layer (CI role ARNs, log group names), read from its state.
# Read only: this layer can never change the bootstrap layer.
data "terraform_remote_state" "bootstrap" {
  backend = "s3"

  config = {
    bucket = "cryptobot-tfstate-patel-pa"
    key    = "bootstrap/terraform.tfstate"
    region = "eu-central-1"
  }
}

locals {
  ci_role_arns = data.terraform_remote_state.bootstrap.outputs.ci_role_arns
}

data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}
