# Project: vLLM on EKS Summary
---

## 1. What we built (one sentence)
Provisioned a GPU on **AWS EKS with Terraform**, installed the **NVIDIA GPU Operator**, and served
**Qwen2.5-7B-Instruct-AWQ** through **vLLM's OpenAI-compatible API** — a production-shaped model
inference endpoint, reachable via `curl /v1/completions`.

## 2. The stack, top to bottom (know this cold)
| Layer | Tool | Role in one line |
|---|---|---|
| Provisioning | **Terraform** | Declares VPC + EKS + GPU node as code; one command up, one to tear down |
| Orchestration | **Kubernetes (EKS)** | Schedules/restarts/heals the serving container — makes it a service, not a script |
| GPU enablement | **NVIDIA GPU Operator** | Makes k8s *see* the GPU: device plugin + DCGM metrics + (later) time-slicing |
| Serving engine | **vLLM** | Loads model on GPU, serves fast (PagedAttention + continuous batching), OpenAI API |
| Model | **Qwen2.5-7B-AWQ** | The payload; AWQ = 4-bit so 7B fits in 24 GB with KV-cache room |
| Packaging | **Helm** | Installs the GPU Operator chart (vLLM itself = plain `kubectl apply`) |

## The parts worth knowing

### `eks.tf`

EKS module v21 needs `authentication_mode = "API"` and
`enable_cluster_creator_admin_permissions = true`. v21 defaults that second one to `false`, and
if you miss it you lock yourself out of your own cluster with `kubectl`.

The **system node group** (`m7i.large`, desired 1) keeps CoreDNS, the Operator controller and
metrics off the GPU node.

The **GPU node group**:

```hcl
ami_type       = "AL2023_x86_64_NVIDIA"
instance_types = ["g6.xlarge"]        # fallback: ["g5.xlarge"]
min_size = 0; max_size = 1; desired_size = 1
block_device_mappings = { xvda = { ebs = { volume_size = 100, volume_type = "gp3" } } }
labels = { "workload" = "gpu" }
taints = { gpu = { key = "nvidia.com/gpu", value = "present", effect = "NO_SCHEDULE" } }
```

The taint keeps everything except GPU workloads off the node. `min_size = 0` is what lets us
scale the expensive part to zero between sessions.

### `gpu-operator.tf`

Chart `gpu-operator` v26.3.2 from `https://helm.ngc.nvidia.com/nvidia`, with
`driver.enabled=false` and `toolkit.enabled=false` because the AMI already provides both.

One thing worth attention: the Operator's DaemonSets need a toleration for the custom taint
(`nvidia.com/gpu Exists NoSchedule`), or they never land on the GPU node and the node never
advertises a GPU.


### `k8s/vllm-deployment.yaml`

The image's entrypoint already starts the API server, so pass everything through `args`. Using
`command` overrides the entrypoint and nothing starts.

```
--model=Qwen/Qwen2.5-7B-Instruct-AWQ
--quantization=awq_marlin        # not plain "awq", which selects the slow kernel
--dtype=float16
--gpu-memory-utilization=0.90
--max-model-len=8192
--max-num-seqs=16
--port=8000
```

Other details:

- `resources.limits["nvidia.com/gpu"] = 1`, plus modest CPU/memory requests (2 CPU, 8 Gi).
- `tolerations` for `nvidia.com/gpu Exists NoSchedule`, and `nodeSelector: { workload: gpu }`.
- First boot is slow: an ~11 GB image pull followed by a model load. The `startupProbe` on
  `/health` uses `failureThreshold: 60, periodSeconds: 10`, giving it ten minutes before
  Kubernetes gives up. Readiness and liveness take over after that. Without a generous startup
  probe you get a restart loop that looks like a crash but is just a slow model load.
- No `HF_TOKEN`, since the model is ungated.
- ClusterIP Service on 8000, reached with `kubectl port-forward`.

### `scripts/verify.sh` — the single verification entry point

One script, run after `kubectl apply`, that proves the whole chain end to end:

```bash
bash scripts/verify.sh
```

| Step | What it proves |
|---|---|
| `kubectl config current-context` | I'm pointed at the right cluster (cheap, catches the classic mistake) |
| `kubectl wait --for=condition=ready pod -l app=vllm --timeout=900s` | The pod scheduled on the tainted GPU node and passed its startup probe |
| port-forward, then retry `GET /v1/models` until it answers | The tunnel is actually up — no blind `sleep` |
| `POST /v1/completions` and grep for `"text"` | **The checkpoint:** the GPU generated tokens. Asserts, so it exits non-zero on failure |
| `kubectl exec deploy/vllm -- nvidia-smi` | Real VRAM number to compare against the KV-cache math below |
| grep the logs for `Available KV cache memory` / `Maximum concurrency` | The KV-cache evidence, which is the flagship talking point |

Two design choices worth defending:

- **The timeout is 900s, not 300s.** It has to exceed the `startupProbe` runway (60 × 10s ≈ 10 min),
  or the verifier fails a pod that is merely still loading — a false negative that looks like a
  crash. Verification timeouts must be *looser* than the probe they're waiting on.
