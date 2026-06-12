terraform {
  required_version = "~> 1.15"

  cloud {
    organization = "Shikha_Projects"

    workspaces {
      name = "ai-infra-projects-2026"
    }
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.35"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.17"
    }
  }
}
