# Offline checks of the environment module against a mock AWS provider: no AWS account, no
# credentials needed. Run in this module's folder: terraform init -backend=false, then
# terraform test (Terraform 1.17+: older versions cannot mock ephemeral resources).
# The runs use dev's values (below) unless a run says otherwise; the layers envs/dev and
# envs/prod check in their own tests that they pass their values in.

variables {
  env          = "dev"
  region       = "eu-central-1"
  model_bucket = "cryptobot-models-test"

  # What the platform layer's state would provide.
  platform = {
    applied                              = true
    vpc_id                               = "vpc-platform"
    private_subnet_ids                   = ["subnet-private-a", "subnet-private-b"]
    node_security_group_id               = "sg-nodes"
    cluster_name                         = "cryptobot"
    external_secrets_controller_role_arn = "arn:aws:iam::123456789012:role/cryptobot-external-secrets"
  }

  postgres = {
    instance_class          = "db.t4g.micro"
    backup_retention_period = 1
  }

  mongo = {
    instance_class          = "db.t4g.medium"
    backup_retention_period = 1
  }

  deletion_protection = false
  keep_data           = false
  password_version    = 1
}

mock_provider "aws" {
  # What reading a credentials secret back returns in the mock apply run below. Plan runs
  # never open it: its secret ID is unknown until the secret exists.
  mock_ephemeral "aws_secretsmanager_secret_version" {
    defaults = {
      secret_string = "{\"username\":\"cryptobot\",\"password\":\"mockpassword\"}"
    }
  }

  # A made-up account.
  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "123456789012"
    }
  }

  mock_data "aws_partition" {
    defaults = {
      partition = "aws"
    }
  }
}

# Distinct (valid) JSON per pod role document, so the tests can see which one a role uses.
override_data {
  target = data.aws_iam_policy_document.pod_trust["api"]
  values = {
    json = "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Sid\":\"ApiTrust\",\"Effect\":\"Allow\",\"Action\":\"sts:AssumeRole\",\"Principal\":{\"Service\":\"pods.eks.amazonaws.com\"}}]}"
  }
}

override_data {
  target = data.aws_iam_policy_document.pod_trust["retrain"]
  values = {
    json = "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Sid\":\"RetrainTrust\",\"Effect\":\"Allow\",\"Action\":\"sts:AssumeRole\",\"Principal\":{\"Service\":\"pods.eks.amazonaws.com\"}}]}"
  }
}

override_data {
  target = data.aws_iam_policy_document.pod_model_access["api"]
  values = {
    json = "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Sid\":\"ApiRead\",\"Effect\":\"Allow\",\"Action\":\"s3:GetObject\",\"Resource\":\"*\"}]}"
  }
}

override_data {
  target = data.aws_iam_policy_document.pod_model_access["retrain"]
  values = {
    json = "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Sid\":\"RetrainWrite\",\"Effect\":\"Allow\",\"Action\":\"s3:PutObject\",\"Resource\":\"*\"}]}"
  }
}

mock_provider "kubernetes" {}

# Distinct (valid) JSON per policy document, so the tests can see which one a role uses.
override_data {
  target = data.aws_iam_policy_document.external_secrets_trust
  values = {
    json = "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Sid\":\"Trust\",\"Effect\":\"Allow\",\"Action\":\"sts:AssumeRole\",\"Principal\":{\"AWS\":\"*\"}}]}"
  }
}

override_data {
  target = data.aws_iam_policy_document.external_secrets_read
  values = {
    json = "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Sid\":\"Read\",\"Effect\":\"Allow\",\"Action\":\"secretsmanager:GetSecretValue\",\"Resource\":\"*\"}]}"
  }
}

