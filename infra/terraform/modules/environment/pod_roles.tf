# AWS rights for this environment's pods, through EKS Pod Identity: one IAM role per
# Kubernetes service account (k8s/base/serviceaccounts.yaml). The service account
# `cryptobot` (the other pods) gets no AWS rights at all.
#
# The model lives in the bootstrap layer's bucket under one prefix per environment
# (dev/model.pkl, prod/model.pkl), so dev can never read or overwrite prod's model.
# Exactly the calls src/models/model_store.py makes:
#   api      head_object + get_object → s3:GetObject (also covers HeadObject)
#   retrain  put_object               → s3:PutObject
# Without s3:ListBucket, S3 answers 403 (not 404) while no model exists yet: until the first
# retrain has run, the API logs "no model at s3://…: AccessDenied(… GetObject … Access
# Denied)". That is expected, not a permission problem.

locals {
  pod_roles = {
    api     = ["s3:GetObject"]
    retrain = ["s3:PutObject"]
  }
}

# Only EKS Pod Identity may assume a role, and only for this cluster, this environment's
# namespace and the role's own service account (session tags that Pod Identity sets itself).
data "aws_iam_policy_document" "pod_trust" {
  for_each = local.pod_roles

  statement {
    sid     = "PodIdentityForThisServiceAccountOnly"
    actions = ["sts:AssumeRole", "sts:TagSession"]

    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/eks-cluster-name"
      values   = [var.platform.cluster_name]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/kubernetes-namespace"
      values   = [var.env]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/kubernetes-service-account"
      values   = [each.key]
    }
  }
}

data "aws_iam_policy_document" "pod_model_access" {
  for_each = local.pod_roles

  statement {
    sid       = "ThisEnvironmentsModelOnly"
    actions   = each.value
    resources = ["arn:${data.aws_partition.current.partition}:s3:::${var.model_bucket}/${var.env}/*"]
  }
}

resource "aws_iam_role" "pod" {
  for_each = local.pod_roles

  name               = "cryptobot-${var.env}-${each.key}"
  description        = "Pod Identity role of the ${each.key} service account in ${var.env}"
  assume_role_policy = data.aws_iam_policy_document.pod_trust[each.key].json
}

resource "aws_iam_role_policy" "pod_model_access" {
  for_each = local.pod_roles

  name   = "${var.env}-model"
  role   = aws_iam_role.pod[each.key].id
  policy = data.aws_iam_policy_document.pod_model_access[each.key].json
}

resource "aws_eks_pod_identity_association" "pod" {
  for_each = local.pod_roles

  cluster_name    = var.platform.cluster_name
  namespace       = var.env
  service_account = each.key
  role_arn        = aws_iam_role.pod[each.key].arn

  # The trust policy above relies on these tags.
  disable_session_tags = false
}
