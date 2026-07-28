## Production-Grade LLM Serving with vLLM on Amazon EKS
(Terraform + NVIDIA GPU Operator)

One model, one GPU, served over vLLM's OpenAI-compatible API. Every piece of infrastructure
comes from Terraform, so the cluster can be rebuilt or destroyed with one command.

This is the foundation project. 
Multi-model routing (#2) and GPU observability (#4) are built ultilizing the same cluster.

**Done when:** `curl .../v1/completions` returns tokens from a GPU node that Terraform created,
and I can read the GPU's memory usage and defend the `--gpu-memory-utilization` and
`--max-model-len` values I picked.
Those two flags are the KV-cache-vs-OOM tradeoff.

## What's actually being deployed

There is no app and no dataset here. The deliverable is an **inference API**: an HTTP endpointthat takes a prompt and returns generated text. 
Everything below exists to get one model onto one GPU and keep it serving.
This is the AI infra job. Someone else trains the model and someone else builds the product on top.

| Layer | Tool | What it does here |
|---|---|---|
| Provisioning | **Terraform** | Declares the VPC, EKS cluster and GPU node as code. Reproducible, and destroyable in one command. |
| Orchestration | **Kubernetes (EKS)** | Schedules the serving container onto the GPU node, restarts it when it dies, handles networking. This is what makes it a service instead of a script. |
| GPU enablement | **NVIDIA GPU Operator** | Makes Kubernetes aware the GPU exists. Without it, the scheduler sees a plain machine and `nvidia.com/gpu` is never advertised. |
| Serving engine | **vLLM** | Loads the model onto the GPU and serves it. PagedAttention plus continuous batching are what make it fast. Exposes an OpenAI-compatible API. |
| Model | **Qwen2.5-7B-Instruct-AWQ** | The payload. AWQ is 4-bit quantized, so a 7B model fits on a 24 GB card with plenty of room left for KV cache. |
| Package manager | **Helm** | Installs the GPU Operator chart (roughly six components) in one go, via Terraform's `helm_release`. vLLM is *not* Helm here, just `kubectl apply`. |
| Test client | **curl** | Hits `/v1/completions`. That response is the checkpoint. |

**Why self-host instead of calling an API?** Cost at scale, prompts that never leave the VPC,
latency you control, and the ability to run whatever model you want.

## Technologies locked:

- **AWS EKS**, provisioned by Terraform.
- **`Qwen/Qwen2.5-7B-Instruct-AWQ`** as the model. Ungated on Hugging Face, so no token to
  manage, and ~5–6 GB of weights.
- **The AMI ships the driver, not the Operator.** EKS's accelerated AMI
  (`AL2023_x86_64_NVIDIA`) already has the NVIDIA driver, so the GPU Operator runs with
  `driver.enabled=false`. It still owns the device plugin, DCGM exporter and time-slicing
  config, all of which later projects reuse. The alternative (letting the Operator install the
  driver) is officially unsupported on Amazon Linux 2023.
- **Helm for the Operator, raw YAML for vLLM.** A single Deployment doesn't need a chart, and
  editing YAML is faster than re-templating when you're iterating on engine flags.

## Hardware

1× **g6.xlarge** (NVIDIA L4, 24 GB VRAM, ~$0.805/hr, 100 GB gp3 root) for the model, plus
1× **m7i.large** CPU node so that CoreDNS and friends never land on the expensive card.

The L4 was sized from the model. Qwen2.5-7B in 4-bit AWQ is about 5.3 GB of weights, which leaves
roughly 13 GB of the 24 GB for KV cache once context and overhead are paid for.

## Pinned versions

| Component | Pin |
|---|---|
| Terraform | ≥ 1.5 |
| AWS provider | ~> 6.0 |
| terraform-aws-modules/vpc/aws | ~> 6.0 (single NAT) |
| terraform-aws-modules/eks/aws | ~> 21.0 |
| EKS cluster | 1.33 |
| GPU AMI type | `AL2023_x86_64_NVIDIA` |
| GPU instance | `g6.xlarge` (L4 24 GB), fallback `g5.xlarge` (A10G) |
| GPU Operator chart | v26.3.2, `driver.enabled=false`, `toolkit.enabled=false` |
| vLLM image | `vllm/vllm-openai:v0.22.1` (never `:latest`) |
| Model | `Qwen/Qwen2.5-7B-Instruct-AWQ` |

Pinning the vLLM image matters more than it looks. `:latest` changes engine defaults under you,
and then a config that worked yesterday OOMs today.

## Project Layout

```
vllm-serving-eks/
  terraform/
    versions.tf      # provider + module pins
    providers.tf     # aws, kubernetes, helm (helm authenticates through EKS)
    variables.tf     # region, cluster_version, gpu_instance_type
    vpc.tf           # terraform-aws-modules/vpc, single NAT gateway
    eks.tf           # EKS + system and GPU node groups
    gpu-operator.tf  # helm_release nvidia/gpu-operator
    outputs.tf       # cluster name + the update-kubeconfig command
  k8s/
    vllm-deployment.yaml  # Deployment + ClusterIP Service
  scripts/
    smoke-test.sh    # port-forward + curl /v1/completions
```

The GPU Operator lives in Terraform so `terraform destroy` cleans it up with everything else.
vLLM stays as a plain manifest because that's the file I edit most.

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

The taint keeps everything except GPU workloads off the node. `min_size = 0` is what lets me
scale the expensive part to zero between sessions.

### `gpu-operator.tf`

Chart `gpu-operator` v26.3.2 from `https://helm.ngc.nvidia.com/nvidia`, with
`driver.enabled=false` and `toolkit.enabled=false` because the AMI already provides both.

One thing that bites: the Operator's DaemonSets need a toleration for the custom taint
(`nvidia.com/gpu Exists NoSchedule`), or they never land on the GPU node and the node never
advertises a GPU.

Device plugin, GFD, DCGM exporter and NFD stay on. Projects 2 and 4 depend on them.

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
- First boot is slow: a 5–6 GB image pull followed by a model load. The `startupProbe` on
  `/health` uses `failureThreshold: 60, periodSeconds: 10`, giving it ten minutes before
  Kubernetes gives up. Readiness and liveness take over after that. Without a generous startup
  probe you get a restart loop that looks like a crash but is just a slow model load.
- No `HF_TOKEN`, since the model is ungated.
- ClusterIP Service on 8000, reached with `kubectl port-forward`.

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

## Build sequence

Each step has something to check before moving on.

1. **Quota.** Request EC2 "Running On-Demand G and VT Instances" ≥ 8 vCPU.
   *Check:* Service Quotas shows the applied quota. **This is the number one blocker. New
   accounts sit at 0, and approval takes anywhere from minutes to two days.**
2. **`terraform apply`** for VPC, EKS and both node groups.
   *Check:* `aws eks update-kubeconfig …`, then `kubectl get nodes` shows 1 system + 1 GPU node
   `Ready`.
3. **Taint and label** on the GPU node.
   *Check:* `kubectl describe node <gpu-node>` shows the taint and `workload=gpu`.
4. **GPU Operator** settles (it installed itself during step 2).
   *Check:* `kubectl -n gpu-operator get pods` is healthy and the node advertises
   `nvidia.com/gpu: "1"`. If that number never appears, look at DaemonSet tolerations first.
5. **`kubectl apply -f k8s/vllm-deployment.yaml`.**
   *Check:* the pod schedules on the GPU node rather than sitting `Pending`, the logs show the
   KV cache line, and `/health` returns 200.
6. **The checkpoint curl**, through `kubectl port-forward svc/vllm 8000:8000`:
   ```bash
   curl localhost:8000/v1/completions -d '{"model":"Qwen/Qwen2.5-7B-Instruct-AWQ","prompt":"Hello, my name is","max_tokens":20}'
   ```
   *Check:* tokens come back. `scripts/smoke-test.sh` does this for you.
7. **Read the GPU.** `kubectl exec deploy/vllm -- nvidia-smi`, and optionally curl the DCGM
   exporter for `DCGM_FI_DEV_FB_USED` as a preview of project 4.
   *Check:* you have a VRAM number and it lines up with the math above.
8. **Turn it off.** Scale the GPU group to 0 if you're back tomorrow, or `terraform destroy` if
   you're done.
   *Check:* `kubectl get nodes` shows no GPU node.

## Cost

Per component, us-east-1 on-demand:

| Component | $/hr |
|---|---|
| EKS control plane | 0.10 |
| GPU node `g6.xlarge` (L4) | ~0.805 (`g5.xlarge` is ~1.006) |
| System node `m7i.large` | ~0.10 |
| NAT gateway (single) | ~0.045 plus ~$0.045/GB |
| EBS gp3 (100 GB + ~20 GB) | ~$0.013/hr, about $10/mo |

Three states are worth remembering:

| State | ~$/hr | What's running |
|---|---|---|
| **Active** | **~$1.05** | Everything. The only state where the GPU bills. |
| **GPU scaled to 0** | **~$0.25** (~$6/day) | Control plane, system node, NAT, EBS. |
| **Destroyed** | **$0** | Nothing. |

In practice: a focused 5–8 hour session runs **$6–9**. Leaving it scaled to zero overnight is
**not free**, it's about $6/day, so destroy it if you're away for more than a day. Leaving the
whole thing up for a month is roughly **$780**, of which the GPU alone is $588. Destroy between
sessions and the entire project lands somewhere around **$15–30**.

## Guardrails

- `min_size = 0` on the GPU group, so scaling to zero is always available.
- `terraform destroy` is the only true $0 state. It's the one that also kills the control plane
  and NAT gateway.
- Tag everything `project=vllm-serving-eks` and set a **$20 AWS Budgets alert**. The alert is
  the backstop for the night you forget.

## Before you start

- **AWS credentials.** `aws sts get-caller-identity` should work, and the GPU vCPU quota from
  step 1 must be approved. The quota gates everything else.
- **Region.** Default is `us-east-1`. Switch if you hit `InsufficientInstanceCapacity` on g6/g5.
- **g6 vs g5.** g6.xlarge (L4) is the default and the cheaper card. g5.xlarge (A10G) is the
  one-variable fallback if capacity or quota doesn't line up.
