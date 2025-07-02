#!/bin/bash
set -euo pipefail

: "${AZURE_RESOURCE_GROUP:?Must set AZURE_RESOURCE_GROUP}"
: "${AZURE_SUBSCRIPTION_ID:?Must set AZURE_SUBSCRIPTION_ID}"

resource_group="$AZURE_RESOURCE_GROUP"
subscription_id="$AZURE_SUBSCRIPTION_ID"
output_file="storage_misconfig.json"
grouped_json='{"storage_accounts": []}'

echo "Scanning Azure Storage Accounts for misconfigurations..."
echo "Resource Group: $resource_group"
echo "Subscription ID: $subscription_id"

# Validate resource group exists in the current subscription
echo "Validating resource group '$resource_group' exists in subscription '$subscription_id'..."
if ! resource_group_exists=$(az group show --name "$resource_group" --subscription "$subscription_id" --query "name" -o tsv 2>/dev/null); then
    echo "ERROR: Resource group '$resource_group' was not found in subscription '$subscription_id'."
    echo ""
    echo "Available resource groups in subscription '$subscription_id':"
    az group list --subscription "$subscription_id" --query "[].name" -o tsv | sort
    echo ""
    echo "Please verify:"
    echo "1. The resource group name is correct"
    echo "2. You have access to the resource group"
    echo "3. You're using the correct subscription"
    echo "4. The resource group exists in this subscription"
    exit 1
fi

echo "Resource group '$resource_group' validated successfully."

# List all storage accounts
if ! storage_accounts=$(az storage account list -g "$resource_group" --subscription "$subscription_id" -o json 2>storage_list_err.log); then
    echo "Failed to list storage accounts"
    cat storage_list_err.log
    exit 1
fi
rm -f storage_list_err.log

# Validate JSON response and check for empty result
if [ -z "$storage_accounts" ] || ! echo "$storage_accounts" | jq . > /dev/null 2>/dev/null; then
    echo "ERROR: Invalid or empty JSON response from az storage account list"
    exit 1
fi

# Check if we have any storage accounts
storage_count=$(echo "$storage_accounts" | jq 'length' 2>/dev/null || echo "0")
if [ "$storage_count" -eq 0 ]; then
    echo "No storage accounts found in resource group '$resource_group'"
    echo "$grouped_json" > "$output_file"
    echo "Report saved to: $output_file"
    exit 0
fi

# Add issue to grouped JSON
add_issue_to_account() {
  local name="$1"
  local title="$2"
  local reason="$3"
  local next_step="$4"
  local severity="$5"

  grouped_json=$(echo "$grouped_json" | jq \
    --arg name "$name" \
    --arg title "$title" \
    --arg reason "$reason" \
    --arg next_step "$next_step" \
    --argjson severity "$severity" \
    '
    .storage_accounts |= map(
      if .name == $name then
        .issues += [{
          "title": $title,
          "reason": $reason,
          "next_step": $next_step,
          "severity": $severity
        }]
      else
        .
      end
    )')
}

# Loop through storage accounts using process substitution (more robust than for loop)
while IFS= read -r row; do
  # Validate each row is valid JSON before processing
  if ! echo "$row" | jq . > /dev/null 2>/dev/null; then
    echo "WARNING: Skipping invalid JSON row: $row"
    continue
  fi
  
  name=$(echo "$row" | jq -r '.name')
  id=$(echo "$row" | jq -r '.id')
  url="https://portal.azure.com/#@/resource${id}"

  echo "Checking $name"

  if ! props=$(az storage account show --name "$name" --resource-group "$resource_group" --subscription "$subscription_id" -o json 2>prop_err.log); then
    echo "Could not retrieve properties for $name"
    continue
  fi
  rm -f prop_err.log
  
  # Validate properties JSON before using it
  if ! props_json=$(echo "$props" | jq '.' 2>/dev/null); then
    echo "WARNING: Invalid JSON properties for $name, skipping"
    continue
  fi

  # Initialize entry in grouped JSON
  grouped_json=$(echo "$grouped_json" | jq \
    --arg name "$name" \
    --arg url "$url" \
    --argjson details "$props_json" \
    '.storage_accounts += [{
      "name": $name,
      "resource_url": $url,
      "details": $details,
      "issues": []
    }]')

  # Checks begin
  allow_blob_public=$(echo "$props" | jq -r '.allowBlobPublicAccess')
  if [[ "$allow_blob_public" == "true" || "$allow_blob_public" == "null" ]]; then
    add_issue_to_account "$name" \
      "Blob public access enabled" \
      "Enabling public blob access can lead to unauthorized data exposure." \
      "Set allowBlobPublicAccess to false to block anonymous access." \
      4
  fi

  shared_key_access=$(echo "$props" | jq -r '.allowSharedKeyAccess // true')
  if [[ "$shared_key_access" == "true" ]]; then
    add_issue_to_account "$name" \
      "Shared key access is enabled" \
      "Shared keys provide full access and are less secure than identity-based access." \
      "Set allowSharedKeyAccess to false and use Azure AD/MSI instead." \
      4
  fi

  oauth_default=$(echo "$props" | jq -r '.defaultToOAuthAuthentication // false')
  if [[ "$oauth_default" != "true" ]]; then
    add_issue_to_account "$name" \
      "OAuth not enabled as default auth" \
      "OAuth (Azure AD) is more secure and enforces identity-based access." \
      "Set defaultToOAuthAuthentication to true to prefer OAuth over keys." \
      4
  fi

  has_identity=$(echo "$props" | jq -r '.identity.type // empty')
  if [[ -z "$has_identity" ]]; then
    add_issue_to_account "$name" \
      "No managed identity assigned" \
      "Managed identities allow secure service-to-service communication without secrets." \
      "Assign a system- or user-assigned managed identity." \
      4
  fi

  https_only=$(echo "$props" | jq -r '.enableHttpsTrafficOnly')
  if [[ "$https_only" != "true" ]]; then
    add_issue_to_account "$name" \
      "HTTPS not enforced" \
      "Unencrypted HTTP exposes data in transit. HTTPS ensures secure communication." \
      "Enable HTTPS-only access by setting enableHttpsTrafficOnly to true." \
      4
  fi

  tls_ver=$(echo "$props" | jq -r '.minimumTlsVersion')
  if [[ "$tls_ver" != "TLS1_2" && "$tls_ver" != "TLS1_3" ]]; then
    add_issue_to_account "$name" \
      "Weak TLS version in use" \
      "TLS versions below 1.2 are deprecated and considered insecure." \
      "Set minimumTlsVersion to TLS1_2 or higher." \
      4
  fi

  net_action=$(echo "$props" | jq -r '.networkRuleSet.defaultAction')
  ip_count=$(echo "$props" | jq '.networkRuleSet.ipRules | length')
  vnet_count=$(echo "$props" | jq '.networkRuleSet.virtualNetworkRules | length')

  if [[ "$net_action" == "Allow" && "$ip_count" == 0 && "$vnet_count" == 0 ]]; then
    add_issue_to_account "$name" \
      "Storage open to all networks" \
      "Open access increases risk of unauthorized access and violates zero-trust." \
      "Restrict access by setting defaultAction to Deny and configuring IP/VNet rules." \
      4
  fi
done < <(echo "$storage_accounts" | jq -c '.[]')

# Write final grouped JSON
echo "$grouped_json" > "$output_file"
echo "Report saved to: $output_file"
