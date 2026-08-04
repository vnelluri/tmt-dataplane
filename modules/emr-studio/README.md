# modules/emr-studio — Terraform module: EMR Studio

Provisions the single, platform-global EMR Studio the backend deep-links users
into for notebook sessions. Applied by this repo's root (`module.emr_studio`),
in the dataplane account next to the EMR Serverless apps it attaches to. The
control-plane backend only **consumes** its outputs (it never applies it).

**`auth_mode` defaults to `"IAM"`** (no Identity Center — the backend presigns
per user; see "IAM authentication mode" below). Set `auth_mode = "SSO"` for the
Identity Center path (see "Prerequisites" and "Admin-owned Studio").

This is a **module** (no provider/backend blocks). The root already wires it
(default IAM mode):

```hcl
module "emr_studio" {
  source = "./modules/emr-studio"

  name_prefix         = var.name_prefix
  vpc_id              = var.vpc_id
  subnet_ids          = var.subnet_ids
  default_s3_location = "s3://${var.artifacts_bucket}/emr-studio-workspaces"

  # IAM mode (default) requires the principal(s) allowed to presign:
  backend_principal_arns = [var.backend_task_role_arn]
}

# Wire the outputs into the backend (see "IAM authentication mode"):
#   module.emr_studio.studio_id, module.emr_studio.tier_role_arns
```

For the SSO (Identity Center) path instead, set `auth_mode = "SSO"` and supply
`session_mappings` — its inputs and prerequisites are below.

## Prerequisites (out of scope for this module)

- **AWS IAM Identity Center must already be enabled** in this account/region,
  with your Entra ID tenant federated as an external IdP and SCIM-syncing the
  security groups documented in the platform README's naming convention
  (`myapp-platform-admin`, `myapp-{tenantId}-datascientist`, …). `auth_mode =
  "SSO"` depends on this; it is account-level AWS configuration, not
  something Terraform's `aws_emr_studio` resource can set up.
- `session_mappings` keys must match Identity Center identity **names**
  exactly (group names if `session_identity_type = "GROUP"`, the default).

## Admin-owned Studio (`create_studio = false`)

Creating an EMR Studio in SSO auth mode makes EMR register it as a managed
application in IAM Identity Center — the `CreateStudio` call internally invokes
`sso:CreateApplication` / `sso:CreateManagedApplicationInstance`. A locked-down
CI/CD role often can't do that (e.g. a permissions boundary with an explicit
deny on those actions), so `terraform apply` fails on the `aws_emr_studio`
resource even though the rest of the module would succeed.

Set `create_studio = false` to split the work:

- **This module still creates** the security groups, service/user roles, and
  the `basic`/`intermediate` session policies — none of which touch Identity
  Center — and exposes their ARNs/IDs as outputs.
- **An Identity Center admin creates the Studio out-of-band** (console, CLI, or
  their own Terraform with `sso:` permissions), passing this module's
  `service_role_arn`, `user_role_arn`, `engine_security_group_id`,
  `workspace_security_group_id`, plus your VPC/subnets and `default_s3_location`.
- **You pass the result back** via `studio_id` and `studio_url`; the module
  surfaces `studio_url` as the `url` output (so the SSM/`EMR_STUDIO_URL` wiring
  is unchanged) and uses `studio_id` for session mappings.

Deliberately **not** importing `aws_emr_studio` into this state is the safer
choice: since the CI/CD role can't `sso:DeleteManagedApplicationInstance`, a
`terraform destroy` of an imported Studio would fail — leaving it unmanaged
here means the pipeline can never break it.

**Session mappings** still reference the (now external) Studio and are created
by this module. `CreateStudioSessionMapping` calls
`sso:CreateApplicationAssignment` + identity-store reads — a *narrower*
permission than `CreateApplication`, so the boundary may allow it even when it
blocks Studio creation. If it doesn't, leave `session_mappings = {}` and have
the admin own the mappings too.

Ordering: apply this module (roles/SGs/policies) → hand the outputs to the
admin → admin creates the Studio → re-apply with `studio_id`/`studio_url` set
(and `session_mappings` if permitted).

## IAM authentication mode (`auth_mode = "IAM"`)

