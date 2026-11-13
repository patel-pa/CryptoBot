# Container logs of the EKS cluster (platform layer), sent by Fluent Bit from the
# CloudWatch observability add-on. They are created here, in the layer that is never
# destroyed, so the logs outlive every cluster teardown, and with a retention period,
# so they never grow forever (the add-on would create them without one).
resource "aws_cloudwatch_log_group" "containers" {
  for_each = toset(["application", "dataplane", "host"])

  name              = "/aws/containerinsights/${var.eks_cluster_name}/${each.key}"
  retention_in_days = 7
}
