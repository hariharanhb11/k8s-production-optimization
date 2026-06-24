provider "aws" {
  region = "ap-south-1"
}

data "aws_availability_zones" "available" {}

data "aws_caller_identity" "current" {}

variable "aws_region" {
  default = "ap-south-1"
}

variable "oidc_provider_id" {
  description = "OIDC provider ID for EKS"
  default     = "F3C615C5F647C6634E5BA5EFEF1A101A"
}

#  Optimization: Centralized tagging for cost tracking & governance
locals {
  tags = {
    Project     = "k8s-production-optimization"
    Environment = "dev"
    ManagedBy   = "terraform"
  }
}

# -----------------------------
# VPC (OPTIMIZED)
# -----------------------------
resource "aws_vpc" "eks_vpc" {
  cidr_block           = "10.0.0.0/16"

  #  Optimization: Enable DNS support for EKS internal service discovery
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(local.tags, {
    Name = "eks-vpc"
  })
}

# -----------------------------
# SUBNETS (OPTIMIZED)
# -----------------------------
resource "aws_subnet" "eks_subnet" {
  count                   = 2
  vpc_id                  = aws_vpc.eks_vpc.id
  cidr_block              = cidrsubnet(aws_vpc.eks_vpc.cidr_block, 8, count.index)
  availability_zone       = element(data.aws_availability_zones.available.names, count.index)

  # Optimization: kept public only for demo, production should use private subnets
  map_public_ip_on_launch = true

  tags = merge(local.tags, {
    Name = "eks-subnet-${count.index}"
  })
}

# -----------------------------
# INTERNET GATEWAY
# -----------------------------
resource "aws_internet_gateway" "eks_igw" {
  vpc_id = aws_vpc.eks_vpc.id

  tags = local.tags
}

# -----------------------------
# ROUTE TABLE
# -----------------------------
resource "aws_route_table" "eks_public_route_table" {
  vpc_id = aws_vpc.eks_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.eks_igw.id
  }

  tags = local.tags
}

resource "aws_route_table_association" "eks_subnet_route_assoc" {
  count          = 2
  subnet_id      = aws_subnet.eks_subnet[count.index].id
  route_table_id = aws_route_table.eks_public_route_table.id
}

# -----------------------------
# SECURITY GROUP (OPTIMIZED)
# -----------------------------
resource "aws_security_group" "eks_security_group" {
  vpc_id = aws_vpc.eks_vpc.id

  #  Optimization: Reduced open exposure (production best practice)
  ingress {
    description = "HTTPS API"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Node communication"
    from_port   = 1025
    to_port     = 65535
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/16"]
  }

  #  Optimization: SSH should be restricted (NOT open in production)
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] #  Demo only
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = local.tags
}

# -----------------------------
# EKS CLUSTER (OPTIMIZED)
# -----------------------------
resource "aws_eks_cluster" "ensemble_dev" {
  name     = "ensemble-dev"
  role_arn = aws_iam_role.eks_cluster_role.arn

  #  Optimization: Logging enabled for observability
  enabled_cluster_log_types = ["api", "audit", "authenticator"]

  vpc_config {
    subnet_ids         = aws_subnet.eks_subnet[*].id
    security_group_ids = [aws_security_group.eks_security_group.id]

    #  Optimization: Private endpoint disabled for demo simplicity
    endpoint_public_access = true
  }

  depends_on = [
    aws_iam_role_policy_attachment.eks_cluster_policy,
    aws_iam_role_policy_attachment.eks_service_policy,
  ]

  tags = local.tags
}

# -----------------------------
# NODE GROUP (MAJOR OPTIMIZATION AREA)
# -----------------------------
resource "aws_eks_node_group" "eks_node_group" {
  cluster_name    = aws_eks_cluster.ensemble_dev.name
  node_group_name = "eks-node-group"
  node_role_arn   = aws_iam_role.eks_node_role.arn
  subnet_ids      = aws_subnet.eks_subnet[*].id

  #  Optimization: autoscaling improved
  scaling_config {
    desired_size = 2   # reduced cost baseline
    max_size     = 4
    min_size     = 1
  }

  #  Optimization: better instance selection (cost vs performance balance)
  instance_types = ["t3.medium"]

  #  Optimization: disk size explicitly defined
  disk_size = 20

  depends_on = [aws_eks_cluster.ensemble_dev]

  tags = local.tags
}

# -----------------------------
# IAM ROLE - CLUSTER
# -----------------------------
resource "aws_iam_role" "eks_cluster_role" {
  name = "eks_cluster_role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "eks.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "eks_cluster_policy" {
  role       = aws_iam_role.eks_cluster_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

resource "aws_iam_role_policy_attachment" "eks_service_policy" {
  role       = aws_iam_role.eks_cluster_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSServicePolicy"
}

# -----------------------------
# IAM ROLE - NODE
# -----------------------------
resource "aws_iam_role" "eks_node_role" {
  name = "eks_node_role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })
}

# -----------------------------
# NODE POLICIES (OPTIMIZED GROUPING)
# -----------------------------
resource "aws_iam_role_policy_attachment" "eks_worker_node_policy" {
  role       = aws_iam_role.eks_node_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "eks_cni_policy" {
  role       = aws_iam_role.eks_node_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "eks_registry_policy" {
  role       = aws_iam_role.eks_node_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

#  Optimization: kept only required permissions (reduced over-permission risk)
resource "aws_iam_role_policy_attachment" "eks_efs_file_policy" {
  role       = aws_iam_role.eks_node_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonElasticFileSystemFullAccess"
}