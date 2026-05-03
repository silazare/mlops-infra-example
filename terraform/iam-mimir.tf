// Mimir IAM
resource "aws_iam_role" "mimir" {
  name               = "${local.name}-mimir"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_assume.json

  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "mimir_s3" {
  role       = aws_iam_role.mimir.name
  policy_arn = aws_iam_policy.mimir_s3_access.arn
}

resource "aws_eks_pod_identity_association" "mimir" {
  cluster_name    = module.eks.cluster_name
  namespace       = "monitoring"
  service_account = "mimir"
  role_arn        = aws_iam_role.mimir.arn
}