run "databases_are_small_private_encrypted_and_pinned" {
  command = plan

  assert {
    condition = local.postgres == {
      engine_version          = "18"
      instance_class          = "db.t4g.micro"
      allocated_storage       = 20
      backup_retention_period = 1
      deletion_protection     = false
      skip_final_snapshot     = true
      port                    = 5432
      db_name                 = "cryptobot"
      username                = "cryptobot"
    }
    error_message = "PostgreSQL settings changed: version (must match docker compose), size, backups or snapshot behaviour."
  }

  assert {
    condition = local.mongo == {
      engine_version          = "8.0.2"
      instance_class          = "db.t4g.medium"
      instance_count          = 1
      backup_retention_period = 1
      deletion_protection     = false
      skip_final_snapshot     = true
      port                    = 27017
      db_name                 = "cryptobot"
      username                = "cryptobot"
    }
    error_message = "DocumentDB settings changed: version (must match docker compose), size, instance count, backups or snapshot behaviour."
  }

  assert {
    condition = (
      aws_db_instance.postgres.engine == "postgres" &&
      aws_db_instance.postgres.engine_version == "18" &&
      aws_db_instance.postgres.instance_class == "db.t4g.micro" &&
      aws_db_instance.postgres.storage_type == "gp3" &&
      aws_db_instance.postgres.storage_encrypted == true &&
      aws_db_instance.postgres.publicly_accessible == false &&
      aws_db_instance.postgres.multi_az == false &&
      aws_db_instance.postgres.backup_retention_period == 1 &&
      aws_db_instance.postgres.deletion_protection == false &&
      aws_db_instance.postgres.skip_final_snapshot == true
    )
    error_message = "RDS must be the small, private, encrypted, single-zone PostgreSQL 18 instance of dev."
  }

  assert {
    condition = (
      aws_db_instance.postgres.performance_insights_enabled == false &&
      aws_db_instance.postgres.monitoring_interval == 0 &&
      length(aws_db_instance.postgres.enabled_cloudwatch_logs_exports) == 0 &&
      length(aws_docdb_cluster.mongo.enabled_cloudwatch_logs_exports) == 0
    )
    error_message = "No Performance Insights, enhanced monitoring or log exports (cost, and log groups that never expire)."
  }

  assert {
    condition = (
      aws_docdb_cluster.mongo.engine == "docdb" &&
      aws_docdb_cluster.mongo.engine_version == "8.0.2" &&
      aws_docdb_cluster.mongo.storage_encrypted == true &&
      aws_docdb_cluster.mongo.backup_retention_period == 1 &&
      aws_docdb_cluster.mongo.deletion_protection == false &&
      aws_docdb_cluster.mongo.skip_final_snapshot == true &&
      length(aws_docdb_cluster_instance.mongo) == 1 &&
      aws_docdb_cluster_instance.mongo[0].instance_class == "db.t4g.medium"
    )
    error_message = "DocumentDB must be one small, encrypted 8.0 instance."
  }
}

run "passwords_never_reach_the_state" {
  command = plan

  # (Write-only arguments always read as null, so only the plain arguments and the
  # versions are checked; removing a write-only argument fails validation anyway.)
  assert {
    condition = (
      aws_db_instance.postgres.password == null &&
      aws_db_instance.postgres.password_wo_version == 1 &&
      aws_docdb_cluster.mongo.master_password == null &&
      aws_docdb_cluster.mongo.master_password_wo_version == 1
    )
    error_message = "The databases must get their passwords only through write-only arguments."
  }

  assert {
    condition = alltrue([
      for version in aws_secretsmanager_secret_version.credentials :
      version.secret_string == null && version.secret_string_wo_version == 1
    ]) && length(aws_secretsmanager_secret_version.credentials) == 2
    error_message = "The credentials secrets must be written only through write-only arguments."
  }
}

run "secrets_have_fixed_names_only_dev_can_read" {
  command = plan

  assert {
    condition = merge(
      { for db, secret in aws_secretsmanager_secret.credentials : db => secret.name },
      { for db, secret in aws_secretsmanager_secret.endpoint : "${db}-endpoint" => secret.name },
      ) == {
      postgres            = "cryptobot/dev/postgres"
      mongo               = "cryptobot/dev/mongo"
      "postgres-endpoint" = "cryptobot/dev/postgres-endpoint"
      "mongo-endpoint"    = "cryptobot/dev/mongo-endpoint"
    }
    error_message = "The secrets must have the fixed names under cryptobot/dev/ (the overlay and the IAM policies use them)."
  }

  assert {
    condition = alltrue([
      for secret in concat(values(aws_secretsmanager_secret.credentials), values(aws_secretsmanager_secret.endpoint)) :
      secret.recovery_window_in_days == 0
    ])
    error_message = "Dev secrets must be deleted at once on destroy, or the next session cannot create them again."
  }
}

run "only_the_nodes_reach_the_databases" {
  command = plan

  assert {
    condition = {
      for db, rule in aws_vpc_security_group_ingress_rule.from_nodes :
      db => "${rule.referenced_security_group_id} ${rule.ip_protocol} ${rule.from_port}-${rule.to_port} ${rule.cidr_ipv4 == null && rule.cidr_ipv6 == null}"
      } == {
      postgres = "sg-nodes tcp 5432-5432 true"
      mongo    = "sg-nodes tcp 27017-27017 true"
    }
    error_message = "Each database must accept its own port from the nodes' security group only, never from an address range."
  }

  assert {
    condition = alltrue([
      for sg in aws_security_group.db : sg.vpc_id == "vpc-platform" && length(sg.egress) == 0
    ])
    error_message = "The database security groups belong in the platform's VPC and have no outbound rules."
  }

  assert {
    condition = (
      tolist(aws_db_subnet_group.postgres.subnet_ids) == tolist(["subnet-private-a", "subnet-private-b"]) &&
      tolist(aws_docdb_subnet_group.mongo.subnet_ids) == tolist(["subnet-private-a", "subnet-private-b"])
    )
    error_message = "The databases belong in the platform's private subnets."
  }

  assert {
    condition = (
      aws_db_instance.postgres.db_subnet_group_name == "cryptobot-dev-postgres" &&
      aws_docdb_cluster.mongo.db_subnet_group_name == "cryptobot-dev-mongo"
    )
    error_message = "Each database must use its own subnet group (the private subnets)."
  }
}

