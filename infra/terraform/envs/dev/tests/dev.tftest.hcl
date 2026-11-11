# Offline checks of the dev environment layer against a mock AWS provider: no AWS account,
# no credentials needed. Run: terraform init -backend=false, then terraform test
# (Terraform 1.17+: older versions cannot mock ephemeral resources).

mock_provider "aws" {
  # What reading a credentials secret back returns in the mock apply run below. Plan runs
  # never open it: its secret ID is unknown until the secret exists.
  mock_ephemeral "aws_secretsmanager_secret_version" {
    defaults = {
      secret_string = "{\"username\":\"cryptobot\",\"password\":\"mockpassword\"}"
    }
  }
}

# What the platform layer's state would provide.
override_data {
  target = data.terraform_remote_state.platform
  values = {
    outputs = {
      vpc_id                 = "vpc-platform"
      private_subnet_ids     = ["subnet-private-a", "subnet-private-b"]
      node_security_group_id = "sg-nodes"
    }
  }
}

run "databases_are_small_private_encrypted_and_pinned" {
  command = plan

  assert {
    condition = local.postgres == {
      engine_version          = "18"
      instance_class          = "db.t4g.micro"
      allocated_storage       = 20
      backup_retention_period = 1
      deletion_protection     = false
      skip_final_snapshot     = true
      port                    = 5432
      db_name                 = "cryptobot"
      username                = "cryptobot"
    }
    error_message = "PostgreSQL settings changed: version (must match docker compose), size, backups or snapshot behaviour."
  }

  assert {
    condition = local.mongo == {
      engine_version          = "8.0.2"
      instance_class          = "db.t4g.medium"
      instance_count          = 1
      backup_retention_period = 1
      deletion_protection     = false
      skip_final_snapshot     = true
      port                    = 27017
      db_name                 = "cryptobot"
      username                = "cryptobot"
    }
    error_message = "DocumentDB settings changed: version (must match docker compose), size, instance count, backups or snapshot behaviour."
  }

  assert {
    condition = (
      aws_db_instance.postgres.engine == "postgres" &&
      aws_db_instance.postgres.engine_version == "18" &&
      aws_db_instance.postgres.instance_class == "db.t4g.micro" &&
      aws_db_instance.postgres.storage_type == "gp3" &&
      aws_db_instance.postgres.storage_encrypted == true &&
      aws_db_instance.postgres.publicly_accessible == false &&
      aws_db_instance.postgres.multi_az == false &&
      aws_db_instance.postgres.backup_retention_period == 1 &&
      aws_db_instance.postgres.deletion_protection == false &&
      aws_db_instance.postgres.skip_final_snapshot == true
    )
    error_message = "RDS must be the small, private, encrypted, single-zone PostgreSQL 18 instance of dev."
  }

  assert {
    condition = (
      aws_db_instance.postgres.performance_insights_enabled == false &&
      aws_db_instance.postgres.monitoring_interval == 0 &&
      length(aws_db_instance.postgres.enabled_cloudwatch_logs_exports) == 0 &&
      length(aws_docdb_cluster.mongo.enabled_cloudwatch_logs_exports) == 0
    )
    error_message = "No Performance Insights, enhanced monitoring or log exports (cost, and log groups that never expire)."
  }

  assert {
    condition = (
      aws_docdb_cluster.mongo.engine == "docdb" &&
      aws_docdb_cluster.mongo.engine_version == "8.0.2" &&
      aws_docdb_cluster.mongo.storage_encrypted == true &&
      aws_docdb_cluster.mongo.backup_retention_period == 1 &&
      aws_docdb_cluster.mongo.deletion_protection == false &&
      aws_docdb_cluster.mongo.skip_final_snapshot == true &&
      length(aws_docdb_cluster_instance.mongo) == 1 &&
      aws_docdb_cluster_instance.mongo[0].instance_class == "db.t4g.medium"
    )
    error_message = "DocumentDB must be one small, encrypted 8.0 instance."
  }
}

run "passwords_never_reach_the_state" {
  command = plan

  # (Write-only arguments always read as null, so only the plain arguments and the
  # versions are checked; removing a write-only argument fails validation anyway.)
  assert {
    condition = (
      aws_db_instance.postgres.password == null &&
      aws_db_instance.postgres.password_wo_version == 1 &&
      aws_docdb_cluster.mongo.master_password == null &&
      aws_docdb_cluster.mongo.master_password_wo_version == 1
    )
    error_message = "The databases must get their passwords only through write-only arguments."
  }

  assert {
    condition = alltrue([
      for version in aws_secretsmanager_secret_version.credentials :
      version.secret_string == null && version.secret_string_wo_version == 1
    ]) && length(aws_secretsmanager_secret_version.credentials) == 2
    error_message = "The credentials secrets must be written only through write-only arguments."
  }
}

