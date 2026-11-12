# Two secrets per database, under fixed names that only this environment's roles may read
# (cryptobot/dev/*). External Secrets merges both into one Kubernetes Secret.
#
# 1. Credentials (username + password), written FIRST. AWS generates the password at apply
#    time as an ephemeral value: it is written straight into Secrets Manager and never
#    stored in the Terraform state or plan. The databases then read it back from there,
#    so both always get the same password, even when a first apply fails half-way.
# 2. Endpoint (host, port, database name), written AFTER the database exists. Not secret,
#    but kept here so no account-specific host name has to live in the public repository.

locals {
  databases = toset(["postgres", "mongo"])

  # Bump to give both databases new passwords: the secrets get new values first, then the
  # databases read them back. Running pods keep the old password until External Secrets
  # has copied the new one and they restart (README, "New passwords"). If
  # AWS rejects the database change (e.g. the instance is busy), the secret already holds
  # the new password and Terraform cannot see the difference: bump the number again.
  password_version = 1
}

ephemeral "aws_secretsmanager_random_password" "db" {
  for_each = local.databases

  password_length     = 40
  exclude_punctuation = true # letters and digits only: nothing a database or a URL forbids
}

resource "aws_secretsmanager_secret" "credentials" {
  for_each = local.databases

  name        = "cryptobot/${local.env}/${each.key}"
  description = "${each.key} of ${local.env}: master username and password"

  # Gone at once on destroy, so the next session can create the same name again (the
  # default 30-day recovery window would block it).
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "credentials" {
  for_each = aws_secretsmanager_secret.credentials

  secret_id = each.value.id
  secret_string_wo = jsonencode({
    username = local.credentials_usernames[each.key]
    password = ephemeral.aws_secretsmanager_random_password.db[each.key].random_password
  })
  secret_string_wo_version = local.password_version
}

# The databases' passwords, read back from exactly the secret versions just written
# (never stored).
ephemeral "aws_secretsmanager_secret_version" "credentials" {
  for_each = aws_secretsmanager_secret_version.credentials

  secret_id  = each.value.secret_id
  version_id = each.value.version_id
}

locals {
  credentials_usernames = {
    postgres = local.postgres.username
    mongo    = local.mongo.username
  }

  passwords = {
    for db, version in ephemeral.aws_secretsmanager_secret_version.credentials :
    db => jsondecode(version.secret_string).password
  }
}

resource "aws_secretsmanager_secret" "endpoint" {
  for_each = local.databases

  name                    = "cryptobot/${local.env}/${each.key}-endpoint"
  description             = "${each.key} of ${local.env}: host, port and database name"
  recovery_window_in_days = 0
}

locals {
  endpoints = {
    postgres = { host = aws_db_instance.postgres.address, port = local.postgres.port, dbname = local.postgres.db_name }
    mongo    = { host = aws_docdb_cluster.mongo.endpoint, port = local.mongo.port, dbname = local.mongo.db_name }
  }
}

resource "aws_secretsmanager_secret_version" "endpoint" {
  for_each = aws_secretsmanager_secret.endpoint

  secret_id     = each.value.id
  secret_string = jsonencode(local.endpoints[each.key])
}