run "dev_role_trusts_only_the_controller_for_dev_and_reads_only_dev" {
  command = plan

  assert {
    condition = (
      length(data.aws_iam_policy_document.external_secrets_trust.statement) == 1 &&
      toset(data.aws_iam_policy_document.external_secrets_trust.statement[0].actions) == toset(["sts:AssumeRole", "sts:TagSession"]) &&
      one(data.aws_iam_policy_document.external_secrets_trust.statement[0].principals).type == "AWS" &&
      toset(one(data.aws_iam_policy_document.external_secrets_trust.statement[0].principals).identifiers) == toset(["arn:aws:iam::123456789012:role/cryptobot-external-secrets"])
    )
    error_message = "Only the External Secrets controller's role may assume (and tag) the dev role."
  }

  assert {
    condition = {
      for c in data.aws_iam_policy_document.external_secrets_trust.statement[0].condition :
      c.variable => "${c.test} ${join(",", c.values)}"
      } == {
      "aws:RequestTag/esoNamespace" = "StringEquals dev"
      "aws:RequestTag/esoStoreKind" = "StringEquals SecretStore"
    }
    error_message = "The dev role may be assumed only with the session tags of a SecretStore in the dev namespace."
  }

  assert {
    condition = (
      length(data.aws_iam_policy_document.external_secrets_read.statement) == 1 &&
      toset(data.aws_iam_policy_document.external_secrets_read.statement[0].actions) == toset(["secretsmanager:GetSecretValue"]) &&
      toset(data.aws_iam_policy_document.external_secrets_read.statement[0].resources) == toset(["arn:aws:secretsmanager:eu-central-1:123456789012:secret:cryptobot/dev/*"])
    )
    error_message = "The dev role may only read the values of the cryptobot/dev/* secrets."
  }

  assert {
    condition = (
      aws_iam_role.external_secrets.name == "cryptobot-dev-external-secrets" &&
      aws_iam_role.external_secrets.assume_role_policy == data.aws_iam_policy_document.external_secrets_trust.json &&
      aws_iam_role_policy.external_secrets_read.policy == data.aws_iam_policy_document.external_secrets_read.json
    )
    error_message = "The role must be named for the controller's permission (cryptobot-*-external-secrets) and use the trust and read policies."
  }
}

run "each_pod_role_serves_one_service_account_with_one_model_right" {
  command = plan

  assert {
    condition = alltrue([
      for sa, doc in data.aws_iam_policy_document.pod_trust :
      length(doc.statement) == 1 &&
      toset(doc.statement[0].actions) == toset(["sts:AssumeRole", "sts:TagSession"]) &&
      one(doc.statement[0].principals).type == "Service" &&
      toset(one(doc.statement[0].principals).identifiers) == toset(["pods.eks.amazonaws.com"]) &&
      { for c in doc.statement[0].condition : c.variable => "${c.test} ${join(",", c.values)}" } == {
        "aws:RequestTag/eks-cluster-name"           = "StringEquals cryptobot"
        "aws:RequestTag/kubernetes-namespace"       = "StringEquals dev"
        "aws:RequestTag/kubernetes-service-account" = "StringEquals ${sa}"
      }
    ]) && length(data.aws_iam_policy_document.pod_trust) == 2
    error_message = "Each pod role may be assumed only by EKS Pod Identity for its own service account in the dev namespace of this cluster."
  }

  assert {
    condition = {
      for sa, doc in data.aws_iam_policy_document.pod_model_access :
      sa => "${join(",", sort(doc.statement[0].actions))} ${join(",", doc.statement[0].resources)} ${length(doc.statement)}"
      } == {
      api     = "s3:GetObject arn:aws:s3:::cryptobot-models-test/dev/* 1"
      retrain = "s3:PutObject arn:aws:s3:::cryptobot-models-test/dev/* 1"
    }
    error_message = "api may only read and retrain may only write, and only the dev/ prefix of the model bucket."
  }

  assert {
    condition = {
      for sa, role in aws_iam_role.pod :
      sa => "${role.name} ${role.assume_role_policy == data.aws_iam_policy_document.pod_trust[sa].json} ${aws_iam_role_policy.pod_model_access[sa].policy == data.aws_iam_policy_document.pod_model_access[sa].json}"
      } == {
      api     = "cryptobot-dev-api true true"
      retrain = "cryptobot-dev-retrain true true"
    }
    error_message = "Each role must be named after its service account and use its own trust and model policies."
  }

  assert {
    condition = {
      for sa, assoc in aws_eks_pod_identity_association.pod :
      sa => "${assoc.cluster_name} ${assoc.namespace} ${assoc.service_account} ${assoc.disable_session_tags}"
      } == {
      api     = "cryptobot dev api false"
      retrain = "cryptobot dev retrain false"
    }
    error_message = "Each role must be associated with its own service account in dev, with session tags on (the trust policy needs them)."
  }

  assert {
    condition     = output.model_s3 == { bucket = "cryptobot-models-test", key = "dev/model.pkl" }
    error_message = "The dev overlay must get the model bucket and the dev/ key."
  }
}

