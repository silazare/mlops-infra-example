// Common data/locals

data "aws_availability_zones" "available" {}
data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  name            = "mltest"
  cluster_version = "1.37"
  # self-hosted Ubuntu AMI publication — pin separately
  ubuntu_eks_version = "1.36"
  region             = "ap-southeast-1"

  vpc_cidr = "10.0.0.0/16"
  azs      = slice(data.aws_availability_zones.available.names, 0, 3)

  tags = {
    Blueprint  = local.name
    GithubRepo = "github.com/silazare/mlops-infra-example"
    Owner      = "slazarev"
  }

  # Chart versions for helm_releases in the EKS layer
  argocd_version    = "10.10.5"
  karpenter_version = "1.15.0"

  # Git ref consumed by the root Application and propagated to all ApplicationSets
  argocd_target_revision = "master"

  # ECR repositories for Argo Workflows images build
  ecr_repositories = [
    # Jupyterlab images
    "jupyterlab-llm",
    "jupyterlab-llm-cache",
    # Triton images
    "triton-py",
    "triton-py-cache",
    "triton-ui",
    "triton-ui-cache",
  ]

  # Core and MLOps layers addons
  # Set to false to skip an addon deployment on the cluster.
  enabled_addons = {
    monitoring          = true  # kube-prometheus-stack + loki + promtail
    linstor             = false # piraeus-operator + linstor-cluster
    alb_controller      = true
    traefik             = true
    nvidia_gpu_operator = true
    metrics_server      = true
    istio               = true
    cert_manager        = false
    bank_vaults         = true  # vault-operator
    llm_d               = false # mlops layer - llm-d stack for inference setup
    jupyterlab          = false # mlops layer
    jupyterhub          = false # mlops layer
    argo_workflows      = true  # mlops layer
    openclaw            = false # mlops layer
  }
}
