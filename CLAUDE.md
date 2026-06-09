# Project Overview

AWS EKS cluster bootstrap for ML/observability workloads, built on the same GitOps Bridge pattern as [argocd-infra-example](../argocd-infra-example/) but with a Mimir+Alloy+Loki+Grafana stack instead of kube-prometheus-stack, NVIDIA GPU Operator on Karpenter-provisioned GPU nodes, four Karpenter NodePools (CPU + GPU, AL2023 and Ubuntu), in-cluster image builds via BuildKit, a JupyterLab Argo Application synced manually from `mlops/`, and a Piraeus/LINSTOR persistent-storage stack (DRBD9 replication + LVM-thin) running as a bare-metal-shaped POC on a dedicated managed node group plus diskless DRBD clients on the Karpenter `ubuntu` pool.

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
  main.tf                         # locals (cluster name `mltest`, region, ECR repo list, chart versions, target_revision, `enabled_addons` map)
  versions.tf                     # provider + Terraform version pins (incl. hashicorp/cloudinit for Ubuntu userData)
  providers.tf                    # aws, helm, kubectl, kubernetes (all with exec auth) + cloudinit
  vpc.tf                          # VPC module + Traefik external/node SGs
  eks.tf                          # EKS module (addons incl. EBS CSI Pod Identity assoc) + managed node groups `karpenter` and `linstor-storage`
  karpenter.tf                    # Karpenter Helm CRD + chart
  karpenter-ec2.tf                # 4 NodePools/EC2NodeClasses: `default`, `gpu` (legacy AL2023), `ubuntu` (also Piraeus diskless tier), `gpu-ubuntu`
  userdata/linstor-storage.sh.tpl # cloud-init for the `linstor-storage` NG: kernel headers, lvm2/thin-provisioning-tools, udev rule → /dev/linstor-data
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
    piraeus-operator.yaml         # ApplicationSet, OCI chart from ghcr.io/piraeusdatastore — operator + CRDs (sync-wave 0)
    linstor-cluster.yaml          # ApplicationSet, OCI chart (independent revision) — LinstorCluster CR + SatelliteConfig + SCs (sync-wave 1)
  mlops/
    jupyterlab-llm.yaml           # Plain Application (not ApplicationSet) — manual sync, points at argocd/manifests/jupyterlab-llm/
    jupyterhub.yaml               # ApplicationSet, z2jh chart + $values; gated by enable_jupyterhub; auto-sync; ignoreDifferences on hub Secret + hub/proxy checksum annotations

argocd/helm-values/               # static Helm values pulled via multi-source $values ref
  traefik/values.yaml
  alb-controller/values.yaml
  mimir/values.yaml               # ingest-storage disabled, Kafka off, single replica everything
  alloy/values.yaml               # configMap.content with the full Alloy pipeline; controller.* overrides for hostNetwork + hostPath mounts
  grafana/values.yaml             # admin creds, Mimir+Loki datasources, dashboards (1860 + dotdc 15757-15760 + inline kubernetes-logs)
  loki/values.yaml                # SingleBinary, filesystem, lokiCanary/test/chunksCache/resultsCache disabled
  kube-state-metrics/values.yaml  # 1 replica, pinned to system node group
  nvidia-gpu-operator/values.yaml # driver pinned to nvcr.io tag, toolkit on, MIG/vGPU off, dcgm-exporter + NFD/GFD on
  piraeus-operator/values.yaml    # installCRDs=true, satellite nodeSelector, drbd.linbit.com/* tolerations, operator resources
  linstor-cluster/values.yaml     # LinstorCluster + LinstorSatelliteConfiguration (hdd-pool on /dev/linstor-data) + StorageClasses (linstor-hdd-1r, linstor-hdd-2r)
  jupyterhub/values.yaml          # z2jh — all pods on karpenter `ubuntu` pool, dynamic gp3 per-user PVCs, DummyAuthenticator placeholder, scheduling/placeholder/prePuller on, Traefik ingress jupyter.local
  jupyterhub/values-baremetal.yaml # bare-metal variant — cloud autoscaling knobs off (userScheduler/podPriority/userPlaceholder/continuous prePuller), commented Keycloak-OIDC skeleton for prod
  argo-workflows/values.yaml      # Argo Workflows — manual helm test (NOT yet under ArgoCD); client-auth, no ingress, restricted PSS, GC defaults. See "Argo Workflows" section

