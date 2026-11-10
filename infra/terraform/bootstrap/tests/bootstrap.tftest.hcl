# Offline checks of the bootstrap layer against a mock AWS provider: no AWS account
# or credentials needed. Run: terraform init -backend=false, then terraform test.

mock_provider "aws" {}

run "every_bucket_gets_every_protection" {
  command = plan

  assert {
    condition = alltrue([
      for names in [
        keys(aws_s3_bucket_versioning.this),
        keys(aws_s3_bucket_server_side_encryption_configuration.this),
        keys(aws_s3_bucket_public_access_block.this),
        keys(aws_s3_bucket_ownership_controls.this),
        keys(aws_s3_bucket_policy.this),
        keys(aws_s3_bucket_lifecycle_configuration.this),
      ] : toset(names) == toset(["tfstate", "models"])
    ])
    error_message = "Each protection must exist once for the tfstate and the models bucket."
  }

  assert {
    condition     = alltrue([for v in aws_s3_bucket_versioning.this : v.versioning_configuration[0].status == "Enabled"])
    error_message = "Versioning must be enabled on every bucket."
  }

  assert {
    condition = alltrue([for b in aws_s3_bucket_public_access_block.this :
      b.block_public_acls && b.block_public_policy && b.ignore_public_acls && b.restrict_public_buckets
    ])
    error_message = "Public access must be fully blocked on every bucket."
  }

  assert {
    condition     = alltrue([for o in aws_s3_bucket_ownership_controls.this : o.rule[0].object_ownership == "BucketOwnerEnforced"])
    error_message = "ACLs must stay disabled (BucketOwnerEnforced) on every bucket."
  }

  assert {
    condition = alltrue([for d in data.aws_iam_policy_document.https_only :
      d.statement[0].effect == "Deny" && d.statement[0].actions == toset(["s3:*"]) &&
      toset([for c in d.statement[0].condition : "${c.test} ${c.variable} ${join(",", c.values)}"]) == toset(["Bool aws:SecureTransport false"])
    ])
    error_message = "Every bucket policy must deny requests that do not use HTTPS."
  }

  assert {
    condition     = aws_s3_bucket.this["tfstate"].bucket == "cryptobot-tfstate-patel-pa"
    error_message = "The state bucket name must match the backend block in backend.tf."
  }
}

run "ecr_keeps_images_safe" {
  command = plan

  assert {
    condition     = aws_ecr_repository.app.image_tag_mutability == "IMMUTABLE"
    error_message = "Image tags must be immutable (the same SHA must always mean the same image)."
  }

  assert {
    condition = [
      for r in jsondecode(aws_ecr_lifecycle_policy.app.policy).rules :
      "${r.rulePriority} ${try(r.selection.tagPatternList[0], "untagged")}"
    ] == ["1 prod-*", "2 untagged", "3 *"]
    error_message = "The prod-* rule must come first, so the rule for all other tags never expires a prod image."
  }
}
