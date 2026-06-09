# Infra Components

AWS EKS layer (Terraform):
- [x] VPC
- [x] EKS cluster and EKS addons
- [x] Karpenter
- [x] AWS Load Balancer Controller IAM
- [x] ArgoCD
- [x] GitOps Bridge — cluster Secret + root Application

Core layer (ArgoCD at `argocd/applications/core/`):
- [x] Traefik ingress controller
- [x] AWS Load Balancer Controller (Helm release; IAM stays in TF)
- [x] NVIDIA GPU Operator
- [x] Grafana Mimir + Alloy — Monitoring
- [x] Piraeus Operator for Linstor tests

MLOps layer (ArgoCD at `argocd/applications/mlops/`):
- [x] JupyterLab (CUDA/LLM) — image built in-cluster via BuildKit Job, deploy via manual-sync Argo Application
- [x] JupyterHub — multi-user Jupyterhub
- [x] Argo Workflows - CI for ML pipelines

### Core Addons toggle
Each core component is gated by an `enable_<addon>` flag in [terraform/main.tf](terraform/main.tf).
Flags are published as labels on the ArgoCD cluster Secret; each ApplicationSet in [argocd/applications/core/](argocd/applications/core/) filters on its own label. Set a value to `false` and Argo prunes the addon.


## Deployment

1. Terraform — creates VPC, EKS, Karpenter, ArgoCD, cluster Secret, root Application.
2. ArgoCD picks up the root Application → recursively discovers `argocd/applications/core/` and `argocd/applications/apps/`.
3. ApplicationSets materialise child Applications that install Traefik, ALB controller, etc.
4. Traefik comes up, NLB gets provisioned by ALB controller, you map the NLB IP in `/etc/hosts`.

### 1. Terraform

```shell
cd terraform
terraform init -upgrade
terraform apply
```

### 2. Wait for ArgoCD to sync core platform

During the first minutesthe ArgoCD UI is not yet reachable via `argocd.local`. 
Access the UI via port-forward:

```shell
k -n argocd port-forward svc/argocd-server 8080:80
# open http://localhost:8080
```

### 3. Map the NLB IP into `/etc/hosts`

```shell
k -n traefik get svc traefik \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' \
  | xargs dig +short
```

Pick any one of the returned IPs and add:

```shell
<IP>  argocd.local argo-workflows.local grafana.local jupyter.local
```

### 4. Retrieve ArgoCD admin password

```shell
k -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d; echo
```

Login to CLI and add the GitOps repo (if not public):

```shell
argocd login argocd.local:443

argocd repo add https://github.com/silazare/argocd-infra-example.git \
  --username silazare --password github_pat_xxxxx

argocd repo add ghcr.io --type helm --name stable --enable-oci
```

## Delete infrastructure

```shell
# delete ArgoCD root application

# remove stuck application sets
for kind in applications applicationsets; do
  for name in $(kubectl -n argocd get $kind -o name); do
    kubectl -n argocd patch $name --type=json \
      -p='[{"op":"remove","path":"/metadata/finalizers"}]' 2>/dev/null
  done
done

# deleted Karpenter CRD to fix terraform destroy stuck
terraform state rm helm_release.karpenter_crd

terraform destroy
```

## JupyterLab example with GPU

https://medium.com/@sinan.ozel_23433/iac-for-generative-ai-llm-jupyterlab-on-kubernetes-a33d31841a27
https://www.jimangel.io/posts/nvidia-rtx-gpu-kubernetes-setup/

### 1. Build & push image — in-cluster with BuildKit rootless

Build runs as a Job in `buildkit` namespace and pushes image, layer cache to `jupyterlab-llm-cache` repo. Update branch/tag inside `build-job.yaml` if needed.

Edit the tag in files (keep them in sync), then build + push + sync:

- [mlops/jupyterlab-llm/build-job.yaml](mlops/jupyterlab-llm/build-job.yaml) — `--output=...:<NEW_TAG>`
- [argocd/manifests/jupyterlab-llm/jupyterlab-llm-pod.yaml](argocd/manifests/jupyterlab-llm/jupyterlab-llm-pod.yaml) — `image: ...:<NEW_TAG>`

```shell
k replace --force -f mlops/jupyterlab-llm/build-job.yaml
```

### 2. Deploy via Argo manual sync

Application is not auto-synced — image must exist in ECR before first sync. 
Trigger sync manually:

```shell
argocd app sync jupyterlab-llm
```

## Piraeus Operator tests for Linstor

Sandbox for a Piraeus / LINSTOR / DRBD persistent-storage stack
Settings at [argocd/helm-values/linstor-cluster/values.yaml](argocd/helm-values/linstor-cluster/values.yaml)

Three placement modes, one StorageClass per replica count:

| Manifest | StorageClass | Placement | What it proves |
|---|---|---|---|
| [mlops/hdd1-test-sts.yaml](mlops/hdd1-test-sts.yaml) | `linstor-hdd-1r` (`autoPlace=1`) | 1 diskful replica on a storage node | Provisioning + ext4 + Retain reclaim works; PV survives Pod recreate on the same node |
| [mlops/hdd2-test-sts.yaml](mlops/hdd2-test-sts.yaml) | `linstor-hdd-2r` (`autoPlace=2`) | 2 diskful replicas across storage nodes | Synchronous DRBD replication; Pod can come back on either replica node |
| [mlops/diskless-test-sts.yaml](mlops/diskless-test-sts.yaml) | `linstor-hdd-2r` | 2 diskful on storage NG + 1 diskless DRBD client on karpenter `ubuntu` node | Compute / storage separation pattern — the bare-metal target shape where GPU nodes mount data over the network from CPU storage nodes |

### Quick check

