module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  name               = var.cluster_name
  kubernetes_version = var.cluster_version

  endpoint_public_access = true

  # v21 manages access via EKS access entries (no more aws-auth configmap). This grants
  # the identity running `terraform apply` cluster-admin — without it you can't kubectl.
  enable_cluster_creator_admin_permissions = true

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  # Core EKS addons. The v21 module does NOT install these by default — without the VPC CNI
  # nodes get no pod networking and stay NotReady (this is what failed the first apply).
  # vpc-cni uses before_compute so the CNI is registered before the node groups are created.
  addons = {
    vpc-cni = {
      before_compute = true
      most_recent    = true
    }
    kube-proxy = {
      most_recent = true
    }
    coredns = {
      most_recent = true
    }
  }

  eks_managed_node_groups = {
    # Small CPU node so system pods (CoreDNS, metrics, GPU Operator controller) don't
    # have to land on the expensive GPU node (which is also tainted).
    system = {
      ami_type       = "AL2023_x86_64_STANDARD"
      instance_types = [var.system_instance_type]
      min_size       = 1
      max_size       = 2
      desired_size   = 1

      # Default 20GB root caused an ephemeral-storage eviction (router image alone is 5.3GB);
      # Project 4 adds Prometheus + Grafana to this node, so give it real headroom.
      block_device_mappings = {
        xvda = {
          device_name = "/dev/xvda"
          ebs = {
            volume_size = 50
            volume_type = "gp3"
          }
        }
      }
    }

    # GPU node. AL2023_x86_64_NVIDIA is the EKS accelerated AMI — driver + container
    # toolkit are baked in, so the GPU Operator runs with driver.enabled=false.
    gpu = {
      ami_type       = "AL2023_x86_64_NVIDIA"
      instance_types = [var.gpu_instance_type]
      min_size       = 0 # allows scale-to-zero between sessions for cost
      max_size       = 2
      desired_size   = 2 # Row 2: one GPU per model behind the router (was 1 in Row 1)

      # Default 20GB root is too small for the NVIDIA AMI + ~11GB vLLM image + HF cache.
      block_device_mappings = {
        xvda = {
          device_name = "/dev/xvda"
          ebs = {
            volume_size = 100
            volume_type = "gp3"
          }
        }
      }

      labels = {
        workload = "gpu"
      }

      taints = {
        gpu = {
          key    = "nvidia.com/gpu"
          value  = "present"
          effect = "NO_SCHEDULE"
        }
      }
    }
  }
}
