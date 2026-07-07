output "emr_application_id" {
  description = "Per-tenant EMR Serverless application ID → Tenant.emrApplicationId."
  value       = aws_emrserverless_application.tenant.id
}

output "execution_role_arn" {
  description = "Per-tenant execution role ARN → Tenant.executionRoleArn."
  value       = aws_iam_role.execution.arn
}

output "s3_prefix" {
  description = "Tenant artifact prefix → Tenant.s3BucketName."
  value       = "s3://${var.artifacts_bucket}/${var.tenant_id}/"
}

output "kms_key_arn" {
  description = "Per-tenant Snowflake token KMS key (grant Encrypt/Decrypt to the backend task role)."
  value       = aws_kms_key.snowflake.arn
}
