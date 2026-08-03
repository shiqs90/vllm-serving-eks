# Setup — vLLM on EKS

## Prerequisites

**Local tools:**
- AWS CLI (configured) — `aws sts get-caller-identity`
- Terraform ≥ 1.5 — `terraform version`
- kubectl — `kubectl version --client`
- Helm ≥ 3, and `jq` (pretty-prints the smoke-test JSON)

**AWS account:**
- Permissions to create VPC, EKS, EC2, IAM.
- **GPU vCPU quota** — the #1 blocker on new accounts. Request "Running On-Demand G and VT
  Instances" → **≥ 8 vCPU** *before* starting (approval can take minutes to 24–48h). Check with:
  ```bash
  aws service-quotas get-service-quota \
    --service-code ec2 --quota-code L-DB2E81BA --region us-east-1
  ```
- Region: `us-east-1` (has g6 capacity + quota); switch if you hit `InsufficientInstanceCapacity`.
- Model `Qwen/Qwen2.5-7B-Instruct-AWQ` is ungated on HF — no token needed.

---

## Setup steps

Each step has a verify check — don't move on until it passes.

1. **Confirm the GPU quota is approved.**
   > Verify: Service Quotas shows applied quota **≥ 8**.

2. **Provision with Terraform** (VPC + EKS + system node + GPU node + GPU Operator, one apply):
   ```bash
   cd terraform && terraform init && terraform apply   # ~15–25 min
   ```
   > Verify: apply completes and prints the `configure_kubectl` output.

3. **Point kubectl at the cluster:**
   ```bash
   aws eks update-kubeconfig --name vllm-serving-eks --region us-east-1
   kubectl get nodes
   ```
   > Verify: 1 system + 1 GPU node, both `Ready`.

4. **Confirm the GPU Operator + GPU is advertised:**
   ```bash
   kubectl -n gpu-operator get pods
   kubectl get nodes -o jsonpath='{.items[*].status.allocatable.nvidia\.com/gpu}{"\n"}'
   ```
   > Verify: pods healthy; a node shows `nvidia.com/gpu: "1"`.

5. **Deploy vLLM:**
   ```bash
   kubectl apply -f k8s/vllm-deployment.yaml
   kubectl get pods -l app=vllm -w
   ```
   > Verify: pod schedules on the GPU node (not `Pending`). First boot is slow — pulls a ~11 GB
   > image + downloads weights + captures CUDA graphs (several min); the startup probe allows ~10 min.

6. **Prove tokens + read GPU memory:**
   ```bash
   bash scripts/verify.sh
   ```
   (waits for the pod, port-forwards, POSTs `/v1/completions`, runs `nvidia-smi` in the pod, greps
   the KV-cache log line)
   > Verify: response contains generated `"text"`; `nvidia-smi` shows ~19–20 GB of 24 GB used.

7. **Tear down:** scale the GPU node group to 0 between sessions, or destroy when done for days:
   ```bash
   cd terraform && terraform destroy
   ```
   > Verify: no GPU node / destroy completes ($0). Set a **$20 AWS Budgets alert** as backstop.

---

## Costs (us-east-1, on-demand)

| State | ~$/hr | What's running |
|---|---|---|
| **Active** (working) | **~$1.05** | everything up — the only time the GPU bills |
| **Scaled to 0** (GPU group `desired=0`) | **~$0.25** (~$6/day) | control plane + system node + NAT + EBS |
| **Destroyed** (`terraform destroy`) | **$0** | nothing |

Breakdown at "active": GPU `g6.xlarge` (L4) ~$0.805/hr + EKS control plane $0.10 + system node
`m7i.large` ~$0.10 + single NAT ~$0.045 + EBS ~$0.013. If capacity forces the `g5.xlarge` fallback,
the GPU line rises to ~$1.006/hr (active ≈ ~$1.25/hr).

A focused 5–8h session ≈ **$6–9**; the whole project, destroying between sessions ≈ **$15–30**.
Running 24/7 for a month ≈ **$780** — don't.

**Guardrails:** `min_size=0` scale-to-zero · `terraform destroy` for true $0 · tag
`project=vllm-serving-eks` · $20 AWS Budgets alert.
