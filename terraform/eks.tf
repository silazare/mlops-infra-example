// EKS cluster
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.18"

  name               = local.name
  kubernetes_version = local.cluster_version

  # Give the Terraform identity admin access to the cluster
  # which will allow it to deploy resources into the cluster
  enable_cluster_creator_admin_permissions = true
  endpoint_public_access                   = true

  addons = {
    aws-ebs-csi-driver = {
      most_recent = true
      pod_identity_association = [
        {
          role_arn        = aws_iam_role.ebs_csi_controller.arn
          service_account = "ebs-csi-controller-sa"
        }
      ]
      configuration_values = jsonencode({
        controller = {
          nodeSelector = {
            "karpenter.sh/controller" = "true"
          }
          tolerations = [
            {
              key      = "karpenter.sh/controller"
              operator = "Exists"
              effect   = "NoSchedule"
            }
          ]
        }
      })
    }
    coredns = {
      most_recent = true
      configuration_values = jsonencode({
        nodeSelector = {
          "karpenter.sh/controller" = "true"
        }
        tolerations = [
          {
            key      = "karpenter.sh/controller"
            operator = "Exists"
            effect   = "NoSchedule"
          }
        ]
      })
    }
    eks-pod-identity-agent = {
      most_recent = true
      # Must exist before nodes join so first pods can obtain IAM tokens
      before_compute = true
    }
    kube-proxy = {
      most_recent = true
    }
    vpc-cni = {
      most_recent = true
      # Must exist before nodes join, otherwise kubelet never reports Ready
      before_compute = true
    }
  }

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  eks_managed_node_groups = {
    karpenter = {
      instance_types = ["t3a.large"]
      capacity_type  = "SPOT"

      min_size     = 2
      max_size     = 3
      desired_size = 2

      iam_role_additional_policies = {
        # least-privilege, scoped to this cluster via eks:eks-cluster-name tag
        AmazonEBSCSIDriverPolicy     = "arn:aws:iam::aws:policy/AmazonEBSCSIDriverEKSClusterScopedPolicy"
        AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
      }

      labels = {
        # Used to ensure Karpenter runs on nodes that it does not manage
        "karpenter.sh/controller" = "true"
      }

      taints = {
        karpenter = {
          key    = "karpenter.sh/controller"
          value  = "true"
          effect = "NO_SCHEDULE"
        }
      }

      tags = {
        # Tag is required for AmazonEBSCSIDriverEKSClusterScopedPolicy
        "ebs.csi.aws.com/cluster-name" = local.name
      }
    }
  }

  node_security_group_tags = {
    # Karpenter should discover exactly one SG with this tag
    "karpenter.sh/discovery" = local.name
  }

  tags = local.tags
}

// Karpenter module
module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "~> 21.18"

  cluster_name = module.eks.cluster_name

  # Name needs to match role name passed to the EC2NodeClass
  node_iam_role_use_name_prefix = false
  node_iam_role_name            = local.name

  create_pod_identity_association = true

  # Used to attach additional IAM policies to the Karpenter node IAM role
  node_iam_role_additional_policies = {
    # least-privilege, scoped to this cluster via eks:eks-cluster-name tag
    AmazonEBSCSIDriverPolicy     = "arn:aws:iam::aws:policy/AmazonEBSCSIDriverEKSClusterScopedPolicy"
    AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  }

  tags = local.tags
}
