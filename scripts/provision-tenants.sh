#!/usr/bin/env bash
# Declarative tenant reconcile:
#   1. Read the desired tenant set from the platform API (source of truth).
#   2. terraform apply the full state (idempotent; heals lost events).
#   3. Write provisioned resource IDs back for every non-active tenant.
#
# Required env:
#   PLATFORM_API_URL     e.g. https://ml.example.com
#   PLATFORM_API_TOKEN   PlatformAdmin bearer token (injected from Secrets
#                        Manager by the CodeBuild environment)
set -euo pipefail

auth=(-H "Authorization: Bearer ${PLATFORM_API_TOKEN}")
api="${PLATFORM_API_URL%/}"

echo "==> Fetching desired tenants from ${api}/tenants"
tenants_json=$(curl -sfS "${auth[@]}" "${api}/tenants?pageSize=500")

# Suspended tenants keep their resources (jobs are blocked at the API layer);
# only the tenant *set* comes from the API. Capacity overrides may be layered
# in via terraform.tfvars if a tenant needs more than the default cap.
echo "${tenants_json}" | jq '{
  tenants: (.items | map({(.tenantId): {name: .name}}) | add // {})
}' > tenants.auto.tfvars.json
count=$(echo "${tenants_json}" | jq '.items | length')
echo "==> Reconciling ${count} tenant(s)"

terraform init -input=false
terraform apply -input=false -auto-approve

echo "==> Writing back provisioning results"
outputs=$(terraform output -json tenants)

echo "${tenants_json}" | jq -r '.items[] | select(.provisioningStatus != "active") | .tenantId' |
while read -r tenant_id; do
  [ -z "${tenant_id}" ] && continue
  body=$(echo "${outputs}" | jq --arg id "${tenant_id}" '{
    status: "active",
    emrApplicationId: .[$id].emrApplicationId,
    executionRoleArn: .[$id].executionRoleArn,
    kmsKeyArn:        .[$id].kmsKeyArn,
    s3BucketName:     .[$id].s3BucketName
  }')
  echo "    -> ${tenant_id}"
  curl -sfS "${auth[@]}" -X PUT \
    -H "Content-Type: application/json" \
    -d "${body}" \
    "${api}/tenants/${tenant_id}/provisioning" > /dev/null
done

echo "==> Reconcile complete"
