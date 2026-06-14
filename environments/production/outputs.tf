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
  description = "IAM role ARN to set as AWS_ROLE_ARN secret in pdm-app"
  value       = aws_iam_role.github_actions.arn
}

output "oidc_provider_arn" {
  description = "EKS OIDC provider ARN — used when creating IRSA roles for pods"
  value       = module.pdm_env.oidc_provider_arn
}

output "oidc_provider_url" {
  description = "EKS OIDC provider URL"
  value       = module.pdm_env.oidc_provider_url
}

output "s3_bucket_name" {
  description = "S3 bucket name for PDF storage"
  value       = module.pdm_env.s3_bucket_name
}

output "backend_irsa_role_arn" {
  description = "IAM role ARN to annotate the backend ServiceAccount with"
  value       = module.pdm_env.backend_irsa_role_arn
}

output "external_secrets_role_arn" {
  description = "IAM role ARN to annotate the external-secrets controller ServiceAccount with"
  value       = module.pdm_env.external_secrets_role_arn
}
