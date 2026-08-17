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
  description = "Backend task role ARN (output of tmt//backend/iac) — trusted to assume the runtime role and use the KMS keys."
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

variable "tenant_role_permissions_boundary_arn" {
  description = "Org permissions boundary the backend must attach to runtime-created tenant execution roles (must match the backend's TENANT_ROLE_PERMISSIONS_BOUNDARY_ARN). Empty = no boundary enforcement."
  type        = string
  default     = ""
}

variable "vpc_id" {
  description = "Dataplane VPC id (for the EMR Studio engine/workspace security groups)."
  type        = string
}

variable "subnet_ids" {
  description = "Dataplane VPC subnets for EMR Serverless workers and EMR Studio Workspaces."
  type        = list(string)
}

# EMR Studio IAM-mode federation to Entra: the ARN of the IAM SAML provider your
# admin created out-of-band. This stack never creates it (no iam:CreateSAMLProvider).
# See docs/EMR_STUDIO_FEDERATION_REQUEST.md.
variable "emr_studio_saml_provider_arn" {
  description = "ARN of the admin-created IAM SAML provider (Entra) for EMR Studio federation. Required to apply the emr_studio module in IAM mode."
  type        = string
  default     = ""
}
