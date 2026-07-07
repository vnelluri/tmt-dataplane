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

variable "control_plane_account_id" {
  description = "AWS account ID running the tmt control plane."
  type        = string
}

variable "backend_task_role_arn" {
  description = "Backend task role ARN (output of tmt//backend/iac)."
  type        = string
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

variable "subnet_ids" {
  description = "Dataplane VPC subnets for EMR Serverless workers."
  type        = list(string)
}

variable "security_group_ids" {
  description = "Security groups for EMR Serverless workers."
  type        = list(string)
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
