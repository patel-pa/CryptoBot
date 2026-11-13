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
  description = "true: AWS refuses to delete either database until an apply has set this to false. With keep_data, that apply (teardown step 1) also names the final snapshots."
  type        = bool
}

variable "keep_data" {
  description = "true (prod): destroy saves a final snapshot of each database, and creating a database restores the newest one (snapshots.tf). false (dev): nothing is kept, every create starts empty."
  type        = bool
}

variable "first_create" {
  description = "With keep_data only: true for the very first create, when no final snapshot exists yet. The databases then start empty."
  type        = bool
  default     = false

  validation {
    condition     = !var.first_create || var.keep_data
    error_message = "first_create only applies to an environment that keeps its data (keep_data = true)."
  }
}

variable "restore_snapshots" {
  description = "With keep_data only: restore these snapshots (by name, per database: postgres, mongo) instead of the newest ones, e.g. an older one after a bad change. Read only when a database is created."
  type        = map(string)
  default     = {}

  validation {
    condition     = alltrue([for db in keys(var.restore_snapshots) : contains(["postgres", "mongo"], db)])
    error_message = "restore_snapshots takes the keys postgres and mongo only."
  }

  validation {
    condition     = length(var.restore_snapshots) == 0 || var.keep_data
    error_message = "restore_snapshots only applies to an environment that keeps its data (keep_data = true)."
  }

  # An empty name would not fail anywhere: AWS would simply create an EMPTY database.
  validation {
    condition     = alltrue([for name in values(var.restore_snapshots) : length(trimspace(name)) > 0])
    error_message = "restore_snapshots: every snapshot name must be set (an empty name would create an empty database)."
  }

  validation {
    condition     = !(var.first_create && length(var.restore_snapshots) > 0)
    error_message = "first_create (start empty) and restore_snapshots (restore these) contradict each other: use one."
  }
}

variable "password_version" {
  description = "Raise by one to give both databases new passwords (README, \"New passwords\")."
  type        = number
}
