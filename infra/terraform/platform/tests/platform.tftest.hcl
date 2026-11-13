# Offline checks of the platform layer against mock providers: no AWS account, no
# cluster, no credentials needed. Run: terraform init -backend=false, then terraform test.

mock_provider "aws" {
  # The provider still checks that policy JSON is valid.
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }

  # A made-up account and the identity that applies the layer (it becomes cluster admin).
  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "123456789012"
      arn        = "arn:aws:sts::123456789012:assumed-role/AccountFullAccessRole/tester"
    }
  }

  mock_data "aws_iam_session_context" {
    defaults = {
      issuer_arn = "arn:aws:iam::123456789012:role/AccountFullAccessRole"
    }
  }

  mock_data "aws_partition" {
    defaults = {
      partition  = "aws"
      dns_suffix = "amazonaws.com"
    }
  }
}

mock_provider "kubernetes" {}

mock_provider "helm" {}

# What the bootstrap layer's state would provide.
override_data {
  target = data.terraform_remote_state.bootstrap
  values = {
    outputs = {
      ci_role_arns = {
        build         = "arn:aws:iam::123456789012:role/cryptobot-github-build"
        "deploy-dev"  = "arn:aws:iam::123456789012:role/cryptobot-github-deploy-dev"
        "deploy-prod" = "arn:aws:iam::123456789012:role/cryptobot-github-deploy-prod"
      }
      container_log_groups = [
        "/aws/containerinsights/cryptobot/application",
        "/aws/containerinsights/cryptobot/dataplane",
        "/aws/containerinsights/cryptobot/host",
      ]
    }
  }
}

run "network_has_two_zones_one_nat_and_a_free_s3_path" {
  command = plan

  assert {
    condition     = local.azs == ["eu-central-1a", "eu-central-1b"]
    error_message = "The VPC must use the zones a and b of the region."
  }

  assert {
    condition     = module.vpc.private_subnets_cidr_blocks == tolist(["10.0.0.0/19", "10.0.32.0/19"])
    error_message = "Two large private subnets (/19) are expected, one per zone."
  }

  assert {
    condition     = module.vpc.public_subnets_cidr_blocks == tolist(["10.0.128.0/24", "10.0.129.0/24"])
    error_message = "Two small public subnets (/24) are expected, one per zone."
  }

  assert {
    condition     = length(module.vpc.natgw_ids) == 1
    error_message = "Exactly one NAT gateway (the cheapest option) is expected."
  }

  assert {
    condition     = aws_vpc_endpoint.s3.vpc_endpoint_type == "Gateway" && aws_vpc_endpoint.s3.service_name == "com.amazonaws.eu-central-1.s3"
    error_message = "S3 traffic must use the free gateway endpoint, not the NAT gateway."
  }

  assert {
    condition = local.subnet_tags == {
      public  = { "kubernetes.io/role/elb" = 1 }
      private = { "kubernetes.io/role/internal-elb" = 1 }
    }
    error_message = "The subnets must carry the tags the Load Balancer Controller looks for."
  }
}

