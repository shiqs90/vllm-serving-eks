# Project 1 — vLLM Serving Foundation on EKS (Terraform + NVIDIA GPU Operator)

## Context

Production-grade LLM serving foundation: vLLM running on a GPU provisioned end-to-end with
infrastructure-as-code. Part 1 of a series (multi-model routing and GPU observability build
on this cluster).

**Definition of done :** One model answers through vLLM's
OpenAI-compatible API on an EKS GPU node provisioned with Terraform; `curl .../v1/completions`
returns tokens, **and** I can read GPU memory utilization and justify the
`--gpu-memory-utilization` and `--max-model-len` flags (the KV-cache-vs-OOM tradeoff).

**Locked decisions:**
- Cloud: **AWS EKS**, provisioned with Terraform.
- Model: **`Qwen/Qwen2.5-7B-Instruct-AWQ`** (ungated on HF, ~5–6 GB weights, no token needed).
- Driver/AMI: **Option A** — EKS accelerated AMI (`AL2023_x86_64_NVIDIA`) ships the driver;
  the GPU Operator runs with `driver.enabled=false` and still owns the device plugin, DCGM
  exporter, and time-slicing config (reused by the observability and GPU-sharing projects).
  Chosen because the Operator installing the driver on Amazon Linux 2023 is **unsupported**
  by NVIDIA, and this path is the AWS-recommended, simplest, fastest-booting option.
- Packaging: **Helm** installs the GPU Operator (via Terraform's `helm_release` in
  `gpu-operator.tf`); **vLLM is deployed with plain `kubectl apply`** — a single Deployment
  doesn't need a chart, and raw YAML iterates faster on flags.
- Build style: plan-first, then build checkpoint-by-checkpoint.

## What this is — orientation & glossary

There is **no custom App or dataset** here. 
What gets deployed is an **inference API**: an HTTP endpoint that takes a prompt and returns generated text. Everything below exists to put one model on one GPU and serve it reliably — which is precisely the AI Infrastructure
Engineer's job --> operate the serving platform, not train the model or build the app on top.

**The layers, top to bottom:**

| Layer | Tool | What it does here (2-liner) |
|---|---|---|
| Provisioning (IaC) | **Terraform** | Declares the cloud infra as code — VPC, EKS cluster, and the GPU node — so the environment is reproducible and tear-down-able with one command. |
| Orchestration | **Kubernetes (EKS)** | Runs and supervises the serving container: schedules it onto the GPU node, restarts it on failure, handles networking/scaling. The control layer that makes serving *production-grade*, not a one-off script. |
| GPU enablement | **NVIDIA GPU Operator** | Makes Kubernetes actually *see and use* the GPU (driver, device plugin, metrics). Without it, k8s has no idea a GPU exists. |
| Serving engine | **vLLM** | The inference server: loads the model onto the GPU and serves it fast (PagedAttention + continuous batching = high throughput, low latency). Exposes an OpenAI-compatible API. |
| Model (payload) | **Qwen2.5-7B-Instruct-AWQ** | The LLM being served — turns prompts into text. AWQ = 4-bit quantized so a 7B model fits in a 24 GB GPU with room for KV-cache. Just the payload that proves the stack works. |
| Package manager | **Helm** | Kubernetes' package installer — deploys pre-templated, configurable bundles ("charts") in one command. Used here (via Terraform `helm_release`) to install the **GPU Operator** chart = ~6 components at once. *vLLM itself is plain `kubectl apply`, not Helm.* In Row 2, the whole vLLM stack + router is one chart. |
| Test client | **curl** | Hits `/v1/completions` to prove the end]point returns tokens — the checkpoint. |

**Why self-host instead of calling Claude/OpenAI?** Because *
Self-hosting your own infra wins on cost-at-scale, data privacy (prompts stay in your VPC),
latency, and model control

## Hardware

1× **g6.xlarge** GPU node (NVIDIA **L4, 24 GB VRAM**, Ada — ~$0.805/hr, 100 GB gp3 root) plus
1× **m7i.large** CPU system node so system pods never occupy the GPU. The L4 is sized from the
model: Qwen2.5-7B in 4-bit AWQ ≈ 5.3 GB of weights, leaving ~13 GB of the 24 GB for KV-cache.

## Pinned versions

