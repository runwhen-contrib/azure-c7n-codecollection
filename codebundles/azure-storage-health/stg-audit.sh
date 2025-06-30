#!/bin/bash
# stg-audit.sh – Audit changes to Azure Storage Accounts
# Outputs two JSON files:
#   stg_changes_success.json – successful operations
#   stg_changes_failed.json  – failed operations
# Environment variables:
#   AZURE_SUBSCRIPTION_ID   – subscription to query (default: current)
#   AZURE_RESOURCE_GROUP    – resource group containing storage accounts (required)
#   AZURE_ACTIVITY_LOG_OFFSET – time window e.g. 24h, 7d (default: 24h)

set -euo pipefail

SUCCESS_OUTPUT="stg_changes_success.json"
FAILED_OUTPUT="stg_changes_failed.json"

echo "[]" > "$SUCCESS_OUTPUT"
echo "[]" > "$FAILED_OUTPUT"

# Decide subscription
if [ -z "${AZURE_SUBSCRIPTION_ID:-}" ]; then
  subscription=$(az account show --query "id" -o tsv)
  echo "Using current subscription: $subscription"
else
  subscription="$AZURE_SUBSCRIPTION_ID"
  echo "Using specified subscription: $subscription"
fi
az account set --subscription "$subscription" || { echo "Failed to set subscription"; exit 1; }

# Validate resource group
if [ -z "${AZURE_RESOURCE_GROUP:-}" ]; then
  echo "Error: AZURE_RESOURCE_GROUP must be set" >&2
  exit 1
fi

# Time window (defaults to 24h)
TIME_OFFSET=${AZURE_ACTIVITY_LOG_OFFSET:-"24h"}

echo "Fetching Storage Accounts in resource group $AZURE_RESOURCE_GROUP…"
accounts=$(az storage account list -g "$AZURE_RESOURCE_GROUP" --query "[].id" -o tsv)
if [ -z "$accounts" ]; then
  echo "No storage accounts found in $AZURE_RESOURCE_GROUP" >&2
  exit 0
fi

tmp_success="$(mktemp)"
tmp_failed="$(mktemp)"
echo "[]" > "$tmp_success"
echo "[]" > "$tmp_failed"

for account in $accounts; do
  echo "Processing $account"
  logs=$(az monitor activity-log list \
    --resource-id "$account" \
    --offset "$TIME_OFFSET" \
    --output json)

  if [ $? -ne 0 ]; then
    echo "Warning: could not fetch activity logs for $account" >&2
    continue
  fi

  # Extract interesting operations (write/delete/action) and split by status
  echo "$logs" | jq --arg acc "$(basename "$account")" '
    map(select((.operationName.value | test("/(write|delete|action)") )) | . + {
      stgName: $acc,
      operation: (.operationName.value | split("/") | last),
      timestamp: .eventTimestamp,
      caller: .caller,
      changeStatus: .status.value,
      resourceUrl: ("https://portal.azure.com/#resource" + .resourceId),
      correlationId: .correlationId
    } | {
      stgName,
      operation,
      timestamp,
      caller,
      changeStatus,
      resourceId: .resourceId,
      correlationId,
      resourceUrl
    })' > _current.json

  # Separate success and failure
  jq 'map(select(.changeStatus == "Succeeded"))' _current.json > _succ.json
  jq 'map(select(.changeStatus != "Succeeded"))' _current.json > _fail.json

  jq -s '.[0]+.[1]' "$tmp_success" _succ.json > _sc.tmp && mv _sc.tmp "$tmp_success"
  jq -s '.[0]+.[1]' "$tmp_failed"  _fail.json > _fl.tmp && mv _fl.tmp "$tmp_failed"
  rm -f _current.json _succ.json _fail.json

done

# Deduplicate based on correlationId|resourceId|operation
for file in "$tmp_success" "$tmp_failed"; do
  jq '
    map(. + {key: ((.correlationId|tostring) + "|" + (.resourceId|ascii_downcase) + "|" + .operation)}) |
    group_by(.key) | map(.[0]) | map(del(.key))
  ' "$file" > "$file.dedupe"
  mv "$file.dedupe" "$file"
  # Sort newest first
  jq 'sort_by(.timestamp) | reverse' "$file" > "$file.sorted" && mv "$file.sorted" "$file"
  done

mv "$tmp_success" "$SUCCESS_OUTPUT"
mv "$tmp_failed"  "$FAILED_OUTPUT"

echo "Storage account changes saved to:"
echo "  $SUCCESS_OUTPUT (successful operations)"
echo "  $FAILED_OUTPUT  (failed operations)"
