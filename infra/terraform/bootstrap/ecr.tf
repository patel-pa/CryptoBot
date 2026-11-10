# The one image every CryptoBot service runs (api, streamer, dashboard, jobs).
# Tag = git commit SHA; IMMUTABLE means a tag can never point to another image later,
# so prod runs byte for byte what was tested in dev.
resource "aws_ecr_repository" "app" {
  name                 = "cryptobot"
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true # basic scanning, free
  }

  encryption_configuration {
    encryption_type = "AES256"
  }
}

# Rollback = redeploy an older SHA, so old images are kept: the newest 10 images
# promoted to prod (second tag prod-<main SHA>), however many dev pushes follow, and
# the newest 30 tagged images overall. An image matched by a rule's tag filter is never
# expired by a later rule, so the prod rule comes first; prod images still count
# toward the 30, they just cannot be expired by that rule. Parts of a tagged image
# (platform images, attestations) are never expired while that image exists; only
# leftovers of failed pushes are untagged.
resource "aws_ecr_lifecycle_policy" "app" {
  repository = aws_ecr_repository.app.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Images promoted to prod: keep the newest 10"
        selection = {
          tagStatus      = "tagged"
          tagPatternList = ["prod-*"]
          countType      = "imageCountMoreThan"
          countNumber    = 10
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Untagged images (failed pushes) after 1 day"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 1
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 3
        description  = "All tagged images: keep the newest 30 (prod-* never expired here)"
        selection = {
          tagStatus      = "tagged"
          tagPatternList = ["*"]
          countType      = "imageCountMoreThan"
          countNumber    = 30
        }
        action = { type = "expire" }
      },
    ]
  })
}
