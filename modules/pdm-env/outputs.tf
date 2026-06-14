output "cluster_endpoint" {
  description = "EKS cluster API server endpoint"
  value       = module.eks.cluster_endpoint
}

output "cluster_ca_certificate" {
  description = "Base64-encoded cluster CA certificate"
  value       = module.eks.cluster_certificate_authority_data
}

output "ecr_repository_url" {
  description = "ECR repository URL for the backend image"
  value       = aws_ecr_repository.pdm_backend.repository_url
}

output "vpc_id" {
  description = "VPC ID"
  value       = module.vpc.vpc_id
}

output "oidc_provider_arn" {
  description = "ARN of the EKS OIDC provider — used to create IRSA roles"
  value       = module.eks.oidc_provider_arn
}

output "oidc_provider_url" {
  description = "URL of the EKS OIDC provider"
  value       = module.eks.cluster_oidc_issuer_url
}

output "s3_bucket_name" {
  description = "S3 bucket name for PDF storage"
  value       = aws_s3_bucket.pdm_docs.bucket
}

output "backend_irsa_role_arn" {
  description = "IAM role ARN for the backend pod (IRSA) — annotate the ServiceAccount with this"
  value       = aws_iam_role.pdm_backend.arn
}

output "rds_endpoint" {
  description = "RDS postgres endpoint — use this in DATABASE_URL"
  value       = aws_db_instance.pdm.endpoint
}

output "external_secrets_role_arn" {
  description = "IAM role ARN for External Secrets Operator — annotate the external-secrets controller ServiceAccount with this"
  value       = aws_iam_role.external_secrets.arn
}
