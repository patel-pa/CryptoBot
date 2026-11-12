# Outputs of the platform layer (network, cluster, External Secrets controller role), read
# from its state. Read only: this layer can never change the platform layer.
data "terraform_remote_state" "platform" {
  backend = "s3"

  config = {
    bucket = "cryptobot-tfstate-patel-pa"
    key    = "platform/terraform.tfstate"
    region = "eu-central-1"
  }
}

locals {
  # The outputs are missing while the platform layer is destroyed. Then the preconditions
  # (here and in the module's network.tf) stop a normal plan with a clear message; the
  # placeholders below only keep the configuration valid until then. (A destroy plan skips
  # preconditions: see the README for destroying this layer after the cluster is already gone.)
  platform_outputs = ["vpc_id", "private_subnet_ids", "node_security_group_id", "cluster_name", "external_secrets_controller_role_arn"]
  platform_applied = alltrue([
    for output in local.platform_outputs : can(data.terraform_remote_state.platform.outputs[output])
  ])

  platform = {
    applied                              = local.platform_applied
    vpc_id                               = try(data.terraform_remote_state.platform.outputs.vpc_id, "platform-not-applied")
    private_subnet_ids                   = try(data.terraform_remote_state.platform.outputs.private_subnet_ids, [])
    node_security_group_id               = try(data.terraform_remote_state.platform.outputs.node_security_group_id, "platform-not-applied")
    cluster_name                         = try(data.terraform_remote_state.platform.outputs.cluster_name, "platform-not-applied")
    external_secrets_controller_role_arn = try(data.terraform_remote_state.platform.outputs.external_secrets_controller_role_arn, "platform-not-applied")
  }
}

# Address and certificate of the cluster, for the kubernetes provider (providers.tf).
data "aws_eks_cluster" "this" {
  name = local.platform.cluster_name

  lifecycle {
    precondition {
      condition     = local.platform_applied
      error_message = "The platform layer's state has no outputs: apply the platform layer first (and destroy this layer before the platform)."
    }
  }
}

# The model bucket of the bootstrap layer (kept forever; one prefix per environment).
data "terraform_remote_state" "bootstrap" {
  backend = "s3"

  config = {
    bucket = "cryptobot-tfstate-patel-pa"
    key    = "bootstrap/terraform.tfstate"
    region = "eu-central-1"
  }
}
