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
<IP>  argocd.local grafana.local
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
k apply -f mlops/hdd2-test-sts.yaml
k -n piraeus-datastore exec deploy/linstor-controller -- linstor resource list

# Live DRBD state on a specific satellite
k -n piraeus-datastore get pod -l app.kubernetes.io/component=linstor-satellite -o wide
k -n piraeus-datastore exec <satellite-pod> -- drbdadm status
```
