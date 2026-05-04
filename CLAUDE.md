# Project Overview

AWS EKS cluster bootstrap for ML/observability workloads, built on the same GitOps Bridge pattern as [argocd-infra-example](../argocd-infra-example/) but with a Mimir+Alloy+Loki+Grafana stack instead of kube-prometheus-stack, an additional GPU NodePool in Karpenter, and a manual JupyterLab deployment slot under `mlops/`.

Cluster name is `mltest`, region `eu-west-1`, K8s `1.35`. Sandbox-grade — single-replica everywhere, non-production secrets in git, local TF state.

## Two-layer architecture

```
Terraform (cluster-layer — anything AWS-native or required for ArgoCD itself)
  ↓  cluster Secret (GitOps bridge)
  ↓  root Application
ArgoCD GitOps (platform + workloads — everything that runs *on top of* the cluster)
```

**Boundary rule:** Terraform manages anything that requires AWS API or must exist for ArgoCD apps to schedule. ArgoCD manages everything else.

Two foundational k8s resources are deliberately on the TF side:
- **Karpenter** — provisions *capacity* (same layer as VPC-CNI / EBS-CSI), it's not an application.
- **`gp3` StorageClass** — Mimir/Loki/Grafana PVCs depend on it. Putting it under ArgoCD creates a bootstrap deadlock (apps requiring gp3 hang waiting for the storage-classes Application to sync first).

## Repository layout

```
terraform/                        # cluster-layer
  main.tf                         # locals (cluster name `mltest`, region, ECR repo list, chart versions, target_revision)
  versions.tf                     # provider + Terraform version pins
  providers.tf                    # aws, helm, kubectl, kubernetes (all with exec auth)
  vpc.tf                          # VPC module + Traefik external/node SGs
  eks.tf                          # EKS module (addons incl. EBS CSI Pod Identity assoc) + managed node group `karpenter`
  karpenter.tf                    # Karpenter Helm CRD + chart + `default` + `gpu` NodePool/EC2NodeClass
  iam.tf                          # Shared Pod Identity assume policy + EBS CSI role + ALB controller role/policy/assoc
  iam-mimir.tf                    # Mimir Pod Identity role + S3 access policy + association
  s3-mimir.tf                     # Mimir blocks/alertmanager/ruler buckets + lifecycle + encryption
  ecr.tf                          # for_each over local.ecr_repositories
  storage-classes.tf              # gp3 default StorageClass (foundational, kept off GitOps)
  argocd.tf                       # ArgoCD Helm release + cluster Secret + root Application

argocd/applications/              # GitOps — discovered recursively by the root Application
  core/                           # platform-layer components
    traefik.yaml                  # ApplicationSet, reads traefik_sg_id from cluster Secret
    alb-controller.yaml           # ApplicationSet, reads vpc_id + cluster_name + region
    mimir.yaml                    # ApplicationSet, S3 backend; bucket names + region templated from cluster Secret
    alloy.yaml                    # ApplicationSet, DaemonSet — single agent for metrics + logs
    grafana.yaml                  # ApplicationSet, Mimir + Loki datasources, inline + community dashboards
    grafana-loki.yaml             # ApplicationSet, single-binary Loki on filesystem (no Promtail)
    kube-state-metrics.yaml       # ApplicationSet, supplies kube_pod_*/kube_node_*/kube_deployment_* to Mimir
  mlops/                          # MLOps-layer slot — currently empty placeholder, JupyterLab is manual

argocd/helm-values/               # static Helm values pulled via multi-source $values ref
  traefik/values.yaml
  alb-controller/values.yaml
  mimir/values.yaml               # ingest-storage disabled, Kafka off, single replica everything
  alloy/values.yaml               # configMap.content with the full Alloy pipeline; controller.* overrides for hostNetwork + hostPath mounts
  grafana/values.yaml             # admin creds, Mimir+Loki datasources, dashboards (1860 + dotdc 15757-15760 + inline kubernetes-logs)
  loki/values.yaml                # SingleBinary, filesystem, lokiCanary/test/chunksCache/resultsCache disabled
  kube-state-metrics/values.yaml  # 1 replica, pinned to system node group

argocd/manifests/                 # raw manifests slot (currently empty placeholder)

mlops/                            # MLOps workloads — built and applied manually, not via GitOps
  jupyterlab-llm/
    Dockerfile                    # CUDA 12.6 + JupyterLab 4.2 + PyTorch + HuggingFace + LangChain + Tesseract OCR
    tesseract/                    # Tesseract language data download script
    kubernetes/                   # Namespace + Deployment + PVC + Service for JupyterLab on Karpenter `gpu` NodePool
```

