# Architecture Diagram — vLLM Serving on EKS

```mermaid
graph TB
    subgraph dev["Developer / Local Machine"]
        CLI["kubectl / curl"]
        TF["Terraform CLI\n(HCP Cloud remote state)"]
    end

    subgraph hcp["Terraform Cloud (HCP)"]
        STATE["Remote State\nShikha_Projects /\nai-infra-projects-2026"]
    end

    subgraph aws["AWS — us-east-1"]

        subgraph vpc["VPC  10.0.0.0/16"]

            subgraph pub["Public Subnets\n10.0.101.0/24  ·  10.0.102.0/24"]
                NAT["NAT Gateway\n(single, cost-optimised)"]
                IGW["Internet Gateway"]
            end

            subgraph priv["Private Subnets\n10.0.1.0/24  ·  10.0.2.0/24"]

                subgraph eks["EKS Cluster — vllm-serving-eks  (k8s 1.33)"]

                    subgraph addons["EKS Managed Addons"]
                        VPCCNI["vpc-cni\n(before_compute=true)"]
                        PROXY["kube-proxy"]
                        DNS["coredns"]
                    end

                    subgraph system_ng["System Node Group  ·  m7i.large\n50 GB gp3  ·  desired 1"]
                        CORENS["CoreDNS Pod"]
                        GPUCTL["GPU Operator\nController Pod"]
                        METRICS["Metrics / NFD Pod"]
                    end

                    subgraph gpu_ng["GPU Node Group  ·  g6.xlarge  (NVIDIA L4 24 GB)\n100 GB gp3  ·  min 0 / max 2 / desired 2\nTaint: nvidia.com/gpu=present:NoSchedule\nLabel: workload=gpu"]

                        subgraph gpuop_ns["Namespace: gpu-operator\n(Helm chart v26.3.2  ·  driver.enabled=false)"]
                            DP["Device Plugin\nDaemonSet"]
                            DCGM["DCGM Exporter\nDaemonSet"]
                            GFD["GPU Feature\nDiscovery DaemonSet"]
                        end

                        subgraph default_ns["Namespace: default"]
                            SVC["Service: vllm\n(ClusterIP :8000)"]
                            POD["vLLM Pod\nvllm/vllm-openai:v0.22.1\n──────────────────\nQwen2.5-7B-Instruct-AWQ\nquantization: awq_marlin\ndtype: float16\ngpu-memory-utilization: 0.90\nmax-model-len: 8192\nmax-num-seqs: 16\nresources: 1× nvidia.com/gpu\n──────────────────\nstartupProbe /health  (10 min)\nreadinessProbe /health\nlivenessProbe /health"]
                        end

                        GPU["NVIDIA L4 GPU\n24 GB VRAM\n~5.3 GB weights\n~13 GB KV cache"]
                    end

                end
            end
        end

        HF[("HuggingFace Hub\nQwen2.5-7B-AWQ\n~5.3 GB weights\n(downloaded on first boot)")]
        AMI["AL2023_x86_64_NVIDIA AMI\n(NVIDIA driver + toolkit baked in)"]
    end

    subgraph budget["AWS Budgets"]
        ALERT["$20 alert\ntag: project=vllm-serving-eks"]
    end

    %% Provisioning flow
    TF -->|"terraform apply"| STATE
    TF -->|"1. vpc.tf"| vpc
    TF -->|"2. eks.tf"| eks
    TF -->|"3. gpu-operator.tf\n(helm_release depends_on eks)"| gpuop_ns

    %% Network flow
    IGW <--> NAT
    NAT -->|outbound| priv

    %% GPU node bootstraps from AMI
    AMI -.->|"baked-in driver\n& toolkit"| gpu_ng

    %% GPU Operator enables GPU in k8s
    DP -->|"advertises nvidia.com/gpu: 1"| gpu_ng
    DCGM -->|"VRAM metrics"| GPU
    GFD -->|"node feature labels"| gpu_ng

    %% Scheduling
    POD -->|"nodeSelector: workload=gpu\ntoleration: nvidia.com/gpu"| gpu_ng
    POD -->|"limits: nvidia.com/gpu: 1"| GPU

    %% Model weights
    POD -->|"download weights\non first boot"| HF
    HF -.->|"~5.3 GB\nQwen2.5-7B-AWQ"| GPU

    %% Service → Pod
    SVC --> POD

    %% Developer access
    CLI -->|"kubectl port-forward\nsvc/vllm 8000:8000"| SVC
    CLI -->|"curl /v1/completions"| SVC

    %% Cost tagging
    aws -.->|"tag: project=vllm-serving-eks"| ALERT

    %% Styling
    classDef aws_svc fill:#FF9900,color:#000,stroke:#c47700
    classDef k8s fill:#326CE5,color:#fff,stroke:#1a56c4
    classDef nvidia fill:#76B900,color:#000,stroke:#4d7a00
    classDef cost fill:#e8f4e8,color:#333,stroke:#4CAF50
    classDef tf fill:#7B42BC,color:#fff,stroke:#5a2f8a

    class NAT,IGW,HF,AMI aws_svc
    class SVC,POD,CORENS,GPUCTL,METRICS,VPCCNI,PROXY,DNS k8s
    class DP,DCGM,GFD,GPU nvidia
    class ALERT,budget cost
    class TF,STATE tf
```

---

## Component Summary

| Layer | Component | Detail |
|---|---|---|
| **Provisioning** | Terraform + HCP Cloud | Declares all infra as code; remote state in Terraform Cloud |
| **Network** | VPC `10.0.0.0/16` | 2 private subnets (nodes) + 2 public subnets; single NAT gateway |
| **Orchestration** | EKS 1.33 | Managed control plane; nodes in private subnets only |
| **EKS Addons** | vpc-cni / kube-proxy / coredns | Explicitly declared (v21 module doesn't install these by default) |
| **System Node** | `m7i.large` — desired 1 | Runs CoreDNS, GPU Operator controller, metrics; keeps them off the GPU node |
| **GPU Node** | `g6.xlarge` (NVIDIA L4 24 GB) — min 0 / max 2 | Tainted `nvidia.com/gpu=present:NoSchedule`; scale-to-zero for cost control |
| **GPU Operator** | Helm chart v26.3.2 | Device plugin + DCGM exporter + GFD; driver/toolkit disabled (baked into AMI) |
| **Serving Engine** | vLLM `v0.22.1` | OpenAI-compatible API on `:8000`; PagedAttention + continuous batching |
| **Model** | `Qwen2.5-7B-Instruct-AWQ` | 4-bit AWQ → ~5.3 GB weights, ~13 GB KV cache on L4 |
| **Access** | ClusterIP Service + `kubectl port-forward` | No public load balancer; developer access only |

## Cost States

| State | ~$/hr | Running |
|---|---|---|
| **Active** | ~$1.05 | Everything |
| **GPU scaled to 0** | ~$0.25 | Control plane + system node + NAT + EBS |
| **Destroyed** | $0 | Nothing |
```
