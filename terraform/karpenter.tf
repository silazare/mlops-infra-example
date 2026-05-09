// Karpenter CRD Helm release
resource "helm_release" "karpenter_crd" {
  name       = "karpenter-crd"
  chart      = "karpenter-crd"
  repository = "oci://public.ecr.aws/karpenter"
  namespace  = "kube-system"
  version    = local.karpenter_version

  timeout = 600
  atomic  = true

  depends_on = [
    module.eks,
    module.karpenter
  ]
}

// Karpenter Helm release
resource "helm_release" "karpenter" {
  name       = "karpenter"
  chart      = "karpenter"
  repository = "oci://public.ecr.aws/karpenter"
  namespace  = "kube-system"
  version    = local.karpenter_version

  values = [
    <<-EOT
    nodeSelector:
      karpenter.sh/controller: 'true'
    tolerations:
      - key: CriticalAddonsOnly
        operator: Exists
      - key: karpenter.sh/controller
        operator: Exists
        effect: NoSchedule
    settings:
      clusterName: ${module.eks.cluster_name}
      clusterEndpoint: ${module.eks.cluster_endpoint}
      interruptionQueue: ${module.karpenter.queue_name}
    EOT
  ]

  timeout = 600
  atomic  = true

  depends_on = [
    module.eks,
    module.karpenter,
    helm_release.karpenter_crd,
  ]
}
