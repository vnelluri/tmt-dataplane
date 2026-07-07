variable "tenant_id" {
  description = "Platform tenant ID (e.g. tenant-risk-analytics)."
  type        = string
}

variable "tenant_name" {
  description = "Human-readable tenant name (tagging only)."
  type        = string
}

variable "name_prefix" {
  description = "Platform name prefix; also the value of the `platform` tag the backend's IAM policy matches on."
  type        = string
  default     = "ml-platform"
}

variable "artifacts_bucket" {
  description = "Shared artifacts bucket name (from account-baseline)."
  type        = string
}

variable "release_label" {
  description = "EMR Serverless release."
  type        = string
  default     = "emr-7.1.0"
}

variable "max_concurrent_vcpus" {
  description = "Hard cap on concurrent vCPUs for this tenant's EMR application (instantaneous quota enforcement)."
  type        = number
  default     = 64
}

variable "max_memory_gb" {
  description = "Hard cap on concurrent memory (GB). Defaults to 8x vCPUs when null."
  type        = number
  default     = null
}

variable "subnet_ids" {
  description = "Dataplane VPC subnets for EMR Serverless workers (Snowflake private connectivity)."
  type        = list(string)
}

variable "security_group_ids" {
  description = "Security groups for EMR Serverless workers."
  type        = list(string)
}

variable "backend_task_role_arn" {
  description = "Control-plane backend task role — granted Encrypt/Decrypt on the tenant KMS key via key policy (cross-account KMS requires the key policy, and the backend uses the key ARN directly)."
  type        = string
}

variable "job_token_secret_prefix" {
  description = "Secrets Manager name prefix for per-job Snowflake token secrets."
  type        = string
  default     = "ml-platform/job-tokens/"
}

variable "tags" {
  description = "Extra tags for all tenant resources."
  type        = map(string)
  default     = {}
}
