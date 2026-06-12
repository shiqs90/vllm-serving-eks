provider "aws" {
  region = var.region

  default_tags {
    tags = {
      project = "vllm-serving-eks"
    }
  }
}

# Both kubernetes and helm providers authenticate to the cluster with a short-lived
# token fetched via `aws eks get-token` (exec auth), so credentials never go stale
# mid-apply. The cluster must exist first — helm_release depends_on module.eks.
provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.region]
  }
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.region]
    }
  }
}
