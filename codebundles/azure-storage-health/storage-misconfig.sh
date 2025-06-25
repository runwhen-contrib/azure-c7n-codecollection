#!/bin/bash
set -euo pipefail

: "${AZURE_RESOURCE_GROUP:?Must set AZURE_RESOURCE_GROUP}"
: "${AZURE_RESOURCE_SUBSCRIPTION_ID:?Must set AZURE_RESOURCE_SUBSCRIPTION_ID}"

resource_group="$AZURE_RESOURCE_GROUP"
subscription_id="$AZURE_RESOURCE_SUBSCRIPTION_ID"
output_file="storage_misconfig.json"
issues_json='{"issues": []}'

echo "🔍 Scanning Azure Storage Accounts for security misconfigurations..."
echo "Subscription: $subscription_id"
echo "Resource Group: $resource_group"

# Get list of storage accounts
if ! storage_accounts=$(az storage account list -g "$resource_group" --subscription "$subscription_id" -o json 2>storage_list_err.log); then
    err_msg=$(cat storage_list_err.log)
    rm -f storage_list_err.log
    echo "❌ Failed to list storage accounts"
    exit 1
fi
rm -f storage_list_err.log

check_and_add_issue() {
  local title="$1"
  local detail="$2"
  local reason="$3"
  local next_step="$4"
  local severity="$5"
  local name="$6"
  local url="$7"

  issues_json=$(echo "$issues_json" | jq \
    --arg title "$title" \
    --argjson details "$detail" \
    --arg reason "$reason" \
    --arg next_step "$next_step" \
    --argjson severity "$severity" \
    --arg name "$name" \
    --arg resource_url "$url" \
    '.issues += [{
        "title": $title,
        "details": $details,
        "reason": $reason,
        "next_step": $next_step,
        "severity": $severity,
        "name": $name,
        "resource_url": $resource_url
     }]')
}

for row in $(echo "$storage_accounts" | jq -c '.[]'); do
  name=$(echo "$row" | jq -r '.name')
  id=$(echo "$row" | jq -r '.id')
  url="https://portal.azure.com/#@/resource${id}"

  echo "🔹 Checking $name"

  if ! props=$(az storage account show --name "$name" --resource-group "$resource_group" --subscription "$subscription_id" -o json 2>prop_err.log); then
      echo "⚠️  Could not retrieve details for $name"
      continue
  fi
  rm -f prop_err.log
  detail_json=$(echo "$props" | jq '.')

  # Checks
  allow_blob_public=$(echo "$props" | jq -r '.allowBlobPublicAccess // true')
  if [[ "$allow_blob_public" == "true" ]]; then
      check_and_add_issue \
        "Blob public access enabled in $name" \
        "$detail_json" \
        "Enabling public blob access can lead to unauthorized data exposure. Microsoft recommends disabling this to prevent data leaks." \
        "Set allowBlobPublicAccess to false to block anonymous access to containers and blobs." \
        3 \
        "$name" \
        "$url"
  fi

  shared_key_access=$(echo "$props" | jq -r '.allowSharedKeyAccess // true')
  if [[ "$shared_key_access" == "true" ]]; then
      check_and_add_issue \
        "Shared key access is enabled in $name" \
        "$detail_json" \
        "Shared keys provide full access and are less secure than identity-based access. Disabling them helps enforce least privilege access." \
        "Set allowSharedKeyAccess to false and use Azure AD/MSI instead." \
        2 \
        "$name" \
        "$url"
  fi

  oauth_default=$(echo "$props" | jq -r '.defaultToOAuthAuthentication // false')
  if [[ "$oauth_default" != "true" ]]; then
      check_and_add_issue \
        "OAuth is not default authentication for $name" \
        "$detail_json" \
        "OAuth (Azure AD) is the recommended authentication method for secure, identity-based access." \
        "Set defaultToOAuthAuthentication to true to enforce Azure AD auth." \
        2 \
        "$name" \
        "$url"
  fi

  has_identity=$(echo "$props" | jq -r '.identity.type // empty')
  if [[ -z "$has_identity" ]]; then
      check_and_add_issue \
        "No Managed Identity assigned to $name" \
        "$detail_json" \
        "A managed identity enables secure and credential-free access to other Azure services." \
        "Assign a system- or user-assigned identity to enable secure authentication." \
        2 \
        "$name" \
        "$url"
  fi

  https_only=$(echo "$props" | jq -r '.enableHttpsTrafficOnly')
  if [[ "$https_only" != "true" ]]; then
      check_and_add_issue \
        "HTTPS not enforced for $name" \
        "$detail_json" \
        "Allowing HTTP connections can expose data in transit. HTTPS ensures secure encryption." \
        "Set enableHttpsTrafficOnly to true." \
        3 \
        "$name" \
        "$url"
  fi

  tls_ver=$(echo "$props" | jq -r '.minimumTlsVersion')
  if [[ "$tls_ver" != "TLS1_2" && "$tls_ver" != "TLS1_3" ]]; then
      check_and_add_issue \
        "Outdated TLS version for $name" \
        "$detail_json" \
        "Older TLS versions are vulnerable to known exploits. TLS 1.2 or 1.3 is required for compliance." \
        "Set minimumTlsVersion to TLS1_2 or higher." \
        3 \
        "$name" \
        "$url"
  fi

  net_action=$(echo "$props" | jq -r '.networkRuleSet.defaultAction')
  ip_count=$(echo "$props" | jq '.networkRuleSet.ipRules | length')
  vnet_count=$(echo "$props" | jq '.networkRuleSet.virtualNetworkRules | length')

  if [[ "$net_action" == "Allow" && "$ip_count" == 0 && "$vnet_count" == 0 ]]; then
      check_and_add_issue \
        "Storage account $name is open to all networks" \
        "$detail_json" \
        "Leaving storage accounts open to all networks increases attack surface and violates zero-trust principles." \
        "Set defaultAction to Deny and define IP or VNet rules." \
        3 \
        "$name" \
        "$url"
  fi
done

# Write output
echo "$issues_json" > "$output_file"
echo "✅ Report written to: $output_file"
