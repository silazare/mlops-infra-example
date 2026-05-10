// BuildKit IAM + Pod Identity for in-cluster image-build Jobs that push to ECR
resource "kubernetes_namespace_v1" "buildkit" {
  metadata {
    name = "buildkit"
  }
}

resource "kubernetes_service_account_v1" "buildkit" {
  metadata {
    name      = "buildkit"
    namespace = kubernetes_namespace_v1.buildkit.metadata[0].name
  }
}

data "aws_iam_policy_document" "buildkit" {
  statement {
    sid       = "ECRAuthToken"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid    = "ECRPushPullForBuildRepos"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:PutImage",
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
    ]
    resources = [for r in local.ecr_repositories : aws_ecr_repository.this[r].arn]
  }
}

resource "aws_iam_policy" "buildkit" {
  name        = "${local.name}-buildkit"
  description = "ECR push/pull for in-cluster image build Jobs"
  policy      = data.aws_iam_policy_document.buildkit.json
}

resource "aws_iam_role" "buildkit" {
  name               = "${local.name}-buildkit"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_assume.json
  tags               = local.tags
}

resource "aws_iam_role_policy_attachment" "buildkit" {
  role       = aws_iam_role.buildkit.name
  policy_arn = aws_iam_policy.buildkit.arn
}

resource "aws_eks_pod_identity_association" "buildkit" {
  cluster_name    = module.eks.cluster_name
  namespace       = kubernetes_namespace_v1.buildkit.metadata[0].name
  service_account = kubernetes_service_account_v1.buildkit.metadata[0].name
  role_arn        = aws_iam_role.buildkit.arn
}
