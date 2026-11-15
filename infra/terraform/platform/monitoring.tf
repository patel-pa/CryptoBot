# Monitoring: Prometheus and Grafana from the Helm chart kube-prometheus-stack, with the same
# settings as on kind (monitoring/values.yaml), plus our dashboards and alert rule as the
# ConfigMaps Grafana loads by their labels. Needs no AWS rights (no Pod Identity role), keeps
# no data on disks (no EBS volume) and is reached only through kubectl port-forward (no load
# balancer), so it adds nothing to the teardown steps. See monitoring/README.md.

locals {
  monitoring_dir = "${path.module}/../../../monitoring"

  # On kind, `kubectl apply -k monitoring` builds the ConfigMaps from this file. Terraform
  # reads the same file, so both get the same names, labels, annotations and files.
  monitoring_kustomization = yamldecode(file("${local.monitoring_dir}/kustomization.yaml"))
  monitoring_config_maps = {
    for config_map in local.monitoring_kustomization.configMapGenerator : config_map.name => {
      labels      = config_map.options.labels
      annotations = try(config_map.options.annotations, {})
      files       = config_map.files
    }
  }
}

resource "helm_release" "kube_prometheus_stack" {
  name             = "kube-prometheus-stack"
  namespace        = local.monitoring_kustomization.namespace # monitoring
  create_namespace = true
  repository       = "oci://ghcr.io/prometheus-community/charts"
  chart            = "kube-prometheus-stack"
  version          = "93.3.0" # the same as in monitoring/README.md (the tests check it)

  values = [file("${local.monitoring_dir}/values.yaml")]

  # The first install pulls about ten images onto fresh nodes; the default is 5 minutes.
  timeout = 600

  # After the Load Balancer Controller, so nothing races with its webhooks (as External Secrets).
  depends_on = [module.eks, helm_release.aws_lb_controller]
}

resource "kubernetes_config_map_v1" "monitoring" {
  for_each = local.monitoring_config_maps

  metadata {
    name        = each.key
    namespace   = helm_release.kube_prometheus_stack.namespace # created by the release
    labels      = each.value.labels
    annotations = each.value.annotations
  }

  # One entry per file, named like the file (as Kustomize does).
  data = { for path in each.value.files : basename(path) => file("${local.monitoring_dir}/${path}") }
}
