# The account and partition, for the ARNs in the IAM policies (read from the credentials in
# use, so no account ID is written anywhere in the code).
data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}
