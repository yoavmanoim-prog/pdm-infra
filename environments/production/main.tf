module "pdm_env" {
  source          = "../../modules/pdm-env"
  environment     = "production"
  aws_region      = var.aws_region
  cluster_name    = var.cluster_name
  cluster_version = var.cluster_version
  # RDS master password is read from the pdm/backend/db-password Secrets Manager
  # secret inside the module — it is never passed in as a variable.
}
