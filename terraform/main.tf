// Common data/locals

data "aws_availability_zones" "available" {}
data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  name            = "mltest"
  cluster_version = "1.36"
  # self-hosted Ubuntu AMI publication — pin separately
  ubuntu_eks_version = "1.36"
  region             = "eu-west-1"

  vpc_cidr = "10.0.0.0/16"
  azs      = slice(data.aws_availability_zones.available.names, 0, 3)

  tags = {
    Blueprint  = local.name
    GithubRepo = "github.com/silazare/mlops-infra-example"
    Owner      = "slazarev"
  }

  # Chart versions for helm_releases in the EKS layer
  argocd_version    = "10.0.0"
  karpenter_version = "1.13.0"

  # Git ref consumed by the root Application and propagated to all ApplicationSets
  argocd_target_revision = "master"

  # ECR repositories
  ecr_repositories = [
    "jupyterlab-llm",
    "jupyterlab-llm-cache",
  ]

  # Core and MLOps layers addons
  # Set to false to skip an addon deployment on the cluster.
  enabled_addons = {
    monitoring          = false # alloy + mimir + grafana + loki
    linstor             = false # piraeus-operator + linstor-cluster
    alb_controller      = true
    traefik             = true
    nvidia_gpu_operator = true
    metrics_server      = true
    kube_state_metrics  = true
    istio               = true
    cert_manager        = false
    llm_d               = true  # mlops layer - llm-d stack for inference setup
    jupyterlab          = false # mlops layer
    jupyterhub          = false # mlops layer
    argo_workflows      = false # mlops layer
  }
}
