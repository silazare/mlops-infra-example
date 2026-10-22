# DRA test manifests

```bash
k apply -f mlops/dra-test/00-namespace.yaml
```

## Shared checks

```bash
k get resourceslices -o yaml | grep -E 'nodeName|productName|uuid|profile|type:'   # what the drivers publish
k -n dra-test get resourceclaims                                                    # allocated,reserved per pod
k -n dra-test logs <pod> [-c <ctr>]                                                 # UUID printed by nvidia-smi -L
k -n dra-test describe pod <pod> | sed -n '/Events/,$p'                             # why Pending
k -n gpu-dra-driver logs ds/dra-driver-nvidia-gpu-kubelet-plugin -c gpus --tail=50  # prepare/unprepare
```

## 01–04: full GPU, pool `ubuntu-gpu` (T4 / A10G)

| File | Pods | Checks | Expect |
|---|---|---|---|
| `01-claim-single-gpu.yaml` | `claim-single` | explicit claim instead of `nvidia.com/gpu` | UUID in pod log = `uuid` in the node's slice |
| `02-shared-claim.yaml` | `shared-claim` | one claim, two containers (template from 01) | same UUID in `-c a` and `-c b` |
| `03-cel-selector.yaml` | `cel-t4`, `cel-big`, `cel-impossible` | CEL by product / memory | T4; A10G (Karpenter launches g5 if needed); Pending with event |
| `04-first-available.yaml` | `first-available` | prioritized list A10G → any | A10G if free, else T4 instead of Pending |

Clean up before MIG: `kubectl -n dra-test delete pod --all`, claims must disappear with the pods.

## 05–09: Dynamic MIG, pool `ubuntu-gpu-mig` (p5.4xlarge, 1× H100 80GB)

| File | Pods | Checks | Expect |
|---|---|---|---|
| `05-mig-warmup.yaml` | `mig-warmup` | full-GPU claim to make Karpenter launch the node (it does not model MIG claims) | node up, driver built (5–8 min), pod Running. Plugin log: `DynamicMIG enabled`, **not** `hardware does not support MIG`; slice lists profiles `1g.10gb`…`7g.80gb` + `sharedCounters`. **Delete the pod before 06** — a card holding a full-GPU claim cannot be sliced |
| `06-mig-any.yaml` | `mig-any` | any slice, created on prepare | MIG device in pod; on node `nvidia-smi mig -lgi` shows one GI. Delete pod → GI gone |
| `07-mig-profile.yaml` | `mig-profile`, `mig-bogus` | profile by attribute | `1g.10gb` Running; bogus profile Pending |
| `08-mig-two-profiles.yaml` | `mig-pair` | 1g + 2g in one claim, same parent GPU (`matchAttribute: parentUUID`) | both containers up, same parent UUID. Crash test: delete the kubelet-plugin pod while `mig-pair` is ContainerCreating → no orphan GIs after restart |
| `09-mig-fill.yaml` | deploy `mig-fill` ×8 | fill the card with 1g slices (template from 07) | 7 Running, 8th Pending without prepare errors. `scale --replicas=0` → GI list empty |
| `10-mig-remix.yaml` → delete `remix-3g` → `10b-mig-remix-phase-b.yaml` | `remix-3g`, `remix-1g-a/b`, then `remix-2g`, `remix-1g-c` | **the actual Dynamic MIG case**: independent pods of different profiles share one card, the mix changes as pods come and go | A: node shows 3g+1g+1g. B: 3g GI gone, 1g pods untouched. C: 2g+1g+1g+1g; `remix-1g-a/b` same start time, restartCount 0. With static MIG this would be a new `mig.config` and MIG Manager evicting every GPU pod on the node. Run after 09 is scaled to 0 |

Node-side:

```bash
k -n gpu-operator exec ds/nvidia-driver-daemonset -- nvidia-smi mig -lgi

k -n gpu-operator exec ds/nvidia-driver-daemonset -- nvidia-smi --query-gpu=name,mig.mode.current --format=csv
```

Not covered: consumable capacity on a slice (needs `featureGates.ConsumableShares` + `consumableShares` in the driver
values) and a real LLM on `3g.40gb` (llm-d modelserver chart with a claim).
