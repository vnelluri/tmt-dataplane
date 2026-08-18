terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.100"
    }
  }
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.region
  tags       = merge(var.tags, { platform = var.name_prefix, managedBy = "tmt-dataplane" })
}

# ── Shared artifacts bucket ──────────────────────────────────────────────────
resource "aws_s3_bucket" "artifacts" {
  bucket = var.artifacts_bucket
  tags   = local.tags
}

resource "aws_s3_bucket_versioning" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  versioning_configuration {
    status = "Enabled"
  }
}

# Customer-managed key for bucket SSE. The default AWS-managed aws/s3 key
# CANNOT be granted to a cross-account principal, so in the account split the
# control-plane backend's GetObject/PutObject would fail KMS AccessDenied
# even with the bucket policy below. A CMK (key policy grants the backend and
# tenant execution roles, tagged `platform` for the backend's tag-scoped
# identity policy) makes cross-account object access work.
data "aws_iam_policy_document" "artifacts_key" {
  statement {
    sid       = "AccountAdmin"
    actions   = ["kms:*"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${local.account_id}:root"]
    }
  }
  statement {
    sid = "ControlPlaneBackendUse"
    actions = [
      "kms:Encrypt", "kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey",
    ]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = [var.backend_task_role_arn]
    }
  }
}

resource "aws_kms_key" "artifacts" {
  description         = "${var.name_prefix} artifacts bucket SSE"
  enable_key_rotation = true
  policy              = data.aws_iam_policy_document.artifacts_key.json
  tags                = local.tags
}

resource "aws_kms_alias" "artifacts" {
  name          = "alias/${var.name_prefix}-artifacts"
  target_key_id = aws_kms_key.artifacts.key_id
}

resource "aws_s3_bucket_server_side_encryption_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.artifacts.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "artifacts" {
  bucket                  = aws_s3_bucket.artifacts.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Cross-account access for the control-plane backend (S3 browse, artifact
# validation at model registration, tenant prefix markers). S3 uses a
# resource policy rather than the runtime role: these are human-facing
# read/browse paths where the backend's own identity is the right principal.
data "aws_iam_policy_document" "artifacts_bucket_policy" {
  statement {
    sid       = "ControlPlaneBackendList"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.artifacts.arn]
    principals {
      type        = "AWS"
      identifiers = [var.backend_task_role_arn]
    }
  }
  statement {
    sid       = "ControlPlaneBackendObjects"
    actions   = ["s3:GetObject", "s3:PutObject"]
    resources = ["${aws_s3_bucket.artifacts.arn}/*"]
    principals {
      type        = "AWS"
      identifiers = [var.backend_task_role_arn]
    }
  }
}

resource "aws_s3_bucket_policy" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  policy = data.aws_iam_policy_document.artifacts_bucket_policy.json

  depends_on = [aws_s3_bucket_public_access_block.artifacts]
}

# ── CodeBuild project: applies this repo's global stack (account-baseline +
#    EMR Studio). Run manually or from CI — per-tenant resources are NOT
#    managed here anymore; the control-plane backend creates them directly
#    through the runtime role below. ────────────────────────────────────────
data "aws_iam_policy_document" "codebuild_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["codebuild.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "codebuild" {
  name               = "${var.name_prefix}-provisioner-codebuild-role"
  assume_role_policy = data.aws_iam_policy_document.codebuild_assume.json
  tags               = local.tags
}

# The apply pipeline manages exactly what this repo declares: the artifacts
# bucket + CMK, the runtime role, the EMR Studio stack, and its own
# logs/state. Per-tenant resources are the backend's job (runtime role), not
# Terraform's. Tighten further with a permissions boundary if your account
# standards require it.
data "aws_iam_policy_document" "codebuild" {
  statement {
    sid = "ManageGlobalResources"
    actions = [
      "kms:*",
      "s3:*",
      "logs:*",
    ]
    resources = ["*"]
  }
  statement {
    sid = "ManageStudioAndRuntimeRoles"
    actions = [
      "iam:CreateRole", "iam:DeleteRole", "iam:GetRole", "iam:TagRole",
      "iam:PutRolePolicy", "iam:DeleteRolePolicy", "iam:GetRolePolicy",
      "iam:ListRolePolicies", "iam:ListAttachedRolePolicies",
      "iam:ListInstanceProfilesForRole", "iam:UpdateAssumeRolePolicy",
    ]
    resources = [
      # The platform-global EMR Studio roles (service + basic/intermediate
      # tier) and the dataplane runtime role this module manages.
      "arn:aws:iam::${local.account_id}:role/${var.name_prefix}-emr-studio-*",
      "arn:aws:iam::${local.account_id}:role/${var.name_prefix}-dataplane-runtime",
    ]
  }
  # EMR Studio (platform-global, applied here in IAM auth mode): the Studio
  # resource + its two security groups, and passing the service role to
  # CreateStudio.
  statement {
    sid = "ManageEmrStudio"
    actions = [
      "elasticmapreduce:CreateStudio", "elasticmapreduce:DeleteStudio",
      "elasticmapreduce:DescribeStudio", "elasticmapreduce:UpdateStudio",
      "elasticmapreduce:ListStudios",
      "ec2:CreateSecurityGroup", "ec2:DeleteSecurityGroup",
      "ec2:DescribeSecurityGroups", "ec2:CreateTags",
      "ec2:AuthorizeSecurityGroupIngress", "ec2:AuthorizeSecurityGroupEgress",
      "ec2:RevokeSecurityGroupIngress", "ec2:RevokeSecurityGroupEgress",
      "ec2:DescribeVpcs", "ec2:DescribeSubnets",
    ]
    resources = ["*"]
  }
  statement {
    sid       = "PassEmrStudioServiceRole"
    actions   = ["iam:PassRole"]
    resources = ["arn:aws:iam::${local.account_id}:role/${var.name_prefix}-emr-studio-*"]
  }
  # NOTE: no iam:*SAMLProvider permissions. The EMR Studio IAM SAML provider is
  # created out-of-band by an IAM admin and referenced by ARN — this pipeline
  # never creates it (a permissions boundary may deny it, and it is a
  # sensitive account-global identity resource). See the emr-studio module.
}

