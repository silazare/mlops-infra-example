# Project Overview

Sandbox EKS cluster `mltest` (eu-west-1, K8s 1.36) for ML / LLM-inference / observability experiments, built on the GitOps Bridge pattern (same as [argocd-infra-example](../argocd-infra-example/)). Sandbox-grade: single replica everywhere, non-production secrets in git, local Terraform state.

What runs on it:
- **Platform (core):** Traefik ingress behind an NLB (ALB controller), kube-prometheus-stack + Loki/Promtail, NVIDIA GPU Operator, Istio control plane (base + istiod, Gateway-API Inference Extension on), Piraeus/LINSTOR storage POC, cert-manager (off), metrics-server.
- **Workloads (mlops):** JupyterLab (in-cluster BuildKit image build, manual sync), JupyterHub (z2jh), Argo Workflows as in-cluster CI, llm-d multi-model LLM inference (vLLM + EPP KV-cache-aware routing behind Istio Gateways) unified by LiteLLM, OpenClaw AI agent.

Runbooks, access and smoke tests live in [README.md](README.md). Long-form storage/LLM plans (`*PLAN*.md`) are local-only, gitignored.

## Two-layer architecture

```
Terraform  (cluster layer: anything needing the AWS API or required for ArgoCD itself)
  ↓ cluster Secret `in-cluster` (GitOps Bridge)  ↓ root Application
ArgoCD     (everything that runs on top of the cluster)
```

**Boundary rule:** Terraform owns VPC, EKS + addons, IAM/Pod Identity, ECR, Karpenter (capacity, same layer as CNI/CSI), the `gp3` default StorageClass (under ArgoCD it deadlocks bootstrap — PVC-backed apps wait for it), ArgoCD itself and the bridge Secret. ArgoCD owns every chart and manifest above that. After bootstrap, changes are `git push`; the only recurring `terraform apply` is flipping an addon toggle.

## Repository layout

```
terraform/            cluster layer: main.tf (locals, versions, enabled_addons), vpc/eks/karpenter/iam/ecr/argocd
argocd/applications/  ApplicationSets discovered recursively by the root app — core/ (platform) and mlops/ (workloads)
argocd/helm-values/   static values per app, pulled via multi-source `$values` ref
argocd/charts/        in-repo Helm charts (llm-d-modelserver)
argocd/manifests/     raw manifests / kustomizations applied as an extra Application source
mlops/                image build sources + smoke-test manifests, applied by hand (not GitOps)
diagrams/             architecture diagrams (.md + svg)
```

## GitOps Bridge contract

Terraform writes Secret `in-cluster` (ns `argocd`, label `argocd.argoproj.io/secret-type: cluster`). ApplicationSets use a `clusters` generator against it with `goTemplate: true` + `goTemplateOptions: ["missingkey=error"]`.

- **Annotations** carry cluster parameters: `cluster_name`, `region`, `vpc_id`, `traefik_sg_id`, `alb_backend_sg_id`, `target_revision` (git ref for every `$values` source). IAM role ARNs are never published — Pod Identity associations bind SA→role on the AWS side, Helm values never see ARNs.
- **Toggle labels** `enable_<key>` come from `local.enabled_addons` in `terraform/main.tf`; each ApplicationSet matches its own label. Key in the map must equal the label suffix — the only implicit TF↔Git contract. `false` → Argo prunes the child Application and its namespace (PVCs on `gp3` are `Delete` → data gone; LINSTOR/monitoring leave orphan PVs to clean by hand).
- **Adding a component** = ApplicationSet in `argocd/applications/{core,mlops}/` + values in `argocd/helm-values/<app>/` + toggle in `enabled_addons` + one `terraform apply`.

House rules for ApplicationSets: `project: default`, `automated {prune, selfHeal}`, `CreateNamespace=true`, sync-waves for ordering, `ServerSideApply=true` for charts with large CRDs, `ignoreDifferences` + `RespectIgnoreDifferences=true` for fields operators mutate at runtime (webhook caBundles, self-generated secrets). Pin every chart and image tag; no `:latest`.

