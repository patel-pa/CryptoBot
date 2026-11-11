output "vpc_id" {
  description = "VPC of the cluster; the envs layers put their databases in it."
  value       = module.vpc.vpc_id
}

output "private_subnet_ids" {
  description = "Private subnets (one per zone) for the nodes and the databases."
  value       = module.vpc.private_subnets
}
