variable "name_prefix" {
  description = "Prefix for all named resources (e.g. ml-platform)."
  type        = string
  default     = "ml-platform"
}

variable "vpc_id" {
  description = "VPC to attach the Studio's Engine/Workspace security groups to."
  type        = string
}

variable "subnet_ids" {
  description = "Private subnets the Studio can launch Workspaces into (must route to the VPC's EMR Serverless / EMR endpoints)."
  type        = list(string)
}

variable "default_s3_location" {
  description = "S3 URI where Workspace notebook files (.ipynb) are stored, e.g. s3://ml-platform-artifacts-prod/emr-studio-workspaces."
  type        = string
}

variable "default_s3_location_kms_key_arn" {
  description = "KMS CMK ARN the default_s3_location bucket is SSE-encrypted with (e.g. tmt-dataplane's artifacts CMK). When set, the Studio service/user/tier roles get kms:Decrypt/GenerateDataKey/DescribeKey on it — required or Workspace autosave to an SSE-KMS bucket fails. Empty = bucket uses SSE-S3 (no grant needed)."
  type        = string
  default     = ""
}

variable "workspace_egress_cidrs" {
  description = "CIDRs the Workspace security group may reach on 443 (Studio control-plane API, git, package indexes). Restrict to VPC endpoint / NAT egress ranges where possible; defaults to unrestricted."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "session_mappings" {
  description = <<-EOT
    IAM Identity Center identity -> access tier, keyed by identity name (the
    Identity Center group/user name — SCIM-synced from the Entra security
    groups documented in the platform README, e.g. "myapp-platform-admin").
    Tier must be "basic" or "intermediate" (see session policies below).
  EOT
  type        = map(string)
  default     = {}

  validation {
    condition     = alltrue([for tier in values(var.session_mappings) : contains(["basic", "intermediate"], tier)])
    error_message = "Each session_mappings value must be \"basic\" or \"intermediate\"."
  }
}

variable "session_identity_type" {
  description = "Identity type for all entries in session_mappings — \"GROUP\" (recommended) or \"USER\"."
  type        = string
  default     = "GROUP"
}

variable "auth_mode" {
  description = <<-EOT
    EMR Studio authentication mode. "IAM" (the default — no Identity Center; the
    backend presigns a URL after assuming a per-tier role, so this REQUIRES
    backend_principal_arns and ignores session_mappings) or "SSO" (IAM Identity
    Center — uses user_role + session_mappings). IAM mode avoids the sso: writes
    that a locked-down CI/CD role can't perform, at the cost of the backend
    calling the EMR Studio API at launch time. See the module README
    "IAM authentication mode".
  EOT
  type        = string
  default     = "IAM"

  validation {
    condition     = contains(["SSO", "IAM"], var.auth_mode)
    error_message = "auth_mode must be \"SSO\" or \"IAM\"."
  }
}

variable "backend_principal_arns" {
  description = "IAM mode only: principals (e.g. the backend task role ARN) allowed to assume the basic/intermediate tier roles to presign Studio URLs. Required when auth_mode = \"IAM\"."
  type        = list(string)
  default     = []
}

variable "emr_serverless_runtime_role_arn_pattern" {
  description = "IAM mode only: ARN (pattern) of the EMR Serverless job runtime role(s) the intermediate tier may iam:PassRole when starting jobs. Defaults to * — scope to the tenant execution-role pattern in production."
  type        = string
  default     = "*"
}

variable "create_studio" {
  description = <<-EOT
    Whether this module creates the aws_emr_studio resource. Creating a Studio
    in SSO auth mode calls sso:CreateApplication /
    sso:CreateManagedApplicationInstance to register it in IAM Identity Center;
    a locked-down CI/CD role (e.g. one whose permissions boundary denies those
    actions) cannot do that. Set false to have an Identity Center admin create
    the Studio out-of-band and pass its identifiers via studio_id/studio_url —
    this module then still manages the security groups, IAM roles, session
    policies, and (permissions permitting) session_mappings. Default true keeps
    the original single-apply behaviour.
  EOT
  type        = bool
  default     = true
}

variable "studio_id" {
  description = "ID of an externally created (admin-owned) EMR Studio. Required when create_studio = false — used for session mappings and the studio_id output; ignored when create_studio = true."
  type        = string
  default     = ""
}

variable "studio_url" {
  description = "Access URL of an externally created (admin-owned) EMR Studio. Required when create_studio = false — surfaced as the url output (which SSM feeds to the backend); ignored when create_studio = true."
  type        = string
  default     = ""
}

variable "tags" {
  description = "Tags applied to all resources."
  type        = map(string)
  default     = {}
}
