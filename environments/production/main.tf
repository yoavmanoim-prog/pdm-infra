module "pdm_env" {
  source          = "../../modules/pdm-env"
  environment     = "production"
  aws_region      = var.aws_region
  cluster_name    = var.cluster_name
  cluster_version = var.cluster_version
  db_password     = var.db_password # passed from production.tfvars, never hardcoded
}
