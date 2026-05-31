output "cluster_endpoint" {
  description = "EKS cluster API server endpoint"
  value       = module.pdm_env.cluster_endpoint
}

output "cluster_ca_certificate" {
  description = "Base64-encoded cluster CA certificate"
  value       = module.pdm_env.cluster_ca_certificate
  sensitive   = true
}

output "ecr_repository_url" {
  description = "ECR repository URL for the backend image"
  value       = module.pdm_env.ecr_repository_url
}

output "vpc_id" {
  description = "VPC ID"
  value       = module.pdm_env.vpc_id
}

output "github_actions_role_arn" {
  description = "IAM role ARN to set as ACTIONS_ROLE_ARN secret in pdm-app"
  value       = aws_iam_role.github_actions.arn
}