# IDs and host names exist only after an apply. The mock apply invents them, which is
# enough to check that each database is wired to its own security group and endpoint.
run "each_database_gets_its_own_security_group_and_endpoint" {
  command = apply

  # Pod Identity associations accept only well-formed role ARNs; distinct ones per role, so
  # a swapped association would show.
  override_resource {
    target = aws_iam_role.pod["api"]
    values = { arn = "arn:aws:iam::123456789012:role/cryptobot-dev-api" }
  }

  override_resource {
    target = aws_iam_role.pod["retrain"]
    values = { arn = "arn:aws:iam::123456789012:role/cryptobot-dev-retrain" }
  }

  assert {
    condition = alltrue([
      for db in ["postgres", "mongo"] :
      aws_vpc_security_group_ingress_rule.from_nodes[db].security_group_id == aws_security_group.db[db].id
    ])
    error_message = "Each database port must be opened on that database's own security group."
  }

  assert {
    condition = (
      aws_db_instance.postgres.vpc_security_group_ids == toset([aws_security_group.db["postgres"].id]) &&
      aws_docdb_cluster.mongo.vpc_security_group_ids == toset([aws_security_group.db["mongo"].id])
    )
    error_message = "Each database must sit in its own security group, and only there."
  }

  assert {
    condition = (
      jsondecode(aws_secretsmanager_secret_version.endpoint["postgres"].secret_string) == { host = aws_db_instance.postgres.address, port = 5432, dbname = "cryptobot" } &&
      jsondecode(aws_secretsmanager_secret_version.endpoint["mongo"].secret_string) == { host = aws_docdb_cluster.mongo.endpoint, port = 27017, dbname = "cryptobot" } &&
      aws_secretsmanager_secret_version.endpoint["postgres"].secret_id == aws_secretsmanager_secret.endpoint["postgres"].id &&
      aws_secretsmanager_secret_version.endpoint["mongo"].secret_id == aws_secretsmanager_secret.endpoint["mongo"].id
    )
    error_message = "Each endpoint secret must hold its own database's host name (without the port), port and database name."
  }

  assert {
    condition = (
      kubernetes_manifest.secret_store.manifest.apiVersion == "external-secrets.io/v1" &&
      kubernetes_manifest.secret_store.manifest.kind == "SecretStore" &&
      kubernetes_manifest.secret_store.manifest.metadata.namespace == "dev" &&
      kubernetes_manifest.secret_store.manifest.metadata.name == "aws-secrets-manager"
    )
    error_message = "The dev namespace needs a namespaced SecretStore (never a ClusterSecretStore)."
  }

  assert {
    condition = kubernetes_manifest.secret_store.manifest.spec.provider.aws == {
      service           = "SecretsManager"
      region            = "eu-central-1"
      role              = aws_iam_role.external_secrets.arn
      sessionTagsPolicy = "Simple"
    }
    error_message = "The SecretStore must use the dev role with sessionTagsPolicy Simple, and nothing else (no hand-written session tags, no other credentials)."
  }

  assert {
    condition = alltrue([
      for sa in ["api", "retrain"] :
      aws_eks_pod_identity_association.pod[sa].role_arn == aws_iam_role.pod[sa].arn &&
      aws_iam_role_policy.pod_model_access[sa].role == aws_iam_role.pod[sa].id
    ])
    error_message = "Each service account must get its own role, and each role its own model policy."
  }
}

