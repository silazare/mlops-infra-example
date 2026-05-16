// Default EC2NodeClass and NodePool — general-purpose CPU workloads
resource "kubectl_manifest" "karpenter_ec2nodeclass_al2023" {
  yaml_body = <<EOF
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: al2023
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

resource "kubectl_manifest" "karpenter_nodepool_al2023" {
  yaml_body = <<EOF
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: al2023
spec:
  disruption:
    budgets:
      - nodes: 10%
    consolidateAfter: 0s
    consolidationPolicy: WhenEmptyOrUnderutilized
  limits:
    cpu: "20"
    memory: 128Gi
  template:
    metadata:
      labels:
        nodegroup: al2023
    spec:
      expireAfter: 720h
      nodeClassRef:
        group: karpenter.k8s.aws
        kind: EC2NodeClass
        name: al2023
      requirements:
        - key: "karpenter.k8s.aws/instance-category"
          operator: In
          values: ["t"]
          minValues: 1
        - key: "karpenter.k8s.aws/instance-cpu"
          operator: In
          values: ["2", "4", "8"]
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
    kubectl_manifest.karpenter_ec2nodeclass_al2023
  ]
}

// GPU EC2NodeClass and NodePool — GPU workloads
resource "kubectl_manifest" "karpenter_ec2nodeclass_al2023_gpu" {
  yaml_body = <<EOF
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: al2023-gpu
spec:
  amiFamily: AL2023
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

resource "kubectl_manifest" "karpenter_nodepool_al2023_gpu" {
  yaml_body = <<EOF
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: al2023-gpu
spec:
  disruption:
    budgets:
      - nodes: 10%
    # Keep GPU nodes warm
    consolidateAfter: 15m
    consolidationPolicy: WhenEmpty
  limits:
    nvidia.com/gpu: "1"
  template:
    metadata:
      labels:
        nodegroup: al2023-gpu
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
        name: al2023-gpu
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
    kubectl_manifest.karpenter_ec2nodeclass_al2023_gpu
  ]
}

// Ubuntu EC2NodeClass and NodePool (self-hosted image) — general-purpose CPU workloads
data "aws_ssm_parameter" "ubuntu_eks_ami" {
  name = "/aws/service/canonical/ubuntu/eks/24.04/${local.cluster_version}/stable/current/amd64/hvm/ebs-gp3/ami-id"
}

data "cloudinit_config" "ubuntu_node" {
  base64_encode = false
  gzip          = false
  boundary      = "//"

  part {
    content_type = "text/x-shellscript"
    content      = <<-EOT
      #!/bin/bash
      set -ex

      /etc/eks/bootstrap.sh ${module.eks.cluster_name} \
        --b64-cluster-ca ${module.eks.cluster_certificate_authority_data} \
        --apiserver-endpoint ${module.eks.cluster_endpoint} \
        --kubelet-extra-args "--node-labels=nodegroup=ubuntu --register-with-taints=nodegroup=ubuntu:NoSchedule"
    EOT
  }
}

resource "kubectl_manifest" "karpenter_ec2nodeclass_ubuntu" {
  yaml_body = <<EOF
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: ubuntu
spec:
  amiFamily: Custom
  amiSelectorTerms:
    - id: ${data.aws_ssm_parameter.ubuntu_eks_ami.value}
  role: ${module.karpenter.node_iam_role_name}
  subnetSelectorTerms:
    - tags:
        karpenter.sh/discovery: ${local.name}
  securityGroupSelectorTerms:
    - tags:
        karpenter.sh/discovery: ${local.name}
  blockDeviceMappings:

    - deviceName: /dev/sda1
      ebs:
        volumeSize: 64Gi
        volumeType: gp3
        encrypted: true
  metadataOptions:
    httpEndpoint: enabled
    httpProtocolIPv6: disabled
    httpPutResponseHopLimit: 2
    httpTokens: required
  userData: |
    ${indent(4, data.cloudinit_config.ubuntu_node.rendered)}
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

resource "kubectl_manifest" "karpenter_nodepool_ubuntu" {
  yaml_body = <<EOF
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: ubuntu
spec:
  disruption:
    budgets:
      - nodes: 10%
    consolidateAfter: 0s
    consolidationPolicy: WhenEmptyOrUnderutilized
  limits:
    cpu: "8"
    memory: 16Gi
  template:
    metadata:
      labels:
        nodegroup: ubuntu
    spec:
      taints:
        - key: nodegroup
          value: ubuntu
          effect: NoSchedule
      expireAfter: 24h
      nodeClassRef:
        group: karpenter.k8s.aws
        kind: EC2NodeClass
        name: ubuntu
      requirements:
        - key: "karpenter.k8s.aws/instance-category"
          operator: In
          values: ["t"]
        - key: "karpenter.k8s.aws/instance-cpu"
          operator: In
          values: ["2", "4"]
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
    kubectl_manifest.karpenter_ec2nodeclass_ubuntu
  ]
}

// Ubuntu EC2NodeClass and NodePool (self-hosted image) — GPU workloads
data "cloudinit_config" "ubuntu_gpu_node" {
  base64_encode = false
  gzip          = false
  boundary      = "//"

  part {
    content_type = "text/x-shellscript"
    content      = <<-EOT
      #!/bin/bash
      set -ex

      /etc/eks/bootstrap.sh ${module.eks.cluster_name} \
        --b64-cluster-ca ${module.eks.cluster_certificate_authority_data} \
        --apiserver-endpoint ${module.eks.cluster_endpoint} \
        --kubelet-extra-args "--node-labels=nodegroup=gpu-ubuntu --register-with-taints=nvidia.com/gpu=true:NoSchedule"
    EOT
  }
}

resource "kubectl_manifest" "karpenter_ec2nodeclass_ubuntu_gpu" {
  yaml_body = <<EOF
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: ubuntu-gpu
spec:
  amiFamily: Custom
  amiSelectorTerms:
    - id: ${data.aws_ssm_parameter.ubuntu_eks_ami.value}
  role: ${module.karpenter.node_iam_role_name}
  subnetSelectorTerms:
    - tags:
        karpenter.sh/discovery: ${local.name}
  securityGroupSelectorTerms:
    - tags:
        karpenter.sh/discovery: ${local.name}
  blockDeviceMappings:
    - deviceName: /dev/sda1
      ebs:
        volumeSize: 128Gi
        volumeType: gp3
        encrypted: true
  metadataOptions:
    httpEndpoint: enabled
    httpProtocolIPv6: disabled
    httpPutResponseHopLimit: 2
    httpTokens: required
  userData: |
    ${indent(4, data.cloudinit_config.ubuntu_gpu_node.rendered)}
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

resource "kubectl_manifest" "karpenter_nodepool_ubuntu_gpu" {
  yaml_body = <<EOF
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: ubuntu-gpu
spec:
  disruption:
    budgets:
      - nodes: 10%
    consolidateAfter: 15m
    consolidationPolicy: WhenEmpty
  limits:
    nvidia.com/gpu: "1"
  template:
    metadata:
      labels:
        nodegroup: ubuntu-gpu
    spec:
      taints:
      # Block non-GPU pods; only workloads with the matching toleration land here.
      # The NVIDIA GPU Operator components tolerate this taint by default.
        - key: nvidia.com/gpu
          value: "true"
          effect: NoSchedule
      expireAfter: 24h
      nodeClassRef:
        group: karpenter.k8s.aws
        kind: EC2NodeClass
        name: ubuntu-gpu
      requirements:
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
    kubectl_manifest.karpenter_ec2nodeclass_ubuntu_gpu
  ]
}
