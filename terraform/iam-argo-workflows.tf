// Argo Workflows IAM for step pods
data "aws_iam_policy_document" "argo_workflows" {
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

resource "aws_iam_policy" "argo_workflows" {
  name        = "${local.name}-argo-workflows"
  description = "Argo Workflows ECR access"
  policy      = data.aws_iam_policy_document.argo_workflows.json
}

resource "aws_iam_role" "argo_workflows" {
  name               = "${local.name}-argo-workflows"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_assume.json
  tags               = local.tags
}

resource "aws_iam_role_policy_attachment" "argo_workflows" {
  role       = aws_iam_role.argo_workflows.name
  policy_arn = aws_iam_policy.argo_workflows.arn
}

resource "aws_eks_pod_identity_association" "argo_workflows" {
  cluster_name    = module.eks.cluster_name
  namespace       = "argo"
  service_account = "argo-workflow"
  role_arn        = aws_iam_role.argo_workflows.arn
}
