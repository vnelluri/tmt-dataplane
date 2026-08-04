terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

locals {
  # default_s3_location is s3://bucket/optional/prefix — split so IAM
  # statements can scope ListBucket (needs the bucket ARN) separately from
  # object actions (needs the bucket+prefix ARN).
  s3_location_trimmed = trimprefix(var.default_s3_location, "s3://")
  s3_bucket_name      = split("/", local.s3_location_trimmed)[0]
  s3_bucket_arn       = "arn:aws:s3:::${local.s3_bucket_name}"
  s3_prefix           = join("/", slice(split("/", local.s3_location_trimmed), 1, length(split("/", local.s3_location_trimmed))))
  s3_objects_arn      = local.s3_prefix == "" ? "${local.s3_bucket_arn}/*" : "${local.s3_bucket_arn}/${local.s3_prefix}/*"

  # Authentication mode gates two disjoint resource sets: SSO uses a shared
  # user_role + session policies + session mappings (Identity Center); IAM
  # uses per-tier assumable roles the backend presigns with (no Identity
  # Center). See the module README.
  is_sso = var.auth_mode == "SSO"
  is_iam = var.auth_mode == "IAM"
}

# ── Security groups ───────────────────────────────────────────────────────────
# Two-SG model required by EMR Studio: the Workspace (notebook editor UI) only
# ever talks to the Engine (the attached EMR Serverless application / cluster)
# on 18888 (Jupyter Enterprise Gateway); nothing else may reach the Workspace.
resource "aws_security_group" "engine" {
  name        = "${var.name_prefix}-emr-studio-engine"
  description = "EMR Studio Engine SG — accepts Workspace connections on 18888."
  vpc_id      = var.vpc_id
  tags        = merge(var.tags, { Name = "${var.name_prefix}-emr-studio-engine" })
}

resource "aws_security_group" "workspace" {
  name        = "${var.name_prefix}-emr-studio-workspace"
  description = "EMR Studio Workspace SG — outbound only, to the Engine SG and the Studio control plane."
  vpc_id      = var.vpc_id
  tags        = merge(var.tags, { Name = "${var.name_prefix}-emr-studio-workspace" })
}

resource "aws_vpc_security_group_ingress_rule" "engine_from_workspace" {
  security_group_id            = aws_security_group.engine.id
  referenced_security_group_id = aws_security_group.workspace.id
  ip_protocol                  = "tcp"
  from_port                    = 18888
  to_port                      = 18888
  description                  = "Jupyter Enterprise Gateway from Workspace"
}

resource "aws_vpc_security_group_egress_rule" "engine_all" {
  security_group_id = aws_security_group.engine.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
  description       = "Engine reaches EMR Serverless / AWS API endpoints"
}

resource "aws_vpc_security_group_egress_rule" "workspace_to_engine" {
  security_group_id            = aws_security_group.workspace.id
  referenced_security_group_id = aws_security_group.engine.id
  ip_protocol                  = "tcp"
  from_port                    = 18888
  to_port                      = 18888
  description                  = "Workspace reaches Jupyter Enterprise Gateway on the Engine"
}

resource "aws_vpc_security_group_egress_rule" "workspace_https" {
  for_each = toset(var.workspace_egress_cidrs)

  security_group_id = aws_security_group.workspace.id
  cidr_ipv4         = each.value
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  description       = "Workspace reaches the EMR Studio control plane / git / package indexes"
}

# ── Service role (assumed by the EMR Studio control plane itself) ───────────
data "aws_iam_policy_document" "studio_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["elasticmapreduce.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "service" {
  name               = "${var.name_prefix}-emr-studio-service-role"
  assume_role_policy = data.aws_iam_policy_document.studio_assume.json
  tags               = var.tags
}