| Component | Pin |
|---|---|
| Terraform | ≥ 1.5 |
| AWS provider | ~> 6.0 |
| terraform-aws-modules/vpc/aws | ~> 6.0 (single-NAT) |
| terraform-aws-modules/eks/aws | ~> 21.0 |
| EKS cluster version | 1.33 |
| GPU node AMI type | `AL2023_x86_64_NVIDIA` (accelerated) |
| GPU instance | `g6.xlarge` (L4, 24 GB, ~$0.80/hr) — fallback `g5.xlarge` (A10G) |
| NVIDIA GPU Operator chart | v26.3.2 (`driver.enabled=false`, `toolkit.enabled=false`) |
| vLLM image | `vllm/vllm-openai:v0.22.1` (do NOT use `:latest`) |
| Model | `Qwen/Qwen2.5-7B-Instruct-AWQ` |

## Repo / file layout

```
vllm-serving-eks/
  terraform/
    versions.tf      # provider + module version pins
    providers.tf     # aws, kubernetes, helm providers (helm uses EKS auth)
    variables.tf     # region, cluster_version, gpu_instance_type (default g6.xlarge)
    vpc.tf           # terraform-aws-modules/vpc ~>6.0, single NAT gateway
    eks.tf           # terraform-aws-modules/eks ~>21.0; system + gpu node groups
    gpu-operator.tf  # helm_release nvidia/gpu-operator v26.3.2 (driver.enabled=false)
    outputs.tf       # cluster_name + `aws eks update-kubeconfig` command
  k8s/
    vllm-deployment.yaml  # Deployment + ClusterIP Service
  scripts/
    smoke-test.sh    # port-forward + curl /v1/completions
  README.md          # KV-cache math, build sequence, checkpoint evidence
```

Split: GPU Operator lives in Terraform as a `helm_release` (so `terraform destroy` cleans it
up); the vLLM manifest stays plain YAML applied with `kubectl` (faster flag iteration than
re-applying TF).

## Key implementation details

### Terraform (`eks.tf`)
- EKS module v21: `authentication_mode = "API"`, `enable_cluster_creator_admin_permissions = true`
  (v21 defaults this to false — without it you lock yourself out of `kubectl`).
- **System node group** (`m7i.large`, desired 1) so CoreDNS / Operator controller / metrics land
  off the GPU node.
- **GPU node group**:
  ```hcl
  ami_type       = "AL2023_x86_64_NVIDIA"
  instance_types = ["g6.xlarge"]        # fallback: ["g5.xlarge"]
  min_size = 0; max_size = 1; desired_size = 1
  block_device_mappings = { xvda = { ebs = { volume_size = 100, volume_type = "gp3" } } }
  labels = { "workload" = "gpu" }
  taints = { gpu = { key = "nvidia.com/gpu", value = "present", effect = "NO_SCHEDULE" } }
  ```
  `min_size=0` enables scale-to-zero for cost.

### GPU Operator (`gpu-operator.tf`)
- `helm_release` from `https://helm.ngc.nvidia.com/nvidia`, chart `gpu-operator` v26.3.2.
- Values: `driver.enabled=false`, `toolkit.enabled=false`; add a `daemonsets.tolerations`
  entry for `nvidia.com/gpu Exists NoSchedule` (custom taint value).
- Device plugin, GFD, DCGM exporter, NFD stay enabled (defaults) — these feed Rows 3 & 4.

### vLLM (`k8s/vllm-deployment.yaml`)
- Image entrypoint already runs the API server — pass model/flags via `args`, never `command`.
- Args (24 GB starting point):
  ```
  --model=Qwen/Qwen2.5-7B-Instruct-AWQ
  --quantization=awq_marlin        # NOT plain "awq" (that forces the slow kernel)
  --dtype=float16
  --gpu-memory-utilization=0.90
  --max-model-len=8192
  --max-num-seqs=16
  --port=8000
  ```
- `resources.limits["nvidia.com/gpu"] = 1`; modest cpu/mem requests (e.g. 2 cpu / 8Gi).
- `tolerations`: `nvidia.com/gpu Exists NoSchedule`; `nodeSelector: { workload: gpu }`.
- Probes tolerant of slow first boot (5–6 GB pull + model load): `startupProbe` GET `/health`
  `failureThreshold: 60, periodSeconds: 10` (~10 min); readiness/liveness GET `/health` after.
- No `HF_TOKEN` (model is ungated). Optional HF cache on emptyDir.
- `Service` ClusterIP :8000, reached via `kubectl port-forward` for the checkpoint.

### KV-cache-vs-OOM rationale (documented in README)
24 GB budget ≈ CUDA context ~1 GB + AWQ weights ~5.5 GB + activations ~1–2 GB → **~14–16 GB
for KV cache**. `--gpu-memory-utilization 0.90` sets the ceiling vLLM allocates KV cache under;
`--max-model-len` bounds per-sequence context (Qwen2.5-7B ≈ ~64 KB/token, so 8192 ≈ ~0.5 GB
for one full-length sequence). **OOM remedy order:** lower `--gpu-memory-utilization` (0.90→0.85→0.80),
then `--max-model-len` (8192→4096), then `--max-num-seqs`, then `--enforce-eager` as a diagnostic.
Capture vLLM's startup "# GPU blocks" / KV-cache line as evidence.

