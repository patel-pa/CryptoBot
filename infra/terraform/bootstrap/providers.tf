# Credentials come from the environment (AWS_PROFILE), never from this file. CI runs
# only offline checks (terraform.yml): no AWS credentials there.
provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = "cryptobot"
      Layer     = "bootstrap"
      ManagedBy = "terraform"
    }
  }
}
