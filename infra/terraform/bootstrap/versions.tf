terraform {
  # 1.10+ for S3 state locking without DynamoDB (use_lockfile in backend.tf); 1.14+
  # because older `terraform test` versions refuse to clean up the ECR repository
  # (prevent_destroy) at the end of the test that applies the CI roles against a mock.
  required_version = ">= 1.14, < 2.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}
