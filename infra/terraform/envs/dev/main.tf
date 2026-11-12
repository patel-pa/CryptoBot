# The dev environment: the shared module (infra/terraform/modules/environment) with dev's
# values. Dev holds nothing that cannot be reloaded from Binance, so: the smallest sizes,
# 1 day of backups, no deletion protection, no snapshots. Every session starts empty; the
# ingest job reloads the last day.

locals {
  env = "dev"
}

module "environment" {
  source = "../../modules/environment"

  env          = local.env
  region       = var.region
  platform     = local.platform
  model_bucket = data.terraform_remote_state.bootstrap.outputs.model_bucket

  postgres = {
    instance_class          = "db.t4g.micro"
    backup_retention_period = 1 # days
  }

  mongo = {
    instance_class          = "db.t4g.medium" # the smallest DocumentDB offers
    backup_retention_period = 1
  }

  deletion_protection = false
  keep_data           = false # every create starts empty

  # Raise by one to give both dev databases new passwords (module README, "New passwords").
  password_version = 1
}
