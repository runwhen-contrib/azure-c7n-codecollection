#!/bin/bash
# stg-audit.sh – Audit changes to Azure Storage Accounts
# Outputs two JSON files:
#   stg_changes_success.json – successful operations
#   stg_changes_failed.json  – failed operations
# Environment variables:
#   AZURE_SUBSCRIPTION_ID       – subscription to query (default: current)
#   AZURE_RESOURCE_GROUP        – resource group containing storage accounts (required)
#   AZURE_ACTIVITY_LOG_OFFSET   – time window e.g. 24h, 7d (default: 24h)

set -euo pipefail

SUCCESS_OUTPUT="stg_changes_success.json"
FAILED_OUTPUT="stg_changes_failed.json"
echo "{}" > "$SUCCESS_OUTPUT"
echo "{}" > "$FAILED_OUTPUT"

# Select subscription
if [ -z "${AZURE_SUBSCRIPTION_ID:-}" ]; then
  subscription=$(az account show --query "id" -o tsv)
else
  subscription="$AZURE_SUBSCRIPTION_ID"
fi
az account set --subscription "$subscription"

# Resource group validation
if [ -z "${AZURE_RESOURCE_GROUP:-}" ]; then
  echo "Error: AZURE_RESOURCE_GROUP must be set" >&2
  exit 1
fi

TIME_OFFSET="${AZURE_ACTIVITY_LOG_OFFSET:-24h}"
accounts=$(az storage account list -g "$AZURE_RESOURCE_GROUP" --query "[].id" -o tsv)

if [ -z "$accounts" ]; then
  echo "No storage accounts found in resource group $AZURE_RESOURCE_GROUP"
  exit 0
fi

tmp_success="$(mktemp)"
tmp_failed="$(mktemp)"
echo "{}" > "$tmp_success"
echo "{}" > "$tmp_failed"

for account in $accounts; do
  stg_name=$(basename "$account")
  logs=$(az monitor activity-log list \
    --resource-id "$account" \
    --offset "$TIME_OFFSET" \
    --output json)

  echo "$logs" | jq --arg acc "$stg_name" '
    map(select(.operationName.value | test("write|delete")) | {
      stgName: $acc,
      operation: (.operationName.value | split("/") | last),
      operationDisplay: .operationName.localizedValue,
      timestamp: .eventTimestamp,
      caller: .caller,
      changeStatus: .status.value,
      resourceId: .resourceId,
      correlationId: .correlationId,
      resourceUrl: ("https://portal.azure.com/#resource" + .resourceId),
      security_classification:
        (if .operationName.value | test("delete") then "High"
         elif .operationName.value | test("listKeys|regenerateKey|listAccountSas") then "Critical"
         elif .operationName.value | test("write|setAccessPolicy") then "Medium"
         else "Info" end),
      reason:
        (if .operationName.value | test("delete") then "Deleting a storage account or sub-resource removes data permanently"
         elif .operationName.value | test("listKeys") then "Listing account keys exposes credentials that grant full control"
         elif .operationName.value | test("regenerateKey") then "Key regeneration usually occurs during key rotation or after a suspected compromise"
         elif .operationName.value | test("listAccountSas") then "Enumerating SAS tokens may reveal delegated, time-limited access to external parties"
         elif .operationName.value | test("setAccessPolicy") then "Modifying access policies can inadvertently expose containers or blobs to public access"
         elif .operationName.value | test("write") then "Write operation changed configuration or permissions of the storage account"
         else "Miscellaneous operation" end)
    })' > _current.json

  jq 'group_by(.stgName) | map({ (.[0].stgName): . }) | add' _current.json > _grouped.json

  jq 'with_entries(.value |= map(select(.changeStatus == "Succeeded")))' _grouped.json > _succ.json

  jq 'with_entries(.value |= map(select(.changeStatus != "Succeeded")))' _grouped.json > _fail.json

  jq -s 'add' "$tmp_success" _succ.json > _sc.tmp && mv _sc.tmp "$tmp_success"
  jq -s 'add' "$tmp_failed"  _fail.json > _fl.tmp && mv _fl.tmp "$tmp_failed"

  rm -f _current.json _grouped.json _succ.json _fail.json
done

# Sort each group by timestamp (desc)
for file in "$tmp_success" "$tmp_failed"; do
  jq 'with_entries({ key: .key, value: (.value | sort_by(.timestamp) | reverse) })' "$file" > "$file.sorted"
  mv "$file.sorted" "$file"
done

mv "$tmp_success" "$SUCCESS_OUTPUT"
mv "$tmp_failed"  "$FAILED_OUTPUT"

echo "Audit completed:"
echo "  ✅ Successful changes → $SUCCESS_OUTPUT"
echo "  ⚠️  Failed changes     → $FAILED_OUTPUT"
