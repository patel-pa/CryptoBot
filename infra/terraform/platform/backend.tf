# State in the bucket of the bootstrap layer, under its own key: destroying this
# layer can never touch the bootstrap layer's state.
terraform {
  backend "s3" {
    bucket       = "cryptobot-tfstate-patel-pa"
    key          = "platform/terraform.tfstate"
    region       = "eu-central-1"
    encrypt      = true
    use_lockfile = true
  }
}
