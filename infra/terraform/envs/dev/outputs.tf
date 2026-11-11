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

output "model_s3" {
  description = "MODEL_S3_BUCKET and MODEL_S3_KEY for the dev overlay."
  value = {
    bucket = local.model_bucket
    key    = "${local.env}/model.pkl"
  }
}

output "pod_role_arns" {
  description = "Pod Identity roles of the dev service accounts (api reads the model, retrain writes it)."
  value       = { for sa, role in aws_iam_role.pod : sa => role.arn }
}

output "postgres_identifier" {
  description = "RDS instance of dev (for the AWS console and CLI)."
  value       = aws_db_instance.postgres.identifier
}

output "mongo_cluster_identifier" {
  description = "DocumentDB cluster of dev (for the AWS console and CLI)."
  value       = aws_docdb_cluster.mongo.cluster_identifier
}
