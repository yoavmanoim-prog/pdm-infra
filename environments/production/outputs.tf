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
