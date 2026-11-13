# What happens to the data when the environment is destroyed and created again.
#
# keep_data = false (dev): nothing is kept. Destroy deletes the databases with their backups,
#   and every create starts empty.
#
# keep_data = true (prod):
#   Destroy saves a final snapshot of each database before deleting it. The snapshot's name
#   is set by teardown step 1 (apply with deletion_protection = false) from the time of that
#   plan, e.g. cryptobot-prod-postgres-final-2026-11-20-1730: a new name for every teardown,
#   as AWS requires. Without step 1 there is no name, and the destroy stops before it
#   deletes a database ("final_snapshot_identifier is required").
#
#   Creating a database restores the newest final snapshot (or the one named in
#   restore_snapshots). Terraform first asks AWS whether the database exists. Only when it
#   does not (that is, a create) does it look for a snapshot: a running environment never
#   needs one, so teardown and destroy also work in the very first session. No snapshot at
#   all stops the plan with "Your query returned no results", unless first_create = true
#   (the very first create, which starts empty).

locals {
  final_snapshot_time = formatdate("YYYY-MM-DD-hhmm", plantimestamp())

  final_snapshot = {
    for db in local.databases :
    db => var.keep_data && !var.deletion_protection ? "${local.name}-${db}-final-${local.final_snapshot_time}" : null
  }
}

# Does the database exist already? These lookups return an empty list instead of failing.
# DocumentDB runs on the RDS API, so the RDS cluster lookups also see its clusters and
# snapshots.
data "aws_db_instances" "postgres" {
  count = var.keep_data ? 1 : 0

  filter {
    name   = "db-instance-id"
    values = ["${local.name}-postgres"]
  }
}

data "aws_rds_clusters" "mongo" {
  count = var.keep_data ? 1 : 0

  filter {
    name   = "db-cluster-id"
    values = ["${local.name}-mongo"]
  }
}

locals {
  exists = {
    postgres = length(try(data.aws_db_instances.postgres[0].instance_identifiers, [])) > 0
    mongo    = length(try(data.aws_rds_clusters.mongo[0].cluster_identifiers, [])) > 0
  }

  # Look up the newest snapshot only for a database about to be created, and only if no
  # snapshot was named by hand.
  find_newest = {
    for db in local.databases :
    db => var.keep_data && !var.first_create && !local.exists[db] && !contains(keys(var.restore_snapshots), db)
  }
}

# The newest MANUAL snapshot: final snapshots are manual ones (the daily automatic backups are
# not, and AWS deletes those together with the database here anyway).
data "aws_db_snapshot" "postgres" {
  count = local.find_newest["postgres"] ? 1 : 0

  db_instance_identifier = "${local.name}-postgres"
  snapshot_type          = "manual"
  most_recent            = true
}

data "aws_db_cluster_snapshot" "mongo" {
  count = local.find_newest["mongo"] ? 1 : 0

  db_cluster_identifier = "${local.name}-mongo"
  snapshot_type         = "manual"
  most_recent           = true
}

locals {
  # The snapshot each database is created from; null = start empty. Only used by a create:
  # databases.tf tells Terraform to ignore it afterwards.
  restore_from = {
    for db in local.databases :
    db => (
      !var.keep_data || var.first_create || local.exists[db] ? null :
      contains(keys(var.restore_snapshots), db) ? var.restore_snapshots[db] :
      db == "postgres" ? data.aws_db_snapshot.postgres[0].id : data.aws_db_cluster_snapshot.mongo[0].id
    )
  }
}
