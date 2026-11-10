# GitHub Actions signs in to AWS with short-lived OIDC tokens: no AWS key is stored
# in GitHub. IAM trusts GitHub's token issuer through this provider.
resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}

data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

locals {
  eks_cluster_arn = "arn:${data.aws_partition.current.partition}:eks:${var.region}:${data.aws_caller_identity.current.account_id}:cluster/${var.eks_cluster_name}"

  # One role per CI job. "subject" is the only workflow context that may assume the
  # role (the token's "sub" claim): a job on the dev branch that uses no GitHub
  # environment, or a job in the GitHub environment "production" (required reviewer,
  # only main may deploy there).
  ci_roles = {
    build = {
      subject = "repo:${var.github_repository}:ref:refs/heads/dev"
      policy  = data.aws_iam_policy_document.build.json
    }
    deploy-dev = {
      subject = "repo:${var.github_repository}:ref:refs/heads/dev"
      policy  = data.aws_iam_policy_document.deploy_dev.json
    }
    deploy-prod = {
      subject = "repo:${var.github_repository}:environment:production"
      policy  = data.aws_iam_policy_document.deploy_prod.json
    }
  }
}

data "aws_iam_policy_document" "github_trust" {
  for_each = local.ci_roles

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = [each.value.subject]
    }
  }
}

resource "aws_iam_role" "ci" {
  for_each = local.ci_roles

  name               = "cryptobot-github-${each.key}"
  description        = "GitHub Actions ${each.key} job, only for ${each.value.subject}"
  assume_role_policy = data.aws_iam_policy_document.github_trust[each.key].json
}

resource "aws_iam_role_policy" "ci" {
  for_each = local.ci_roles

  name   = each.key
  role   = aws_iam_role.ci[each.key].id
  policy = each.value.policy
}

# build: log in to ECR and push the image of a dev commit.
data "aws_iam_policy_document" "build" {
  statement {
    sid       = "EcrLogin"
    actions   = ["ecr:GetAuthorizationToken"] # cannot be limited to one repository
    resources = ["*"]
  }

  statement {
    sid = "PushImage"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:CompleteLayerUpload",
      "ecr:DescribeImages",
      "ecr:GetDownloadUrlForLayer",
      "ecr:InitiateLayerUpload",
      "ecr:PutImage",
      "ecr:UploadLayerPart",
    ]
    resources = [aws_ecr_repository.app.arn]
  }
}

# deploy-dev: look up the image's digest and reach the cluster. What the job may do
# inside Kubernetes (only the dev namespace) is an EKS access entry in the platform layer.
data "aws_iam_policy_document" "deploy_dev" {
  statement {
    sid       = "FindImage"
    actions   = ["ecr:DescribeImages"]
    resources = [aws_ecr_repository.app.arn]
  }

  statement {
    sid       = "ReachCluster"
    actions   = ["eks:DescribeCluster"]
    resources = [local.eks_cluster_arn]
  }
}

# deploy-prod: as deploy-dev, plus give the tested image a second tag, prod-<main SHA>
# (the existing manifest under that tag; nothing is rebuilt). ECR keeps prod-* images
# apart from dev pushes (ecr.tf).
data "aws_iam_policy_document" "deploy_prod" {
  source_policy_documents = [data.aws_iam_policy_document.deploy_dev.json]

  statement {
    sid       = "TagTestedImage"
    actions   = ["ecr:BatchGetImage", "ecr:PutImage"]
    resources = [aws_ecr_repository.app.arn]
  }
}
