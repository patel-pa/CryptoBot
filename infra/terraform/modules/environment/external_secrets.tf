# How this environment's namespace gets its database secrets, with the two locks that keep
# dev and prod from ever reading each other's passwords (see also the platform README):
#
# 1. Kubernetes: only this layer creates the namespace's SecretStore (deploy jobs may create
#    ExternalSecrets, never SecretStores). It names this environment's role and sets
#    sessionTagsPolicy Simple: External Secrets then tags every sign-in with the store's
#    namespace and kind (esoNamespace, esoStoreKind; hand-written tags are ignored).
# 2. AWS: this role trusts the External Secrets controller only when those tags name this
#    environment and "SecretStore", and it may read nothing but cryptobot/<env>/*.
#
# The controller's role (platform layer) may only assume roles named
# cryptobot-*-external-secrets. Its ARN is resolved when this trust policy is created, so
# this layer must be re-created whenever the platform is (session order: destroy the envs
# layers first).

locals {
  secret_store_name = "aws-secrets-manager"
}

data "aws_iam_policy_document" "external_secrets_trust" {
  statement {
    sid     = "ExternalSecretsControllerForThisEnvironmentOnly"
    actions = ["sts:AssumeRole", "sts:TagSession"]

    principals {
      type        = "AWS"
      identifiers = [var.platform.external_secrets_controller_role_arn]
    }

    # On both actions: a sign-in without these tags is refused too.
    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/esoNamespace"
      values   = [var.env]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/esoStoreKind"
      values   = ["SecretStore"]
    }
  }
}

data "aws_iam_policy_document" "external_secrets_read" {
  statement {
    sid = "ReadThisEnvironmentsSecrets"
    # Reading a value is all External Secrets does here (DescribeSecret only for metadata).
    actions   = ["secretsmanager:GetSecretValue"]
    resources = ["arn:${data.aws_partition.current.partition}:secretsmanager:${var.region}:${data.aws_caller_identity.current.account_id}:secret:cryptobot/${var.env}/*"]
  }
}

resource "aws_iam_role" "external_secrets" {
  name               = "cryptobot-${var.env}-external-secrets"
  description        = "Assumed by the External Secrets controller for the ${var.env} namespace only"
  assume_role_policy = data.aws_iam_policy_document.external_secrets_trust.json
}

resource "aws_iam_role_policy" "external_secrets_read" {
  name   = "read-${var.env}-secrets"
  role   = aws_iam_role.external_secrets.id
  policy = data.aws_iam_policy_document.external_secrets_read.json
}

resource "kubernetes_manifest" "secret_store" {
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "SecretStore"
    metadata = {
      name      = local.secret_store_name
      namespace = var.env
      labels    = { "app.kubernetes.io/part-of" = "cryptobot" }
    }
    spec = {
      provider = {
        aws = {
          service           = "SecretsManager"
          region            = var.region
          role              = aws_iam_role.external_secrets.arn
          sessionTagsPolicy = "Simple"
        }
      }
    }
  }

  # The store never exists without its read permission: ExternalSecrets may sync at once.
  depends_on = [aws_iam_role_policy.external_secrets_read]
}
