# tmt-dataplane — per-tenant compute provisioning (dataplane account)

Terraform for everything the ML training platform needs **inside a dataplane
AWS account**. Pipelines are set up per AWS account, so this repo is deployed
by the dataplane account's own pipeline — separately from the `tmt` monorepo,
whose `backend/iac` / `frontend/iac` modules deploy the control-plane ECS
services.

## What it manages

**`modules/account-baseline`** — one instance per dataplane account:

- Shared artifacts S3 bucket (versioned, SSE, public access blocked)
- `ml-platform-provisioning` EventBridge bus with a resource policy that lets
  the control-plane backend `PutEvents` cross-account (set the backend's
  `TENANT_PROVISIONING_EVENT_BUS` to this bus ARN)
- EventBridge rule on `TenantProvisioningRequested` → CodeBuild project that
  runs this repo's reconcile (`pipeline/buildspec.yml`)
- `ml-platform-dataplane-runtime` cross-account role — THE mechanism of the
  account split: the backend assumes it with a `tenantId` session tag for
  every EMR and job-secret operation (set the backend's
  `DATAPLANE_RUNTIME_ROLE_ARN` to this role's ARN), and its permissions are
  ABAC-constrained so a request tagged for tenant A cannot touch tenant B's
  application even if the backend has a tenancy bug
- Artifacts **bucket policy** and per-tenant **KMS key policies** granting
  the control-plane backend task role direct cross-account access (S3
  browse/validation and Snowflake-token encryption use the backend's own
  identity with full ARNs — the tenant's key ARN reaches the backend via the
  provisioning write-back)

**`modules/tenant`** — one instance per tenant (`for_each` over `var.tenants`):

- EMR Serverless application with `maximum_capacity` as the hard per-tenant
  concurrency cap (tagged `platform` + `tenantId` — the backend's IAM policy
  and cost-allocation reports key off these tags)
- Execution role `ml-platform-tenant-<id>-exec`, assumable by EMR Serverless
  and SageMaker, scoped to the tenant's S3 prefix, the platform's job-token
  secrets, and the tenant's KMS key
- Per-tenant KMS key with alias `ml-platform-snowflake-<id>` (matches the
  backend `KmsCipher` alias convention)
- The tenant's `s3://<bucket>/<tenantId>/` prefix marker

## Provisioning flow (reconcile, not imperative)

The platform API is the source of truth for which tenants should exist:

```
POST /tenants (control plane)             this repo's pipeline (dataplane acct)
        │                                            │
        ├─ tenant stored, status=pending             │
        └─ PutEvents ─────────► EventBridge bus ──► CodeBuild
                                                     │  scripts/provision-tenants.sh
                                                     │  1. GET /tenants from platform API
                                                     │  2. terraform apply (all tenants)
                                                     │  3. PUT /tenants/{id}/provisioning
                                                     │     (emrApplicationId, executionRoleArn,
                                                     ▼      s3BucketName → status=active)
```

Because step 2 applies the **full desired state** every run, a lost event or
failed run is self-healing: the next trigger (or a scheduled/manual run)
converges everything.

## Deploying

1. Fill in the S3 state backend in `providers.tf` and the account-specific
   values in a `terraform.tfvars`.
2. `terraform init && terraform apply` once by hand to bootstrap the baseline
   (bus, CodeBuild); after that the pipeline drives itself.
3. Point the control-plane backend at the bus:
   `TENANT_PROVISIONING_EVENT_BUS=<event_bus_arn output>`.

Default service quota is ~25 EMR Serverless applications per account/region —
request an increase early, and shard tenants across additional dataplane
accounts (one more instance of this repo's pipeline) if tenant count grows
past that.