argocd/manifests/                 # raw manifests slot, Argo applies these directly
  jupyterlab-llm/                 # Namespace + Deployment + PVC + Service for JupyterLab on `gpu-ubuntu` NodePool

mlops/                            # MLOps workloads — image build sources + smoke-test pods (NOT applied via GitOps)
  jupyterlab-llm/
    Dockerfile                    # CUDA 12.6 + JupyterLab 4.2 + PyTorch + HuggingFace + LangChain + Tesseract OCR
    build-job.yaml                # Kubernetes Job: BuildKit rootless, builds image from this folder, pushes to ECR
    tesseract/                    # Tesseract language data download script
  gpu-test-pod.yaml               # Smoke test Pod for GPU stack — runs nvidia-smi on `gpu-ubuntu`
  ubuntu-test-pod.yaml            # Smoke test Pod for Ubuntu bootstrap — runs on `ubuntu` debug NodePool
  hdd1-test-sts.yaml              # Piraeus smoke test: StatefulSet w/ 1-replica PVC (linstor-hdd-1r), pinned to satellite=yes
  hdd2-test-sts.yaml              # Piraeus smoke test: 2-replica synchronous DRBD (linstor-hdd-2r)
  diskless-test-sts.yaml          # Piraeus smoke test: Pod on karpenter `ubuntu` (no local pool) → diskless DRBD client

