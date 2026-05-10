# Project Overview

AWS EKS cluster bootstrap for ML/observability workloads, built on the same GitOps Bridge pattern as [argocd-infra-example](../argocd-infra-example/) but with a Mimir+Alloy+Loki+Grafana stack instead of kube-prometheus-stack, NVIDIA GPU Operator on Karpenter-provisioned GPU nodes, four Karpenter NodePools (CPU + GPU, AL2023 and Ubuntu), in-cluster image builds via BuildKit, and a JupyterLab Argo Application synced manually from `mlops/`.

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
  versions.tf                     # provider + Terraform version pins (incl. hashicorp/cloudinit for Ubuntu userData)
  providers.tf                    # aws, helm, kubectl, kubernetes (all with exec auth) + cloudinit
  vpc.tf                          # VPC module + Traefik external/node SGs
  eks.tf                          # EKS module (addons incl. EBS CSI Pod Identity assoc) + managed node group `karpenter`
  karpenter.tf                    # Karpenter Helm CRD + chart + 4 NodePools/EC2NodeClasses: `default`, `gpu` (legacy AL2023), `ubuntu`, `gpu-ubuntu`
  iam.tf                          # Shared Pod Identity assume policy + EBS CSI role + ALB controller role/policy/assoc
  iam-mimir.tf                    # Mimir Pod Identity role + S3 access policy + association
  iam-buildkit.tf            # `buildkit` namespace + `buildkit` SA + Pod Identity role with ECR push (used by BuildKit Job)
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
    nvidia-gpu-operator.yaml      # ApplicationSet, GPU Operator chart (driver + toolkit + device-plugin + dcgm + NFD/GFD)
  mlops/
    jupyterlab-llm.yaml           # Plain Application (not ApplicationSet) — manual sync, points at argocd/manifests/jupyterlab-llm/

argocd/helm-values/               # static Helm values pulled via multi-source $values ref
  traefik/values.yaml
  alb-controller/values.yaml
  mimir/values.yaml               # ingest-storage disabled, Kafka off, single replica everything
  alloy/values.yaml               # configMap.content with the full Alloy pipeline; controller.* overrides for hostNetwork + hostPath mounts
  grafana/values.yaml             # admin creds, Mimir+Loki datasources, dashboards (1860 + dotdc 15757-15760 + inline kubernetes-logs)
  loki/values.yaml                # SingleBinary, filesystem, lokiCanary/test/chunksCache/resultsCache disabled
  kube-state-metrics/values.yaml  # 1 replica, pinned to system node group
  nvidia-gpu-operator/values.yaml # driver pinned to nvcr.io tag, toolkit on, MIG/vGPU off, dcgm-exporter + NFD/GFD on

argocd/manifests/                 # raw manifests slot, Argo applies these directly
  jupyterlab-llm/                 # Namespace + Deployment + PVC + Service for JupyterLab on `gpu-ubuntu` NodePool

