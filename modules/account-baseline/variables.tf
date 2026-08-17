variable "name_prefix" {
  description = "Platform name prefix."
  type        = string
  default     = "ml-platform"
}

variable "artifacts_bucket" {
  description = "Name for the shared artifacts bucket created in this account."
  type        = string
}

variable "job_token_secret_prefix" {
  description = "Secrets Manager name prefix for per-job token secrets (must match the backend's SECRETS_MANAGER_JOB_TOKEN_PREFIX)."
  type        = string
  default     = "ml-platform/job-tokens/"
}

variable "backend_task_role_arn" {
  description = "The control-plane backend task role ARN (output of tmt//backend/iac) — trusted to assume the runtime role and use the artifacts CMK."
  type        = string
}

variable "repo_clone_url" {
  description = "HTTPS clone URL of this tmt-dataplane repository (CodeBuild source)."
  type        = string
}

variable "repo_branch" {
  description = "Branch the apply pipeline builds from."
  type        = string
  default     = "main"
}

variable "tenant_role_permissions_boundary_arn" {
  description = "Org permissions boundary the backend must attach to runtime-created tenant execution roles (backend setting TENANT_ROLE_PERMISSIONS_BOUNDARY_ARN must match). Empty = no boundary enforcement."
  type        = string
  default     = ""
}

variable "tags" {
  description = "Tags applied to all resources."
  type        = map(string)
  default     = {}
}
