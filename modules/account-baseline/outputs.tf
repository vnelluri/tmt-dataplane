output "artifacts_bucket" {
  description = "Shared artifacts bucket name."
  value       = aws_s3_bucket.artifacts.bucket
}

output "event_bus_arn" {
  description = "Set the backend's TENANT_PROVISIONING_EVENT_BUS to this ARN."
  value       = aws_cloudwatch_event_bus.provisioning.arn
}

output "runtime_role_arn" {
  description = "Cross-account runtime role for tenant-tagged job operations."
  value       = aws_iam_role.runtime.arn
}

output "codebuild_project_name" {
  description = "Provisioner CodeBuild project (also runnable manually to reconcile)."
  value       = aws_codebuild_project.provisioner.name
}
