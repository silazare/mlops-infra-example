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
- [ ] NVIDIA GPU Operator — GPU setup
- [x] Grafana Mimir + Alloy — Monitoring

MLOps layer (ArgoCD at `argocd/applications/mlops/`):
- TBD


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
<IP>  argocd.local vault.local hipster.local grafana.local prometheus.local alertmanager.local
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


## JupyterLab example with GPU - manual deploy

https://medium.com/@sinan.ozel_23433/iac-for-generative-ai-llm-jupyterlab-on-kubernetes-a33d31841a27
https://www.jimangel.io/posts/nvidia-rtx-gpu-kubernetes-setup/

1) Build Docker image

```shell
cd jupyterlab-llm
docker build --tag jupyterlab-llm:25.01 .
```

2) Push Docker image to ECR

```shell
aws ecr get-login-password --region eu-west-1 | docker login --username AWS --password-stdin 576087096890.dkr.ecr.eu-west-1.amazonaws.com
docker tag jupyterlab-llm:25.01 576087096890.dkr.ecr.eu-west-1.amazonaws.com/jupyterlab-llm:25.01
docker push 576087096890.dkr.ecr.eu-west-1.amazonaws.com/jupyterlab-llm:25.01
```