# The same code with other inputs: every name, path and trust condition follows `env`, so
# neither environment can reach the other's secrets, model or namespace, and every setting
# follows its own input (values unlike dev's and unlike each other, so a hard-coded value or a
# mixed-up input shows).
run "every_name_path_condition_and_setting_follows_the_inputs" {
  command = plan

  variables {
    env                 = "prod"
    postgres            = { instance_class = "db.t4g.small", backup_retention_period = 7 }
    mongo               = { instance_class = "db.r6g.large", backup_retention_period = 5 }
    deletion_protection = true
    password_version    = 2
  }

  assert {
    condition = output.databases == {
      postgres = { instance_class = "db.t4g.small", backup_retention_period = 7, deletion_protection = true }
      mongo    = { instance_class = "db.r6g.large", backup_retention_period = 5, deletion_protection = true }
    }
    error_message = "Each database must take its size, backup days and deletion protection from the inputs."
  }

  assert {
    condition = (
      aws_db_instance.postgres.password_wo_version == 2 &&
      aws_docdb_cluster.mongo.master_password_wo_version == 2 &&
      alltrue([for version in aws_secretsmanager_secret_version.credentials : version.secret_string_wo_version == 2])
    )
    error_message = "Raising password_version must give both secrets and both databases new passwords."
  }

  assert {
    condition = (
      kubernetes_manifest.secret_store.manifest.metadata.namespace == "prod" &&
      kubernetes_manifest.secret_store.manifest.metadata.name == "aws-secrets-manager"
    )
    error_message = "prod's SecretStore belongs in the prod namespace (else prod's ExternalSecrets never sync)."
  }

  assert {
    condition = output.secret_names == {
      postgres            = "cryptobot/prod/postgres"
      mongo               = "cryptobot/prod/mongo"
      "postgres-endpoint" = "cryptobot/prod/postgres-endpoint"
      "mongo-endpoint"    = "cryptobot/prod/mongo-endpoint"
    }
    error_message = "prod's secrets must live under cryptobot/prod/."
  }

  assert {
    condition = (
      aws_db_instance.postgres.identifier == "cryptobot-prod-postgres" &&
      aws_docdb_cluster.mongo.cluster_identifier == "cryptobot-prod-mongo" &&
      aws_docdb_cluster_instance.mongo[0].identifier == "cryptobot-prod-mongo-1" &&
      aws_db_subnet_group.postgres.name == "cryptobot-prod-postgres" &&
      aws_docdb_subnet_group.mongo.name == "cryptobot-prod-mongo" &&
      toset([for sg in aws_security_group.db : sg.name]) == toset(["cryptobot-prod-postgres", "cryptobot-prod-mongo"])
    )
    error_message = "prod's databases, subnet groups and security groups must carry prod's names."
  }

  assert {
    condition = (
      aws_iam_role.external_secrets.name == "cryptobot-prod-external-secrets" &&
      {
        for c in data.aws_iam_policy_document.external_secrets_trust.statement[0].condition :
        c.variable => join(",", c.values)
        } == {
        "aws:RequestTag/esoNamespace" = "prod"
        "aws:RequestTag/esoStoreKind" = "SecretStore"
      } &&
      toset(data.aws_iam_policy_document.external_secrets_read.statement[0].resources) == toset(["arn:aws:secretsmanager:eu-central-1:123456789012:secret:cryptobot/prod/*"])
    )
    error_message = "prod's External Secrets role must trust only a SecretStore in prod and read only cryptobot/prod/*."
  }

  assert {
    condition = alltrue([
      for sa, doc in data.aws_iam_policy_document.pod_trust :
      { for c in doc.statement[0].condition : c.variable => join(",", c.values) }["aws:RequestTag/kubernetes-namespace"] == "prod" &&
      one(data.aws_iam_policy_document.pod_model_access[sa].statement[0].resources) == "arn:aws:s3:::cryptobot-models-test/prod/*" &&
      aws_iam_role.pod[sa].name == "cryptobot-prod-${sa}" &&
      aws_eks_pod_identity_association.pod[sa].namespace == "prod"
    ]) && output.model_s3 == { bucket = "cryptobot-models-test", key = "prod/model.pkl" }
    error_message = "prod's pod roles must serve only the prod namespace and only the prod/ model prefix."
  }
}

# What happens to the data (snapshots.tf). The prod runs use keep_data = true; the lookups
# "does the database exist?" and "newest manual snapshot" are answered by overrides. Runs in
# one file share their state, and the apply run above has already "created" dev's databases,
# so the prod runs use their own states (state_key).

run "dev_keeps_nothing_and_never_looks_for_snapshots" {
  command = plan

  assert {
    condition = (
      aws_db_instance.postgres.skip_final_snapshot == true &&
      aws_db_instance.postgres.final_snapshot_identifier == null &&
      aws_docdb_cluster.mongo.skip_final_snapshot == true &&
      aws_docdb_cluster.mongo.final_snapshot_identifier == null &&
      length(data.aws_db_instances.postgres) == 0 &&
      length(data.aws_rds_clusters.mongo) == 0 &&
      length(data.aws_db_snapshot.postgres) == 0 &&
      length(data.aws_db_cluster_snapshot.mongo) == 0
    )
    error_message = "Dev keeps nothing: no final snapshot, and no lookups of databases or snapshots."
  }

  assert {
    condition = alltrue([
      for db in ["postgres", "mongo"] :
      output.snapshots.restore_from[db] == null && output.snapshots.final_on_destroy[db] == null
    ])
    error_message = "Dev starts empty and leaves no snapshot behind."
  }
}