## Cluster layer decisions

- **Providers** `helm`/`kubectl`/`kubernetes` authenticate via `exec aws eks get-token`. Never swap for a static `aws_eks_cluster_auth` token — 15-min TTL expires mid-apply.
- **System node group `karpenter`** (managed, spot t3a, tainted `karpenter.sh/controller`) hosts Karpenter, ArgoCD, coredns, EBS CSI controller, istiod, cert-manager. Karpenter provisions everything else.
- **Karpenter NodePools** (`terraform/karpenter-ec2.tf`), all amd64, spot-first, label `nodegroup=<pool>` as the scheduling convention:

  | Pool | AMI | Types | Taint | Purpose |
  |---|---|---|---|---|
  | `al2023` | `al2023@latest` | t-family 2–8 vCPU | none | default for untainted workloads |
  | `al2023-gpu` | `al2023@latest` (resolves to NVIDIA-optimized AMI, driver pre-baked) | g4dn/g5 | `nvidia.com/gpu` | llm-d decode — fastest GPU cold start |
  | `ubuntu` | Ubuntu 24.04 EKS via SSM, `amiFamily: Custom` + cloud-init | t-family 4–8 vCPU | `nodegroup=ubuntu` | cloud-init sandbox, Piraeus diskless tier, JupyterHub |
  | `ubuntu-gpu` | same Ubuntu | g4dn/g5 | `nvidia.com/gpu` | JupyterLab GPU; driver from GPU Operator |

  Ubuntu pools pin `local.ubuntu_eks_version` separately from `cluster_version` because Canonical lags EKS on AMI publication. `k8s.io/*` node labels must be set via the NodePool template, kubelet rejects them in `--node-labels`.
- **Storage:** managed NG `linstor-storage` (Ubuntu custom AMI, extra EBS, taint `linstor-storage`) is the diskful DRBD tier; `gp3` (encrypted, `WaitForFirstConsumer`, default) for everything else. No EFS.
- **Network:** VPC `10.0.0.0/16`, 3 AZs, nodes in private subnets behind a single NAT gateway, public cluster endpoint. Node SG additionally opens TCP 15017 (istiod webhook — the eks module's defaults don't, istiod loops on "webhook is not ready" without it). NetworkPolicy enforcement is on (`vpc-cni` addon `enableNetworkPolicy`); default-allow until a policy selects a pod.
- **Identity:** EKS Pod Identity only (no IRSA), one shared assume policy; associations for EBS CSI, ALB controller, BuildKit (ECR push to every repo in `local.ecr_repositories`).
- **Secrets:** no ESO/Vault/sops. Sandbox precedent is either hardcoded values in git (LiteLLM master key, Grafana admin) or an out-of-band `kubectl create secret` referenced by name (llm-d HF token, OpenClaw env).

## Platform decisions (core)

- **Ingress:** Traefik is the default IngressClass; exposure = chart-native `ingress` blocks with `*.local` hosts resolved via `/etc/hosts` → NLB IP, HTTP only. Istio runs control-plane only (no sidecar injection anywhere); Istio Gateways are used by llm-d as internal ClusterIP edges, not as the cluster door.
- **Monitoring:** one kube-prometheus-stack (Prometheus 1d retention, Grafana with Loki datasource), Loki single-binary on filesystem PVC, Promtail with tolerate-everything (every pool is tainted). `*SelectorNilUsesHelmValues: false` so all ServiceMonitors/PodMonitors are scraped. GPU Operator's ServiceMonitor couples it to `enable_monitoring`.
- **GPU Operator:** driver tag pinned (nvcr.io `-amzn2023` tags are unreliable, hence Ubuntu for Operator-installed drivers and the pre-baked AMI for AL2023). Custom dcgm metric set via ConfigMap in `argocd/manifests/nvidia-gpu-operator/` (csv is strict: exactly 3 fields per line).
- **Istio:** `defaultRevision: default`; `ignoreDifferences` on webhook `caBundle` **and** `failurePolicy` — istiod rewrites both at runtime and otherwise fights selfHeal forever.
- **Piraeus/LINSTOR:** two independently versioned OCI charts (operator wave 0, cluster wave 1, retry on CRD race). Diskful replicas on `linstor-storage`, diskless clients on the karpenter `ubuntu` pool (`allowRemoteVolumeAccess`). Never `modprobe drbd`/`drbd-dkms` in userData — in-tree DRBD 8.4 conflicts with the DRBD9 the satellite builds. `Retain` SCs leave orphan PVs + resource-definitions; 2-node DRBD uses `auto-quorum: suspend-io` (fail-closed) until a third satellite exists.

