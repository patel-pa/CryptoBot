terraform {
  # 1.17+: the tests mock an ephemeral resource (`mock_ephemeral`), and `terraform init`
  # already reads the test files, so older versions could not even initialise this layer.
  required_version = ">= 1.17, < 2.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.0"
    }
  }
}
