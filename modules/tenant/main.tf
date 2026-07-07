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

  tags = merge(var.tags, {
    platform   = var.name_prefix # backend IAM policy conditions on this tag
    tenantId   = var.tenant_id   # cost allocation + ABAC
    tenantName = var.tenant_name
    managedBy  = "tmt-dataplane"
  })
}

# ── EMR Serverless application (idle apps cost nothing; the capacity cap is
#    the AWS-enforced per-tenant quota) ──────────────────────────────────────
resource "aws_emrserverless_application" "tenant" {
  name          = "${var.name_prefix}-${var.tenant_id}"
  release_label = var.release_label
  type          = "spark"
  tags          = local.tags

  maximum_capacity {
    cpu    = "${var.max_concurrent_vcpus} vCPU"
    memory = "${coalesce(var.max_memory_gb, var.max_concurrent_vcpus * 8)} GB"
  }

  network_configuration {
    subnet_ids         = var.subnet_ids
    security_group_ids = var.security_group_ids
  }
}

# ── Per-tenant KMS key ───────────────────────────────────────────────────────
# The key POLICY grants the control-plane backend task role Encrypt/Decrypt —
# this is what makes the account split work: the backend uses the key ARN
# (written back to Tenant.kmsKeyArn) with its own credentials; aliases only
# matter for same-account deployments.
data "aws_iam_policy_document" "snowflake_key" {
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
    sid       = "ControlPlaneBackendUse"
    actions   = ["kms:Encrypt", "kms:Decrypt", "kms:DescribeKey"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = [var.backend_task_role_arn]
    }
  }
}

resource "aws_kms_key" "snowflake" {
  description         = "Snowflake OAuth token encryption for ${var.tenant_id}"
  enable_key_rotation = true
  policy              = data.aws_iam_policy_document.snowflake_key.json
  tags                = local.tags
}

resource "aws_kms_alias" "snowflake" {
  name          = "alias/${var.name_prefix}-snowflake-${var.tenant_id}"
  target_key_id = aws_kms_key.snowflake.key_id
}

# ── Tenant S3 prefix marker in the shared artifacts bucket ──────────────────
resource "aws_s3_object" "prefix_marker" {
  bucket  = var.artifacts_bucket
  key     = "${var.tenant_id}/.keep"
  content = ""
}

# ── Execution role: the identity tenant training jobs run as. Name must match
#    the pattern granted iam:PassRole in tmt//backend/iac
#    (ml-platform-tenant-*-exec). ───────────────────────────────────────────
data "aws_iam_policy_document" "exec_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["emr-serverless.amazonaws.com", "sagemaker.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "execution" {
  name               = "${var.name_prefix}-tenant-${var.tenant_id}-exec"
  assume_role_policy = data.aws_iam_policy_document.exec_assume.json
  tags               = local.tags
}

data "aws_iam_policy_document" "execution" {
  statement {
    sid       = "TenantPrefixList"
    actions   = ["s3:ListBucket"]
    resources = ["arn:aws:s3:::${var.artifacts_bucket}"]
    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["${var.tenant_id}/*"]
    }
  }

  statement {
    sid     = "TenantPrefixObjects"
    actions = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = [
      "arn:aws:s3:::${var.artifacts_bucket}/${var.tenant_id}/*"
    ]
  }

  # Read the short-lived per-job Snowflake token secret (ARN is injected by
  # the platform at submission; secrets are created under this prefix).
  statement {
    sid     = "JobTokenSecrets"
    actions = ["secretsmanager:GetSecretValue"]
    resources = [
      "arn:aws:secretsmanager:${local.region}:${local.account_id}:secret:${var.job_token_secret_prefix}*"
    ]
  }

  statement {
    sid       = "TenantKmsDecrypt"
    actions   = ["kms:Decrypt", "kms:DescribeKey"]
    resources = [aws_kms_key.snowflake.arn]
  }

  statement {
    sid = "JobLogs"
    actions = [
      "logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents",
      "logs:DescribeLogGroups", "logs:DescribeLogStreams",
    ]
    resources = ["arn:aws:logs:${local.region}:${local.account_id}:*"]
  }
}

resource "aws_iam_role_policy" "execution" {
  name   = "tenant-scoped-access"
  role   = aws_iam_role.execution.id
  policy = data.aws_iam_policy_document.execution.json
}