```shell
# Satellites + storage pools
k -n piraeus-datastore exec deploy/linstor-controller -- linstor node list
k -n piraeus-datastore exec deploy/linstor-controller -- linstor storage-pool list

# Apply any of the test STS and watch the resource list
k apply -f mlops/linstor/hdd2-test-sts.yaml
k -n piraeus-datastore exec deploy/linstor-controller -- linstor resource list

# Live DRBD state on a specific satellite
k -n piraeus-datastore get pod -l app.kubernetes.io/component=linstor-satellite -o wide
k -n piraeus-datastore exec <satellite-pod> -- drbdadm status
```

## JupyterHub deployment

Sandbox for multi-user JupyterHub via the [zero-to-jupyterhub (z2jh)](https://z2jh.jupyter.org/) chart

| Component | What it is | Deploys |
|---|---|---|
| `hub` | JupyterHub control plane — auth + per-user pod spawning (KubeSpawner) | `hub` Deployment + state DB on `gp3` |
| `proxy` | `configurable-http-proxy` — routes `/hub` and `/user/<name>` traffic | `proxy` Deployment + `proxy-public` Service (ClusterIP) |
| `singleuser` | Template for each user's notebook server (JupyterLab UI, `jupyter_server` backend) | Per-user pod + dynamic 10Gi `gp3` PVC, spawned on first login |
| `scheduling` | Cost/packing: dedicated scheduler, pod priority, warm placeholders | `user-scheduler` Deployment, `PriorityClass`, `user-placeholder` pods |
| `cull` | Idle-culler — stops servers idle >1h so Karpenter scales in | culler service inside the hub (no separate pod) |
| `prePuller` | Pre-pulls the singleuser image so spawns are fast | pre-upgrade Job (`hook`) + continuous DaemonSet on `ubuntu` nodes |

User management — edit the lists in `hub.config.Authenticator`, then `helm upgrade`:
- `allowed_users` — who may log in (the user slicing); `admin_users` — subset with the admin panel.
- Usernames must be DNS-safe (lowercase) — they become the PVC name `claim-<username>` and the `/home/jovyan` owner.

### Access

All users share the single host — routing is path-based inside the proxy (CHP), not per-user ingress:
- Log in at `jupyter.local` > redirected to `/user/<username>/lab` (that user's own pod).
- Admins reach other users' servers via `/hub/admin` > **Access Server**

### PV lifecycle

Each user gets one PVC `claim-<username>` (template `claim-{username}{servername}`), backed by a 10Gi `gp3` volume mounted at `/home/jovyan`. The Hub never deletes a PVC — server shutdown detaches the volume but keeps the data:

```
login            → Hub creates PVC claim-<username> > CSI creates PV (real disk)
                 → PV mounted into the pod as /home/jovyan
server shutdown  → pod deleted, PV detached
                 → PVC + PV REMAIN (data lives on)
re-login         → Hub sees the existing PVC > mounts the same PV
```

### Offboarding a user

Two independent flows — access vs data.

1. **Revoke access** (safe, instant) — remove from `allowed_users`/`admin_users`, then `helm upgrade`. PVC stays, data intact.
2. **Stop a running server** — admin UI `/hub/admin` > **Stop**, or `k -n jupyterhub delete pod jupyter-<username>` (pod only, leaves the PVC).
3. **Handle data — back up BEFORE deleting.**


## Argo Workflows deployment

Workflow engine for ML pipelines, used as an in-cluster CI that deploys Helm releases in order. Installed via ArgoCD ([argo/argo-workflows](https://github.com/argoproj/argo-helm) chart.

| Component | What it is | Deploys |
|---|---|---|
| `controller` | Workflow controller — reconciles `Workflow` CRs into step pods | `controller` Deployment in `argo`, namespaced (`singleNamespace: true`) |
| `server` | Argo UI + API (`argo-server`), auto `--namespaced` on `argo` | `server` Deployment + ClusterIP `:2746` + Traefik Ingress `argo-workflows.local` |
| `crds` | Workflow / CronWorkflow / etc. CRDs | minified CRDs as plain chart templates (`crds.full: false` — no pre-install hook Job, no network pull); Application uses `ServerSideApply=true` |
| `workflow` SA + RBAC | identity step pods run as | SA `argo-workflow` + Role in ns `argo` |
| `extraObjects` (UI) | UI login identity | SA `argo-ui` + long-lived token Secret + `RoleBinding` to `argo-argo-workflows-admin`, scoped to ns `argo` |
| `extraObjects` (deploy) | cross-ns Helm deployer | `wf-helm-deployer` ClusterRole + `mlops-pipelines` Namespace + `argo-workflow-helm` RoleBinding (grants the workflow SA Helm rights in the target ns) |

**Architecture:** control-plane and CI workflows both live in `argo`. Pipelines deploy into target namespaces (`mlops-pipelines`) via cross-namespace RBAC, not by running steps there — adding a target is one Namespace + one RoleBinding in `extraObjects`, no controller-scope change.

### Access

UI at `http://argo-workflows.local` (Traefik, HTTP). No SSO — `client` mode, paste an SA bearer token. The UI lands on ns `argo` at login (where the workflows are) — no Forbidden.

```shell
# Login token, paste WHOLE output (incl. "Bearer ") into the client-auth field
echo "Bearer $(k -n argo get secret argo-ui.service-account-token \
  -o jsonpath='{.data.token}' | base64 -d)"
```

### Smoke test

```shell
# basic test
argo submit -n argo --serviceaccount argo-workflow --watch \
  https://raw.githubusercontent.com/argoproj/argo-workflows/main/examples/hello-world.yaml

# cross-ns Helm deploy
argo submit -n argo --watch mlops/argo-wf/helm-deploy-test.yaml
helm -n mlops-pipelines list
```
