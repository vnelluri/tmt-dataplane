variable "region" {
  description = "Dataplane account region."
  type        = string
  default     = "us-east-1"
}

variable "name_prefix" {
  description = "Platform name prefix."
  type        = string
  default     = "ml-platform"
}

variable "artifacts_bucket" {
  description = "Shared artifacts bucket name (account-unique)."
  type        = string
}

variable "backend_task_role_arn" {
  description = "Backend task role ARN (output of tmt//backend/iac) — trusted to PutEvents, assume the runtime role, and use the KMS keys."
  type        = string
}

variable "job_token_secret_prefix" {
  description = "Secrets Manager name prefix for per-job token secrets (must match the backend's SECRETS_MANAGER_JOB_TOKEN_PREFIX)."
  type        = string
  default     = "ml-platform/job-tokens/"
}

variable "repo_clone_url" {
  description = "HTTPS clone URL of this repository."
  type        = string
}

variable "platform_api_url" {
  description = "Platform API base URL for the reconcile script."
  type        = string
}

variable "platform_api_token_secret_arn" {
  description = "Secrets Manager ARN of the PlatformAdmin API token."
  type        = string
}

variable "vpc_id" {
  description = "Dataplane VPC id (for the EMR Studio engine/workspace security groups)."
  type        = string
}

variable "subnet_ids" {
  description = "Dataplane VPC subnets for EMR Serverless workers and EMR Studio Workspaces."
  type        = list(string)
}

variable "security_group_ids" {
  description = "Security groups for EMR Serverless workers."
  type        = list(string)
}

# EMR Studio IAM-mode federation to Entra: supply exactly one. The metadata XML
# creates the SAML provider here; the ARN references an existing one. See
# docs/EMR_STUDIO_FEDERATION_REQUEST.md.
variable "emr_studio_saml_provider_arn" {
  description = "ARN of an existing IAM SAML provider (Entra) for EMR Studio federation. Leave empty to create one from emr_studio_saml_metadata_document."
  type        = string
  default     = ""
}

variable "emr_studio_saml_metadata_document" {
  description = "Entra federation metadata XML (contents) to create the IAM SAML provider for EMR Studio. Empty to reference an existing one via emr_studio_saml_provider_arn."
  type        = string
  default     = ""
}


# The reconcile script regenerates tenants.auto.tfvars.json from the platform
# API (GET /tenants) on every pipeline run — the API is the source of truth
# for membership; per-tenant capacity overrides live here.
variable "tenants" {
  description = "Tenants to provision, keyed by tenantId."
  type = map(object({
    name                 = string
    max_concurrent_vcpus = optional(number, 64)
    max_memory_gb        = optional(number)
  }))
  default = {}
}
