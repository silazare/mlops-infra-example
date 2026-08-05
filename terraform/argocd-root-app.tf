// GitOps Bridge — cluster Secret >> TF outputs as annotations,
// For ApplicationSets usage in the Git repo (argocd/applications/core/*).
resource "kubernetes_secret_v1" "argocd_in_cluster" {
  metadata {
    name      = "in-cluster"
    namespace = "argocd"
    labels = merge(
      { "argocd.argoproj.io/secret-type" = "cluster" },
      # Core layer addon toggles sourced from local.enabled_addons
      { for k, v in local.enabled_addons : "enable_${k}" => tostring(v) },
    )
    annotations = {
      cluster_name      = module.eks.cluster_name
      region            = local.region
      vpc_id            = module.vpc.vpc_id
      traefik_sg_id     = aws_security_group.ingress_traefik_external.id
      alb_backend_sg_id = aws_security_group.alb_backend.id
      target_revision   = local.argocd_target_revision
    }
  }
  data = {
    name   = "in-cluster"
    server = "https://kubernetes.default.svc"
    config = jsonencode({
      tlsClientConfig = { insecure = false }
    })
  }
  depends_on = [helm_release.argocd]
}

// Root App of Apps
resource "kubectl_manifest" "argocd_root" {
  yaml_body = <<-YAML
    apiVersion: argoproj.io/v1alpha1
    kind: Application
    metadata:
      name: root
      namespace: argocd
      # Cascade-delete all managed resources when the root Application is removed
      finalizers:
        - resources-finalizer.argocd.argoproj.io
    spec:
      project: default
      source:
        repoURL: https://github.com/silazare/mlops-infra-example
        targetRevision: ${local.argocd_target_revision}
        path: argocd/applications
        directory:
          recurse: true
      destination:
        server: https://kubernetes.default.svc
        namespace: argocd
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
  YAML

  depends_on = [
    helm_release.argocd,
    kubernetes_secret_v1.argocd_in_cluster,
  ]
}
