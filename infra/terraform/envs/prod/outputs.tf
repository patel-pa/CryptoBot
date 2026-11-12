# The module's outputs, passed through so `terraform output <name>` works in this folder.

output "secret_names" {
  description = "Secrets Manager names the prod overlay's ExternalSecrets read (credentials and endpoint per database)."
  value       = module.environment.secret_names
}

output "secret_store_name" {
  description = "SecretStore in the prod namespace that the overlay's ExternalSecrets refer to."
  value       = module.environment.secret_store_name
}

output "external_secrets_role_arn" {
  description = "Role the External Secrets controller assumes for the prod namespace."
  value       = module.environment.external_secrets_role_arn
}

output "model_s3" {
  description = "MODEL_S3_BUCKET and MODEL_S3_KEY for the prod overlay."
  value       = module.environment.model_s3
}

output "pod_role_arns" {
  description = "Pod Identity roles of the prod service accounts (api reads the model, retrain writes it)."
  value       = module.environment.pod_role_arns
}

output "postgres_identifier" {
  description = "RDS instance of prod (for the AWS console and CLI)."
  value       = module.environment.postgres_identifier
}

output "mongo_cluster_identifier" {
  description = "DocumentDB cluster of prod (for the AWS console and CLI)."
  value       = module.environment.mongo_cluster_identifier
}

output "snapshots" {
  description = "restore_from: the snapshot each database is created from in this run (null = starts empty, or already exists). final_on_destroy: the name of its final snapshot on destroy (set by teardown step 1; null = not yet)."
  value       = module.environment.snapshots
}
