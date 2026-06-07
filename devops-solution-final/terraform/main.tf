terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.23"
    }
  }

  # Remote state — S3 + DynamoDB lock
  backend "s3" {
    bucket         = "mern-terraform-state"       # Değiştirin
    key            = "mern-app/terraform.tfstate"
    region         = "eu-central-1"
    encrypt        = true
    dynamodb_table = "mern-terraform-locks"
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "mern-devops-case"
      Environment = var.environment
      ManagedBy   = "Terraform"
    }
  }
}

# ─── VPC ──────────────────────────────────────────────────────────────────────
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "${var.project_name}-vpc"
  cidr = "10.0.0.0/16"

  azs             = ["${var.aws_region}a", "${var.aws_region}b", "${var.aws_region}c"]
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]

  enable_nat_gateway     = true
  single_nat_gateway     = var.environment == "production" ? false : true
  enable_dns_hostnames   = true
  enable_dns_support     = true

  # EKS için gerekli subnet tag'leri
  public_subnet_tags = {
    "kubernetes.io/role/elb" = "1"
  }
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = "1"
  }
}

# ─── ECR Repositories ────────────────────────────────────────────────────────
resource "aws_ecr_repository" "mern_server" {
  name                 = "mern-server"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true  # Güvenlik taraması
  }

  lifecycle {
    prevent_destroy = false
  }
}

resource "aws_ecr_repository" "mern_client" {
  name                 = "mern-client"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_repository" "python_etl" {
  name                 = "python-etl"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }
}

# ECR lifecycle policy — eski image'ları temizle (maliyet optimizasyonu)
resource "aws_ecr_lifecycle_policy" "cleanup_policy" {
  for_each   = toset(["mern-server", "mern-client", "python-etl"])
  repository = each.value

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep last 10 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 10
      }
      action = { type = "expire" }
    }]
  })

  depends_on = [
    aws_ecr_repository.mern_server,
    aws_ecr_repository.mern_client,
    aws_ecr_repository.python_etl
  ]
}

# ─── EKS Cluster ─────────────────────────────────────────────────────────────
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 19.0"

  cluster_name    = "${var.project_name}-eks-cluster"
  cluster_version = "1.28"

  vpc_id                         = module.vpc.vpc_id
  subnet_ids                     = module.vpc.private_subnets
  cluster_endpoint_public_access = true

  # EKS Managed Node Group
  eks_managed_node_groups = {
    general = {
      desired_size = 2
      min_size     = 1
      max_size     = 4

      instance_types = ["t3.medium"]
      capacity_type  = "ON_DEMAND"

      labels = {
        Environment = var.environment
        NodeGroup   = "general"
      }

      tags = {
        "k8s.io/cluster-autoscaler/enabled"                              = "true"
        "k8s.io/cluster-autoscaler/${var.project_name}-eks-cluster"      = "owned"
      }
    }
  }

  # AWS Load Balancer Controller için IRSA
  enable_irsa = true

  tags = {
    Cluster = "${var.project_name}-eks-cluster"
  }
}

# ─── CloudWatch Log Group (EKS logs) ─────────────────────────────────────────
resource "aws_cloudwatch_log_group" "eks_logs" {
  name              = "/aws/eks/${var.project_name}-eks-cluster/cluster"
  retention_in_days = 30
}

# ─── Outputs ─────────────────────────────────────────────────────────────────
output "ecr_server_url" {
  value       = aws_ecr_repository.mern_server.repository_url
  description = "ECR URL for MERN server"
}

output "ecr_client_url" {
  value       = aws_ecr_repository.mern_client.repository_url
  description = "ECR URL for MERN client"
}

output "ecr_etl_url" {
  value       = aws_ecr_repository.python_etl.repository_url
  description = "ECR URL for Python ETL"
}

output "eks_cluster_name" {
  value       = module.eks.cluster_name
  description = "EKS cluster name"
}

output "eks_cluster_endpoint" {
  value       = module.eks.cluster_endpoint
  description = "EKS cluster API endpoint"
  sensitive   = true
}
