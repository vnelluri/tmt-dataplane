output "artifacts_bucket" {
  description = "Shared artifacts bucket name."
  value       = aws_s3_bucket.artifacts.bucket
}

output "artifacts_kms_key_arn" {
  description = "CMK the artifacts bucket is SSE-encrypted with; tenant execution roles need decrypt/generate on it."
  value       = aws_kms_key.artifacts.arn
}

output "runtime_role_arn" {
  description = "Cross-account runtime role for tenant-tagged job operations AND tenant provisioning/deprovisioning — set the backend's DATAPLANE_RUNTIME_ROLE_ARN to this."
  value       = aws_iam_role.runtime.arn
}

output "codebuild_project_name" {
  description = "Apply-pipeline CodeBuild project for the global stack (run manually or from CI)."
  value       = aws_codebuild_project.provisioner.name
}