run "secrets_have_fixed_names_only_dev_can_read" {
  command = plan

  assert {
    condition = merge(
      { for db, secret in aws_secretsmanager_secret.credentials : db => secret.name },
      { for db, secret in aws_secretsmanager_secret.endpoint : "${db}-endpoint" => secret.name },
      ) == {
      postgres            = "cryptobot/dev/postgres"
      mongo               = "cryptobot/dev/mongo"
      "postgres-endpoint" = "cryptobot/dev/postgres-endpoint"
      "mongo-endpoint"    = "cryptobot/dev/mongo-endpoint"
    }
    error_message = "The secrets must have the fixed names under cryptobot/dev/ (the overlay and the IAM policies use them)."
  }

  assert {
    condition = alltrue([
      for secret in concat(values(aws_secretsmanager_secret.credentials), values(aws_secretsmanager_secret.endpoint)) :
      secret.recovery_window_in_days == 0
    ])
    error_message = "Dev secrets must be deleted at once on destroy, or the next session cannot create them again."
  }
}

run "only_the_nodes_reach_the_databases" {
  command = plan

  assert {
    condition = {
      for db, rule in aws_vpc_security_group_ingress_rule.from_nodes :
      db => "${rule.referenced_security_group_id} ${rule.ip_protocol} ${rule.from_port}-${rule.to_port} ${rule.cidr_ipv4 == null && rule.cidr_ipv6 == null}"
      } == {
      postgres = "sg-nodes tcp 5432-5432 true"
      mongo    = "sg-nodes tcp 27017-27017 true"
    }
    error_message = "Each database must accept its own port from the nodes' security group only, never from an address range."
  }

  assert {
    condition = alltrue([
      for sg in aws_security_group.db : sg.vpc_id == "vpc-platform" && length(sg.egress) == 0
    ])
    error_message = "The database security groups belong in the platform's VPC and have no outbound rules."
  }

  assert {
    condition = (
      tolist(aws_db_subnet_group.postgres.subnet_ids) == tolist(["subnet-private-a", "subnet-private-b"]) &&
      tolist(aws_docdb_subnet_group.mongo.subnet_ids) == tolist(["subnet-private-a", "subnet-private-b"])
    )
    error_message = "The databases belong in the platform's private subnets."
  }

  assert {
    condition = (
      aws_db_instance.postgres.db_subnet_group_name == "cryptobot-dev-postgres" &&
      aws_docdb_cluster.mongo.db_subnet_group_name == "cryptobot-dev-mongo"
    )
    error_message = "Each database must use its own subnet group (the private subnets)."
  }
}

# IDs and host names exist only after an apply. The mock apply invents them, which is
# enough to check that each database is wired to its own security group and endpoint.
run "each_database_gets_its_own_security_group_and_endpoint" {
  command = apply

  assert {
    condition = alltrue([
      for db in ["postgres", "mongo"] :
      aws_vpc_security_group_ingress_rule.from_nodes[db].security_group_id == aws_security_group.db[db].id
    ])
    error_message = "Each database port must be opened on that database's own security group."
  }

  assert {
    condition = (
      aws_db_instance.postgres.vpc_security_group_ids == toset([aws_security_group.db["postgres"].id]) &&
      aws_docdb_cluster.mongo.vpc_security_group_ids == toset([aws_security_group.db["mongo"].id])
    )
    error_message = "Each database must sit in its own security group, and only there."
  }

  assert {
    condition = (
      jsondecode(aws_secretsmanager_secret_version.endpoint["postgres"].secret_string) == { host = aws_db_instance.postgres.address, port = 5432, dbname = "cryptobot" } &&
      jsondecode(aws_secretsmanager_secret_version.endpoint["mongo"].secret_string) == { host = aws_docdb_cluster.mongo.endpoint, port = 27017, dbname = "cryptobot" } &&
      aws_secretsmanager_secret_version.endpoint["postgres"].secret_id == aws_secretsmanager_secret.endpoint["postgres"].id &&
      aws_secretsmanager_secret_version.endpoint["mongo"].secret_id == aws_secretsmanager_secret.endpoint["mongo"].id
    )
    error_message = "Each endpoint secret must hold its own database's host name (without the port), port and database name."
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

  expect_failures = [aws_db_subnet_group.postgres, aws_docdb_subnet_group.mongo]
}
