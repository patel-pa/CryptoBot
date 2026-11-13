variable "region" {
  description = "AWS region for every resource (Binance blocks US IP addresses)."
  type        = string
  default     = "eu-central-1"
}

variable "cluster_name" {
  description = "Name of the EKS cluster (and of the VPC). Must equal eks_cluster_name of the bootstrap layer, which names the CI roles' cluster and the log groups."
  type        = string
  default     = "cryptobot"
}

variable "vpc_cidr" {
  description = "Address range of the VPC."
  type        = string
  default     = "10.0.0.0/16"
}