## Upstream modules & references

- [terraform-aws-modules/vpc/aws](https://github.com/terraform-aws-modules/terraform-aws-vpc) — VPC
- [terraform-aws-modules/eks/aws](https://github.com/terraform-aws-modules/terraform-aws-eks) — EKS cluster + Karpenter submodule
- [argo-helm ArgoCD chart](https://github.com/argoproj/argo-helm) — ArgoCD bootstrap
- [GitOps Bridge pattern](https://github.com/gitops-bridge-dev/gitops-bridge) — TF→ArgoCD contract
- [grafana/mimir Helm chart 6.x](https://github.com/grafana/mimir) — distributed metrics, S3 backed
- [grafana/alloy Helm chart 1.x](https://github.com/grafana/alloy) — single agent for metrics + logs
- [grafana/loki Helm chart 6.x](https://github.com/grafana/loki) — single-binary mode
- [prometheus-community/kube-state-metrics chart 7.x](https://github.com/prometheus-community/helm-charts) — k8s state metrics
- [dotdc/grafana-dashboards-kubernetes](https://github.com/dotdc/grafana-dashboards-kubernetes) — k8s view dashboards (15757–15760)

## GitOps Bridge contract

Terraform writes a `kubernetes_secret` named `in-cluster` in the `argocd` namespace, labelled `argocd.argoproj.io/secret-type: cluster`. Its annotations carry per-cluster parameters consumed by ApplicationSets via `{{metadata.annotations.*}}` placeholders:

| Annotation | Source | Consumed by |
|---|---|---|
| `cluster_name` | `module.eks.cluster_name` | alb-controller |
| `region` | `local.region` | alb-controller, mimir |
| `vpc_id` | `module.vpc.vpc_id` | alb-controller |
| `traefik_sg_id` | `aws_security_group.ingress_traefik_external.id` | traefik |
| `target_revision` | `local.argocd_target_revision` | every ApplicationSet (git ref of the `$values` source) |
| `mimir_blocks_bucket` | `aws_s3_bucket.mimir_blocks.id` | mimir |
| `mimir_alertmanager_bucket` | `aws_s3_bucket.mimir_alertmanager.id` | mimir |
| `mimir_ruler_bucket` | `aws_s3_bucket.mimir_ruler.id` | mimir |

IAM role ARNs are **not** published as annotations — Pod Identity associations (see [iam.tf](terraform/iam.tf), [iam-mimir.tf](terraform/iam-mimir.tf), and the EBS CSI inline `pod_identity_association` in [eks.tf](terraform/eks.tf)) wire SAs to IAM roles at the AWS API level, so Helm values never need the role ARN.

ApplicationSets in `argocd/applications/{core,mlops}/` use a `clusters` generator that matches this Secret. Helm-based Applications pull static values from `argocd/helm-values/<app>/values.yaml` via a multi-source `$values` ref; cluster-specific bits are interpolated inline via the `helm.values: |` block.

## Component relationships

### Terraform-layer

- **VPC** → **EKS**: VPC id + private subnets. Subnets tagged `karpenter.sh/discovery=mltest` for Karpenter to discover.
- **VPC** → **Traefik SGs**: `ingress_traefik_external` (public 80/443) and `ingress_traefik_node` (intra-VPC 80/443, also tagged `karpenter.sh/discovery`).
- **EKS** → **managed node group `karpenter`**: small SPOT t3a.large pool, label `karpenter.sh/controller: "true"` + matching taint. Hosts Karpenter, ArgoCD, kube-state-metrics, coredns, EBS CSI controller. Workloads can't land here unless they tolerate the taint.
- **EKS** → **Karpenter submodule** (`eks.tf`): cluster_name for IAM / SQS / EventBridge wiring.
- **EKS + Karpenter submodule** → **Karpenter Helm** (`karpenter.tf`): `queue_name` + `node_iam_role_name` as Helm values.
- **EKS** → **EBS CSI Pod Identity** (`eks.tf`): inline `pod_identity_association` inside the `aws-ebs-csi-driver` addon block, referencing `aws_iam_role.ebs_csi_controller` from `iam.tf`.
- **EKS** → **ALB controller Pod Identity** (`iam.tf`): standalone `aws_eks_pod_identity_association` for `aws-load-balancer-controller` SA in `kube-system`.
- **EKS** → **Mimir Pod Identity** (`iam-mimir.tf`): `aws_eks_pod_identity_association` for `mimir` SA in `monitoring`, role with read/write to all three Mimir buckets.
- All Pod Identity roles share a single assume policy (`data.aws_iam_policy_document.pod_identity_assume` in `iam.tf`) trusting `pods.eks.amazonaws.com`.
- **Karpenter NodePools** (`karpenter.tf`): two pools — `default` (CPU SPOT, t* family, 4–8 vCPU) and `gpu` (on-demand g4dn.xlarge/g4dn.2xlarge/g5.xlarge/g5.2xlarge, taint `nvidia.com/gpu=true:NoSchedule`, label `nodegroup: gpu`, `consolidateAfter: 30m` to keep nodes warm against driver compile + image pull cost).
- **`gp3` StorageClass** (`storage-classes.tf`): `kubernetes_storage_class_v1` resource, `is-default-class: true`. Replaces the in-tree gp2 default. Lives in TF for bootstrap reasons.
- **ArgoCD Helm release** (`argocd.tf`): `global.nodeSelector` + `global.tolerations` pin all components (controller/server/repoServer/applicationSet/redis) to the `karpenter` system group.
- **ArgoCD Helm release** → **cluster Secret** → **ApplicationSets**: the chain that lets Git manifests consume TF outputs.

### GitOps-layer

- **traefik** → **ALB controller**: traefik Service is type LoadBalancer with NLB-ip annotations + `aws-load-balancer-security-groups` filled from `traefik_sg_id`. ALB controller (Helm-installed but IAM-rooted in TF) provisions the NLB.
- **kube-state-metrics** → **Alloy** (metric scrape): KSM runs as 1-replica Deployment on the system node group. Alloy DaemonSet on the same node sees it via `discovery.kubernetes "pods"` filtered to `spec.nodeName=$NODE_NAME`, scrapes the `http`/8080 port, ships to Mimir. Other Alloy pods see no KSM target on their nodes — no duplicate scrapes.
- **Alloy** (DaemonSet, hostNetwork + hostPath /proc /sys /) → **Mimir** (write path): kubelet, cAdvisor, node_exporter, KSM, and Alloy's own metrics. Per-pod NODE_NAME is set via downward API and used in discovery filters so each Alloy scrapes only its own kubelet — without that filter every Alloy in the DaemonSet scrapes every kubelet, producing duplicate samples and `err-mimir-sample-out-of-order`. external_labels add `cluster=mltest`.
- **Alloy** (DaemonSet) → **Loki** (write path): `discovery.kubernetes "pods"` with `spec.nodeName` field selector + `loki.source.kubernetes` tail container logs via the kubelet `/api/v1/.../log` endpoint. RBAC includes `pods/log`. Promtail is not used.
- **Mimir** ApplicationSet: `mimir-distributed` chart 6.x with **classic ingester architecture explicitly enabled** (`ingest_storage.enabled: false` + `kafka.enabled: false` + `ingester.push_grpc_method_enabled: true`). Without these, the chart 6.x default brings up Kafka + ingest-storage which is overkill for sandbox. Single replica everywhere. S3 backend, region/bucket names templated from cluster Secret annotations. SA name pinned to `mimir` to match the Pod Identity association.
- **Loki** ApplicationSet: SingleBinary deployment, filesystem storage (10Gi gp3 PVC), no S3. Sandbox-only knobs disabled: `lokiCanary` (was the default canary daemonset, expects Promtail and would alert on missing data with our Alloy setup), `test` (chart's helm-test, requires canary), `chunksCache`/`resultsCache` (memcached, not worth the RAM in sandbox).
- **Grafana** ApplicationSet: Mimir is default datasource (`isDefault: true`), Loki has fixed `uid: loki` for dashboard cross-references. Dashboards bundled inline via `dashboards.default`:
  - `1860` (Node Exporter Full) — needs node_exporter, which Alloy emits with `instance=$NODE_NAME` label.
  - `15757`–`15760` from dotdc/grafana-dashboards-kubernetes — kube-prom-mixin views (Global / Namespaces / Nodes / Pods). Need KSM + cAdvisor + node_exporter, all of which we have. The `cluster` template variable resolves via `external_labels=mltest` set by Alloy.
  - `kubernetes-logs` (inline JSON) — purpose-built log explorer using only `namespace` + `container` labels (no `stream`, `job`, etc., which `loki.source.kubernetes` doesn't auto-populate).

## Karpenter NodePools

Two pools, distinct intents:

| NodePool | Instance types | Capacity | Taint | Use |
|---|---|---|---|---|
| `default` | t-family 4–8 vCPU | spot | none | General workloads (Mimir, Loki, Grafana, etc.) |
| `gpu` | g4dn.xlarge, g4dn.2xlarge, g5.xlarge, g5.2xlarge | on-demand | `nvidia.com/gpu=true:NoSchedule` | JupyterLab and any other `nvidia.com/gpu` consumer |

The system node group (managed, on EKS side) runs Karpenter itself plus ArgoCD + KSM. The split is: managed group hosts what's required for Karpenter to function; Karpenter provisions capacity for everything above it.

## Provider auth

All Kubernetes-scoped providers (`helm`, `kubectl`, `kubernetes`) authenticate via `exec` calling `aws eks get-token --cluster-name <module.eks.cluster_name>`. Do not replace this with a static `data.aws_eks_cluster_auth.cluster.token` — that token has a ~15-minute TTL and expires mid-apply on long runs; `exec` refreshes on each provider call.

## JupyterLab (manual)

`mlops/jupyterlab-llm/` is intentionally outside the GitOps loop. The Dockerfile bakes CUDA 12.6, PyTorch, HuggingFace transformers/diffusers, LangChain, and Tesseract OCR into one image; `kubernetes/` has the manifests to run it.

The Pod uses `nodeSelector: nodegroup=gpu` + `tolerations: nvidia.com/gpu=true:NoSchedule` to land on a Karpenter-provisioned GPU node. PVC uses dynamic `gp3` (no static PV/AZ pinning — Karpenter picks any AZ; `WaitForFirstConsumer` handles AZ matching automatically). NVIDIA driver + container toolkit must already be present on the node — currently not installed (NVIDIA GPU Operator ApplicationSet is on the roadmap but not deployed yet, see README's TODO list).

When ready to migrate to GitOps: drop a JupyterLab ApplicationSet under `argocd/applications/mlops/`, point it at `mlops/jupyterlab-llm/kubernetes/`. The repo structure already has the `mlops/` ApplicationSet directory and `argocd/manifests/` slot prepared.

## ECR repositories

Created via `for_each` over `local.ecr_repositories` in [main.tf](terraform/main.tf). Currently `["jupyterlab-llm"]`. Add new image repos by appending to that list — single-line change.

## Bootstrap

There is a 60–90 second window after `terraform apply` completes when the ArgoCD UI is not yet reachable via `argocd.local` — Traefik hasn't synced yet. Use `kubectl -n argocd port-forward svc/argocd-server 8080:80` once, then switch to the ingress hostname once Traefik is up. After that, all platform changes happen via `git push`, not `terraform apply`.

State is local (`terraform.tfstate` in the working directory, gitignored via `*.tfstate*`) — sandbox project, not production-ready.

## Common commands

```bash
# Bootstrap / day-2 cluster-layer changes
cd terraform
terraform init -upgrade
terraform plan
terraform apply

# Inspect GitOps state
kubectl -n argocd get applications
kubectl -n argocd get applicationsets
kubectl -n argocd get secret in-cluster -o yaml | grep -A20 annotations

# Force ArgoCD to re-sync
kubectl -n argocd patch application root --type merge \
  -p '{"operation":{"sync":{"prune":true}}}'

# Inspect Alloy targets / config
kubectl -n monitoring port-forward ds/alloy 12345:12345
# open http://localhost:12345 → Components

# Inspect Mimir directly
kubectl -n monitoring port-forward svc/mimir-gateway 8090:80
curl http://localhost:8090/prometheus/api/v1/labels

# Build & push JupyterLab image
cd mlops/jupyterlab-llm
docker build -t jupyterlab-llm:25.01 .
aws ecr get-login-password --region eu-west-1 \
  | docker login --username AWS --password-stdin <account>.dkr.ecr.eu-west-1.amazonaws.com
docker tag jupyterlab-llm:25.01 <account>.dkr.ecr.eu-west-1.amazonaws.com/jupyterlab-llm:25.01
docker push <account>.dkr.ecr.eu-west-1.amazonaws.com/jupyterlab-llm:25.01

# Apply JupyterLab manifests manually
kubectl apply -f mlops/jupyterlab-llm/kubernetes/
```
