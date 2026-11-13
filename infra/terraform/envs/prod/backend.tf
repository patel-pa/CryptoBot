# State in the bucket of the bootstrap layer, under its own key: destroying this
# layer can never touch another layer's state.
terraform {
  backend "s3" {
    bucket       = "cryptobot-tfstate-patel-pa"
    key          = "envs/prod/terraform.tfstate"
    region       = "eu-central-1"
    encrypt      = true
    use_lockfile = true
  }
}
