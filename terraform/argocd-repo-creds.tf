// ArgoCD credential template for the entire ghcr.io OCI registry.
resource "kubernetes_secret_v1" "argocd_repo_creds_ghcr" {
  metadata {
    name      = "ghcr-oci-creds"
    namespace = "argocd"
    labels = {
      "argocd.argoproj.io/secret-type" = "repo-creds"
    }
  }
  data = {
    url       = "ghcr.io"
    type      = "helm"
    enableOCI = "true"
  }

  depends_on = [helm_release.argocd]
}
