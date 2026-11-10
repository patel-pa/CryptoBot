# Offline checks of the bootstrap layer against a mock AWS provider: no AWS account
# or credentials needed. Run: terraform init -backend=false, then terraform test.

mock_provider "aws" {}

# The provider still checks that policy JSON is valid (deploy_prod includes deploy_dev's,
# and the role policies use all three), so each permission document gets a small,
# distinct JSON instead of the mock's random text.
override_data {
  target = data.aws_iam_policy_document.build
  values = { json = "{\"Version\":\"2012-10-17\",\"Id\":\"build\",\"Statement\":[]}" }
}

override_data {
  target = data.aws_iam_policy_document.deploy_dev
  values = { json = "{\"Version\":\"2012-10-17\",\"Id\":\"deploy-dev\",\"Statement\":[]}" }
}

override_data {
  target = data.aws_iam_policy_document.deploy_prod
  values = { json = "{\"Version\":\"2012-10-17\",\"Id\":\"deploy-prod\",\"Statement\":[]}" }
}

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

run "container_logs_are_kept_7_days" {
  command = plan

  assert {
    condition = toset([for g in aws_cloudwatch_log_group.containers : g.name]) == toset([
      "/aws/containerinsights/cryptobot/application",
      "/aws/containerinsights/cryptobot/dataplane",
      "/aws/containerinsights/cryptobot/host",
    ])
    error_message = "The log groups must be the ones the CloudWatch add-on's Fluent Bit writes to."
  }

  assert {
    condition     = alltrue([for g in aws_cloudwatch_log_group.containers : g.retention_in_days == 7])
    error_message = "Container logs must expire after 7 days, so they never grow forever."
  }
}

run "container_log_groups_follow_the_cluster_name" {
  command = plan

  variables {
    eks_cluster_name = "other"
  }

  assert {
    condition     = alltrue([for g in aws_cloudwatch_log_group.containers : startswith(g.name, "/aws/containerinsights/other/")])
    error_message = "The log group names must use var.eks_cluster_name, the name the platform layer gives the cluster."
  }
}

run "each_ci_role_trusts_exactly_one_github_context" {
  command = plan

  assert {
    condition = {
      for name, role in local.ci_roles : name => role.subject
      } == {
      build       = "repo:patel-pa/CryptoBot:ref:refs/heads/dev"
      deploy-dev  = "repo:patel-pa/CryptoBot:ref:refs/heads/dev"
      deploy-prod = "repo:patel-pa/CryptoBot:environment:production"
    }
    error_message = "Unexpected token subjects for the CI roles."
  }

  assert {
    condition = alltrue([for name, d in data.aws_iam_policy_document.github_trust :
      length(d.statement) == 1 &&
      toset([for c in d.statement[0].condition : "${c.test} ${c.variable} ${join(",", c.values)}"]) == toset([
        "StringEquals token.actions.githubusercontent.com:aud sts.amazonaws.com",
        "StringEquals token.actions.githubusercontent.com:sub ${local.ci_roles[name].subject}",
      ])
    ])
    error_message = "Each trust policy must check aud and sub with exact matches (no wildcards)."
  }

  assert {
    condition     = toset([for r in aws_iam_role.ci : r.name]) == toset(["cryptobot-github-build", "cryptobot-github-deploy-dev", "cryptobot-github-deploy-prod"])
    error_message = "Unexpected CI role names."
  }
}

run "ci_roles_have_least_privilege" {
  command = plan

  assert {
    condition = toset(flatten([for s in data.aws_iam_policy_document.build.statement : s.actions])) == toset([
      "ecr:GetAuthorizationToken", "ecr:BatchCheckLayerAvailability", "ecr:BatchGetImage",
      "ecr:CompleteLayerUpload", "ecr:DescribeImages", "ecr:GetDownloadUrlForLayer",
      "ecr:InitiateLayerUpload", "ecr:PutImage", "ecr:UploadLayerPart",
    ])
    error_message = "build may only log in to ECR and push images."
  }

  assert {
    condition     = toset(flatten([for s in data.aws_iam_policy_document.deploy_dev.statement : s.actions])) == toset(["ecr:DescribeImages", "eks:DescribeCluster"])
    error_message = "deploy-dev may only look up images and describe the cluster."
  }

  assert {
    condition     = toset(flatten([for s in data.aws_iam_policy_document.deploy_prod.statement : s.actions])) == toset(["ecr:BatchGetImage", "ecr:PutImage"])
    error_message = "deploy-prod may only add a tag to an existing image (plus what deploy-dev may do)."
  }
}

run "repository_must_be_owner_slash_name" {
  command = plan

  variables {
    github_repository = "CryptoBot"
  }

  expect_failures = [var.github_repository]
}

# Which policy JSON each role gets is only known after apply. With the mock provider
# an apply creates nothing real; the target keeps it to the roles and their policies
# (no buckets, which could not be destroyed at the end of the test because of
# prevent_destroy; the two "-target" warnings this prints are expected). Each document
# has a distinct JSON, so a role wired to the wrong one fails.
run "each_role_uses_its_own_policies" {
  command = apply

  plan_options {
    target = [aws_iam_role.ci, aws_iam_role_policy.ci]
  }

  override_data {
    target = data.aws_iam_policy_document.github_trust["build"]
    values = { json = "{\"Version\":\"2012-10-17\",\"Id\":\"build\",\"Statement\":[]}" }
  }

  override_data {
    target = data.aws_iam_policy_document.github_trust["deploy-dev"]
    values = { json = "{\"Version\":\"2012-10-17\",\"Id\":\"deploy-dev\",\"Statement\":[]}" }
  }

  override_data {
    target = data.aws_iam_policy_document.github_trust["deploy-prod"]
    values = { json = "{\"Version\":\"2012-10-17\",\"Id\":\"deploy-prod\",\"Statement\":[]}" }
  }

  assert {
    condition     = alltrue([for name, r in aws_iam_role.ci : r.assume_role_policy == data.aws_iam_policy_document.github_trust[name].json])
    error_message = "Each CI role must use the trust policy for its own GitHub context."
  }

  assert {
    condition = { for name, p in aws_iam_role_policy.ci : name => p.policy } == {
      build       = data.aws_iam_policy_document.build.json
      deploy-dev  = data.aws_iam_policy_document.deploy_dev.json
      deploy-prod = data.aws_iam_policy_document.deploy_prod.json
    }
    error_message = "Each CI role must get its own permissions."
  }

  assert {
    condition     = data.aws_iam_policy_document.deploy_prod.source_policy_documents == tolist([data.aws_iam_policy_document.deploy_dev.json])
    error_message = "deploy-prod may only add deploy-dev's permissions to its own."
  }
}
