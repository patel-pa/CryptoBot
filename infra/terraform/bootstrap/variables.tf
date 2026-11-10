variable "region" {
  description = "AWS region for every resource (Binance blocks US IP addresses)."
  type        = string
  default     = "eu-central-1"
}

variable "github_repository" {
  description = "GitHub repository (owner/name) whose workflows may assume the CI roles."
  type        = string
  default     = "patel-pa/CryptoBot"

  validation {
    condition     = can(regex("^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$", var.github_repository))
    error_message = "Use the form owner/name, e.g. patel-pa/CryptoBot."
  }
}

variable "eks_cluster_name" {
  description = "EKS cluster of the platform layer: the deploy roles may describe it, and its container log groups are created here."
  type        = string
  default     = "cryptobot"
}