PV_PLAN.md                        # Long-form bare-metal storage plan: rationale, public benchmarks, LVM-thin vs ZFS, appendices
EKS_PV_TEST_PLAN.md               # POC plan on this EKS cluster, phase-by-phase with chaos tests + Phase 2.5 diskless via karpenter
BARE_PV_PLAN.md                   # Production-ready bare-metal rollout: 1→2→3→N node phases, ops procedures, monitoring, backups
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
- [piraeusdatastore/piraeus-operator](https://github.com/piraeusdatastore/piraeus-operator) — Piraeus Operator + LinstorCluster chart (OCI registry `ghcr.io/piraeusdatastore`), two independently-versioned charts (operator + cluster)

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

The same Secret also carries **addon toggle labels** sourced from `local.enabled_addons` ([main.tf](terraform/main.tf)) via `{ for k, v in local.enabled_addons : "enable_${k}" => tostring(v) }`. Each core ApplicationSet adds the matching key to its `clusters.selector.matchLabels` — flip a value to `false` (or remove the key) and the ApplicationSet stops matching this cluster, so Argo prunes the child Application:

| Label | Controls | ApplicationSets |
|---|---|---|
| `enable_monitoring` | metrics + logs stack | alloy, mimir, grafana, grafana-loki |
| `enable_linstor` | persistent-storage stack | piraeus-operator, linstor-cluster |
| `enable_alb_controller` | NLB provisioner for Traefik | alb-controller |
| `enable_traefik` | ingress | traefik |
| `enable_nvidia_gpu_operator` | GPU driver + device-plugin | nvidia-gpu-operator |
| `enable_metrics_server` | HPA / `kubectl top` metrics | metrics-server |
| `enable_kube_state_metrics` | k8s state metrics for Mimir | kube-state-metrics |
| `enable_jupyterhub` | multi-user JupyterHub (z2jh) | jupyterhub (mlops layer, not core) |

Flag-key in `enabled_addons` must match the `matchLabels` suffix (without the `enable_` prefix) — this is the only implicit contract between TF and the GitOps repo. Disabling `enable_linstor` or `enable_monitoring` removes stateful workloads with PVCs (Loki filesystem, Mimir cache, LINSTOR resources under `Retain` policy) — orphan PVs and LINSTOR resource-definitions stay behind, clean manually. Disabling `enable_alb_controller` while `enable_traefik` is on leaves the Traefik Service in `<pending>` (no NLB provisioner).

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
- **Karpenter NodePools** (`karpenter-ec2.tf`): four pools — see [Karpenter NodePools](#karpenter-nodepools) for the full table. The Ubuntu pools use `amiFamily: Custom` with userData rendered via `data "cloudinit_config"` (Karpenter v1 dropped first-class `Ubuntu` family). The `ubuntu` pool's cloud-init now installs `linux-headers-virtual` so the Piraeus satellite init-container can DKMS-build DRBD9 against the running kernel; the satellite label `storage.k8s.io/satellite: "yes"` is set via the NodePool `template.metadata.labels` (kubelet rejects `k8s.io/*` labels from `--node-labels` via NodeRestriction — Karpenter's controller bypasses this).
- **EKS** → **managed node group `linstor-storage`** (`eks.tf`): dedicated storage tier on a custom Ubuntu 24.04 AMI (`ami_type = "CUSTOM"`), `c5.large` ON_DEMAND, root EBS (32 GiB) plus a data EBS (128 GiB encrypted) at `/dev/sdb`. userData template at [userdata/linstor-storage.sh.tpl](terraform/userdata/linstor-storage.sh.tpl) installs `lvm2 thin-provisioning-tools linux-headers-virtual nvme-cli` and writes a udev rule that creates the stable symlink `/dev/linstor-data → first non-root EBS NVMe`. Labelled `storage.k8s.io/tier=hdd` + `storage.k8s.io/satellite=yes`, tainted `linstor-storage=true:NoSchedule` (only Piraeus components tolerate it). **No `modprobe drbd` / no `drbd-dkms`** in userData — Piraeus satellite loads DRBD9 itself, and the in-tree DRBD 8.4 from the Ubuntu kernel would conflict.
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
- **Piraeus Operator** ApplicationSet (`sync-wave: "0"`): OCI chart `ghcr.io/piraeusdatastore/piraeus-operator` (chart `piraeus`, baseline `2.10.7`). Brings up the operator Deployment, CRDs, leader-elected controllers, and reconciles the satellite DaemonSet + CSI driver onto every node carrying `storage.k8s.io/satellite=yes` (currently the `linstor-storage` NG plus the karpenter `ubuntu` pool). `installCRDs: true` is mandatory or the second chart fails with "no matches for kind LinstorCluster". `ignoreDifferences` is set for `Secret piraeus-operator-tls` (`/data`) and `ValidatingWebhookConfiguration` `clientConfig.caBundle` because the operator self-rotates them and otherwise ArgoCD shows permanent drift; `RespectIgnoreDifferences=true` in syncOptions enforces the ignore at sync time.
- **LinstorCluster** ApplicationSet (`sync-wave: "1"`): OCI chart `ghcr.io/piraeusdatastore/linstor-cluster` (**independent revision** from the operator chart, baseline `1.1.1`). Ships the `LinstorCluster` CR (operator nodeSelector + tolerations for `linstor-storage` + `nodegroup=ubuntu`), one `LinstorSatelliteConfiguration` named `hdd-pool` matching nodes labelled `storage.k8s.io/tier=hdd` (LVM-thin on `vg_data/thin_data` over `/dev/linstor-data`), and `StorageClass`-es `linstor-hdd-1r` (autoPlace=1) and `linstor-hdd-2r` (autoPlace=2 with Cozystack-tuned DRBD split-brain props: `auto-quorum=suspend-io`, `on-no-data-accessible=suspend-io`, `on-suspended-primary-outdated=force-secondary`, `rr-conflict=retry-connect`). Both SCs use `allowRemoteVolumeAccess: "true"` so karpenter ubuntu nodes (no local pool) can attach as diskless DRBD clients. ApplicationSet has a retry policy with exponential backoff because on first sync the CRDs may not yet be registered after the operator chart finishes.
- **JupyterLab** plain `Application` (not `ApplicationSet`), **manual sync**: manifests at `argocd/manifests/jupyterlab-llm/` (namespace `jupyterlab`), image at `<acct>.dkr.ecr.eu-west-1.amazonaws.com/jupyterlab-llm:<tag>`. Manual sync because image must exist in ECR before first sync — chicken-and-egg with the build Job. Deploys onto `gpu-ubuntu` Karpenter NodePool. Tag is bumped explicitly per release in **both** `mlops/jupyterlab-llm/build-job.yaml` and `argocd/manifests/jupyterlab-llm/jupyterlab-llm-pod.yaml` — no `:latest`/`:dev` mutability. Same-tag rebuilds would need Argo Image Updater (digest strategy), not deployed yet.
- **JupyterHub** (z2jh) ApplicationSet, **auto-sync**, gated by `enable_jupyterhub` (mlops layer extends the core toggle pattern). Multi-source: z2jh chart `4.3.5` from `https://hub.jupyter.org/helm-chart/` + `$values` ref to `argocd/helm-values/jupyterhub/values.yaml` (same shape as the Loki/Mimir ApplicationSets), namespace `jupyterhub`, `CreateNamespace=true`. **All** hub/proxy/scheduler/singleuser/prePuller pods pinned to the karpenter `ubuntu` pool (nodeSelector `nodegroup=ubuntu` + toleration for its `NoSchedule` taint, on both `scheduling.corePods`/`userPods` and per-component). Per-user `/home/jovyan` on dynamic `gp3` PVC `claim-<username>`; Hub state SQLite on its own `gp3` PVC `hub-db-dir`. Exposed via Traefik Ingress on `jupyter.local` (path-routed by CHP, no per-user ingress). Auth = `DummyAuthenticator` placeholder (real Keycloak-OIDC is a commented skeleton in `values-baremetal.yaml`). **GitOps gotcha:** z2jh regenerates 3 secret tokens (`hub.config.ConfigurableHTTPProxy.auth_token`, `JupyterHub.cookie_secret`, `CryptKeeper.keys`) into Secret `hub` via `randAlphaNum` on every render — under Argo (`helm template`, no cluster lookup) they drift each sync, and the derived `checksum/secret` (hub) + `checksum/auth-token` (proxy) pod-template annotations roll the pods. The Application `ignoreDifferences` those 3 Secret `/data` keys **and** the two Deployment checksum annotations, with `RespectIgnoreDifferences=true`; the user list lives in `data.values.yaml` (not the ignored keys) so it still syncs. `values-baremetal.yaml` is the static-node variant: cloud-autoscaling knobs off (`userScheduler`/`podPriority`/`userPlaceholder`/continuous prePuller), `cull` + hook prePuller kept, lower `startTimeout`.

## Karpenter NodePools

Four pools:

| NodePool | AMI | Instance types | Capacity | Taint | Use |
|---|---|---|---|---|---|
| `default` | AL2023 (alias `al2023@latest`) | t-family 2–8 vCPU | spot | none | General workloads (Mimir, Loki, Grafana, BuildKit Job, etc.) |
| `gpu` | AL2023 standard via SSM (`amiFamily: AL2023`) | g4dn.xlarge / g4dn.2xlarge / g5.xlarge / g5.2xlarge | spot | `nvidia.com/gpu=true:NoSchedule` | **Legacy / unused.** Operator-driver path blocked by missing nvcr.io `-amzn2023` driver tags. Kept as reference. |
| `ubuntu` | Canonical Ubuntu 24.04 EKS via SSM (`amiFamily: Custom` + `cloudinit_config` userData) | t-family 2–4 vCPU | spot | `nodegroup=ubuntu:NoSchedule` | Sandbox for cloud-init / userData debugging **and Piraeus diskless DRBD client tier** (label `storage.k8s.io/satellite=yes` from NodePool template, kernel headers from userData → satellite registers without a storage pool, becomes diskless) |
| `gpu-ubuntu` | Same Ubuntu 24.04 AMI | g4dn / g5 .xlarge / .2xlarge | spot | `nvidia.com/gpu=true:NoSchedule` | JupyterLab + any GPU workload — driver installed by GPU Operator (nvcr.io ubuntu24.04 tags reliable) |

In addition to the four Karpenter pools and the `karpenter` system NG, the EKS module defines a dedicated managed NG `linstor-storage` (custom Ubuntu AMI, see Terraform-layer notes) carrying labels `storage.k8s.io/tier=hdd` + `storage.k8s.io/satellite=yes` and taint `linstor-storage=true:NoSchedule`. That NG is the diskful tier for Piraeus replicas; `gpu-ubuntu` / `ubuntu` consume those replicas remotely as diskless clients.

The system node group (managed, on EKS side) runs Karpenter itself plus ArgoCD + KSM. The split is: managed group hosts what's required for Karpenter to function; Karpenter provisions capacity for everything above it.

**Karpenter alias quirk:** `alias: al2023@latest` auto-resolves to the **NVIDIA-optimized** AL2023 AMI (`*-nvidia-*`) when the provisioned instance type has a GPU. Same for `bottlerocket@latest`. This is why the legacy `gpu` pool uses an explicit SSM parameter for standard AL2023 instead of the alias — to actually exercise the Operator-driver path.

## Provider auth

All Kubernetes-scoped providers (`helm`, `kubectl`, `kubernetes`) authenticate via `exec` calling `aws eks get-token --cluster-name <module.eks.cluster_name>`. Do not replace this with a static `data.aws_eks_cluster_auth.cluster.token` — that token has a ~15-minute TTL and expires mid-apply on long runs; `exec` refreshes on each provider call.

## JupyterLab — split between manual build and Argo deploy

Two-stage flow with a deliberate cut between image build (manual) and deploy (GitOps, manual sync):

1. **Image build** — `mlops/jupyterlab-llm/Dockerfile` baked into a CUDA 12.6 + JupyterLab 4.2 + PyTorch + HuggingFace + LangChain + Tesseract image. Built **in-cluster** by `mlops/jupyterlab-llm/build-job.yaml` — Kubernetes Job using `moby/buildkit:rootless`, runs on `default` Karpenter pool, pushes to `<acct>.dkr.ecr.eu-west-1.amazonaws.com/jupyterlab-llm:<tag>` and layer cache to `jupyterlab-llm-cache`. Authenticates to ECR via Pod Identity on SA `buildkit` in `buildkit` namespace ([iam-buildkit.tf](terraform/iam-buildkit.tf)). Trigger: `kubectl replace --force -f mlops/jupyterlab-llm/build-job.yaml` (Job is immutable). No shell wrappers.

2. **Deploy** — Argo `Application` at `argocd/applications/mlops/jupyterlab-llm.yaml`, manifests at `argocd/manifests/jupyterlab-llm/` (namespace `jupyterlab` — Namespace + Deployment + PVC + Service). **Manual sync** (no `automated{}` block) because image must be in ECR before first sync, otherwise pods stay `ImagePullBackOff`. Pod uses `nodeSelector: nodegroup=gpu-ubuntu` + `tolerations: nvidia.com/gpu=true:NoSchedule`. PVC on dynamic `gp3` (`WaitForFirstConsumer` handles AZ matching). Trigger: `argocd app sync jupyterlab-llm` (or UI Sync button).

Tag bumps: edit the tag in **both** `build-job.yaml` (the `--output ...:<TAG>` arg) and `jupyterlab-llm-pod.yaml` (the `image: ...:<TAG>` line). Commit, build, sync. No `:latest`/`:dev` mutability — releases are explicit and reproducible.

## Piraeus / LINSTOR storage stack

Two-chart Helm deployment via ArgoCD, modelled on bare-metal but exercised here on EKS. Documented at length in three plan files at repo root: [PV_PLAN.md](PV_PLAN.md) (high-level architecture + public benchmarks), [EKS_PV_TEST_PLAN.md](EKS_PV_TEST_PLAN.md) (POC phase-by-phase on this cluster), [BARE_PV_PLAN.md](BARE_PV_PLAN.md) (production-ready bare-metal rollout 1→2→3→N node phases). The [README.md](README.md) "Piraeus Operator tests for Linstor" section is the short-form operator overview.

Stack shape:
- **Diskful tier** = managed NG `linstor-storage` (`eks.tf`), Ubuntu custom AMI with the dedicated data EBS prepped by [userdata/linstor-storage.sh.tpl](terraform/userdata/linstor-storage.sh.tpl) (LVM-thin pool `vg_data/thin_data` over `/dev/linstor-data`, the udev-symlinked first non-root NVMe). LINSTOR satellite + CSI Node + diskful DRBD9 replicas live here.
- **Diskless tier** = karpenter `ubuntu` NodePool (`karpenter-ec2.tf`), same Ubuntu AMI but no data EBS, kernel headers from cloud-init, only `storage.k8s.io/satellite=yes` label (no `tier=hdd`) — `LinstorSatelliteConfiguration` for `hdd-pool` doesn't match → satellite registers without a pool → resources placed here become diskless DRBD clients over TCP to the diskful peers.
- **Control plane** = `linstor-controller` (single-replica Deployment) + per-node `linstor-satellite` DaemonSet + CSI controller/node DaemonSets + `linstor-affinity-controller` + `piraeus-ha-controller`, all reconciled by the operator into namespace `piraeus-datastore` and pinned via `nodeSelector: storage.k8s.io/satellite=yes` + tolerations for `linstor-storage` and `nodegroup=ubuntu`.

StorageClasses ([argocd/helm-values/linstor-cluster/values.yaml](argocd/helm-values/linstor-cluster/values.yaml)):
- `linstor-hdd-1r` — `autoPlace: "1"`, single replica, `reclaimPolicy: Retain`, layerList `drbd storage` (DRBD layer included even for 1r so it can grow to Nr in place later).
- `linstor-hdd-2r` — `autoPlace: "2"`, synchronous DRBD replication across two `linstor-storage` nodes, same retain/expansion semantics, plus the Cozystack split-brain protection properties. **Diskless attachment is allowed** via `allowRemoteVolumeAccess: "true"` — that's what lets a Pod on the karpenter `ubuntu` pool mount the same volume as a DRBD client.

Smoke-test manifests in [mlops/](mlops/) — apply with `kubectl apply -f <file>`, not via GitOps:
- `hdd1-test-sts.yaml` — StatefulSet on `satellite=yes` consuming `linstor-hdd-1r`, single diskful replica.
- `hdd2-test-sts.yaml` — same shape but `linstor-hdd-2r`, exercises 2-way synchronous DRBD.
- `diskless-test-sts.yaml` — pinned to `nodegroup=ubuntu` + tolerating its taint, consumes `linstor-hdd-2r` → 2 diskful replicas on storage NG + 1 Diskless client on the karpenter node. Demonstrates compute/storage separation.

Operational notes baked in from POC chaos tests:
- **DRBD 8.4 conflict**: never `modprobe drbd` or install `drbd-dkms` in userData — the in-tree 8.4 from `linux-image-*` clashes with the DRBD9 the satellite init-container builds via DKMS. The two userData templates (`linstor-storage.sh.tpl` and the karpenter `ubuntu` cloud-init in `karpenter-ec2.tf`) only install `linux-headers-virtual` (+ LVM tools on the storage tier).
- **Single-node LVM-thin** is fragile under chaos (force-detach of the data EBS corrupted `vg_data` metadata in Phase 1.7 T3) — production bare-metal plan starts with mdadm RAID1 underneath LVM (see BARE_PV_PLAN.md §5 / §2.3).
- **`Retain` reclaimPolicy** leaves orphan PVs after PVC delete and LINSTOR resource-definitions hanging — must be cleaned manually (`kubectl delete pv` + `linstor resource-definition delete`). See BARE_PV_PLAN.md §10.4.
- **2-node DRBD without tiebreaker** is split-brain-prone — `auto-quorum: suspend-io` makes that fail-closed (IO suspended on both sides) rather than diverging. Adding a 3rd satellite (even diskless, e.g. the karpenter ubuntu node) gives `auto-add-quorum-tiebreaker=True` something to place and restores 2/3 quorum.
- **`piraeus-ha-controller`** sets `drbd.linbit.com/lost-quorum:NoSchedule` taints on nodes whose resources have lost quorum, and clears them when restored. The taint stays sticky on orphan resource-definitions whose peers were terminated (`Connecting` state forever) — fix by deleting the orphan RD.

## Argo Workflows

Workflow engine for ML pipelines. Currently a **manual `helm` test**, not under ArgoCD — values at [argocd/helm-values/argo-workflows/values.yaml](argocd/helm-values/argo-workflows/values.yaml) (kept in the GitOps values dir so the prod move is just adding an Application + `$values` ref). Upstream chart `argo/argo-workflows` (`argoproj.github.io/argo-helm`), images pinned `v4.0.5` via common `images.tag` (public quay.io — works on the internet). Bumped 3.6→4.0 (major): removed `schedule`(→`schedules`)/`podPriority`/`mutex`/`semaphore` in Workflow specs and reduced log levels — none used here; `authModes`/securityContext/RBAC unchanged. v4 makes full CRDs default but we keep `crds.full: false`.

**Current shape (test):**
- **CRDs** `crds.full: false` — minified CRDs as plain chart templates. `full: true` would run a pre-install Job that pulls the kubectl image + downloads CRDs from `raw.githubusercontent.com` (kept off — avoids the network dependency; not airgapped here but no reason to).
- **Scope** `singleNamespace: false` + `controller.workflowNamespaces: [mlops-pipelines]` — cluster-scoped controller (same shape as prod). Argo installed in ns `argo`; workflows run in `mlops-pipelines`. The chart creates SA `argo-workflow` + namespaced Role in each `workflowNamespaces` entry, so those namespaces must exist **before** install.
- **Auth** `server.authModes: [client]` — no SSO. UI login = paste a ServiceAccount bearer token. `extraObjects` ships SA `argo-ui` + a long-lived token Secret + a **ClusterRoleBinding** to the chart's aggregated `argo-workflows-admin` ClusterRole (cluster-wide so the UI lists workflows across namespaces). `secure: false` (HTTP; no TLS, no gateway).
- **Access** no Ingress — `kubectl port-forward` only.
- **Security** restricted-PSS securityContext on every pod set already (controller/server/executor/mainContainer pod+container level) and `controller.workflowDefaults.spec.securityContext` (runAsNonRoot/1000, seccomp RuntimeDefault) for step pods — harmless on EKS, ready for a Kyverno-restricted cluster later. **Caveat:** `workflowDefaults` forces `runAsUser: 1000` on step pods, so workflow images that need root or a different UID must override `spec.securityContext` per-Workflow.
- **Cleanup** `workflowDefaults.spec.ttlStrategy` (success 1h / any 24h / fail 3d) + `podGC: OnWorkflowSuccess` — completed Workflows and their pods are reaped automatically (the namespace is long-lived, so this keeps it from filling up).
- **Metrics** `controller.metricsConfig.enabled: true` (endpoint on `:8080/metrics`); `serviceMonitor.enabled: false` — this cluster scrapes via Alloy/Mimir, not prometheus-operator, so no ServiceMonitor CRD. Wire scraping via an Alloy `discovery.kubernetes` target if needed.
- **Artifacts** not configured — `hello-world` doesn't need them.

**Migration path to prod** (each step is a values edit, no rework — the test shape is already prod-shaped on scope/security):
1. **GitOps** — add an ApplicationSet at `argocd/applications/mlops/argo-workflows.yaml` (multi-source: chart + `$values` ref to this file, same pattern as jupyterhub/loki/mimir), gated behind an `enable_argo_workflows` toggle label. CRDs are large even minified — set `ServerSideApply=true` in the Application `syncOptions` (same reason as the GPU-operator `ClusterPolicy`).
2. **Auth** — swap `server.authModes` to `[sso]` and add `server.sso` (Keycloak OIDC): `issuer`/`clientId`/`clientSecret`/`redirectUrl`/`scopes: [groups]`/`rbac.enabled: true`. Drop the `argo-ui` token objects from `extraObjects`. Group→SA mapping via `workflows.argoproj.io/rbac-rule` annotations on SAs. OIDC client secret via External Secrets (this repo has no ESO yet — add it, or SealedSecrets, like the jupyterhub-oidc skeleton).
3. **Ingress** — `server.ingress.enabled: true` with `ingressClassName: traefik` + a host (e.g. `argo-wf.local`), matching the grafana/jupyterhub pattern. Then `server.secure` stays false (TLS terminated at Traefik/NLB) or flip to true for end-to-end.
4. **Artifacts** — `artifactRepository.s3` (bucket/endpoint/region) + an ExternalSecret `argo-artifacts` **in each workflow namespace** (the secret is read by the step pods, not the controller) via `extraObjects`. On EKS prefer IRSA/Pod Identity (`useSDKCreds: true`, drop the static keys) and an S3 bucket + Pod Identity role in Terraform, mirroring the Mimir S3 wiring.
5. **Network** — if Kyverno/NetworkPolicy lands, add a default-deny NetworkPolicy for `mlops-pipelines` (DNS + egress to kube-apiserver + S3 endpoint) via `extraObjects`; the securityContexts are already restricted-compliant.

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

# Inspect Piraeus / LINSTOR state
kubectl -n piraeus-datastore get pods -o wide
kubectl -n piraeus-datastore exec deploy/linstor-controller -- linstor node list
kubectl -n piraeus-datastore exec deploy/linstor-controller -- linstor storage-pool list
kubectl -n piraeus-datastore exec deploy/linstor-controller -- linstor resource list

# Live DRBD state on a specific satellite (replicas, peers, sync %)
kubectl -n piraeus-datastore get pod -l app.kubernetes.io/component=linstor-satellite -o wide
kubectl -n piraeus-datastore exec <satellite-pod> -- drbdadm status

# Apply Piraeus smoke tests (NOT via GitOps — these live in mlops/)
kubectl apply -f mlops/hdd1-test-sts.yaml      # 1-replica diskful
kubectl apply -f mlops/hdd2-test-sts.yaml      # 2-replica synchronous DRBD
kubectl apply -f mlops/diskless-test-sts.yaml  # diskless client on karpenter ubuntu

# Clean orphan PV + LINSTOR resource-definition (Retain policy aftermath)
kubectl patch pv <pv-name> -p '{"spec":{"claimRef":null}}'
kubectl delete pv <pv-name>
kubectl -n piraeus-datastore exec deploy/linstor-controller -- \
  linstor resource-definition delete <pv-name>

# Argo Workflows — manual helm test (NOT via GitOps yet)
helm repo add argo https://argoproj.github.io/argo-helm && helm repo update
kubectl create ns argo
kubectl create ns mlops-pipelines   # must exist before install (chart makes SA/Role here)
helm upgrade --install argo-wf argo/argo-workflows \
  -n argo -f argocd/helm-values/argo-workflows/values.yaml

# UI login token (paste as "Bearer <token>" in the client-auth field)
kubectl -n argo get secret argo-ui.service-account-token \
  -o jsonpath='{.data.token}' | base64 -d; echo
kubectl -n argo port-forward svc/argo-wf-argo-workflows-server 2746:2746

# Submit a smoke workflow (runs under SA argo-workflow in mlops-pipelines)
argo submit -n mlops-pipelines --watch --serviceaccount argo-workflow \
  https://raw.githubusercontent.com/argoproj/argo-workflows/main/examples/hello-world.yaml
```
