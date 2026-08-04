output "studio_id" {
  description = "EMR Studio ID (module-created, or the admin-created studio_id when create_studio = false)."
  value       = local.studio_id_effective
}

output "url" {
  description = "Studio access URL — set this as the backend's EMR_STUDIO_URL (see backend/iac's ssm/emr/studio-url parameter). Module-created, or the passed-in studio_url when create_studio = false."
  value       = local.studio_url_effective
}

output "service_role_arn" {
  description = "Studio service role ARN."
  value       = aws_iam_role.service.arn
}

output "user_role_arn" {
  description = "SSO mode: Studio user role ARN — shared by every SSO session (platform-global; see README limitation). Null in IAM mode (see tier_role_arns)."
  value       = one(aws_iam_role.user[*].arn)
}

output "engine_security_group_id" {
  description = "Engine SG ID — attach this to any EMR Serverless application / cluster the Studio should be able to reach."
  value       = aws_security_group.engine.id
}

output "workspace_security_group_id" {
  description = "Workspace SG ID."
  value       = aws_security_group.workspace.id
}

output "session_policy_arns" {
  description = "SSO mode: session policy ARNs by tier (basic, intermediate), for wiring additional session_mappings outside this module. Null entries in IAM mode."
  value       = local.session_policy_arns
}

output "auth_mode" {
  description = "The Studio's authentication mode (\"SSO\" or \"IAM\")."
  value       = var.auth_mode
}

output "tier_role_arns" {
  description = "IAM mode: tier name (basic/intermediate) -> assumable role ARN the backend presigns with. Empty map in SSO mode. Feed these to the backend's EMR_STUDIO_BASIC_ROLE_ARN / EMR_STUDIO_INTERMEDIATE_ROLE_ARN and grant the backend task role sts:AssumeRole on them."
  value       = { for k, r in aws_iam_role.tier : k => r.arn }
}