run "prod_create_restores_the_newest_manual_snapshot" {
  command   = plan
  state_key = "prod" # its own, empty state: these runs plan a create

  variables {
    env                 = "prod"
    keep_data           = true
    deletion_protection = true
    postgres            = { instance_class = "db.t4g.small", backup_retention_period = 7 }
    mongo               = { instance_class = "db.t4g.medium", backup_retention_period = 7 }
  }

  # Neither database exists yet; the newest final snapshots are these.
  override_data {
    target = data.aws_db_instances.postgres[0]
    values = { instance_identifiers = [] }
  }

  override_data {
    target = data.aws_rds_clusters.mongo[0]
    values = { cluster_identifiers = [] }
  }

  override_data {
    target = data.aws_db_snapshot.postgres[0]
    values = { id = "cryptobot-prod-postgres-final-2026-11-20-1730" }
  }

  override_data {
    target = data.aws_db_cluster_snapshot.mongo[0]
    values = { id = "cryptobot-prod-mongo-final-2026-11-20-1730" }
  }

  assert {
    condition = (
      one(data.aws_db_instances.postgres[0].filter).name == "db-instance-id" &&
      one(data.aws_db_instances.postgres[0].filter).values == toset(["cryptobot-prod-postgres"]) &&
      one(data.aws_rds_clusters.mongo[0].filter).name == "db-cluster-id" &&
      one(data.aws_rds_clusters.mongo[0].filter).values == toset(["cryptobot-prod-mongo"])
    )
    error_message = "The existence checks must ask for exactly this environment's databases."
  }

  assert {
    condition = (
      data.aws_db_snapshot.postgres[0].db_instance_identifier == "cryptobot-prod-postgres" &&
      data.aws_db_snapshot.postgres[0].snapshot_type == "manual" &&
      data.aws_db_snapshot.postgres[0].most_recent == true &&
      data.aws_db_cluster_snapshot.mongo[0].db_cluster_identifier == "cryptobot-prod-mongo" &&
      data.aws_db_cluster_snapshot.mongo[0].snapshot_type == "manual" &&
      data.aws_db_cluster_snapshot.mongo[0].most_recent == true
    )
    error_message = "The lookups must find the newest MANUAL snapshot (final snapshots) of this environment's own databases."
  }

  assert {
    condition = (
      aws_db_instance.postgres.snapshot_identifier == "cryptobot-prod-postgres-final-2026-11-20-1730" &&
      aws_docdb_cluster.mongo.snapshot_identifier == "cryptobot-prod-mongo-final-2026-11-20-1730" &&
      output.snapshots.restore_from == {
        postgres = "cryptobot-prod-postgres-final-2026-11-20-1730"
        mongo    = "cryptobot-prod-mongo-final-2026-11-20-1730"
      }
    )
    error_message = "A created database must be restored from the snapshot found for it."
  }

  assert {
    condition = (
      aws_db_instance.postgres.deletion_protection == true &&
      aws_db_instance.postgres.skip_final_snapshot == false &&
      aws_db_instance.postgres.final_snapshot_identifier == null &&
      aws_db_instance.postgres.backup_retention_period == 7 &&
      aws_docdb_cluster.mongo.deletion_protection == true &&
      aws_docdb_cluster.mongo.skip_final_snapshot == false &&
      aws_docdb_cluster.mongo.final_snapshot_identifier == null &&
      aws_docdb_cluster.mongo.backup_retention_period == 7
    )
    error_message = "A running prod database is protected, keeps 7 days of backups and takes a final snapshot, whose name only teardown step 1 sets."
  }
}

run "prod_running_never_looks_for_a_snapshot" {
  command   = plan
  state_key = "prod" # its own, empty state: these runs plan a create

  variables {
    env                 = "prod"
    keep_data           = true
    deletion_protection = true
  }

  override_data {
    target = data.aws_db_instances.postgres[0]
    values = { instance_identifiers = ["cryptobot-prod-postgres"] }
  }

  override_data {
    target = data.aws_rds_clusters.mongo[0]
    values = { cluster_identifiers = ["cryptobot-prod-mongo"] }
  }

  assert {
    condition = (
      length(data.aws_db_snapshot.postgres) == 0 &&
      length(data.aws_db_cluster_snapshot.mongo) == 0 &&
      output.snapshots.restore_from == { postgres = null, mongo = null }
    )
    error_message = "While the databases exist, no snapshot is looked up (none may exist yet in the first session)."
  }
}

run "prod_first_create_starts_empty" {
  command   = plan
  state_key = "prod" # its own, empty state: these runs plan a create

  variables {
    env                 = "prod"
    keep_data           = true
    deletion_protection = true
    first_create        = true
  }

  override_data {
    target = data.aws_db_instances.postgres[0]
    values = { instance_identifiers = [] }
  }

  override_data {
    target = data.aws_rds_clusters.mongo[0]
    values = { cluster_identifiers = [] }
  }

  assert {
    condition = (
      length(data.aws_db_snapshot.postgres) == 0 &&
      length(data.aws_db_cluster_snapshot.mongo) == 0 &&
      output.snapshots.restore_from == { postgres = null, mongo = null } &&
      aws_db_instance.postgres.skip_final_snapshot == false &&
      aws_docdb_cluster.mongo.skip_final_snapshot == false
    )
    error_message = "The very first create starts empty (no snapshot exists yet), but still keeps a final snapshot on destroy."
  }
}

