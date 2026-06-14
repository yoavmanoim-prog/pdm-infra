data "aws_caller_identity" "current" {}

# ==========================================
# GitHub Actions OIDC Provider
# ==========================================

resource "aws_iam_openid_connect_provider" "github_actions" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

# ==========================================
# IAM Role — assumed by GitHub Actions
# ==========================================

resource "aws_iam_role" "github_actions" {
  name = "pdm-github-actions"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = aws_iam_openid_connect_provider.github_actions.arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringLike = {
            "token.actions.githubusercontent.com:sub" = "repo:yoavmanoim-prog/pdm-app:*"
          }
          StringEquals = {
            "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          }
        }
      }
    ]
  })
}

# ==========================================
# ECR push permissions
# ==========================================

resource "aws_iam_policy" "github_actions_ecr" {
  name        = "pdm-github-actions-ecr"
  description = "Allows GitHub Actions to push images to ECR"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:PutImage",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:DescribeRepositories"
        ]
        # allow push to both backend and frontend ECR repositories
        Resource = [
          "arn:aws:ecr:${var.aws_region}:${data.aws_caller_identity.current.account_id}:repository/pdm-backend",
          "arn:aws:ecr:${var.aws_region}:${data.aws_caller_identity.current.account_id}:repository/pdm-frontend"
        ]
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "github_actions_ecr" {
  role       = aws_iam_role.github_actions.name
  policy_arn = aws_iam_policy.github_actions_ecr.arn
}

# ==========================================
# S3 + CloudFront deploy permissions
# ==========================================

resource "aws_iam_policy" "github_actions_frontend_deploy" {
  name        = "pdm-github-actions-frontend-deploy"
  description = "Allows GitHub Actions to deploy the frontend to S3 and invalidate CloudFront"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:ListBucket"
        ]
        Resource = [
          "arn:aws:s3:::pdm-frontend-*",
          "arn:aws:s3:::pdm-frontend-*/*"
        ]
      },
      {
        # list-distributions is needed so CI can look up the distribution ID at runtime
        Effect   = "Allow"
        Action   = ["cloudfront:ListDistributions", "cloudfront:CreateInvalidation"]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "github_actions_frontend_deploy" {
  role       = aws_iam_role.github_actions.name
  policy_arn = aws_iam_policy.github_actions_frontend_deploy.arn
}
