# Outputs of the platform layer (VPC, private subnets, the nodes' security group), read
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
  # The outputs are missing while the platform layer is destroyed. Then the subnet groups'
  # preconditions (network.tf) stop the plan with a clear message; the placeholders below
  # only keep the configuration valid until then and can never reach AWS.
  platform_applied = alltrue([
    for output in ["vpc_id", "private_subnet_ids", "node_security_group_id"] :
    can(data.terraform_remote_state.platform.outputs[output])
  ])

  platform = {
    vpc_id                 = try(data.terraform_remote_state.platform.outputs.vpc_id, "platform-not-applied")
    private_subnet_ids     = try(data.terraform_remote_state.platform.outputs.private_subnet_ids, [])
    node_security_group_id = try(data.terraform_remote_state.platform.outputs.node_security_group_id, "platform-not-applied")
  }
}
