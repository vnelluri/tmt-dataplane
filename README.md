# tmt-dataplane — dataplane-account global stack

Terraform for everything the ML training platform needs **inside a dataplane
AWS account** that is *global* (applied once per account). Pipelines are set
up per AWS account, so this repo is deployed by the dataplane account's own
pipeline — separately from the `tmt` monorepo, whose `backend/iac` /
`frontend/iac` modules deploy the control-plane ECS services.

**Per-tenant resources are NOT managed here.** The control-plane backend
creates and tears them down **directly via boto3** through the runtime role
(`POST /tenants` / `DELETE /tenants` in `tmt`): EMR Serverless application
(interactive endpoint enabled), execution role
`ml-platform-tenant-<id>-exec`, per-tenant KMS key
(`alias/ml-platform-snowflake-<id>`), and the S3 prefix marker. This repo's
job is to stand up the account so the backend can do that safely.

## What it manages

**`modules/account-baseline`** — one instance per dataplane account:

- Shared artifacts S3 bucket (versioned, SSE with a CMK, public access
  blocked) + a bucket policy granting the control-plane backend task role
  direct cross-account access (S3 browse/validation uses the backend's own
  identity)
- `ml-platform-dataplane-runtime` cross-account role — THE mechanism of the
  account split: the backend assumes it with a `tenantId` session tag for
  every EMR/job-secret operation **and for tenant provisioning/
  deprovisioning** (set the backend's `DATAPLANE_RUNTIME_ROLE_ARN` to this
  role's ARN). Every grant is ABAC-constrained on the `tenantId` tag, so a
  request tagged for tenant A cannot touch tenant B's resources even if the
  backend has a tenancy bug. Provisioning grants: `CreateApplication` /
  `CreateKey` require the matching `tenantId` *request* tag; teardown
  (`Stop/DeleteApplication`, `ScheduleKeyDeletion`) requires the matching
  *resource* tag; execution-role management is scoped to the
  `…-tenant-*-exec` name pattern, with an optional deny-without-boundary
  guard (`tenant_role_permissions_boundary_arn` — must match the backend's
  `TENANT_ROLE_PERMISSIONS_BOUNDARY_ARN`)
- A CodeBuild **apply pipeline** for this repo's global stack
  (`pipeline/buildspec.yml` — plain `terraform apply`; run manually or from
  CI)

**Platform-global EMR Studio** (root `module.emr_studio`, in
`modules/emr-studio`, IAM auth mode) — applied here because it is
applied-once-global like the baseline, lives next to the EMR Serverless apps
its Workspaces attach to, and stores Workspaces in this account's artifacts
bucket. No Identity Center: users reach the Studio access URL and federate in
through Entra (SAML), assuming the `basic`/`intermediate` tier roles via
`AssumeRoleWithSAML`. The backend makes no EMR Studio API call. Wire the
`emr_studio_url` root output into the backend's `EMR_STUDIO_URL`; hand
`emr_studio_tier_role_arns` + `emr_studio_saml_provider_arn` to the Entra
admin (`docs/EMR_STUDIO_FEDERATION_REQUEST.md` in the tmt monorepo).

## Tenant lifecycle (owned by the backend, not this repo)

```
POST /tenants (control plane)
   │ assume ml-platform-dataplane-runtime (+tenantId session tag)
   ├─ kms:CreateKey + alias ml-platform-snowflake-<id>
   ├─ iam:CreateRole ml-platform-tenant-<id>-exec  (+ org boundary)
   ├─ emr-serverless:CreateApplication (interactive endpoint on)
   └─ S3 prefix marker → tenant active

DELETE /tenants/{id} (suspend first)
   └─ reverse teardown; KMS key gets a 30-day recovery window;
      S3 artifacts kept unless ?deleteData=true
```

Idempotent and resumable on both sides — see `tmt` ARCHITECTURE §3.7/§3.9.

## Deploying

1. Fill in the S3 state backend in `providers.tf` and the account-specific
   values in a `terraform.tfvars` (see `terraform.tfvars.example`).
2. `terraform init && terraform apply` once by hand to bootstrap; after that
   the CodeBuild apply pipeline (or your CI) drives changes.
3. Wire the outputs into the control-plane backend:
   `DATAPLANE_RUNTIME_ROLE_ARN=<runtime_role_arn>`,
   SSM `/ml-platform/emr/studio-url` = `<emr_studio_url>`.

Default service quota is ~25 EMR Serverless applications per account/region —
request an increase early, and shard tenants across additional dataplane
accounts (one more instance of this repo) if tenant count grows past that.