An alternative to Identity Center entirely. In SSO mode `CreateStudio` registers
the Studio in IAM Identity Center (the `sso:` writes a locked-down CI/CD role
can't do); IAM mode has **no Identity Center**, so none of that applies — no
federation, no SCIM, no session mappings, no `sso:` permissions.

Set `auth_mode = "IAM"` and the module instead creates **two assumable tier
roles** (`…-emr-studio-basic`, `…-emr-studio-intermediate`) trusted by
`backend_principal_arns`. The backend assumes the tier role for a user's role
(`RoleSessionName` = the user's stable id) and calls
`elasticmapreduce:CreateStudioPresignedUrl` to deep-link them in — mirroring the
SageMaker presign path. Per-user Workspace ownership still holds: EMR Studio tags
each Workspace with `creatorUserId = ${aws:userId}`, which embeds the
`RoleSessionName`, so the tier roles' collaboration permissions are creator-scoped.

```hcl
module "emr_studio" {
  source                 = "./modules/emr-studio"
  name_prefix            = var.name_prefix
  vpc_id                 = var.vpc_id
  subnet_ids             = var.subnet_ids
  default_s3_location    = "s3://${var.artifacts_bucket}/emr-studio-workspaces"
  auth_mode              = "IAM"
  backend_principal_arns = [var.backend_task_role_arn]   # who may presign
  # session_mappings is ignored in IAM mode
}
```

Wire back: feed `tier_role_arns` to the backend's `EMR_STUDIO_BASIC_ROLE_ARN` /
`EMR_STUDIO_INTERMEDIATE_ROLE_ARN` and `emr_studio_tier_role_arns` (so the task
role gets `sts:AssumeRole`), set `EMR_AUTH_MODE=IAM` and `EMR_STUDIO_ID`. Full
design + trade-offs (attribution, MRM) in the tmt monorepo's
`docs/EMR_STUDIO_IAM_MODE.md`.

## Known limitation (matches the platform README)

The Studio is **platform-global** while jobs/data are **per-tenant** — the
shared `user_role` and the two session policies (`basic`, `intermediate`)
grant EMR Serverless browse/attach and Workspace-bucket access, but cannot
scope S3 by tenant prefix the way per-tenant EMR Serverless execution roles
do for job submission. Per-tenant Studios are a later release; until then,
treat Studio-launched notebook access as platform-wide within whichever tier
a user's group is mapped to.

## What this module does NOT do

- Create or manage IAM Identity Center itself, its external IdP federation,
  or its users/groups.
- Create per-tenant EMR Serverless applications — those come from
  `tmt-dataplane`, same as job-submission compute (see `backend/iac/README.md`).
- Grant the backend any EMR Studio API permissions — the backend only reads
  the static URL from SSM and redirects the browser; no API calls happen
  against EMR Studio at request time.

## Resources created

- Two security groups (`engine`, `workspace`) wired per AWS's documented
  two-SG model (Workspace → Engine on 18888 only).
- A service role (assumed by the EMR Studio control plane) and a shared user
  role (assumed by federated sessions), each scoped to the Workspace S3
  location plus read/attach access to EMR Serverless.
- Two customer-managed session policies (`basic`, `intermediate`) used by
  `session_mappings`.
- The `aws_emr_studio` resource itself (unless `create_studio = false`) and its
  `aws_emr_studio_session_mapping` entries.

## Variables of note

- `default_s3_location` — where Workspace `.ipynb` files are stored; the
  module derives bucket/prefix from this for IAM scoping, so pass a real
  `s3://bucket[/prefix]` URI.
- `workspace_egress_cidrs` — defaults to `0.0.0.0/0` on 443 for the Workspace
  SG (Studio control plane, git, package indexes); restrict to your VPC
  endpoint / NAT ranges in production.
- `session_mappings` — `map(string)` of identity name → `"basic"` |
  `"intermediate"`. Empty by default; without at least one entry, nobody can
  open a session against the Studio.
- `create_studio` — `bool`, default `true`. Set `false` for the admin-owned
  Studio split above; then `studio_id` and `studio_url` are **required**.
- `studio_id` / `studio_url` — identifiers of an externally created Studio,
  used only when `create_studio = false`.
- `auth_mode` — `"IAM"` (default) or `"SSO"`; see "IAM authentication mode".
- `backend_principal_arns` — IAM mode only; principals allowed to assume the
  tier roles. **Required** when `auth_mode = "IAM"`.
- `emr_serverless_runtime_role_arn_pattern` — IAM mode only; role(s) the
  intermediate tier may `iam:PassRole` to start jobs (default `*`).
