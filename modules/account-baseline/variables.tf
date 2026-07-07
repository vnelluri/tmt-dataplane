variable "name_prefix" {
  description = "Platform name prefix."
  type        = string
  default     = "ml-platform"
}

variable "artifacts_bucket" {
  description = "Name for the shared artifacts bucket created in this account."
  type        = string
}

variable "control_plane_account_id" {
  description = "AWS account ID running the tmt backend (control plane)."
  type        = string
}

variable "backend_task_role_arn" {
  description = "The control-plane backend task role ARN (output of tmt//backend/iac) — trusted to PutEvents and to assume the runtime role."
  type        = string
}

variable "repo_clone_url" {
  description = "HTTPS clone URL of this tmt-dataplane repository (CodeBuild source)."
  type        = string
}

variable "repo_branch" {
  description = "Branch the provisioning pipeline builds from."
  type        = string
  default     = "main"
}

variable "platform_api_url" {
  description = "Base URL of the platform API, used by the reconcile script (GET /tenants, PUT /tenants/{id}/provisioning)."
  type        = string
}

variable "platform_api_token_secret_arn" {
  description = "Secrets Manager ARN holding a PlatformAdmin API token for the write-back calls."
  type        = string
}

variable "tags" {
  description = "Tags applied to all resources."
  type        = map(string)
  default     = {}
}