run "cluster_is_pinned_and_each_deploy_role_edits_only_its_namespace" {
  command = plan

  assert {
    condition = local.cluster == {
      kubernetes_version      = "1.37"
      support_type            = "STANDARD"
      endpoint_public_access  = true
      endpoint_private_access = true
      authentication_mode     = "API"
      enabled_log_types       = []
      instance_types          = ["t3.medium"]
      node_count              = 2
    }
    error_message = "Cost and security settings changed: version, support type (extended costs 6x), endpoints, authentication, control-plane logs or node size/count."
  }

  assert {
    condition = local.node_tags == {
      Project   = "cryptobot"
      Layer     = "platform"
      ManagedBy = "terraform"
      Name      = "cryptobot-node"
    }
    error_message = "The node servers, their disks and primary network cards must carry the project tags (default_tags do not reach them) and a readable name."
  }

  assert {
    condition     = module.eks.cluster_version == "1.37"
    error_message = "The cluster must run Kubernetes 1.37."
  }

  assert {
    condition = { for name, addon in module.eks.cluster_addons : name => addon.addon_version } == {
      "vpc-cni"                = "v1.22.4-eksbuild.14"
      "eks-pod-identity-agent" = "v1.4.1-eksbuild.3"
      "kube-proxy"             = "v1.37.0-eksbuild.39"
      coredns                  = "v1.14.7-eksbuild.35"
    }
    error_message = "The core add-ons must be exactly the pinned versions."
  }

  assert {
    condition     = module.eks.access_entries["cluster_creator"].principal_arn == "arn:aws:iam::123456789012:role/AccountFullAccessRole"
    error_message = "The identity that applies this layer must become cluster admin."
  }

  assert {
    condition = {
      for name, entry in module.eks.access_entries : name => "${entry.principal_arn} ${join(",", sort(entry.kubernetes_groups))}"
      if name != "cluster_creator"
      } == {
      "deploy-dev"  = "arn:aws:iam::123456789012:role/cryptobot-github-deploy-dev cryptobot-deploy-dev"
      "deploy-prod" = "arn:aws:iam::123456789012:role/cryptobot-github-deploy-prod cryptobot-deploy-prod"
    }
    error_message = "Each deploy role (from the bootstrap layer) must map to its own Kubernetes group."
  }

  assert {
    condition = {
      for env, binding in kubernetes_role_binding_v1.deploy :
      env => "${binding.metadata[0].namespace} ${binding.role_ref[0].kind}/${binding.role_ref[0].name} ${binding.subject[0].name}"
      } == {
      dev  = "dev ClusterRole/edit cryptobot-deploy-dev"
      prod = "prod ClusterRole/edit cryptobot-deploy-prod"
    }
    error_message = "Each deploy group may only edit its own namespace."
  }

  assert {
    condition     = module.eks.kms_key_arn == null && module.eks.cloudwatch_log_group_name == null && module.eks.oidc_provider_arn == null
    error_message = "No own KMS key, no control-plane log group, no IRSA OIDC provider."
  }
}

