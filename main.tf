module "account_baseline" {
  source = "./modules/account-baseline"

  name_prefix                   = var.name_prefix
  artifacts_bucket              = var.artifacts_bucket
  control_plane_account_id      = var.control_plane_account_id
  backend_task_role_arn         = var.backend_task_role_arn
  repo_clone_url                = var.repo_clone_url
  platform_api_url              = var.platform_api_url
  platform_api_token_secret_arn = var.platform_api_token_secret_arn
}

module "tenant" {
  source   = "./modules/tenant"
  for_each = var.tenants

  tenant_id             = each.key
  tenant_name           = each.value.name
  name_prefix           = var.name_prefix
  artifacts_bucket      = module.account_baseline.artifacts_bucket
  backend_task_role_arn = var.backend_task_role_arn
  max_concurrent_vcpus  = each.value.max_concurrent_vcpus
  max_memory_gb         = each.value.max_memory_gb
  subnet_ids            = var.subnet_ids
  security_group_ids    = var.security_group_ids
}

# Consumed by scripts/provision-tenants.sh for the write-back step
# (PUT /tenants/{id}/provisioning on the platform API).
output "tenants" {
  description = "Per-tenant provisioned resource IDs."
  value = {
    for id, mod in module.tenant : id => {
      emrApplicationId = mod.emr_application_id
      executionRoleArn = mod.execution_role_arn
      s3BucketName     = mod.s3_prefix
      kmsKeyArn        = mod.kms_key_arn
    }
  }
}

output "event_bus_arn" {
  value = module.account_baseline.event_bus_arn
}
