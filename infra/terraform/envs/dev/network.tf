# Where the databases live and who may reach them: the platform's private subnets, and
# only the EKS nodes (every pod's traffic leaves through the nodes' security group).

locals {
  db_ports = {
    postgres = local.postgres.port
    mongo    = local.mongo.port
  }
}

resource "aws_db_subnet_group" "postgres" {
  name        = "${local.name}-postgres"
  description = "Private subnets of the platform layer"
  subnet_ids  = local.platform.private_subnet_ids

  lifecycle {
    precondition {
      condition     = local.platform_applied
      error_message = "The platform layer's state has no network outputs: apply the platform layer first (and destroy this layer before the platform)."
    }
  }
}

resource "aws_docdb_subnet_group" "mongo" {
  name        = "${local.name}-mongo"
  description = "Private subnets of the platform layer"
  subnet_ids  = local.platform.private_subnet_ids

  lifecycle {
    precondition {
      condition     = local.platform_applied
      error_message = "The platform layer's state has no network outputs: apply the platform layer first (and destroy this layer before the platform)."
    }
  }
}

resource "aws_security_group" "db" {
  for_each = local.db_ports

  name        = "${local.name}-${each.key}"
  description = "${each.key} of ${local.env}: only from the EKS nodes"
  vpc_id      = local.platform.vpc_id

  # No outbound rules: a database never starts connections itself (answers to allowed
  # connections still flow back). Inbound rules are the separate resources below.
  egress = []
}

resource "aws_vpc_security_group_ingress_rule" "from_nodes" {
  for_each = local.db_ports

  security_group_id            = aws_security_group.db[each.key].id
  description                  = "${each.key} from the EKS nodes (all pods)"
  referenced_security_group_id = local.platform.node_security_group_id
  ip_protocol                  = "tcp"
  from_port                    = each.value
  to_port                      = each.value
}
