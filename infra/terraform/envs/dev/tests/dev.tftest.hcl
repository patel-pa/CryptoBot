# Offline checks of the dev layer against mock providers: no AWS account, no credentials.
# Run: terraform init -backend=false, then terraform test (Terraform 1.17+).
# What the databases, secrets and roles look like is tested in the module
# (infra/terraform/modules/environment/tests); here only that dev passes dev's values in
# and wires the platform's outputs through.

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

run "dev_passes_its_values_to_the_module" {
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
      postgres = { instance_class = "db.t4g.micro", backup_retention_period = 1, deletion_protection = false }
      mongo    = { instance_class = "db.t4g.medium", backup_retention_period = 1, deletion_protection = false }
    }
    error_message = "dev must get the smallest sizes, 1 day of backups and no deletion protection."
  }

  assert {
    condition = alltrue([
      for db in ["postgres", "mongo"] :
      module.environment.snapshots.restore_from[db] == null && module.environment.snapshots.final_on_destroy[db] == null
    ])
    error_message = "dev keeps no data (keep_data = false): no restore, no final snapshot."
  }

  assert {
    condition = (
      output.secret_names == {
        postgres            = "cryptobot/dev/postgres"
        mongo               = "cryptobot/dev/mongo"
        "postgres-endpoint" = "cryptobot/dev/postgres-endpoint"
        "mongo-endpoint"    = "cryptobot/dev/mongo-endpoint"
      } &&
      output.secret_store_name == "aws-secrets-manager" &&
      output.model_s3 == { bucket = "cryptobot-models-test", key = "dev/model.pkl" } &&
      output.postgres_identifier == "cryptobot-dev-postgres" &&
      output.mongo_cluster_identifier == "cryptobot-dev-mongo"
    )
    error_message = "The dev overlay relies on these names: cryptobot/dev/* secrets, the store aws-secrets-manager, dev/model.pkl."
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
