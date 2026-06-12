#!/usr/bin/env bash
set -euo pipefail

# Checkpoint for Row 1: prove the vLLM OpenAI-compatible API returns tokens, then read GPU memory.
# Assumes kubectl is pointed at the cluster (aws eks update-kubeconfig ...) and the manifest is applied.

MODEL="Qwen/Qwen2.5-7B-Instruct-AWQ"
LOCAL_PORT=8000

echo "==> Waiting for the vLLM deployment to become available"
echo "    (first boot pulls ~11GB image + downloads weights — can take several minutes)..."
kubectl wait --for=condition=available --timeout=900s deployment/vllm

echo "==> Port-forwarding svc/vllm ${LOCAL_PORT}:8000"
kubectl port-forward svc/vllm "${LOCAL_PORT}:8000" >/dev/null 2>&1 &
PF_PID=$!
trap 'kill ${PF_PID} 2>/dev/null || true' EXIT
sleep 5

echo "==> POST /v1/completions"
curl -sS "http://localhost:${LOCAL_PORT}/v1/completions" \
  -H 'Content-Type: application/json' \
  -d "{\"model\":\"${MODEL}\",\"prompt\":\"Hello, my name is\",\"max_tokens\":32,\"temperature\":0}" | jq .

echo
echo "==> GPU memory (nvidia-smi inside the pod):"
kubectl exec deploy/vllm -- nvidia-smi
