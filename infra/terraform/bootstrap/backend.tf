# The state of this layer lives in the bucket this layer creates (s3_buckets.tf).
# On the very first run that bucket does not exist yet: see README.md, "First run".
terraform {
  backend "s3" {
    bucket       = "cryptobot-tfstate-patel-pa" # = local.buckets.tfstate
    key          = "bootstrap/terraform.tfstate"
    region       = "eu-central-1"
    encrypt      = true
    use_lockfile = true # lock = a small .tflock object next to the state
  }
}