## Build sequence (each step has a verification check)

1. **Quota** — request EC2 "Running On-Demand G and VT Instances" ≥ 8 vCPU.
   *Verify:* Service Quotas shows applied quota ≥ 8. **(#1 blocker — 0 by default on new accounts.)**
2. **`terraform apply`** VPC + EKS + node groups.
   *Verify:* `aws eks update-kubeconfig …` then `kubectl get nodes` → 1 system + 1 GPU node `Ready`.
3. **Confirm taint/label** on GPU node.
   *Verify:* `kubectl describe node <gpu>` shows the taint + `workload=gpu`.
4. **GPU Operator** comes up (installed via the `helm_release` in step 2).
   *Verify:* `kubectl -n gpu-operator get pods` healthy; node advertises `nvidia.com/gpu: "1"`.
5. **`kubectl apply -f k8s/vllm-deployment.yaml`.**
   *Verify:* pod schedules on the GPU node (not Pending); logs show the KV-cache line; `/health` 200.
6. **Checkpoint curl** via `kubectl port-forward svc/vllm 8000:8000`:
   `curl /v1/completions -d '{"model":"Qwen/Qwen2.5-7B-Instruct-AWQ","prompt":"Hello, my name is","max_tokens":20}'`.
   *Verify:* returns tokens.
7. **Read GPU mem** — `kubectl exec deploy/vllm -- nvidia-smi` (and optionally curl the DCGM
   exporter's `DCGM_FI_DEV_FB_USED` as a bridge to Row 4).
   *Verify:* VRAM-used captured; tune flags + document rationale if OOM.
8. **Cost down** — scale GPU group to 0 (back tomorrow) or `terraform destroy` (done with Row 1).
   *Verify:* `kubectl get nodes` shows no GPU node. Set a $20 AWS Budgets alert as backstop.

## Verification (end-to-end)

The project is verified end-to-end when step 6 returns generated tokens through the
OpenAI-compatible API and step 7 produces the GPU-memory reading + a written justification
of the two flags. `scripts/smoke-test.sh` automates 6; this README captures the evidence
(token output + `nvidia-smi` reading + KV-cache math).

## Approximate cost (us-east-1, on-demand)

Per-component hourly:

| Component | $/hr |
|---|---|
| EKS control plane | 0.10 |
| GPU node `g6.xlarge` (L4) | ~0.805 (fallback `g5.xlarge` ~1.006) |
| System node `m7i.large` | ~0.10 |
| NAT gateway (single) | ~0.045 + ~$0.045/GB data |
| EBS gp3 (100 GB GPU + ~20 GB system) | ~$0.013/hr (~$10/mo) |

Three states that matter:

| State | ~$/hr | What's running |
|---|---|---|
| **Active** (working on it) | **~$1.05/hr** | everything up — this is the only time the GPU bills |
| **Scaled to 0** (GPU group `desired=0`, back tomorrow) | **~$0.25/hr** (~$6/day) | control plane + system node + NAT + EBS; GPU stopped |
| **Destroyed** (`terraform destroy`) | **$0** | nothing |

Practical totals:
- A focused **Row-1 session (5–8h)**: **~$6–9**.
- Leaving it **scaled-to-0 overnight** still costs ~$6/day — not free. For multi-day gaps, **destroy**.
- Leaving **everything running 24/7 for a month**: **~$780** — don't. (GPU alone is ~$588/mo.)

The whole Row-1 exercise, if you destroy between sessions, should land in the **~$15–30** range.

## Cost guardrails
- `min_size=0` → scale GPU node group to zero between sessions (control plane ~$0.10/hr + system
  node + single NAT keep running ≈ $0.25/hr, the ~$0.80/hr GPU stops).
- `terraform destroy` when done for days — the only true $0 state (also kills control plane + NAT).
- Tag everything `project=vllm-serving-eks`; set a **$20 AWS Budgets alert** as a backstop.

## Still open (decide before/at build time)
- **AWS account & local credentials** — assumes `aws sts get-caller-identity` works and the GPU
  vCPU quota request (step 1) is approved. Quota approval can take minutes to 24–48h and gates
  everything.
- **Region** — default `us-east-1`; switch if g6/g5 capacity is short (`InsufficientInstanceCapacity`).
- **g6 vs g5** — plan defaults to g6.xlarge (L4, cheaper); one-variable fallback to g5.xlarge (A10G)
  if capacity/quota differs.