mlops/                            # MLOps workloads — image build sources + smoke-test pods (NOT applied via GitOps)
  jupyterlab-llm/
    Dockerfile                    # CUDA 12.6 + JupyterLab 4.2 + PyTorch + HuggingFace + LangChain + Tesseract OCR
    build-job.yaml                # Kubernetes Job: BuildKit rootless, builds image from this folder, pushes to ECR
    tesseract/                    # Tesseract language data download script
  gpu-test-pod.yaml               # Smoke test Pod for GPU stack — runs nvidia-smi on `gpu-ubuntu`
  ubuntu-test-pod.yaml            # Smoke test Pod for Ubuntu bootstrap — runs on `ubuntu` debug NodePool
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
- **EKS** → **buildkit Pod Identity** (`iam-buildkit.tf`): `buildkit` namespace + `buildkit` SA created in TF (so the Pod Identity assoc has stable subjects to bind), role with ECR push to every repo in `local.ecr_repositories`. Consumed by `mlops/jupyterlab-llm/build-job.yaml`.
- All Pod Identity roles share a single assume policy (`data.aws_iam_policy_document.pod_identity_assume` in `iam.tf`) trusting `pods.eks.amazonaws.com`.
- **Karpenter NodePools** (`karpenter.tf`): four pools — see [Karpenter NodePools](#karpenter-nodepools) for the full table. The Ubuntu pools use `amiFamily: Custom` with userData rendered via `data "cloudinit_config"` (Karpenter v1 dropped first-class `Ubuntu` family).
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
- **NVIDIA GPU Operator** ApplicationSet: gpu-operator chart with driver-DaemonSet + toolkit + device-plugin + dcgm-exporter + NFD + GFD. Driver image version pinned in values (chart default tag often missing for `-amzn2023` on nvcr.io; the `gpu-ubuntu` NodePool uses Ubuntu where coverage is reliable). Tolerates `nvidia.com/gpu=true:NoSchedule`. `ServerSideApply=true` in syncOptions because the `ClusterPolicy` CRD has annotations that exceed kubectl client-side apply limit.
- **JupyterLab** plain `Application` (not `ApplicationSet`), **manual sync**: manifests at `argocd/manifests/jupyterlab-llm/` (namespace `jupyterlab`), image at `<acct>.dkr.ecr.eu-west-1.amazonaws.com/jupyterlab-llm:<tag>`. Manual sync because image must exist in ECR before first sync — chicken-and-egg with the build Job. Deploys onto `gpu-ubuntu` Karpenter NodePool. Tag is bumped explicitly per release in **both** `mlops/jupyterlab-llm/build-job.yaml` and `argocd/manifests/jupyterlab-llm/jupyterlab-llm-pod.yaml` — no `:latest`/`:dev` mutability. Same-tag rebuilds would need Argo Image Updater (digest strategy), not deployed yet.

## Karpenter NodePools

Four pools:

| NodePool | AMI | Instance types | Capacity | Taint | Use |
|---|---|---|---|---|---|
| `default` | AL2023 (alias `al2023@latest`) | t-family 2–8 vCPU | spot | none | General workloads (Mimir, Loki, Grafana, BuildKit Job, etc.) |
| `gpu` | AL2023 standard via SSM (`amiFamily: AL2023`) | g4dn.xlarge / g4dn.2xlarge / g5.xlarge / g5.2xlarge | spot | `nvidia.com/gpu=true:NoSchedule` | **Legacy / unused.** Operator-driver path blocked by missing nvcr.io `-amzn2023` driver tags. Kept as reference. |
| `ubuntu` | Canonical Ubuntu 24.04 EKS via SSM (`amiFamily: Custom` + `cloudinit_config` userData) | t-family 2–4 vCPU | spot | `nodegroup=ubuntu:NoSchedule` | Sandbox for cloud-init / userData debugging |
| `gpu-ubuntu` | Same Ubuntu 24.04 AMI | g4dn / g5 .xlarge / .2xlarge | spot | `nvidia.com/gpu=true:NoSchedule` | JupyterLab + any GPU workload — driver installed by GPU Operator (nvcr.io ubuntu24.04 tags reliable) |

The system node group (managed, on EKS side) runs Karpenter itself plus ArgoCD + KSM. The split is: managed group hosts what's required for Karpenter to function; Karpenter provisions capacity for everything above it.

**Karpenter alias quirk:** `alias: al2023@latest` auto-resolves to the **NVIDIA-optimized** AL2023 AMI (`*-nvidia-*`) when the provisioned instance type has a GPU. Same for `bottlerocket@latest`. This is why the legacy `gpu` pool uses an explicit SSM parameter for standard AL2023 instead of the alias — to actually exercise the Operator-driver path.

## Provider auth

All Kubernetes-scoped providers (`helm`, `kubectl`, `kubernetes`) authenticate via `exec` calling `aws eks get-token --cluster-name <module.eks.cluster_name>`. Do not replace this with a static `data.aws_eks_cluster_auth.cluster.token` — that token has a ~15-minute TTL and expires mid-apply on long runs; `exec` refreshes on each provider call.

## JupyterLab — split between manual build and Argo deploy

Two-stage flow with a deliberate cut between image build (manual) and deploy (GitOps, manual sync):

1. **Image build** — `mlops/jupyterlab-llm/Dockerfile` baked into a CUDA 12.6 + JupyterLab 4.2 + PyTorch + HuggingFace + LangChain + Tesseract image. Built **in-cluster** by `mlops/jupyterlab-llm/build-job.yaml` — Kubernetes Job using `moby/buildkit:rootless`, runs on `default` Karpenter pool, pushes to `<acct>.dkr.ecr.eu-west-1.amazonaws.com/jupyterlab-llm:<tag>` and layer cache to `jupyterlab-llm-cache`. Authenticates to ECR via Pod Identity on SA `buildkit` in `buildkit` namespace ([iam-buildkit.tf](terraform/iam-buildkit.tf)). Trigger: `kubectl replace --force -f mlops/jupyterlab-llm/build-job.yaml` (Job is immutable). No shell wrappers.

2. **Deploy** — Argo `Application` at `argocd/applications/mlops/jupyterlab-llm.yaml`, manifests at `argocd/manifests/jupyterlab-llm/` (namespace `jupyterlab` — Namespace + Deployment + PVC + Service). **Manual sync** (no `automated{}` block) because image must be in ECR before first sync, otherwise pods stay `ImagePullBackOff`. Pod uses `nodeSelector: nodegroup=gpu-ubuntu` + `tolerations: nvidia.com/gpu=true:NoSchedule`. PVC on dynamic `gp3` (`WaitForFirstConsumer` handles AZ matching). Trigger: `argocd app sync jupyterlab-llm` (or UI Sync button).

Tag bumps: edit the tag in **both** `build-job.yaml` (the `--output ...:<TAG>` arg) and `jupyterlab-llm-pod.yaml` (the `image: ...:<TAG>` line). Commit, build, sync. No `:latest`/`:dev` mutability — releases are explicit and reproducible.

## ECR repositories

Created via `for_each` over `local.ecr_repositories` in [main.tf](terraform/main.tf). Currently `["jupyterlab-llm", "jupyterlab-llm-cache"]` — second one stores BuildKit layer cache for incremental rebuilds. Add new image repos by appending to that list — single-line change. The `buildkit` Pod Identity role auto-grants ECR push on every repo in the list.

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

# Build & push JupyterLab image (BuildKit rootless Job in `buildkit` ns)
kubectl replace --force -f mlops/jupyterlab-llm/build-job.yaml
kubectl -n buildkit logs -f -l job-name=build-jupyterlab-llm --all-containers

# Deploy / refresh JupyterLab (manual sync, after build finishes)
argocd app sync jupyterlab-llm
```