run "controllers_are_pinned_and_deploy_jobs_cannot_change_secret_stores" {
  command = plan

  assert {
    condition = {
      for name, release in { lb = helm_release.aws_lb_controller, eso = helm_release.external_secrets } :
      name => "${release.namespace} ${release.chart} ${release.version}"
      } == {
      lb  = "kube-system aws-load-balancer-controller 3.6.2"
      eso = "external-secrets external-secrets 2.14.0"
    }
    error_message = "The controllers must be the pinned chart versions in their namespaces."
  }

  assert {
    condition = (
      local.lb_controller_values.enableServiceMutatorWebhook == false &&
      local.lb_controller_values.replicaCount == 1 &&
      local.lb_controller_values.region == "eu-central-1" &&
      contains(keys(local.lb_controller_values), "vpcId") &&
      local.lb_controller_values.serviceAccount.name == "aws-load-balancer-controller"
    )
    error_message = "Load Balancer Controller: Service webhook off, one replica, region and VPC set, its service account."
  }

  assert {
    condition     = local.lb_controller_values.defaultTags == { Project = "cryptobot", ManagedBy = "aws-load-balancer-controller" }
    error_message = "Every ALB, target group and security group the Load Balancer Controller creates must carry the project tag."
  }

  assert {
    condition     = module.aws_lb_controller_pod_identity.iam_policy_name == "cryptobot-aws-lb-controller"
    error_message = "The Load Balancer Controller's IAM policy must carry the project name, not the module's generic one."
  }

  assert {
    condition = alltrue([
      for m in [module.aws_lb_controller_pod_identity, module.external_secrets_pod_identity] :
      length(m.associations) == 1
    ]) && module.aws_lb_controller_pod_identity.associations["controller"].service_account == "aws-load-balancer-controller" && module.aws_lb_controller_pod_identity.associations["controller"].namespace == "kube-system" && module.external_secrets_pod_identity.associations["controller"].service_account == "external-secrets" && module.external_secrets_pod_identity.associations["controller"].namespace == "external-secrets"
    error_message = "Each controller role must belong to exactly its controller's service account."
  }

  assert {
    condition = (
      yamldecode(helm_release.external_secrets.values[0]).serviceAccount.name == "external-secrets" &&
      yamldecode(helm_release.external_secrets.values[0]).rbac.aggregateToEdit == false
    )
    error_message = "External Secrets: its role's service account, and its resources kept out of the \"edit\" role."
  }

  assert {
    condition = {
      for env, role in kubernetes_role_v1.external_secrets_user :
      env => "${role.metadata[0].namespace} ${join(",", role.rule[0].api_groups)} ${join(",", sort(role.rule[0].resources))} ${length(role.rule)}"
      } == {
      dev  = "dev external-secrets.io externalsecrets 1"
      prod = "prod external-secrets.io externalsecrets 1"
    }
    error_message = "Deploy jobs may manage ExternalSecrets in their namespace, but never SecretStores."
  }

  assert {
    condition = {
      for env, binding in kubernetes_role_binding_v1.external_secrets_user :
      env => "${binding.metadata[0].namespace} ${binding.role_ref[0].kind}/${binding.role_ref[0].name} ${binding.subject[0].name}"
      } == {
      dev  = "dev Role/cryptobot-external-secrets-user cryptobot-deploy-dev"
      prod = "prod Role/cryptobot-external-secrets-user cryptobot-deploy-prod"
    }
    error_message = "Each deploy group gets the ExternalSecret rights of its own namespace only."
  }

  assert {
    condition = (
      length(data.aws_iam_policy_document.external_secrets.statement) == 1 &&
      toset(data.aws_iam_policy_document.external_secrets.statement[0].actions) == toset(["sts:AssumeRole", "sts:TagSession"]) &&
      toset(data.aws_iam_policy_document.external_secrets.statement[0].resources) == toset(["arn:aws:iam::123456789012:role/cryptobot-*-external-secrets"])
    )
    error_message = "The External Secrets controller may only assume (and tag) the per-environment roles."
  }

  assert {
    condition = (
      aws_eks_addon.cloudwatch_observability.addon_version == "v7.0.1-eksbuild.1" &&
      jsondecode(aws_eks_addon.cloudwatch_observability.configuration_values).containerLogs.enabled == true &&
      length(jsondecode(aws_eks_addon.cloudwatch_observability.configuration_values).agents) == 0 &&
      alltrue([for feature in ["containerInsights", "applicationSignals", "otelContainerInsights", "kubeStateMetrics", "nodeExporter", "dcgmExporter", "neuronMonitor"] :
      jsondecode(aws_eks_addon.cloudwatch_observability.configuration_values)[feature].enabled == false])
    )
    error_message = "The CloudWatch add-on (pinned version) must send container logs only: no agent pods, metrics features off."
  }

  assert {
    condition     = one(aws_eks_addon.cloudwatch_observability.pod_identity_association).service_account == "cloudwatch-agent"
    error_message = "The CloudWatch role must be associated with the service account Fluent Bit runs as."
  }
}

run "log_add_on_refuses_a_cluster_without_kept_log_groups" {
  command = plan

  override_data {
    target = data.terraform_remote_state.bootstrap
    values = {
      outputs = {
        ci_role_arns = {
          build         = "arn:aws:iam::123456789012:role/cryptobot-github-build"
          "deploy-dev"  = "arn:aws:iam::123456789012:role/cryptobot-github-deploy-dev"
          "deploy-prod" = "arn:aws:iam::123456789012:role/cryptobot-github-deploy-prod"
        }
        container_log_groups = ["/aws/containerinsights/other/application"]
      }
    }
  }

  expect_failures = [aws_eks_addon.cloudwatch_observability]
}

# Route table IDs exist only after apply. With the mock provider an apply creates nothing
# real; the target keeps it to the endpoint and the network parts it needs.
run "s3_endpoint_serves_only_the_private_route_tables" {
  command = apply

  plan_options {
    target = [aws_vpc_endpoint.s3]
  }

  assert {
    condition     = toset(aws_vpc_endpoint.s3.route_table_ids) == toset(module.vpc.private_route_table_ids) && length(module.vpc.private_route_table_ids) > 0
    error_message = "The S3 endpoint belongs on the private route tables (the nodes' traffic)."
  }
}