data "aws_iam_policy_document" "service" {
  statement {
    sid = "AllowEMRReadOnly"
    actions = [
      "elasticmapreduce:ListInstances",
      "elasticmapreduce:DescribeCluster",
      "elasticmapreduce:ListSteps",
    ]
    resources = ["*"]
  }

  statement {
    sid = "AllowEC2ENIAndNetworkReadOnly"
    actions = [
      "ec2:DescribeSecurityGroups",
      "ec2:DescribeSubnets",
      "ec2:DescribeVpcs",
      "ec2:DescribeNetworkInterfaces",
      "ec2:CreateNetworkInterface",
      "ec2:CreateNetworkInterfacePermission",
      "ec2:DeleteNetworkInterface",
    ]
    resources = ["*"]
  }

  statement {
    sid       = "AllowWorkspaceBucketList"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = [local.s3_bucket_arn]
  }

  statement {
    sid = "AllowWorkspaceBucketObjects"
    actions = [
      "s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:GetEncryptionConfiguration",
    ]
    resources = [local.s3_objects_arn]
  }

  # Workspace autosave writes to the (SSE-KMS) artifacts bucket; without KMS
  # use on its CMK, PutObject fails AccessDenied. Skipped for SSE-S3 buckets.
  dynamic "statement" {
    for_each = var.default_s3_location_kms_key_arn == "" ? [] : [1]
    content {
      sid       = "AllowWorkspaceBucketKms"
      actions   = ["kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"]
      resources = [var.default_s3_location_kms_key_arn]
    }
  }
}

resource "aws_iam_role_policy" "service" {
  name   = "emr-studio-service"
  role   = aws_iam_role.service.id
  policy = data.aws_iam_policy_document.service.json
}

# ── User role (assumed by every federated SSO user via Identity Center) ─────
# SSO mode only. Platform-global by design (see repo README's MVP limitation):
# all users share this one role, so it is scoped to browsing/attaching EMR
# Serverless applications and the shared Workspace bucket — NOT to any tenant's
# data. Per-tenant isolation for notebook activity is a later release.
resource "aws_iam_role" "user" {
  count              = local.is_sso ? 1 : 0
  name               = "${var.name_prefix}-emr-studio-user-role"
  assume_role_policy = data.aws_iam_policy_document.studio_assume.json
  tags               = var.tags
}

data "aws_iam_policy_document" "user" {
  statement {
    sid = "AllowStudioSelfService"
    actions = [
      "elasticmapreduce:DescribeStudio",
      "elasticmapreduce:ListStudios",
      "elasticmapreduce:DescribeCluster",
      "elasticmapreduce:ListInstances",
      "elasticmapreduce:ListSteps",
    ]
    resources = ["*"]
  }

  statement {
    sid = "AllowEmrServerlessBrowse"
    actions = [
      "emr-serverless:ListApplications",
      "emr-serverless:GetApplication",
      "emr-serverless:ListJobRuns",
      "emr-serverless:GetJobRun",
    ]
    resources = ["*"]
  }

  statement {
    sid       = "AllowWorkspaceBucketList"
    actions   = ["s3:ListBucket"]
    resources = [local.s3_bucket_arn]
  }

  statement {
    sid       = "AllowWorkspaceBucketObjects"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = [local.s3_objects_arn]
  }

  dynamic "statement" {
    for_each = var.default_s3_location_kms_key_arn == "" ? [] : [1]
    content {
      sid       = "AllowWorkspaceBucketKms"
      actions   = ["kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"]
      resources = [var.default_s3_location_kms_key_arn]
    }
  }
}

resource "aws_iam_role_policy" "user" {
  count  = local.is_sso ? 1 : 0
  name   = "emr-studio-user"
  role   = aws_iam_role.user[0].id
  policy = data.aws_iam_policy_document.user.json
}

# ── Session policies (referenced by session mappings below) ─────────────────
# Mirrors AWS's published "basic" / "intermediate" EMR Studio session-policy
# templates: they further restrict what an assumed session may do beyond the
# user role above. "basic" = attach + run notebooks only; "intermediate" adds
# the ability to create/terminate the EMR Serverless applications a Workspace
# attaches to.
data "aws_iam_policy_document" "session_basic" {
  statement {
    sid = "BasicNotebookUsage"
    actions = [
      "elasticmapreduce:DescribeStudio",
      "elasticmapreduce:DescribeCluster",
      "elasticmapreduce:ListInstances",
      "emr-serverless:ListApplications",
      "emr-serverless:GetApplication",
      "emr-serverless:GetJobRun",
    ]
    resources = ["*"]
  }
  statement {
    sid       = "BasicWorkspaceStorage"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:ListBucket"]
    resources = [local.s3_bucket_arn, local.s3_objects_arn]
  }
}

