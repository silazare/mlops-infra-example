// ArgoCD Helm release
resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  namespace        = "argocd"
  version          = local.argocd_version
  create_namespace = true

  values = [
    <<-EOT
    global:
      nodeSelector:
        karpenter.sh/controller: "true"
      tolerations:
        - key: karpenter.sh/controller
          operator: Exists
          effect: NoSchedule

    # HA redis cluster (3 servers + 3 haproxy)
    redis-ha:
      enabled: false
    # Single in-memory redis for app state and caching
    redis:
      enabled: true

    # OIDC/SSO proxy for GitHub/Google/Okta login
    dex:
      enabled: false

    # Webhook and Slack alert sender
    notifications:
      enabled: false

    # Core reconciler — watches apps and syncs state. StatefulSet, min 1.
    controller:
      replicas: 1

    # Disable Argo's built-in HTTPS redirect for sandbox — Traefik terminates TLS
    configs:
      params:
        server.insecure: true

    # API / UI frontend.
    server:
      replicas: 1
      autoscaling:
        enabled: false
      ingress:
        enabled: true
        ingressClassName: traefik
        hostname: argocd.local

    # Clones git repos and renders manifests
    repoServer:
      replicas: 1
      autoscaling:
        enabled: false

    # Generates Applications from templates (ApplicationSet CR).
    applicationSet:
      replicas: 1
    EOT
  ]

  depends_on = [
    module.eks,
    helm_release.karpenter,
  ]
}

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
      cluster_name    = module.eks.cluster_name
      region          = local.region
      vpc_id          = module.vpc.vpc_id
      traefik_sg_id   = aws_security_group.ingress_traefik_external.id
      target_revision = local.argocd_target_revision

      # Mimir S3 bucket names — consumed by argocd/applications/core/mimir.yaml
      mimir_blocks_bucket       = aws_s3_bucket.mimir_blocks.id
      mimir_alertmanager_bucket = aws_s3_bucket.mimir_alertmanager.id
      mimir_ruler_bucket        = aws_s3_bucket.mimir_ruler.id
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
