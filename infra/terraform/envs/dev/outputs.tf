output "secret_names" {
  description = "Secrets Manager names the dev overlay's ExternalSecrets read (credentials and endpoint per database)."
  value = merge(
    { for db, secret in aws_secretsmanager_secret.credentials : db => secret.name },
    { for db, secret in aws_secretsmanager_secret.endpoint : "${db}-endpoint" => secret.name },
  )
}

output "postgres_identifier" {
  description = "RDS instance of dev (for the AWS console and CLI)."
  value       = aws_db_instance.postgres.identifier
}

output "mongo_cluster_identifier" {
  description = "DocumentDB cluster of dev (for the AWS console and CLI)."
  value       = aws_docdb_cluster.mongo.cluster_identifier
}
