output "state_bucket" {
  description = "S3 bucket holding the Terraform state of every layer (backend \"s3\" bucket)."
  value       = aws_s3_bucket.this["tfstate"].id
}