data "aws_iam_policy_document" "session_intermediate" {
  source_policy_documents = [data.aws_iam_policy_document.session_basic.json]

  statement {
    sid = "IntermediateApplicationLifecycle"
    actions = [
      "emr-serverless:StartApplication",
      "emr-serverless:StopApplication",
      "emr-serverless:StartJobRun",
      "emr-serverless:CancelJobRun",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "session_basic" {
  count  = local.is_sso ? 1 : 0
  name   = "${var.name_prefix}-emr-studio-session-basic"
  policy = data.aws_iam_policy_document.session_basic.json
  tags   = var.tags
}

resource "aws_iam_policy" "session_intermediate" {
  count  = local.is_sso ? 1 : 0
  name   = "${var.name_prefix}-emr-studio-session-intermediate"
  policy = data.aws_iam_policy_document.session_intermediate.json
  tags   = var.tags
}

locals {
  session_policy_arns = {
    basic        = one(aws_iam_policy.session_basic[*].arn)
    intermediate = one(aws_iam_policy.session_intermediate[*].arn)
  }

  # The Studio this module operates on: the one it creates, or (when
  # create_studio = false) the admin-created one passed in. one() yields null
  # for the absent branch so the conditional never indexes an empty list.
  studio_id_effective  = var.create_studio ? one(aws_emr_studio.this[*].id) : var.studio_id
  studio_url_effective = var.create_studio ? one(aws_emr_studio.this[*].url) : var.studio_url
}

# Cross-variable invariants (Terraform < 1.9 can't reference other variables in
# a variable validation block, so enforce them here):
#  - create_studio = false ⇒ studio_id/studio_url supplied (admin-owned Studio).
#  - auth_mode = "IAM" ⇒ backend_principal_arns supplied (who may presign).
resource "terraform_data" "require_external_studio" {
  lifecycle {
    precondition {
      condition     = var.create_studio || (var.studio_id != "" && var.studio_url != "")
      error_message = "create_studio = false requires both studio_id and studio_url (the admin-created Studio's identifiers)."
    }
    precondition {
      condition     = var.auth_mode != "IAM" || length(var.backend_principal_arns) > 0
      error_message = "auth_mode = \"IAM\" requires backend_principal_arns (the principals allowed to assume the tier roles and presign)."
    }
  }
}

# ── Studio ────────────────────────────────────────────────────────────────────
# Skipped when create_studio = false: an Identity Center admin creates the
# Studio out-of-band (CreateStudio in SSO mode needs sso: write permissions a
# locked-down CI/CD role may lack), passing service_role/user_role/SG ids from
# this module's outputs; its id/url come back in via studio_id/studio_url.
resource "aws_emr_studio" "this" {
  count = var.create_studio ? 1 : 0

  name                        = "${var.name_prefix}-studio"
  auth_mode                   = var.auth_mode
  default_s3_location         = var.default_s3_location
  engine_security_group_id    = aws_security_group.engine.id
  workspace_security_group_id = aws_security_group.workspace.id
  service_role                = aws_iam_role.service.arn
  # user_role is an SSO-mode concept (the shared role every federated session
  # assumes); IAM mode has no user_role — access is via presigned URLs.
  user_role  = local.is_sso ? one(aws_iam_role.user[*].arn) : null
  vpc_id     = var.vpc_id
  subnet_ids = var.subnet_ids
  tags       = var.tags
}

# ── Session mappings ──────────────────────────────────────────────────────────
# Grants IAM Identity Center groups/users access; the identity names must
# already exist in Identity Center (SCIM-synced from the Entra security
# groups documented in the platform README) — this module does not create
# them. Works against either the module-created or the admin-created Studio.
# If the CI/CD role also cannot create session mappings (sso:CreateApplication-
# Assignment / identitystore reads), leave session_mappings empty and have the
# admin own them too.
resource "aws_emr_studio_session_mapping" "this" {
  # SSO only — IAM mode has no session mappings (access is via presigned URLs).
  for_each = local.is_sso ? var.session_mappings : {}

  studio_id          = local.studio_id_effective
  identity_type      = var.session_identity_type
  identity_name      = each.key
  session_policy_arn = local.session_policy_arns[each.value]
}

# ── IAM auth mode: per-tier assumable roles ─────────────────────────────────
# In IAM mode there is no Identity Center. The backend assumes one of these
# roles (with RoleSessionName = the user's STABLE id, so EMR Studio's
# creatorUserId=${aws:userId} Workspace ownership is per-user and stable across
# logins) and calls emr:CreateStudioPresignedUrl to deep-link the user in.
# "basic" = browse + attach + run notebooks; "intermediate" adds EMR Serverless
# application lifecycle — mirroring the SSO session-policy tiers.
data "aws_iam_policy_document" "backend_assume" {
  count = local.is_iam ? 1 : 0
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "AWS"
      identifiers = var.backend_principal_arns
    }
  }
}

data "aws_iam_policy_document" "iam_tier_basic" {
  count = local.is_iam ? 1 : 0

  statement {
    sid       = "StudioAccessAndPresign"
    actions   = ["elasticmapreduce:CreateStudioPresignedUrl", "elasticmapreduce:DescribeStudio", "elasticmapreduce:ListStudios"]
    resources = ["*"]
  }
  statement {
    sid = "WorkspaceLifecycle"
    actions = [
      "elasticmapreduce:CreateEditor", "elasticmapreduce:DescribeEditor",
      "elasticmapreduce:ListEditors", "elasticmapreduce:StartEditor",
      "elasticmapreduce:StopEditor", "elasticmapreduce:DeleteEditor",
      "elasticmapreduce:OpenEditorInConsole", "elasticmapreduce:AttachEditor",
      "elasticmapreduce:DetachEditor",
    ]
    resources = ["*"]
  }
  # Per-user Workspace ownership: EMR Studio tags each Workspace with
  # creatorUserId = the creator's aws:userId (which, for an assumed-role
  # session, embeds RoleSessionName). Scoping the collaboration-management
  # actions to that tag means a user may only manage the Workspaces they own.
  statement {
    sid = "WorkspaceCollaborationOwnerScoped"
    actions = [
      "elasticmapreduce:UpdateEditor", "elasticmapreduce:PutWorkspaceAccess",
      "elasticmapreduce:DeleteWorkspaceAccess", "elasticmapreduce:ListWorkspaceAccessIdentities",
    ]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "elasticmapreduce:ResourceTag/creatorUserId"
      values   = ["$${aws:userId}"]
    }
  }
  statement {
    sid = "EmrServerlessBrowseAttach"
    actions = [
      "emr-serverless:ListApplications", "emr-serverless:GetApplication",
      "emr-serverless:ListJobRuns", "emr-serverless:GetJobRun",
      "emr-serverless:GetDashboardForJobRun", "emr-serverless:AccessInteractiveEndpoints",
    ]
    resources = ["*"]
  }
  statement {
    sid       = "WorkspaceStorage"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:ListBucket"]
    resources = [local.s3_bucket_arn, local.s3_objects_arn]
  }
  dynamic "statement" {
    for_each = var.default_s3_location_kms_key_arn == "" ? [] : [1]
    content {
      sid       = "WorkspaceStorageKms"
      actions   = ["kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"]
      resources = [var.default_s3_location_kms_key_arn]
    }
  }
  statement {
    sid       = "PassServiceRoleForWorkspaceCreation"
    actions   = ["iam:PassRole"]
    resources = [aws_iam_role.service.arn]
  }
  statement {
    sid       = "DescribeNetworkAndListRoles"
    actions   = ["ec2:DescribeVpcs", "ec2:DescribeSubnets", "ec2:DescribeSecurityGroups", "iam:ListRoles"]
    resources = ["*"]
  }
}

