# The prod environment: the shared module (infra/terraform/modules/environment) with prod's
# values. Prod keeps its data across sessions: deletion protection, 7 days of backups, a
# final snapshot on destroy and a restore from the newest one on create (README, "One work
# session": the teardown there has two steps).

locals {
  env = "prod"
}

module "environment" {
  source = "../../modules/environment"

  env          = local.env
  region       = var.region
  platform     = local.platform
  model_bucket = data.terraform_remote_state.bootstrap.outputs.model_bucket

  postgres = {
    instance_class          = "db.t4g.small" # 2 GB RAM; dev runs db.t4g.micro
    backup_retention_period = 7              # days
  }

  mongo = {
    instance_class          = "db.t4g.medium" # the smallest DocumentDB offers
    backup_retention_period = 7
  }

  keep_data           = true
  deletion_protection = var.deletion_protection
  first_create        = var.first_create
  restore_snapshots   = var.restore_snapshots

  # Raise by one to give both prod databases new passwords (module README, "New passwords").
  password_version = 1
}
