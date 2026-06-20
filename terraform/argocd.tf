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
