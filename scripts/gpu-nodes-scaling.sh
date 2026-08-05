#!/usr/bin/env bash
# Scale the GPU node group in / out. Use this to stop the GPU bill between sessions, or to
# free the GPU while debugging a stuck pod.
#
# WHY A SCRIPT AND NOT TERRAFORM: the EKS module sets
#   ignore_changes = [scaling_config[0].desired_size]
# on the node group, so editing desired_size in eks.tf is a silent no-op on a live cluster.
# Editing max_size alone fails the other way — UpdateNodegroupConfig validates the whole
# config and rejects desired > max ("desired capacity 2 can't be greater than max size 1").
# The fix is to move all bounds in ONE call, which is what this script does.
#
# Usage:
#   scripts/gpu-nodes-scaling.sh status   # what AWS currently thinks
#   scripts/gpu-nodes-scaling.sh in       # desired -> 0  (pause: ~$1.05/hr -> ~$0.25/hr)
#   scripts/gpu-nodes-scaling.sh out      # desired -> 1
#   scripts/gpu-nodes-scaling.sh out 2    # desired -> 2  (P2 multi-model: one GPU per model)
set -uo pipefail

CLUSTER="${CLUSTER:-vllm-serving-eks}"
REGION="${REGION:-us-east-1}"
ACTION="${1:-status}"
COUNT="${2:-1}"

run() { echo "\$ $*"; "$@"; }

# Node group name is generated (name_prefix), so look it up instead of hardcoding it.
echo "==> Finding the GPU node group in cluster '${CLUSTER}'"
echo "\$ aws eks list-nodegroups --cluster-name ${CLUSTER} --region ${REGION} --query 'nodegroups[?starts_with(@,\`gpu\`)]|[0]'"
NG=$(aws eks list-nodegroups --cluster-name "$CLUSTER" --region "$REGION" \
       --query 'nodegroups[?starts_with(@,`gpu`)]|[0]' --output text)
[ -n "$NG" ] && [ "$NG" != "None" ] || { echo "FAIL: no 'gpu*' node group found in ${CLUSTER}."; exit 1; }
echo "    ${NG}"

show() {
  echo; echo "==> Current state"
  run aws eks describe-nodegroup --cluster-name "$CLUSTER" --nodegroup-name "$NG" --region "$REGION" \
    --query 'nodegroup.{status:status,scaling:scalingConfig}'
  run kubectl get nodes -l workload=gpu
}

case "$ACTION" in
  status) show ;;

  in|out)
    [ "$ACTION" = "in" ] && DESIRED=0 || DESIRED="$COUNT"
    # max must be >= desired in the same call. min stays 0 to match eks.tf.
    MAX=$(( DESIRED > 1 ? DESIRED : 1 ))
    echo; echo "==> Scaling to desiredSize=${DESIRED} (maxSize=${MAX})"
    run aws eks update-nodegroup-config --cluster-name "$CLUSTER" --nodegroup-name "$NG" --region "$REGION" \
      --scaling-config "minSize=0,maxSize=${MAX},desiredSize=${DESIRED}" || exit 1

    # Async: EKS cordons + drains on scale-in, provisions on scale-out. Poll to ACTIVE.
    echo; echo "==> Waiting for the node group to return to ACTIVE (up to 10 min)..."
    for i in $(seq 1 60); do
      STATUS=$(aws eks describe-nodegroup --cluster-name "$CLUSTER" --nodegroup-name "$NG" --region "$REGION" \
                 --query 'nodegroup.status' --output text)
      echo "    [${i}] status=${STATUS}"
      [ "$STATUS" = "ACTIVE" ] && break
      sleep 10
      [ "$i" = "60" ] && { echo "FAIL: still ${STATUS} after 10 min. Check the AWS console."; exit 1; }
    done
    show

    if [ "$DESIRED" -gt 0 ]; then
      echo; echo "NOTE: the node is up, but the vllm pod still has to pull the ~11GB image and"
      echo "      re-download the weights (no PVC yet) — budget ~5-8 min to first token."
      echo "      Watch it with: bash scripts/verify.sh"
    fi

    echo; echo "REMINDER: keep eks.tf's max_size matching (${MAX}) so 'terraform plan' stays clean."
    ;;

  *) echo "Usage: $0 {status|in|out [count]}"; exit 1 ;;
esac
