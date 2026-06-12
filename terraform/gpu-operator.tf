resource "helm_release" "gpu_operator" {
  name             = "gpu-operator"
  repository       = "https://helm.ngc.nvidia.com/nvidia"
  chart            = "gpu-operator"
  version          = "v26.3.2"
  namespace        = "gpu-operator"
  create_namespace = true

  # Driver + container toolkit ship in the AL2023_x86_64_NVIDIA AMI, so the Operator only
  # manages the device plugin, DCGM exporter, GFD, NFD, and (later) time-slicing config.
  # NOTE: installing the driver via the Operator (driver.enabled=true) is NOT supported on
  # Amazon Linux 2023 — that path requires Ubuntu/RHEL. Hence driver.enabled=false here.
  set {
    name  = "driver.enabled"
    value = "false"
  }
  set {
    name  = "toolkit.enabled"
    value = "false"
  }

  # Tolerate the custom GPU taint so the Operator's DaemonSets land on the GPU node.
  set {
    name  = "daemonsets.tolerations[0].key"
    value = "nvidia.com/gpu"
  }
  set {
    name  = "daemonsets.tolerations[0].operator"
    value = "Exists"
  }
  set {
    name  = "daemonsets.tolerations[0].effect"
    value = "NoSchedule"
  }

  depends_on = [module.eks]
}
