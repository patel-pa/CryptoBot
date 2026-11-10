terraform {
  # 1.10+ for S3 state locking without DynamoDB (use_lockfile in backend.tf).
  required_version = ">= 1.10, < 2.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}
