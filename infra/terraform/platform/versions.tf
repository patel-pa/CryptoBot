terraform {
  # The same minimum as the bootstrap layer: 1.14+ for `terraform test`, 1.14.9+ when
  # the credentials come from `aws login`.
  required_version = ">= 1.14, < 2.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}
