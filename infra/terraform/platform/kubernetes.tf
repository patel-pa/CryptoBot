# One namespace per environment, both in this one cluster.
resource "kubernetes_namespace_v1" "env" {
  for_each = toset(["dev", "prod"])

  metadata {
    name = each.key
    labels = {
      "app.kubernetes.io/part-of" = "cryptobot"
    }
  }

  depends_on = [module.eks]
}

# The CD job of an environment may change everything in its own namespace and nothing
# anywhere else: its Kubernetes group (access entry in eks.tf) gets the built-in
# ClusterRole "edit", bound in that namespace only.
resource "kubernetes_role_binding_v1" "deploy" {
  for_each = kubernetes_namespace_v1.env

  metadata {
    name      = "cryptobot-deploy"
    namespace = each.value.metadata[0].name
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "edit"
  }

  subject {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Group"
    name      = "cryptobot-deploy-${each.key}"
  }
}
