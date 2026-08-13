# modules/emr-studio — Terraform module: EMR Studio

Provisions the single, platform-global EMR Studio the backend deep-links users
into for notebook sessions. Applied by this repo's root (`module.emr_studio`),
in the dataplane account next to the EMR Serverless apps it attaches to. The
control-plane backend only **consumes** its outputs (it never applies it).

**`auth_mode` defaults to `"IAM"`** (no Identity Center — users federate in via
SAML and the backend just deep-links the access URL; see "IAM authentication
mode" below). Set `auth_mode = "SSO"` for the Identity Center path (see
"Prerequisites" and "Admin-owned Studio").

This is a **module** (no provider/backend blocks). The root already wires it
(default IAM mode):

```hcl
module "emr_studio" {
  source = "./modules/emr-studio"

  name_prefix         = var.name_prefix
  vpc_id              = var.vpc_id
  subnet_ids          = var.subnet_ids
  default_s3_location = "s3://${var.artifacts_bucket}/emr-studio-workspaces"

  # IAM mode (default) requires a SAML provider (Entra) — supply exactly one:
  saml_provider_arn = var.emr_studio_saml_provider_arn        # existing IdP, OR
  # saml_metadata_document = var.emr_studio_saml_metadata_document  # create one
}

# Wire the outputs:
#   module.emr_studio.url            -> backend EMR_STUDIO_URL
#   module.emr_studio.tier_role_arns + .saml_provider_arn -> Entra "Role" claim
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

No Identity Center. In SSO mode `CreateStudio` registers the Studio in IAM
Identity Center (the `sso:` writes a locked-down CI/CD role can't do); IAM mode
makes **no `sso:` calls** — access is through the Studio **access URL** +
**IAM federation to your IdP (Entra)**.

Users reach the Studio access URL, federate in through the SAML IdP, and assume
one of the two per-tier roles (`…-emr-studio-basic`, `…-emr-studio-intermediate`)
via **`sts:AssumeRoleWithSAML`** — the Entra "Role" claim maps a user's group to
the basic or intermediate role ARN. AWS's hosted flow then calls
`CreateStudioPresignedUrl` (authorized by the role's own permission) to sign the
user in. **The backend makes no EMR Studio API call** — it only deep-links the
access URL (`CreateStudioPresignedUrl` is not in the boto3 SDK). Per-user
Workspace ownership holds: EMR Studio tags each Workspace with
`creatorUserId = ${aws:userId}`, which embeds the federated session identity, so
the tier roles' collaboration permissions are creator-scoped.

```hcl
module "emr_studio" {
  source              = "./modules/emr-studio"
  name_prefix         = var.name_prefix
  vpc_id              = var.vpc_id
  subnet_ids          = var.subnet_ids
  default_s3_location = "s3://${var.artifacts_bucket}/emr-studio-workspaces"
  auth_mode           = "IAM"
  # Federation to Entra — supply exactly one (session_mappings is ignored):
  saml_provider_arn      = var.emr_studio_saml_provider_arn      # existing IdP, OR
  saml_metadata_document = var.emr_studio_saml_metadata_document # create one
}
```

`saml_provider_arn` (admin-created provider, referenced) is the safer path — a
permissions boundary may deny `iam:CreateSAMLProvider`, the same class of block
that pushed us off SSO. Use `saml_metadata_document` only if the CI/CD role is
allowed to create the provider.

Wire back: set the backend's `EMR_STUDIO_URL` to the module's **`url`** output
(the backend needs nothing else) and `EMR_AUTH_MODE=IAM`. Hand
`tier_role_arns` + `saml_provider_arn` to the Entra admin for the "Role" claim.
Full design + the Entra setup steps in the tmt monorepo's
`docs/EMR_STUDIO_IAM_MODE.md` and `docs/EMR_STUDIO_FEDERATION_REQUEST.md`.

## Known limitation (matches the platform README)

The Studio is **platform-global** while jobs/data are **per-tenant** — the
shared `user_role` and the two session policies (`basic`, `intermediate`)
grant EMR Serverless browse/attach and Workspace-bucket access, but cannot
scope S3 by tenant prefix the way per-tenant EMR Serverless execution roles
do for job submission. Per-tenant Studios are a later release; until then,
treat Studio-launched notebook access as platform-wide within whichever tier
a user's group is mapped to.

## What this module does NOT do

- Configure the Entra tenant / SAML app itself, or manage its users/groups.
  (In IAM mode it *creates the AWS-side IAM SAML provider* from the metadata you
  supply — or references one you pass by ARN — but the Entra-side app, claims,
  and group assignments are the admin's job: `docs/EMR_STUDIO_FEDERATION_REQUEST.md`.)
- Create or manage IAM Identity Center itself (SSO mode's IdP).
- Create per-tenant EMR Serverless applications — those come from
  `tmt-dataplane`, same as job-submission compute (see `backend/iac/README.md`).
- Grant the backend any EMR Studio API permissions — the backend only reads
  the access URL from SSM and redirects the browser; no API calls happen
  against EMR Studio at request time (in either mode).

## Resources created

- Two security groups (`engine`, `workspace`) wired per AWS's documented
  two-SG model (Workspace → Engine on 18888 only).
- A service role (assumed by the EMR Studio control plane).
- **SSO mode:** a shared `user_role`, two customer-managed session policies
  (`basic`, `intermediate`), and `aws_emr_studio_session_mapping` entries.
- **IAM mode:** two per-tier roles (`basic`, `intermediate`) trusted by the
  SAML provider for `sts:AssumeRoleWithSAML`, plus (when
  `saml_metadata_document` is set) the `aws_iam_saml_provider` itself.
- The `aws_emr_studio` resource (unless `create_studio = false`).

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
- `saml_provider_arn` / `saml_metadata_document` — IAM mode only; the SAML IdP
  (Entra) the tier roles federate to. Supply **exactly one** — the ARN of an
  existing provider, or the metadata XML to have the module create one.
  **Required** when `auth_mode = "IAM"`.
- `emr_serverless_runtime_role_arn_pattern` — IAM mode only; role(s) the
  intermediate tier may `iam:PassRole` to start jobs (default `*`).
