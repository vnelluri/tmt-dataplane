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

resource "aws_s3_bucket_server_side_encryption_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
    }
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

# ── Provisioning event bus: the control-plane backend PutEvents here
#    cross-account (TENANT_PROVISIONING_EVENT_BUS = this bus's ARN) ──────────
resource "aws_cloudwatch_event_bus" "provisioning" {
  name = "${var.name_prefix}-provisioning"
  tags = local.tags
}

data "aws_iam_policy_document" "bus_policy" {
  statement {
    sid       = "AllowControlPlanePutEvents"
    actions   = ["events:PutEvents"]
    resources = [aws_cloudwatch_event_bus.provisioning.arn]
    principals {
      type        = "AWS"
      identifiers = [var.backend_task_role_arn]
    }
  }
}

resource "aws_cloudwatch_event_bus_policy" "provisioning" {
  event_bus_name = aws_cloudwatch_event_bus.provisioning.name
  policy         = data.aws_iam_policy_document.bus_policy.json
}

# ── Rule: TenantProvisioningRequested → CodeBuild reconcile ─────────────────
resource "aws_cloudwatch_event_rule" "tenant_provisioning" {
  name           = "${var.name_prefix}-tenant-provisioning"
  event_bus_name = aws_cloudwatch_event_bus.provisioning.name
  tags           = local.tags

  event_pattern = jsonencode({
    source        = ["ml-platform.tenants"]
    "detail-type" = ["TenantProvisioningRequested"]
  })
}

data "aws_iam_policy_document" "events_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "events_to_codebuild" {
  name               = "${var.name_prefix}-provisioning-events-role"
  assume_role_policy = data.aws_iam_policy_document.events_assume.json
  tags               = local.tags
}

resource "aws_iam_role_policy" "events_to_codebuild" {
  name = "start-build"
  role = aws_iam_role.events_to_codebuild.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["codebuild:StartBuild"]
      Resource = aws_codebuild_project.provisioner.arn
    }]
  })
}

resource "aws_cloudwatch_event_target" "codebuild" {
  rule           = aws_cloudwatch_event_rule.tenant_provisioning.name
  event_bus_name = aws_cloudwatch_event_bus.provisioning.name
  arn            = aws_codebuild_project.provisioner.arn
  role_arn       = aws_iam_role.events_to_codebuild.arn
}

# ── CodeBuild project: runs scripts/provision-tenants.sh (declarative
#    reconcile of ALL tenants from the platform API) ─────────────────────────
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

# The provisioner needs to manage exactly what this repo declares: EMR
# Serverless apps, tenant-scoped IAM roles, KMS keys/aliases, S3, events, and
# its own logs/state. Tighten further with a permissions boundary if your
# account standards require it.
data "aws_iam_policy_document" "codebuild" {
  statement {
    sid = "ManageTenantResources"
    actions = [
      "emr-serverless:*",
      "kms:*",
      "s3:*",
      "events:*",
      "logs:*",
    ]
    resources = ["*"]
  }
  statement {
    sid = "ManageTenantRoles"
    actions = [
      "iam:CreateRole", "iam:DeleteRole", "iam:GetRole", "iam:TagRole",
      "iam:PutRolePolicy", "iam:DeleteRolePolicy", "iam:GetRolePolicy",
      "iam:ListRolePolicies", "iam:ListAttachedRolePolicies",
      "iam:ListInstanceProfilesForRole", "iam:UpdateAssumeRolePolicy",
    ]
    resources = [
      "arn:aws:iam::${local.account_id}:role/${var.name_prefix}-tenant-*-exec"
    ]
  }
  statement {
    sid       = "ReadApiToken"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [var.platform_api_token_secret_arn]
  }
}

resource "aws_iam_role_policy" "codebuild" {
  name   = "provisioner"
  role   = aws_iam_role.codebuild.id
  policy = data.aws_iam_policy_document.codebuild.json
}

resource "aws_codebuild_project" "provisioner" {
  name          = "${var.name_prefix}-tenant-provisioner"
  description   = "Reconciles per-tenant dataplane resources from the platform API."
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

    environment_variable {
      name  = "PLATFORM_API_URL"
      value = var.platform_api_url
    }
    environment_variable {
      name  = "PLATFORM_API_TOKEN"
      type  = "SECRETS_MANAGER"
      value = var.platform_api_token_secret_arn
    }
  }

  source {
    type      = "GITHUB"
    location  = var.repo_clone_url
    buildspec = "pipeline/buildspec.yml"
  }

  source_version = var.repo_branch
}

# ── Cross-account runtime role (defense-in-depth, ABAC on tenantId) ─────────
# The backend may assume this with a tenantId session tag for job operations;
# the EMR permissions only match applications tagged with that same tenantId,
# so a control-plane tenancy bug cannot cross tenants.
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
  # through this role.
  statement {
    sid = "JobTokenSecrets"
    actions = [
      "secretsmanager:CreateSecret", "secretsmanager:PutSecretValue",
      "secretsmanager:GetSecretValue", "secretsmanager:DeleteSecret",
      "secretsmanager:DescribeSecret",
    ]
    resources = [
      "arn:aws:secretsmanager:${local.region}:${local.account_id}:secret:ml-platform/job-tokens/*"
    ]
  }
  statement {
    sid = "SageMakerTrainingJobs"
    actions = [
      "sagemaker:CreateTrainingJob", "sagemaker:DescribeTrainingJob",
      "sagemaker:StopTrainingJob",
    ]
    resources = ["*"]
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
}

resource "aws_iam_role_policy" "runtime" {
  name   = "tenant-abac"
  role   = aws_iam_role.runtime.id
  policy = data.aws_iam_policy_document.runtime.json
}
