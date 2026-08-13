module "account_baseline" {
  source = "./modules/account-baseline"

  name_prefix                   = var.name_prefix
  artifacts_bucket              = var.artifacts_bucket
  job_token_secret_prefix       = var.job_token_secret_prefix
  backend_task_role_arn         = var.backend_task_role_arn
  repo_clone_url                = var.repo_clone_url
  platform_api_url              = var.platform_api_url
  platform_api_token_secret_arn = var.platform_api_token_secret_arn
}

module "tenant" {
  source   = "./modules/tenant"
  for_each = var.tenants

  tenant_id               = each.key
  tenant_name             = each.value.name
  name_prefix             = var.name_prefix
  artifacts_bucket        = module.account_baseline.artifacts_bucket
  artifacts_kms_key_arn   = module.account_baseline.artifacts_kms_key_arn
  job_token_secret_prefix = var.job_token_secret_prefix
  backend_task_role_arn   = var.backend_task_role_arn
  max_concurrent_vcpus    = each.value.max_concurrent_vcpus
  max_memory_gb           = each.value.max_memory_gb
  subnet_ids              = var.subnet_ids
  security_group_ids      = var.security_group_ids
}

data "aws_caller_identity" "current" {}

# ── Platform-global EMR Studio (IAM auth mode) ──────────────────────────────
# Applied-once, next to the EMR Serverless apps it attaches to and the
# artifacts bucket its Workspaces store in. IAM mode: users reach the Studio
# access URL and federate in through Entra (SAML); they assume the per-tier
# roles via AssumeRoleWithSAML — no Identity Center, and the backend makes no
# EMR Studio API call (it only deep-links EMR_STUDIO_URL = this module's url
# output). See docs/EMR_STUDIO_FEDERATION_REQUEST.md for the Entra setup.
module "emr_studio" {
  source = "./modules/emr-studio"

  name_prefix         = var.name_prefix
  vpc_id              = var.vpc_id
  subnet_ids          = var.subnet_ids
  default_s3_location = "s3://${var.artifacts_bucket}/emr-studio-workspaces"
  # Workspace autosave writes to the SSE-KMS artifacts bucket — grant its CMK.
  default_s3_location_kms_key_arn = module.account_baseline.artifacts_kms_key_arn

  auth_mode = "IAM"
  # Federation to Entra: the ARN of the IAM SAML provider your admin created
  # out-of-band (this stack never creates it — see the module).
  saml_provider_arn                       = var.emr_studio_saml_provider_arn
  emr_serverless_runtime_role_arn_pattern = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.name_prefix}-tenant-*-exec"
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

# The backend only needs the access URL: set the control-plane backend's
# EMR_STUDIO_URL (SSM) to this. It makes no EMR Studio API call.
output "emr_studio_url" {
  description = "IAM-mode EMR Studio access URL — set the backend's EMR_STUDIO_URL."
  value       = module.emr_studio.url
}

# Entra federation config (hand to the Entra/IAM admin — see
# docs/EMR_STUDIO_FEDERATION_REQUEST.md). NOT consumed by the backend.
output "emr_studio_saml_provider_arn" {
  description = "IAM SAML provider ARN the tier roles trust — the second half of each Entra \"Role\" claim value."
  value       = module.emr_studio.saml_provider_arn
}

output "emr_studio_tier_role_arns" {
  description = "basic/intermediate federated role ARNs users assume via SAML — map Entra groups to these in the \"Role\" claim."
  value       = module.emr_studio.tier_role_arns
}
