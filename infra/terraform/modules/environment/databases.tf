# The two databases of one environment: one zone, encrypted, private. Size, backup days,
# deletion protection and what happens to the data (snapshots.tf) come from the calling
# layer; everything else is the same everywhere.
# TLS is enforced by AWS's default parameter groups (checked 11 Nov 2026: postgres18
# rds.force_ssl = 1, docdb8.0 tls = tls1.2+), so no own parameter groups.

locals {
  name = "cryptobot-${var.env}"

  # The settings that decide cost, safety and versions, in one place (the tests check them).
  # Versions: the same majors as docker compose and the kind overlay (postgres:18, mongo:8.0),
  # and the same in every environment.
  postgres = {
    engine_version          = "18" # major only: AWS picks the minor and applies minor updates
    instance_class          = var.postgres.instance_class
    allocated_storage       = 20 # GB, the gp3 minimum; no storage autoscaling
    backup_retention_period = var.postgres.backup_retention_period
    deletion_protection     = var.deletion_protection
    skip_final_snapshot     = !var.keep_data
    port                    = 5432
    db_name                 = "cryptobot"
    username                = "cryptobot"
  }

  mongo = {
    engine_version          = "8.0.2" # AWS's default 8.0 version on 11 Nov 2026; never auto-upgraded
    instance_class          = var.mongo.instance_class
    instance_count          = 1
    backup_retention_period = var.mongo.backup_retention_period
    deletion_protection     = var.deletion_protection
    skip_final_snapshot     = !var.keep_data
    port                    = 27017
    db_name                 = "cryptobot" # created by the app's first write
    username                = "cryptobot"
  }
}

resource "aws_db_instance" "postgres" {
  identifier     = "${local.name}-postgres"
  engine         = "postgres"
  engine_version = local.postgres.engine_version
  instance_class = local.postgres.instance_class

  allocated_storage = local.postgres.allocated_storage
  storage_type      = "gp3"
  storage_encrypted = true # with the AWS-managed key: no own KMS key to pay for

  db_name             = local.postgres.db_name
  username            = local.postgres.username
  password_wo         = local.passwords["postgres"]
  password_wo_version = var.password_version
  port                = local.postgres.port

  db_subnet_group_name   = aws_db_subnet_group.postgres.name
  vpc_security_group_ids = [aws_security_group.db["postgres"].id]
  publicly_accessible    = false
  multi_az               = false

  backup_retention_period   = local.postgres.backup_retention_period
  deletion_protection       = local.postgres.deletion_protection
  skip_final_snapshot       = local.postgres.skip_final_snapshot
  final_snapshot_identifier = local.final_snapshot["postgres"]
  snapshot_identifier       = local.restore_from["postgres"]
  delete_automated_backups  = true # gone with the database (with keep_data, the final snapshot stays)
  copy_tags_to_snapshot     = true

  auto_minor_version_upgrade = true
  apply_immediately          = true

  # Off: each costs money or creates a log group without retention.
  performance_insights_enabled    = false
  monitoring_interval             = 0
  enabled_cloudwatch_logs_exports = []

  lifecycle {
    # Used only when the database is created. AWS cannot change it later, so Terraform would
    # delete and re-create the running database if a newer snapshot appeared (for example
    # during a restore test): never compare it again.
    ignore_changes = [snapshot_identifier]
  }
}

resource "aws_docdb_cluster" "mongo" {
  cluster_identifier = "${local.name}-mongo"
  engine             = "docdb"
  engine_version     = local.mongo.engine_version

  master_username            = local.mongo.username
  master_password_wo         = local.passwords["mongo"]
  master_password_wo_version = var.password_version
  port                       = local.mongo.port

  db_subnet_group_name   = aws_docdb_subnet_group.mongo.name
  vpc_security_group_ids = [aws_security_group.db["mongo"].id]
  storage_encrypted      = true

  backup_retention_period   = local.mongo.backup_retention_period
  deletion_protection       = local.mongo.deletion_protection
  skip_final_snapshot       = local.mongo.skip_final_snapshot
  final_snapshot_identifier = local.final_snapshot["mongo"]
  snapshot_identifier       = local.restore_from["mongo"]
  apply_immediately         = true

  enabled_cloudwatch_logs_exports = [] # a log group without retention otherwise

  lifecycle {
    ignore_changes = [snapshot_identifier] # as for PostgreSQL above
  }
}

resource "aws_docdb_cluster_instance" "mongo" {
  count = local.mongo.instance_count

  identifier         = "${local.name}-mongo-${count.index + 1}"
  cluster_identifier = aws_docdb_cluster.mongo.id
  instance_class     = local.mongo.instance_class
  apply_immediately  = true
  # (No auto_minor_version_upgrade: DocumentDB never applies minor upgrades on its own.)
}
