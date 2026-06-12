variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
  default     = "vllm-serving-eks"
}

variable "cluster_version" {
  description = "EKS Kubernetes version"
  type        = string
  default     = "1.33"
}

variable "gpu_instance_type" {
  description = "GPU node instance type. g6.xlarge = L4 24GB (cheaper); fallback g5.xlarge = A10G 24GB."
  type        = string
  default     = "g6.xlarge"
}

variable "system_instance_type" {
  description = "Non-GPU system node instance type (runs CoreDNS, GPU Operator controller, etc.)"
  type        = string
  default     = "m7i.large"
}
