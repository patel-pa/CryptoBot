# What may differ between dev and prod comes in here. Everything else (engine versions,
# ports, names, firewall rules, IAM policies) is the same code for both environments, so
# dev tests exactly what prod runs.

variable "env" {
  description = "Environment name: the Kubernetes namespace, the secret path cryptobot/<env>/, the model prefix <env>/ and the name prefix cryptobot-<env>-."
  type        = string

  validation {
    condition     = contains(["dev", "prod"], var.env)
    error_message = "env must be dev or prod: the platform layer creates only these two namespaces."
  }
}

variable "region" {
  description = "AWS region of the databases and secrets."
  type        = string
}

variable "platform" {
  description = "Outputs of the platform layer, read by the calling layer from its state. applied is false while the platform is destroyed; the other values are placeholders then."
  type = object({
    applied                              = bool
    vpc_id                               = string
    private_subnet_ids                   = list(string)
    node_security_group_id               = string
    cluster_name                         = string
    external_secrets_controller_role_arn = string
  })
}

variable "model_bucket" {
  description = "The bootstrap layer's model bucket. This environment's pods may use only its <env>/ prefix."
  type        = string
}

variable "postgres" {
  description = "PostgreSQL instance size and how many days AWS keeps automatic backups."
  type = object({
    instance_class          = string
    backup_retention_period = number
  })
}

variable "mongo" {
  description = "DocumentDB instance size and how many days AWS keeps automatic backups."
  type = object({
    instance_class          = string
    backup_retention_period = number
  })
}

variable "deletion_protection" {
  description = "true: AWS refuses to delete either database until an apply has set this to false."
  type        = bool
}

variable "password_version" {
  description = "Raise by one to give both databases new passwords (README, \"New passwords\")."
  type        = number
}
