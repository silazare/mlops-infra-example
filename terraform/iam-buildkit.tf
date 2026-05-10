// Image builder IAM + Pod Identity for in-cluster BuildKit Jobs that push to ECR
resource "kubernetes_namespace_v1" "buildkit" {
  metadata {
    name = "buildkit"
  }
}

resource "kubernetes_service_account_v1" "image_builder" {
  metadata {
    name      = "image-builder"
    namespace = kubernetes_namespace_v1.buildkit.metadata[0].name
  }
}

data "aws_iam_policy_document" "image_builder" {
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

resource "aws_iam_policy" "image_builder" {
  name        = "${local.name}-image-builder"
  description = "ECR push/pull for in-cluster image build Jobs"
  policy      = data.aws_iam_policy_document.image_builder.json
}

resource "aws_iam_role" "image_builder" {
  name               = "${local.name}-image-builder"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_assume.json
  tags               = local.tags
}

resource "aws_iam_role_policy_attachment" "image_builder" {
  role       = aws_iam_role.image_builder.name
  policy_arn = aws_iam_policy.image_builder.arn
}

resource "aws_eks_pod_identity_association" "image_builder" {
  cluster_name    = module.eks.cluster_name
  namespace       = kubernetes_namespace_v1.buildkit.metadata[0].name
  service_account = kubernetes_service_account_v1.image_builder.metadata[0].name
  role_arn        = aws_iam_role.image_builder.arn
}
