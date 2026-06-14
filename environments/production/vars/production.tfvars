aws_region      = "us-east-1"
cluster_name    = "pdm-prod-EKS"
cluster_version = "1.31"
# db_password removed — the RDS master password is stored in AWS Secrets Manager
# as pdm/backend/db-password and read by the module. Create/rotate it there.
