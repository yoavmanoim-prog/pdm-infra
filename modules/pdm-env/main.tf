data "aws_availability_zones" "available" {}

# ==========================================
# VPC
# ==========================================

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "${var.cluster_name}-vpc"
  cidr = var.vpc_cidr

  azs             = slice(data.aws_availability_zones.available.names, 0, 3)
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]

  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true

  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
  }
}

# ==========================================
# EKS
# ==========================================

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = var.cluster_name
  cluster_version = var.cluster_version

  cluster_endpoint_public_access           = true
  enable_cluster_creator_admin_permissions = true
  enable_irsa                              = true

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  eks_managed_node_groups = {
    default = {
      instance_types = ["t3.small"]
      min_size       = 3
      max_size       = 5
      desired_size   = 3
    }
  }
}

# ==========================================
# Node Auto Scaling (CloudWatch + ASG)
# ==========================================

data "aws_autoscaling_groups" "eks_nodes" {
  filter {
    name   = "tag:eks:cluster-name"
    values = [var.cluster_name]
  }

  depends_on = [module.eks]
}

resource "aws_autoscaling_policy" "scale_out" {
  name                   = "${var.cluster_name}-scale-out"
  autoscaling_group_name = data.aws_autoscaling_groups.eks_nodes.names[0]
  policy_type            = "SimpleScaling"
  adjustment_type        = "ChangeInCapacity"
  scaling_adjustment     = 1
  cooldown               = 300
}

resource "aws_autoscaling_policy" "scale_in" {
  name                   = "${var.cluster_name}-scale-in"
  autoscaling_group_name = data.aws_autoscaling_groups.eks_nodes.names[0]
  policy_type            = "SimpleScaling"
  adjustment_type        = "ChangeInCapacity"
  scaling_adjustment     = -1
  cooldown               = 300
}

resource "aws_cloudwatch_metric_alarm" "scale_out" {
  alarm_name          = "${var.cluster_name}-nodes-scale-out"
  alarm_description   = "Add a node when average CPU exceeds 70%"
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  statistic           = "Average"
  period              = 60
  evaluation_periods  = 2
  threshold           = 70
  comparison_operator = "GreaterThanThreshold"

  dimensions = {
    AutoScalingGroupName = data.aws_autoscaling_groups.eks_nodes.names[0]
  }

  alarm_actions = [aws_autoscaling_policy.scale_out.arn]
}

resource "aws_cloudwatch_metric_alarm" "scale_in" {
  alarm_name          = "${var.cluster_name}-nodes-scale-in"
  alarm_description   = "Remove a node when average CPU drops below 30% for 20 minutes"
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  statistic           = "Average"
  period              = 60
  evaluation_periods  = 20
  threshold           = 30
  comparison_operator = "LessThanThreshold"

  dimensions = {
    AutoScalingGroupName = data.aws_autoscaling_groups.eks_nodes.names[0]
  }

  alarm_actions = [aws_autoscaling_policy.scale_in.arn]
}

# ==========================================
# ECR
# ==========================================

resource "aws_ecr_repository" "pdm_backend" {
  name                 = "pdm-backend"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }
}

# ==========================================
# Helm: ingress-nginx
# ==========================================

resource "helm_release" "ingress_nginx" {
  name             = "ingress-nginx"
  repository       = "https://kubernetes.github.io/ingress-nginx"
  chart            = "ingress-nginx"
  namespace        = "ingress-nginx"
  create_namespace = true
  timeout          = 600

  values = [file("${path.module}/helm-values/ingress-nginx.yaml")]

  depends_on = [module.eks]
}

# ==========================================
# Helm: ArgoCD
# ==========================================

resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  namespace        = "argocd"
  create_namespace = true

  values = [file("${path.module}/helm-values/argocd.yaml")]

  depends_on = [module.eks]
}

# Prometheus stack removed from Terraform — deploy manually in Step 7
# helm install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
#   -n monitoring --create-namespace --set grafana.adminPassword=prom-operator

# ==========================================
# RDS — Managed PostgreSQL
# ==========================================

# Security group — controls who can connect to the RDS instance
# Only allows traffic from inside the VPC (the EKS nodes)
resource "aws_security_group" "rds" {
  name        = "${var.cluster_name}-rds"
  description = "Allow postgres access from EKS nodes"
  vpc_id      = module.vpc.vpc_id

  ingress {
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = [module.vpc.vpc_cidr_block] # only allow connections from within the VPC
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Subnet group — tells RDS which subnets it can use (must span multiple AZs)
resource "aws_db_subnet_group" "pdm" {
  name       = "${var.cluster_name}-rds"
  subnet_ids = module.vpc.private_subnets
}

# The RDS instance itself
resource "aws_db_instance" "pdm" {
  identifier        = "${var.cluster_name}-postgres"
  engine            = "postgres"
  engine_version    = "16"
  instance_class    = "db.t3.micro" # smallest instance — good enough for this project
  allocated_storage = 20            # 20GB disk

  db_name  = "pdm"
  username = "pdm"
  password = var.db_password # passed in via tfvars — never hardcoded

  db_subnet_group_name   = aws_db_subnet_group.pdm.name
  vpc_security_group_ids = [aws_security_group.rds.id]

  skip_final_snapshot = true  # allows destroy without a final backup (fine for dev)
  publicly_accessible = false # not accessible from the internet — only from within the VPC

  tags = {
    Environment = var.environment
  }
}

# ==========================================
# S3 — PDF storage
# ==========================================

resource "aws_s3_bucket" "pdm_docs" {
  bucket = "pdm-docs-${var.environment}"
}

resource "aws_s3_bucket_versioning" "pdm_docs" {
  bucket = aws_s3_bucket.pdm_docs.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "pdm_docs" {
  bucket = aws_s3_bucket.pdm_docs.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "pdm_docs" {
  bucket                  = aws_s3_bucket.pdm_docs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ==========================================
# IRSA — backend pod S3 access
# ==========================================

resource "aws_iam_role" "pdm_backend" {
  name = "pdm-backend-${var.environment}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = module.eks.oidc_provider_arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${module.eks.cluster_oidc_issuer_url}:sub" = "system:serviceaccount:pdm-production:pdm-backend"
          "${module.eks.cluster_oidc_issuer_url}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "pdm_backend_s3" {
  name = "pdm-backend-s3"
  role = aws_iam_role.pdm_backend.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "s3:PutObject",
        "s3:GetObject",
        "s3:DeleteObject",
        "s3:ListBucket"
      ]
      Resource = [
        aws_s3_bucket.pdm_docs.arn,
        "${aws_s3_bucket.pdm_docs.arn}/*"
      ]
    }]
  })
}
