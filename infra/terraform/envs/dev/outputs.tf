output "secret_names" {
  description = "Secrets Manager names the dev overlay's ExternalSecrets read (credentials and endpoint per database)."
  value = merge(
    { for db, secret in aws_secretsmanager_secret.credentials : db => secret.name },
    { for db, secret in aws_secretsmanager_secret.endpoint : "${db}-endpoint" => secret.name },
  )
}

output "secret_store_name" {
  description = "SecretStore in the dev namespace that the overlay's ExternalSecrets refer to."
  value       = local.secret_store_name
}

output "external_secrets_role_arn" {
  description = "Role the External Secrets controller assumes for the dev namespace."
  value       = aws_iam_role.external_secrets.arn
}

output "postgres_identifier" {
  description = "RDS instance of dev (for the AWS console and CLI)."
  value       = aws_db_instance.postgres.identifier
}

output "mongo_cluster_identifier" {
  description = "DocumentDB cluster of dev (for the AWS console and CLI)."
  value       = aws_docdb_cluster.mongo.cluster_identifier
}