data "aws_iam_policy_document" "iam_tier_intermediate" {
  count                   = local.is_iam ? 1 : 0
  source_policy_documents = [data.aws_iam_policy_document.iam_tier_basic[0].json]

  statement {
    sid = "EmrServerlessApplicationLifecycle"
    actions = [
      "emr-serverless:StartApplication", "emr-serverless:StopApplication",
      "emr-serverless:StartJobRun", "emr-serverless:CancelJobRun",
    ]
    resources = ["*"]
  }
  statement {
    sid       = "PassRuntimeRoleForJobRuns"
    actions   = ["iam:PassRole"]
    resources = [var.emr_serverless_runtime_role_arn_pattern]
  }
}

locals {
  # tier name -> permission-policy JSON, empty in SSO mode so no tier roles
  # are created. one() safely yields null for the absent-count branch.
  iam_tier_policy_json = local.is_iam ? {
    basic        = one(data.aws_iam_policy_document.iam_tier_basic[*].json)
    intermediate = one(data.aws_iam_policy_document.iam_tier_intermediate[*].json)
  } : {}
}

resource "aws_iam_role" "tier" {
  for_each           = local.iam_tier_policy_json
  name               = "${var.name_prefix}-emr-studio-${each.key}"
  assume_role_policy = data.aws_iam_policy_document.backend_assume[0].json
  tags               = var.tags
}

resource "aws_iam_role_policy" "tier" {
  for_each = local.iam_tier_policy_json
  name     = "emr-studio-${each.key}"
  role     = aws_iam_role.tier[each.key].id
  policy   = each.value
}
