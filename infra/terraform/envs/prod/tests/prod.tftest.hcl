# Offline checks of the prod layer against mock providers: no AWS account, no credentials.
# Run: terraform init -backend=false, then terraform test (Terraform 1.17+).
# What the databases, secrets, roles and snapshots do is tested in the module
# (infra/terraform/modules/environment/tests); here only that prod passes prod's values in
# and that the command-line switches reach the module.

mock_provider "aws" {
  mock_ephemeral "aws_secretsmanager_secret_version" {
    defaults = {
      secret_string = "{\"username\":\"cryptobot\",\"password\":\"mockpassword\"}"
    }
  }

  # IAM roles accept only valid JSON policies.
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":\"sts:AssumeRole\",\"Principal\":{\"Service\":\"pods.eks.amazonaws.com\"}}]}"
    }
  }

  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "123456789012"
    }
  }

  mock_data "aws_partition" {
    defaults = {
      partition = "aws"
    }
  }

  # A create in a later session: the databases do not exist, the newest final snapshots do.
  mock_data "aws_db_instances" {
    defaults = {
      instance_identifiers = []
    }
  }

  mock_data "aws_rds_clusters" {
    defaults = {
      cluster_identifiers = []
    }
  }

  mock_data "aws_db_snapshot" {
    defaults = {
      id = "cryptobot-prod-postgres-final-2026-11-20-1730"
    }
  }

  mock_data "aws_db_cluster_snapshot" {
    defaults = {
      id = "cryptobot-prod-mongo-final-2026-11-20-1730"
    }
  }
}

mock_provider "kubernetes" {}

# What the bootstrap and platform layers' states would provide.
override_data {
  target = data.terraform_remote_state.bootstrap
  values = {
    outputs = {
      model_bucket = "cryptobot-models-test"
    }
  }
}

override_data {
  target = data.terraform_remote_state.platform
  values = {
    outputs = {
      vpc_id                               = "vpc-platform"
      private_subnet_ids                   = ["subnet-private-a", "subnet-private-b"]
      node_security_group_id               = "sg-nodes"
      cluster_name                         = "cryptobot"
      external_secrets_controller_role_arn = "arn:aws:iam::123456789012:role/cryptobot-external-secrets"
    }
  }
}

run "prod_passes_its_values_to_the_module" {
  command = plan

  assert {
    condition = local.platform == {
      applied                              = true
      vpc_id                               = "vpc-platform"
      private_subnet_ids                   = ["subnet-private-a", "subnet-private-b"]
      node_security_group_id               = "sg-nodes"
      cluster_name                         = "cryptobot"
      external_secrets_controller_role_arn = "arn:aws:iam::123456789012:role/cryptobot-external-secrets"
    }
    error_message = "Each platform output must reach the module under its own name."
  }

  assert {
    condition = module.environment.databases == {
      postgres = { instance_class = "db.t4g.small", backup_retention_period = 7, deletion_protection = true }
      mongo    = { instance_class = "db.t4g.medium", backup_retention_period = 7, deletion_protection = true }
    }
    error_message = "prod must get db.t4g.small / db.t4g.medium, 7 days of backups and deletion protection."
  }

  assert {
    condition = (
      output.secret_names == {
        postgres            = "cryptobot/prod/postgres"
        mongo               = "cryptobot/prod/mongo"
        "postgres-endpoint" = "cryptobot/prod/postgres-endpoint"
        "mongo-endpoint"    = "cryptobot/prod/mongo-endpoint"
      } &&
      output.secret_store_name == "aws-secrets-manager" &&
      output.model_s3 == { bucket = "cryptobot-models-test", key = "prod/model.pkl" } &&
      output.postgres_identifier == "cryptobot-prod-postgres" &&
      output.mongo_cluster_identifier == "cryptobot-prod-mongo"
    )
    error_message = "The prod overlay relies on these names: cryptobot/prod/* secrets, the store aws-secrets-manager, prod/model.pkl."
  }

  assert {
    condition = (
      output.snapshots.restore_from.postgres == "cryptobot-prod-postgres-final-2026-11-20-1730" &&
      output.snapshots.restore_from.mongo == "cryptobot-prod-mongo-final-2026-11-20-1730" &&
      output.snapshots.final_on_destroy.postgres == null &&
      output.snapshots.final_on_destroy.mongo == null
    )
    error_message = "A plain plan restores the newest final snapshots and names no final snapshot yet."
  }
}

run "first_create_reaches_the_module" {
  command = plan

  variables {
    first_create = true
  }

  assert {
    condition     = output.snapshots.restore_from.postgres == null && output.snapshots.restore_from.mongo == null
    error_message = "-var first_create=true must create empty databases."
  }
}

run "restore_snapshots_reach_the_module" {
  command = plan

  variables {
    restore_snapshots = { postgres = "cryptobot-prod-postgres-final-2026-11-01-0900" }
  }

  assert {
    condition = (
      output.snapshots.restore_from.postgres == "cryptobot-prod-postgres-final-2026-11-01-0900" &&
      output.snapshots.restore_from.mongo == "cryptobot-prod-mongo-final-2026-11-20-1730"
    )
    error_message = "A snapshot named on the command line must replace the newest one for that database only."
  }
}

run "teardown_step_1_reaches_the_module" {
  command = plan

  variables {
    deletion_protection = false
  }

  assert {
    condition = (
      module.environment.databases.postgres.deletion_protection == false &&
      module.environment.databases.mongo.deletion_protection == false &&
      startswith(output.snapshots.final_on_destroy.postgres, "cryptobot-prod-postgres-final-") &&
      startswith(output.snapshots.final_on_destroy.mongo, "cryptobot-prod-mongo-final-")
    )
    error_message = "-var deletion_protection=false must turn protection off and name both final snapshots."
  }
}

run "plan_stops_while_the_platform_is_destroyed" {
  command = plan

  override_data {
    target = data.terraform_remote_state.platform
    values = {
      outputs = {}
    }
  }

  # The module stops too (its subnet groups; tested in the module's own tests), but a test
  # can only expect failures of this layer's objects: the module is left out of this run.
  override_module {
    target = module.environment
  }

  expect_failures = [data.aws_eks_cluster.this]

  assert {
    condition     = local.platform.applied == false
    error_message = "Without the platform's outputs, the module must be told the platform is not applied (its own check)."
  }
}
