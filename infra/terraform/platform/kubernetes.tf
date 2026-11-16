# One namespace per environment, both in this one cluster.
resource "kubernetes_namespace_v1" "env" {
  for_each = toset(["dev", "prod"])

  metadata {
    name = each.key
    labels = {
      "app.kubernetes.io/part-of" = "cryptobot"
      # Pod Security "restricted": Kubernetes refuses any pod that may run as root, gain
      # rights or reach into the node (privileged, host network or PID, hostPath). A deploy
      # job may create pods in its namespace (ClusterRole edit) and dev and prod share the
      # nodes, so without it a pod started from dev could read prod's secrets on a node.
      # Every app pod meets it (k8s/base). warn: kubectl apply then names what a refused
      # Deployment's pods lack, instead of a rollout that only times out.
      "pod-security.kubernetes.io/enforce"         = "restricted"
      "pod-security.kubernetes.io/enforce-version" = "v${local.cluster.kubernetes_version}"
      "pod-security.kubernetes.io/warn"            = "restricted"
      "pod-security.kubernetes.io/warn-version"    = "v${local.cluster.kubernetes_version}"
    }
  }

  # A safety net for the destroy (the teardown steps still delete every Ingress first):
  # these namespaces go first, while the controllers still run. The Load Balancer
  # Controller removes the ALB of an Ingress forgotten in them (it can: it depends on the
  # network, controllers.tf: NAT gateway and routes are deleted only after it), and
  # External Secrets removes the finalizer it puts on every ExternalSecret. Otherwise a
  # namespace could hang in "Terminating" and stop the destroy with the cluster, the
  # nodes and the ALB still running.
  depends_on = [module.eks, helm_release.aws_lb_controller, helm_release.external_secrets]
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

# "edit" gives no write rights on External Secrets' resources (rbac.aggregateToEdit = false
# in controllers.tf; reading them stays possible, which is harmless). A deploy job may only
# say WHICH secret it needs (ExternalSecret), never HOW it is read (SecretStore: which AWS
# role, which session tags). The SecretStore of each namespace is created by the envs layer,
# which only the owner applies.
resource "kubernetes_role_v1" "external_secrets_user" {
  for_each = kubernetes_namespace_v1.env

  metadata {
    name      = "cryptobot-external-secrets-user"
    namespace = each.value.metadata[0].name
  }

  rule {
    api_groups = ["external-secrets.io"]
    resources  = ["externalsecrets"]
    verbs      = ["get", "list", "watch", "create", "update", "patch", "delete"]
  }
}

resource "kubernetes_role_binding_v1" "external_secrets_user" {
  for_each = kubernetes_role_v1.external_secrets_user

  metadata {
    name      = "cryptobot-external-secrets-user"
    namespace = each.value.metadata[0].namespace
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = each.value.metadata[0].name
  }

  subject {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Group"
    name      = "cryptobot-deploy-${each.key}"
  }
}