- **It asserts rather than prints.** An earlier `smoke-test.sh` piped the response to `jq` and
  exited 0 regardless, so an error JSON body counted as a pass. It was deleted; grepping for
  `"text"` and exiting non-zero is what makes this usable as a CI gate in project 7.

### KV cache vs OOM

This is the flagship discussion, so here's the Math-

`--gpu-memory-utilization=0.90` means vLLM may touch about 21.6 GB of the 24 GB card. Out of
that comes ~1 GB of CUDA context, ~5.5 GB of AWQ weights and ~1–2 GB of activations. Everything
left over, roughly 13–14 GB, becomes KV cache. KV cache is the leftover, not a reservation,
which is why a cap set too low produces a negative number and the engine refuses to start.

`--max-model-len` bounds the context of a single sequence. Qwen2.5-7B costs roughly 64 KB per
token, so 8192 tokens is about 0.5 GB for one sequence at full length.

**If it OOMs, turn these down in this order:** `--gpu-memory-utilization` (0.90 → 0.85 → 0.80),
then `--max-model-len` (8192 → 4096), then `--max-num-seqs`. Reach for `--enforce-eager` last,
and mostly as a diagnostic: it drops CUDA graphs, which frees a few hundred MB but costs you
speed.

vLLM prints a "# GPU blocks" / KV cache line at startup. That line is the evidence that your
math was right.


## 3. THE headline talking point — KV-cache vs OOM (memorize the numbers)
On a **24 GB L4**, with `--gpu-memory-utilization=0.90` and `--max-model-len=8192`:
- Budget ≈ 20.7 GiB → weights **5.3 GiB** → **KV cache 13.34 GiB = 249,776 tokens = 30.49× concurrency**
- Actual GPU use ≈ **19.5 / 23 GiB (~85%)**, under the 0.90 ceiling

> "Raise utilization → more KV cache/throughput but less OOM headroom. Lower `--max-model-len` →
> shorter max context but more concurrent sequences. OOM on boot? drop util 0.90→0.85, then
> max-model-len 8192→4096, then max-num-seqs, then `--enforce-eager`."

## 4. Why self-host vs. calling Claude/OpenAI
Building the serving platform **is the job**. Self-hosting wins on **cost-at-scale, data privacy
(prompts stay in your VPC), latency, and model control** — a hosted API would delete the infra role.

---

## 5. Issues hit & fixed (the war stories — these impress more than the happy path)

| # | Symptom | Root cause | Fix |
|---|---|---|---|
| 1 | Nodes stuck `NotReady`, node groups `CREATE_FAILED`, empty kube-system | **EKS module v21 sets `bootstrap_self_managed_addons=false`** — no VPC CNI installed by default → no pod networking | Declared an `addons` block: `vpc-cni` (with `before_compute=true`), `kube-proxy`, `coredns`. Recreate failed node groups via `terraform apply -replace=...` |
| 2 | vLLM pod `CrashLoopBackOff`: *"VLLM_PORT 'tcp://…:8000' appears to be a URI"* | Service named `vllm` → k8s auto-injects `VLLM_PORT=tcp://…` (Docker-link env), which vLLM misreads as its listen port | `enableServiceLinks: false` on the pod spec |
| 3 | New pod stuck `Pending` on deploy update | **Single GPU + rolling update** = new pod needs a GPU the old pod still holds → deadlock | `kubectl scale deploy/vllm --replicas=0` then `=1` (or use `Recreate` strategy / multi-GPU for true zero-downtime) |
| 4 | `terraform apply` died at 27 min: `dial tcp: lookup eks… no such host` | **Laptop slept** → local apply lost network (HCP Local execution runs on the laptop) | `caffeinate -ims terraform apply`, lid open + AC; or HCP Remote execution |
| 5 | Planning assumed g6.xlarge + quota request | **g6.xlarge not offered in eu-west-1** (only g5); **GPU quota already 768** (not 0) | Deploy in **us-east-1** (has g6 + quota); skipped the quota-increase step |

**Meta-lesson:** the node *bootstrapped fine* (kubelet ran) in issue #1 — the only symptom was `NotReady`
+ empty kube-system. Lesson: when managed node groups fail with "Unhealthy nodes," check the CNI/addons
first, not the node bootstrap.

---

## 6. Cost & operational commands (the ownership signal)
- **Active:** ~$1.05/hr (g6.xlarge $0.80 + control plane $0.10 + system node $0.10 + NAT $0.05)
- **Paused** (GPU node → 0): ~$0.25/hr · **Destroyed:** $0
- Verify: `bash scripts/verify.sh` · Pause: scale GPU node group `desiredSize=0` · Tear down: `terraform destroy`
- Scale GPU nodes: `bash scripts/gpu-nodes-scaling.sh {status|in|out [n]}` — must go through the AWS CLI,
  not Terraform: the EKS module has `ignore_changes` on `desired_size`, and changing `max_size` alone is
  rejected (`desired > max`). Move all bounds in one call.

## 7. If asked "what would you do for production?"
- Model weights on a **PVC** (not re-download per restart) · **2+ GPUs** for zero-downtime blue/green
- **Autoscaling** (KEDA on queue depth) · **observability** (DCGM → Prometheus → Grafana; cost-per-token)
- Pin every version (image, chart, AMI, modules) — already done here
