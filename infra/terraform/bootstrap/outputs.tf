output "state_bucket" {
  description = "S3 bucket holding the Terraform state of every layer (backend \"s3\" bucket)."
  value       = aws_s3_bucket.this["tfstate"].id
}

output "model_bucket" {
  description = "S3 bucket for the trained model (MODEL_S3_BUCKET); keys dev/model.pkl, prod/model.pkl."
  value       = aws_s3_bucket.this["models"].id
}

output "ecr_repository_url" {
  description = "Image name without tag; images are tagged with the git commit SHA."
  value       = aws_ecr_repository.app.repository_url
}

output "ci_role_arns" {
  description = "IAM role per CI job (build, deploy-dev, deploy-prod) for the CD workflow to assume."
  value       = { for name, role in aws_iam_role.ci : name => role.arn }
}
