output "secret_names" {
  description = "Secrets Manager names the overlay's ExternalSecrets read (credentials and endpoint per database)."
  value = merge(
    { for db, secret in aws_secretsmanager_secret.credentials : db => secret.name },
    { for db, secret in aws_secretsmanager_secret.endpoint : "${db}-endpoint" => secret.name },
  )
}

output "secret_store_name" {
  description = "SecretStore in this environment's namespace that the overlay's ExternalSecrets refer to."
  value       = local.secret_store_name
}

output "external_secrets_role_arn" {
  description = "Role the External Secrets controller assumes for this environment's namespace."
  value       = aws_iam_role.external_secrets.arn
}

output "model_s3" {
  description = "MODEL_S3_BUCKET and MODEL_S3_KEY for the overlay."
  value = {
    bucket = var.model_bucket
    key    = "${var.env}/model.pkl"
  }
}

output "pod_role_arns" {
  description = "Pod Identity roles of the service accounts (api reads the model, retrain writes it)."
  value       = { for sa, role in aws_iam_role.pod : sa => role.arn }
}

output "postgres_identifier" {
  description = "RDS instance (for the AWS console and CLI)."
  value       = aws_db_instance.postgres.identifier
}

output "mongo_cluster_identifier" {
  description = "DocumentDB cluster (for the AWS console and CLI)."
  value       = aws_docdb_cluster.mongo.cluster_identifier
}

output "databases" {
  description = "Size, backup days and deletion protection of both databases, as created."
  value = {
    postgres = {
      instance_class          = aws_db_instance.postgres.instance_class
      backup_retention_period = aws_db_instance.postgres.backup_retention_period
      deletion_protection     = aws_db_instance.postgres.deletion_protection
    }
    mongo = {
      instance_class          = one(distinct(aws_docdb_cluster_instance.mongo[*].instance_class))
      backup_retention_period = aws_docdb_cluster.mongo.backup_retention_period
      deletion_protection     = aws_docdb_cluster.mongo.deletion_protection
    }
  }
}

output "snapshots" {
  description = "restore_from: the snapshot each database is created from in this run (null = starts empty, or already exists). final_on_destroy: the name its final snapshot gets on destroy (set by teardown step 1; null = none)."
  value = {
    restore_from     = local.restore_from
    final_on_destroy = local.final_snapshot
  }
}