run "a_named_snapshot_wins_over_the_newest" {
  command   = plan
  state_key = "prod" # its own, empty state: these runs plan a create

  variables {
    env                 = "prod"
    keep_data           = true
    deletion_protection = true
    restore_snapshots   = { mongo = "cryptobot-prod-mongo-final-2026-11-01-0900" }
  }

  override_data {
    target = data.aws_db_instances.postgres[0]
    values = { instance_identifiers = [] }
  }

  override_data {
    target = data.aws_rds_clusters.mongo[0]
    values = { cluster_identifiers = [] }
  }

  override_data {
    target = data.aws_db_snapshot.postgres[0]
    values = { id = "cryptobot-prod-postgres-final-2026-11-20-1730" }
  }

  assert {
    condition = (
      length(data.aws_db_cluster_snapshot.mongo) == 0 &&
      aws_docdb_cluster.mongo.snapshot_identifier == "cryptobot-prod-mongo-final-2026-11-01-0900" &&
      aws_db_instance.postgres.snapshot_identifier == "cryptobot-prod-postgres-final-2026-11-20-1730"
    )
    error_message = "A snapshot named in restore_snapshots replaces the lookup for that database only."
  }
}

run "teardown_step_1_names_the_final_snapshots" {
  command   = plan
  state_key = "prod" # its own, empty state: these runs plan a create

  variables {
    env                 = "prod"
    keep_data           = true
    deletion_protection = false
  }

  override_data {
    target = data.aws_db_instances.postgres[0]
    values = { instance_identifiers = ["cryptobot-prod-postgres"] }
  }

  override_data {
    target = data.aws_rds_clusters.mongo[0]
    values = { cluster_identifiers = ["cryptobot-prod-mongo"] }
  }

  assert {
    condition = (
      aws_db_instance.postgres.deletion_protection == false &&
      aws_docdb_cluster.mongo.deletion_protection == false &&
      can(regex("^cryptobot-prod-postgres-final-[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{4}$", aws_db_instance.postgres.final_snapshot_identifier)) &&
      can(regex("^cryptobot-prod-mongo-final-[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{4}$", aws_docdb_cluster.mongo.final_snapshot_identifier)) &&
      trimprefix(aws_db_instance.postgres.final_snapshot_identifier, "cryptobot-prod-postgres-") == trimprefix(aws_docdb_cluster.mongo.final_snapshot_identifier, "cryptobot-prod-mongo-") &&
      length(aws_docdb_cluster.mongo.final_snapshot_identifier) <= 63
    )
    error_message = "Teardown step 1 turns protection off and names both final snapshots after the same minute (DocumentDB allows 63 characters)."
  }
}

# A running prod database is never replaced because of a newer snapshot: "created from" is
# read only at creation (ignore_changes in databases.tf). First a (mock) create from one
# snapshot, then a plan in which the configuration names a newer one.
run "prod_is_created_from_a_snapshot" {
  command   = apply
  state_key = "prod-running"

  variables {
    env                 = "prod"
    keep_data           = true
    deletion_protection = true
    restore_snapshots = {
      postgres = "cryptobot-prod-postgres-final-2026-11-20-1730"
      mongo    = "cryptobot-prod-mongo-final-2026-11-20-1730"
    }
  }

  override_data {
    target = data.aws_db_instances.postgres[0]
    values = { instance_identifiers = [] }
  }

  override_data {
    target = data.aws_rds_clusters.mongo[0]
    values = { cluster_identifiers = [] }
  }

  override_resource {
    target = aws_iam_role.pod["api"]
    values = { arn = "arn:aws:iam::123456789012:role/cryptobot-prod-api" }
  }

  override_resource {
    target = aws_iam_role.pod["retrain"]
    values = { arn = "arn:aws:iam::123456789012:role/cryptobot-prod-retrain" }
  }

  assert {
    condition = (
      aws_db_instance.postgres.snapshot_identifier == "cryptobot-prod-postgres-final-2026-11-20-1730" &&
      aws_docdb_cluster.mongo.snapshot_identifier == "cryptobot-prod-mongo-final-2026-11-20-1730"
    )
    error_message = "The databases must be created from the named snapshots."
  }
}

