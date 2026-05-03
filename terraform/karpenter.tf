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

// Default EC2NodeClass and NodePool — general-purpose CPU workloads
resource "kubectl_manifest" "karpenter_ec2nodeclass_default" {
  yaml_body = <<EOF
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: default
spec:
  amiSelectorTerms:
    - alias: al2023@latest # Amazon Linux 2023
  role: ${module.karpenter.node_iam_role_name}
  subnetSelectorTerms:
    - tags:
        karpenter.sh/discovery: ${local.name}
  securityGroupSelectorTerms:
    - tags:
        karpenter.sh/discovery: ${local.name}
  blockDeviceMappings:
    - deviceName: /dev/xvda
      ebs:
        volumeSize: 64Gi
        volumeType: gp3
        encrypted: true
  metadataOptions:
    httpEndpoint: enabled
    httpProtocolIPv6: disabled
    httpPutResponseHopLimit: 2
    httpTokens: required
  tags:
    karpenter.sh/discovery: ${local.name}
    CostCenter: ${local.name}
    # Tag is required for AmazonEBSCSIDriverEKSClusterScopedPolicy
    ebs.csi.aws.com/cluster-name: ${local.name}
EOF

  depends_on = [
    helm_release.karpenter_crd,
    helm_release.karpenter
  ]
}

resource "kubectl_manifest" "karpenter_nodepool_default" {
  yaml_body = <<EOF
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: default
spec:
  disruption:
    budgets:
      - nodes: 10%
    consolidateAfter: 0s
    consolidationPolicy: WhenEmptyOrUnderutilized
  limits:
    cpu: "100"
    memory: 100Gi
  template:
    metadata:
      labels:
        nodegroup: default
    spec:
      expireAfter: 720h
      nodeClassRef:
        group: karpenter.k8s.aws
        kind: EC2NodeClass
        name: default
      requirements:
        - key: "karpenter.k8s.aws/instance-category"
          operator: In
          values: ["t"]
          minValues: 1
        - key: "karpenter.k8s.aws/instance-cpu"
          operator: In
          values: ["4", "8"]
        - key: "karpenter.k8s.aws/instance-generation"
          operator: Gt
          values: ["2"]
        - key: "kubernetes.io/arch"
          operator: In
          values: ["amd64"]
        - key: kubernetes.io/os
          operator: In
          values: ["linux"]
        - key: "karpenter.sh/capacity-type"
          operator: In
          values: ["spot"]
EOF

  depends_on = [
    helm_release.karpenter_crd,
    helm_release.karpenter,
    kubectl_manifest.karpenter_ec2nodeclass_default
  ]
}

// GPU EC2NodeClass and NodePool
resource "kubectl_manifest" "karpenter_ec2nodeclass_gpu" {
  yaml_body = <<EOF
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: gpu
spec:
  amiSelectorTerms:
    - alias: al2023@latest
  role: ${module.karpenter.node_iam_role_name}
  subnetSelectorTerms:
    - tags:
        karpenter.sh/discovery: ${local.name}
  securityGroupSelectorTerms:
    - tags:
        karpenter.sh/discovery: ${local.name}
  blockDeviceMappings:
    - deviceName: /dev/xvda
      ebs:
        volumeSize: 128Gi
        volumeType: gp3
        encrypted: true
  metadataOptions:
    httpEndpoint: enabled
    httpProtocolIPv6: disabled
    httpPutResponseHopLimit: 2
    httpTokens: required
  tags:
    karpenter.sh/discovery: ${local.name}
    CostCenter: ${local.name}
    ebs.csi.aws.com/cluster-name: ${local.name}
EOF

  depends_on = [
    helm_release.karpenter_crd,
    helm_release.karpenter
  ]
}

resource "kubectl_manifest" "karpenter_nodepool_gpu" {
  yaml_body = <<EOF
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: gpu
spec:
  disruption:
    budgets:
      - nodes: 10%
    # Keep GPU nodes warm
    consolidateAfter: 30m
    consolidationPolicy: WhenEmpty
  limits:
    nvidia.com/gpu: "8"
  template:
    metadata:
      labels:
        nodegroup: gpu
    spec:
      # Block non-GPU pods; only workloads with the matching toleration land here.
      # The NVIDIA GPU Operator components tolerate this taint by default.
      taints:
        - key: nvidia.com/gpu
          value: "true"
          effect: NoSchedule
      expireAfter: 720h
      nodeClassRef:
        group: karpenter.k8s.aws
        kind: EC2NodeClass
        name: gpu
      requirements:
        # g4dn = T4, g5 = A10G; both work with NVIDIA GPU Operator on AL2023
        - key: "node.kubernetes.io/instance-type"
          operator: In
          values: ["g4dn.xlarge", "g4dn.2xlarge", "g5.xlarge", "g5.2xlarge"]
        - key: "kubernetes.io/arch"
          operator: In
          values: ["amd64"]
        - key: kubernetes.io/os
          operator: In
          values: ["linux"]
        - key: "karpenter.sh/capacity-type"
          operator: In
          values: ["spot"]
EOF

  depends_on = [
    helm_release.karpenter_crd,
    helm_release.karpenter,
    kubectl_manifest.karpenter_ec2nodeclass_gpu
  ]
}
