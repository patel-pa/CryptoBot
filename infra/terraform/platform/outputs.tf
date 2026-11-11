output "vpc_id" {
  description = "VPC of the cluster; the envs layers put their databases in it."
  value       = module.vpc.vpc_id
}

output "private_subnet_ids" {
  description = "Private subnets (one per zone) for the nodes and the databases."
  value       = module.vpc.private_subnets
}

output "cluster_name" {
  description = "Name of the EKS cluster."
  value       = module.eks.cluster_name
}

output "node_security_group_id" {
  description = "Security group of the nodes; the databases (envs layers) accept connections only from it."
  value       = module.eks.node_security_group_id
}

output "kubeconfig_command" {
  description = "Command that points kubectl at this cluster."
  value       = "aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${var.region}"
}