resource "aws_iam_role_policy" "codebuild" {
  name   = "provisioner"
  role   = aws_iam_role.codebuild.id
  policy = data.aws_iam_policy_document.codebuild.json
}

resource "aws_codebuild_project" "provisioner" {
  name          = "${var.name_prefix}-dataplane-apply"
  description   = "Applies the dataplane global stack (account-baseline + EMR Studio). Run manually or from CI."
  service_role  = aws_iam_role.codebuild.arn
  build_timeout = 30
  tags          = local.tags

  # Serialize runs — concurrent terraform applies against one state are unsafe.
  concurrent_build_limit = 1

  artifacts {
    type = "NO_ARTIFACTS"
  }

  environment {
    compute_type = "BUILD_GENERAL1_SMALL"
    image        = "aws/codebuild/amazonlinux2-x86_64-standard:5.0"
    type         = "LINUX_CONTAINER"
  }

  source {
    type      = "GITHUB"
    location  = var.repo_clone_url
    buildspec = "pipeline/buildspec.yml"
  }

  source_version = var.repo_branch
}

# ── Cross-account runtime role (defense-in-depth, ABAC on tenantId) ─────────
# The backend assumes this with a tenantId session tag for job operations AND
# tenant provisioning/deprovisioning (POST /tenants, DELETE /tenants — the
# backend creates/tears down per-tenant resources directly, no pipeline).
# Every grant is conditioned on the resource/request tenantId tag matching
# the session tag, so a control-plane tenancy bug cannot cross tenants.
data "aws_iam_policy_document" "runtime_assume" {
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "AWS"
      identifiers = [var.backend_task_role_arn]
    }
  }
}

resource "aws_iam_role" "runtime" {
  name               = "${var.name_prefix}-dataplane-runtime"
  assume_role_policy = data.aws_iam_policy_document.runtime_assume.json
  tags               = local.tags
}