## Workload decisions (mlops)

- **JupyterLab:** image built in-cluster (BuildKit rootless Job, Pod Identity → ECR), deployed by a **manual-sync** Application because the image must exist before the first sync. Tag bumped explicitly in both the build Job and the manifest.
- **JupyterHub (z2jh):** all pods on the `ubuntu` pool, per-user `gp3` PVCs, DummyAuthenticator placeholder, `profile_options` (image × resource tier) + a GPU card. z2jh regenerates three secret tokens per render → `ignoreDifferences` on those Secret keys and the hub/proxy checksum annotations, else pods roll every sync.
- **Argo Workflows:** single namespace `argo` (`singleNamespace: true`) hosts controller + workflows; pipelines deploy into target namespaces (`mlops-pipelines`) via a reusable ClusterRole RoleBound per target — one CI namespace, N targets. `releaseName: argo` is load-bearing for the aggregated ClusterRole names. `crds.full: false` (no network-pulling hook Job). Client-token auth, no SSO. Prune caveat: the target namespace is an Argo-managed extraObject.
- **llm-d inference:** per-model Application from a matrix ApplicationSet (`clusters × models` list — one list entry = one model): upstream `llm-d-router-standalone` OCI chart (Envoy + EPP + InferencePool) + our `llm-d-modelserver` chart (vLLM decode on `al2023-gpu`, one GPU per model, weight cache PVC, Gateway/HTTPRoute/DestinationRule). Contracts: router `releaseName` = InferencePool name = `<resourceName>`; `llm-d.ai/model` label identical on router and decode pods; per-model Envoy ConfigMap name override in both `configMap.name` and the volume ref (upstream default `envoy` collides across models). Gateway Service forced to ClusterIP (else an AWS ELB per model); HTTPRoute at sync-wave 10 (istiod caches `BackendNotFound` if it lands before the pool); DestinationRule TLS `SIMPLE` to the EPP (it self-signs on :9002). LiteLLM is the single OpenAI-compatible door (`litellm.local`), DB-less, master key hardcoded so the chart renders the Secret deterministically. Gated HF models need an out-of-band `llm-d-hf-token` Secret.
- **OpenClaw:** single-instance AI agent (shell + browser tools), rendered directly from bjw-s `app-template` (the upstream openclaw-helm wrapper is archived and template-less), image `ghcr.io/openclaw/openclaw` pinned. Gateway :18789 behind Traefik `openclaw.local`, Chromium sidecar, state on a `gp3` PVC, `configMode: overwrite` (strict GitOps; `merge` + ConfigMap `ignoreDifferences` if UI pairing must survive restarts). Security posture: dedicated SA with zero RBAC and no mounted token (agent has shell, kube API is public), `karpenter.sh/do-not-disrupt` on the spot node, NetworkPolicy default-deny — ingress only from ns `traefik`, egress only kube-dns + `0.0.0.0/0 except` private/CGN/link-local (blocks IMDS, Pod Identity agent, in-cluster IPs). `ipBlock.except` is a known VPC CNI hazard (aws/amazon-network-policy-controller-k8s#146: an `except` DENY has overridden a neighbouring kube-dns ALLOW) — after any policy change verify DNS from the pod resolves; the explicit public-CIDR fallback is kept as a comment next to the rule. Secret `openclaw-env` (gateway token, `ANTHROPIC_API_KEY`) is out-of-band; without it the pod sits in `CreateContainerConfigError`.
