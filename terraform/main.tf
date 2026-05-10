// Common data/locals

data "aws_availability_zones" "available" {}
data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  name            = "mltest"
  cluster_version = "1.35"
  region          = "eu-west-1"

  vpc_cidr = "10.0.0.0/16"
  azs      = slice(data.aws_availability_zones.available.names, 0, 3)

  tags = {
    Blueprint  = local.name
    GithubRepo = "github.com/silazare/mlops-infra-example"
    Owner      = "slazarev"
  }

  # Chart versions for helm_releases in the EKS layer
  argocd_version    = "9.5.2"
  karpenter_version = "1.11.1"

  # Git ref consumed by the root Application and propagated to all ApplicationSets
  argocd_target_revision = "master"

  # ECR repositories
  ecr_repositories = [
    "jupyterlab-llm",
    "jupyterlab-llm-cache",
  ]
}