data "aws_iam_policy_document" "runtime" {
  statement {
    sid = "TenantScopedEmrJobs"
    actions = [
      "emr-serverless:StartJobRun", "emr-serverless:GetJobRun",
      "emr-serverless:CancelJobRun", "emr-serverless:ListJobRuns",
    ]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/tenantId"
      values   = ["$${aws:PrincipalTag/tenantId}"]
    }
  }
  # Per-job token secrets live in THIS account so the tenant execution roles
  # can read them account-locally; the backend manages their lifecycle
  # through this role. The backend tags each secret with tenantId, so
  # read/write/delete are ABAC-scoped to the session's tenant; CreateSecret
  # requires the matching request tag. Prefix is the configured one, not a
  # literal, so it can never drift from the backend's actual secret names.
  statement {
    sid       = "JobTokenSecretsCreate"
    actions   = ["secretsmanager:CreateSecret"]
    resources = ["arn:aws:secretsmanager:${local.region}:${local.account_id}:secret:${var.job_token_secret_prefix}*"]
    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/tenantId"
      values   = ["$${aws:PrincipalTag/tenantId}"]
    }
  }
  statement {
    sid = "JobTokenSecretsManage"
    actions = [
      "secretsmanager:PutSecretValue", "secretsmanager:GetSecretValue",
      "secretsmanager:DeleteSecret", "secretsmanager:DescribeSecret",
    ]
    resources = ["arn:aws:secretsmanager:${local.region}:${local.account_id}:secret:${var.job_token_secret_prefix}*"]
    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/tenantId"
      values   = ["$${aws:PrincipalTag/tenantId}"]
    }
  }
  # SageMaker jobs are tagged tenantId at creation; describe/stop are
  # ABAC-scoped to the session tenant, create requires the matching tag.
  statement {
    sid       = "SageMakerCreate"
    actions   = ["sagemaker:CreateTrainingJob"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/tenantId"
      values   = ["$${aws:PrincipalTag/tenantId}"]
    }
  }
  statement {
    sid       = "SageMakerManage"
    actions   = ["sagemaker:DescribeTrainingJob", "sagemaker:StopTrainingJob"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/tenantId"
      values   = ["$${aws:PrincipalTag/tenantId}"]
    }
  }
  statement {
    sid       = "PassTenantExecutionRoles"
    actions   = ["iam:PassRole"]
    resources = ["arn:aws:iam::${local.account_id}:role/${var.name_prefix}-tenant-*-exec"]
    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["emr-serverless.amazonaws.com", "sagemaker.amazonaws.com"]
    }
  }

  # Tag-on-create: StartJobRun/CreateApplication/CreateKey all attach the
  # tenantId tag at creation, which AWS authorizes via TagResource with the
  # REQUEST tag (the resource has no tag yet, so the ResourceTag-conditioned
  # grants below cannot match during creation).
  statement {
    sid       = "TenantTagOnCreate"
    actions   = ["emr-serverless:TagResource", "kms:TagResource"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/tenantId"
      values   = ["$${aws:PrincipalTag/tenantId}"]
    }
  }

  # ── Tenant provisioning / deprovisioning (direct boto3 from the backend) ──
  # Everything the backend creates carries a tenantId tag equal to the
  # session tag, keeping these grants ABAC-scoped like the job path.
  statement {
    sid       = "TenantProvisionEmrAppCreate"
    actions   = ["emr-serverless:CreateApplication"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/tenantId"
      values   = ["$${aws:PrincipalTag/tenantId}"]
    }
  }
  statement {
    sid = "TenantProvisionEmrAppManage"
    actions = [
      "emr-serverless:GetApplication", "emr-serverless:StopApplication",
      "emr-serverless:DeleteApplication", "emr-serverless:TagResource",
    ]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/tenantId"
      values   = ["$${aws:PrincipalTag/tenantId}"]
    }
  }
  # IAM has no tenantId tag on the session-tag axis to condition on the role
  # itself — the name pattern is the scope (same pattern PassRole uses).
  statement {
    sid = "TenantProvisionExecRoles"
    actions = [
      "iam:CreateRole", "iam:GetRole", "iam:TagRole",
      "iam:PutRolePolicy", "iam:DeleteRolePolicy", "iam:DeleteRole",
    ]
    resources = ["arn:aws:iam::${local.account_id}:role/${var.name_prefix}-tenant-*-exec"]
  }
  statement {
    sid       = "TenantProvisionKmsCreate"
    actions   = ["kms:CreateKey"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/tenantId"
      values   = ["$${aws:PrincipalTag/tenantId}"]
    }
  }
  statement {
    sid       = "TenantProvisionKmsManage"
    actions   = ["kms:DescribeKey", "kms:ScheduleKeyDeletion", "kms:TagResource"]
    resources = ["arn:aws:kms:${local.region}:${local.account_id}:key/*"]
    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/tenantId"
      values   = ["$${aws:PrincipalTag/tenantId}"]
    }
  }
  # Create/DeleteAlias evaluate against BOTH the alias and the target key.
  # Alias names follow the backend's KmsCipher convention
  # (alias/<name_prefix>-snowflake-<tenantId>).
  statement {
    sid     = "TenantProvisionKmsAliases"
    actions = ["kms:CreateAlias", "kms:DeleteAlias"]
    resources = [
      "arn:aws:kms:${local.region}:${local.account_id}:alias/${var.name_prefix}-snowflake-*",
      "arn:aws:kms:${local.region}:${local.account_id}:key/*",
    ]
  }
}

# When the org requires a permissions boundary on runtime-created roles,
# CreateRole is only allowed WITH the boundary attached — and the backend
# must set TENANT_ROLE_PERMISSIONS_BOUNDARY_ARN to the same ARN.
data "aws_iam_policy_document" "runtime_boundary_guard" {
  count = var.tenant_role_permissions_boundary_arn == "" ? 0 : 1

  statement {
    sid       = "DenyExecRoleCreateWithoutBoundary"
    effect    = "Deny"
    actions   = ["iam:CreateRole"]
    resources = ["arn:aws:iam::${local.account_id}:role/${var.name_prefix}-tenant-*-exec"]
    condition {
      test     = "StringNotEquals"
      variable = "iam:PermissionsBoundary"
      values   = [var.tenant_role_permissions_boundary_arn]
    }
  }
}

resource "aws_iam_role_policy" "runtime_boundary_guard" {
  count  = var.tenant_role_permissions_boundary_arn == "" ? 0 : 1
  name   = "tenant-role-boundary-guard"
  role   = aws_iam_role.runtime.id
  policy = data.aws_iam_policy_document.runtime_boundary_guard[0].json
}

resource "aws_iam_role_policy" "runtime" {
  name   = "tenant-abac"
  role   = aws_iam_role.runtime.id
  policy = data.aws_iam_policy_document.runtime.json
}
