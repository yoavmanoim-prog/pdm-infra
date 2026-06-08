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
      instance_types = ["t3.medium"]
      min_size       = 1
      max_size       = 3
      desired_size   = 2
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

# Frontend ECR — CI (ci-backend.yml) pushes pdm-frontend images here
resource "aws_ecr_repository" "pdm_frontend" {
  name                 = "pdm-frontend"
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

# ==========================================
# Helm: kube-prometheus-stack
# Installs Prometheus, Grafana, and Alertmanager in one chart.
# Overrides in helm-values/kube-prometheus-stack.yaml configure:
#   - Alertmanager Slack receiver
#   - ServiceMonitor discovery for pdm-backend
#   - Grafana admin password (set via variable so it is never hardcoded)
# ==========================================

# Read secrets from AWS Secrets Manager — Terraform accesses these using
# the OIDC role assumed by CI, so no credentials are ever stored in code.
# Before running terraform apply, create these two secrets in AWS:
#   pdm/grafana/admin-password
#   pdm/alertmanager/slack-webhook-url
data "aws_secretsmanager_secret_version" "grafana_password" {
  secret_id = "pdm/grafana/admin-password"
}

data "aws_secretsmanager_secret_version" "slack_webhook_url" {
  secret_id = "pdm/alertmanager/slack-webhook-url"
}

resource "helm_release" "prometheus_stack" {
  name             = "kube-prometheus-stack"
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "kube-prometheus-stack"
  namespace        = "monitoring"
  create_namespace = true
  version          = "61.3.2" # pin so terraform plan is deterministic

  values = [
    templatefile("${path.module}/helm-values/kube-prometheus-stack.yaml", {
      # values injected from Secrets Manager — never written to disk
      slack_webhook_url = data.aws_secretsmanager_secret_version.slack_webhook_url.secret_string
      grafana_password  = data.aws_secretsmanager_secret_version.grafana_password.secret_string
    })
  ]

  depends_on = [module.eks]
}

# ==========================================
# Helm: ELK stack — centralised logging
#
# Three components, each its own helm_release:
#   Elasticsearch — stores and indexes every log line shipped to it
#   Kibana        — web UI for searching and filtering logs
#   Fluent Bit    — DaemonSet that runs on every node, reads pod logs
#                   from /var/log/containers and forwards them to ES
# ==========================================

resource "helm_release" "elasticsearch" {
  name             = "elasticsearch"
  repository       = "https://helm.elastic.co"
  chart            = "elasticsearch"
  namespace        = "logging"
  create_namespace = true
  version          = "8.5.1"
  timeout          = 900 # ES 8.x is slow to start — default 300s is not enough

  values = [<<-YAML
    replicas: 1
    minimumMasterNodes: 1
    # disable xpack security — not needed for this project
    esConfig:
      elasticsearch.yml: |
        xpack.security.enabled: false
        xpack.security.http.ssl.enabled: false
    # no persistent volume — logs live in pod memory only
    # avoids EBS AZ scheduling conflicts on a small cluster
    persistence:
      enabled: false
    resources:
      requests:
        memory: "512Mi"
      limits:
        memory: "1Gi"
  YAML
  ]

  depends_on = [module.eks]
}

resource "helm_release" "kibana" {
  name       = "kibana"
  repository = "https://helm.elastic.co"
  chart      = "kibana"
  namespace  = "logging"
  version    = "8.5.1"

  values = [<<-YAML
    elasticsearchHosts: "http://elasticsearch-master:9200"
  YAML
  ]

  depends_on = [helm_release.elasticsearch]
}

resource "helm_release" "fluent_bit" {
  name       = "fluent-bit"
  repository = "https://fluent.github.io/helm-charts"
  chart      = "fluent-bit"
  namespace  = "logging"
  version    = "0.46.7"

  values = [file("${path.module}/helm-values/fluent-bit.yaml")]

  depends_on = [helm_release.elasticsearch]
}

# ==========================================
# RDS — Managed PostgreSQL
# ==========================================

# Security group — controls who can connect to the RDS instance
# Allows traffic only from the EKS node security group, not the whole VPC
resource "aws_security_group" "rds" {
  name        = "${lower(var.cluster_name)}-rds" # lowercase because RDS doesn't allow uppercase
  description = "Allow postgres access from EKS nodes"
  vpc_id      = module.vpc.vpc_id

  ingress {
    from_port = 5432
    to_port   = 5432
    protocol  = "tcp"
    # reference the EKS node security group directly — only cluster nodes can reach RDS
    security_groups = [module.eks.node_security_group_id]
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
  name       = "${lower(var.cluster_name)}-rds" # lowercase required
  subnet_ids = module.vpc.private_subnets
}

# The RDS instance itself
resource "aws_db_instance" "pdm" {
  identifier        = "${lower(var.cluster_name)}-postgres" # lowercase required for RDS identifiers
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
