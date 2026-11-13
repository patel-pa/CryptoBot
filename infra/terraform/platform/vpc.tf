# The network: two availability zones (EKS and the AWS databases need two), each
# with a public subnet (load balancer, NAT gateway) and a private subnet (nodes,
# databases). Only the load balancer gets a public address.
locals {
  # Named, not looked up: the network never changes when AWS adds a zone.
  azs = ["${var.region}a", "${var.region}b"]

  # Where the AWS Load Balancer Controller may place internet-facing / internal ALBs.
  subnet_tags = {
    public  = { "kubernetes.io/role/elb" = 1 }
    private = { "kubernetes.io/role/internal-elb" = 1 }
  }
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "6.7.3"

  name = var.cluster_name
  cidr = var.vpc_cidr
  azs  = local.azs

  # Large private subnets (/19, 8,190 addresses each): with the VPC CNI every pod
  # gets an address of its node's subnet. Small public ones (/24) for the ALB and NAT.
  private_subnets = [for i in range(2) : cidrsubnet(var.vpc_cidr, 3, i)]
  public_subnets  = [for i in range(2) : cidrsubnet(var.vpc_cidr, 8, 128 + i)]

  # One NAT gateway for both zones: half the cost of one per zone; a zone outage
  # would cut the private subnets off the internet, accepted for this project.
  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true

  public_subnet_tags  = local.subnet_tags.public
  private_subnet_tags = local.subnet_tags.private
}

# S3 traffic (image layers from ECR, the model file) goes straight to S3 instead of
# through the NAT gateway, which charges per GB. A gateway endpoint is free.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = module.vpc.vpc_id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = module.vpc.private_route_table_ids

  tags = {
    Name = "${var.cluster_name}-s3"
  }
}
