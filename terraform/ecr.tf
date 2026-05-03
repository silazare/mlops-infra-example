resource "aws_ecr_repository" "this" {
  for_each = toset(local.ecr_repositories)

  name = each.key
  tags = local.tags
}