run "a_newer_snapshot_never_replaces_running_prod" {
  command   = plan
  state_key = "prod-running"

  variables {
    env                 = "prod"
    keep_data           = true
    deletion_protection = true
    restore_snapshots = {
      postgres = "cryptobot-prod-postgres-final-2026-11-27-1730"
      mongo    = "cryptobot-prod-mongo-final-2026-11-27-1730"
    }
  }

  # As if AWS did not see the running databases: the configuration then asks for the newer
  # snapshots. Without ignore_changes, both databases would be deleted and re-created.
  override_data {
    target = data.aws_db_instances.postgres[0]
    values = { instance_identifiers = [] }
  }

  override_data {
    target = data.aws_rds_clusters.mongo[0]
    values = { cluster_identifiers = [] }
  }

  override_resource {
    target = aws_iam_role.pod["api"]
    values = { arn = "arn:aws:iam::123456789012:role/cryptobot-prod-api" }
  }

  override_resource {
    target = aws_iam_role.pod["retrain"]
    values = { arn = "arn:aws:iam::123456789012:role/cryptobot-prod-retrain" }
  }

  assert {
    condition = (
      aws_db_instance.postgres.snapshot_identifier == "cryptobot-prod-postgres-final-2026-11-20-1730" &&
      aws_docdb_cluster.mongo.snapshot_identifier == "cryptobot-prod-mongo-final-2026-11-20-1730"
    )
    error_message = "A running database must keep the snapshot it was created from (else Terraform would replace it)."
  }
}

# After a create that failed half-way, one database exists and the other does not: only the
# missing one may be restored, from its own snapshot (both directions).
run "only_the_missing_database_is_restored_postgres_exists" {
  command   = plan
  state_key = "prod"

  variables {
    env                 = "prod"
    keep_data           = true
    deletion_protection = true
  }

  override_data {
    target = data.aws_db_instances.postgres[0]
    values = { instance_identifiers = ["cryptobot-prod-postgres"] }
  }

  override_data {
    target = data.aws_rds_clusters.mongo[0]
    values = { cluster_identifiers = [] }
  }

  override_data {
    target = data.aws_db_cluster_snapshot.mongo[0]
    values = { id = "cryptobot-prod-mongo-final-2026-11-20-1730" }
  }

  assert {
    condition = (
      length(data.aws_db_snapshot.postgres) == 0 &&
      length(data.aws_db_cluster_snapshot.mongo) == 1 &&
      output.snapshots.restore_from.postgres == null &&
      output.snapshots.restore_from.mongo == "cryptobot-prod-mongo-final-2026-11-20-1730"
    )
    error_message = "With PostgreSQL running and DocumentDB missing, only DocumentDB is restored, from its own snapshot."
  }
}

run "only_the_missing_database_is_restored_mongo_exists" {
  command   = plan
  state_key = "prod"

  variables {
    env                 = "prod"
    keep_data           = true
    deletion_protection = true
  }

  override_data {
    target = data.aws_db_instances.postgres[0]
    values = { instance_identifiers = [] }
  }

  override_data {
    target = data.aws_rds_clusters.mongo[0]
    values = { cluster_identifiers = ["cryptobot-prod-mongo"] }
  }

  override_data {
    target = data.aws_db_snapshot.postgres[0]
    values = { id = "cryptobot-prod-postgres-final-2026-11-20-1730" }
  }

  assert {
    condition = (
      length(data.aws_db_snapshot.postgres) == 1 &&
      length(data.aws_db_cluster_snapshot.mongo) == 0 &&
      output.snapshots.restore_from.postgres == "cryptobot-prod-postgres-final-2026-11-20-1730" &&
      output.snapshots.restore_from.mongo == null
    )
    error_message = "With DocumentDB running and PostgreSQL missing, only PostgreSQL is restored, from its own snapshot."
  }
}

run "an_empty_snapshot_name_is_refused" {
  command = plan

  variables {
    env               = "prod"
    keep_data         = true
    restore_snapshots = { postgres = " " }
  }

  expect_failures = [var.restore_snapshots]
}

run "first_create_and_named_snapshots_are_refused_together" {
  command = plan

  variables {
    env               = "prod"
    keep_data         = true
    first_create      = true
    restore_snapshots = { mongo = "cryptobot-prod-mongo-final-2026-11-20-1730" }
  }

  expect_failures = [var.restore_snapshots]
}

run "first_create_needs_keep_data" {
  command = plan

  variables {
    first_create = true
  }

  expect_failures = [var.first_create]
}

run "restore_snapshots_takes_only_known_databases" {
  command = plan

  variables {
    env               = "prod"
    keep_data         = true
    restore_snapshots = { redis = "some-snapshot" }
  }

  expect_failures = [var.restore_snapshots]
}

run "restore_snapshots_needs_keep_data" {
  command = plan

  variables {
    restore_snapshots = { postgres = "some-snapshot" }
  }

  expect_failures = [var.restore_snapshots]
}

run "only_dev_and_prod_exist" {
  command = plan

  variables {
    env = "staging"
  }

  expect_failures = [var.env]
}

run "plan_stops_while_the_platform_is_destroyed" {
  command = plan

  variables {
    platform = {
      applied                              = false
      vpc_id                               = "platform-not-applied"
      private_subnet_ids                   = []
      node_security_group_id               = "platform-not-applied"
      cluster_name                         = "platform-not-applied"
      external_secrets_controller_role_arn = "platform-not-applied"
    }
  }

  expect_failures = [aws_db_subnet_group.postgres, aws_docdb_subnet_group.mongo]
}
