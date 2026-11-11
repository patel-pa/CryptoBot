# Offline checks of the platform layer against mock providers: no AWS account, no
# cluster, no credentials needed. Run: terraform init -backend=false, then terraform test.

mock_provider "aws" {
  # The provider still checks that policy JSON is valid.
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
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
