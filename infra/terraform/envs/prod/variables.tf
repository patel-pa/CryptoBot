variable "region" {
  description = "AWS region for every resource (Binance blocks US IP addresses)."
  type        = string
  default     = "eu-central-1"
}

# The three switches below are set on the command line, never in a file, so a plain
# `terraform plan` is always the safe, normal case.

variable "deletion_protection" {
  description = "Leave true. Teardown step 1 sets it to false (-var deletion_protection=false), which also names the final snapshots; then destroy."
  type        = bool
  default     = true
}

variable "first_create" {
  description = "Only for the very first create, when no final snapshot exists yet (-var first_create=true): the databases start empty."
  type        = bool
  default     = false
}

variable "restore_snapshots" {
  description = "Restore these snapshots instead of the newest ones, e.g. -var 'restore_snapshots={postgres=\"cryptobot-prod-postgres-final-2026-11-20-1730\"}'. Read only when a database is created."
  type        = map(string)
  default     = {}
}
