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
# artifacts bucket its Workspaces store in. IAM mode: the backend assumes the
# tier roles (which trust the backend task role) and presigns — no Identity
# Center. Sourced from the tmt monorepo; the module code lives there.
module "emr_studio" {
  # ref must be a literal (Terraform can't interpolate module source). Bump to a
  # release tag / main once the IAM-mode module changes are merged.
  source = "git::https://github.com/vnelluri/mltpui.git//backend/iac-emr-studio?ref=auth-cognito-saml"

  name_prefix         = var.name_prefix
  vpc_id              = var.vpc_id
  subnet_ids          = var.subnet_ids
  default_s3_location = "s3://${var.artifacts_bucket}/emr-studio-workspaces"
  # Workspace autosave writes to the SSE-KMS artifacts bucket — grant its CMK.
  default_s3_location_kms_key_arn = module.account_baseline.artifacts_kms_key_arn

  auth_mode                               = "IAM"
  backend_principal_arns                  = [var.backend_task_role_arn]
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

# Wire these into the control-plane backend, like runtime_role_arn/event_bus_arn:
#   EMR_STUDIO_ID, EMR_STUDIO_BASIC_ROLE_ARN, EMR_STUDIO_INTERMEDIATE_ROLE_ARN,
#   and backend/iac's emr_studio_tier_role_arns (for sts:AssumeRole).
output "emr_studio_id" {
  description = "IAM-mode EMR Studio id — set the backend's EMR_STUDIO_ID."
  value       = module.emr_studio.studio_id
}

output "emr_studio_tier_role_arns" {
  description = "basic/intermediate tier role ARNs — set the backend's EMR_STUDIO_{BASIC,INTERMEDIATE}_ROLE_ARN and backend/iac emr_studio_tier_role_arns."
  value       = module.emr_studio.tier_role_arns
}
