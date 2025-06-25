#!/bin/bash
set -euo pipefail

: "${AZURE_RESOURCE_GROUP:?Must set AZURE_RESOURCE_GROUP}"
: "${AZURE_RESOURCE_SUBSCRIPTION_ID:?Must set AZURE_RESOURCE_SUBSCRIPTION_ID}"

resource_group="$AZURE_RESOURCE_GROUP"
subscription_id="$AZURE_RESOURCE_SUBSCRIPTION_ID"

OUTPUT_FILE="storage_misconfig.json"
issues_json='{"issues": []}'

echo "\n🔍 Scanning Storage Accounts for security misconfigurations..."
echo "Subscription ID: $subscription_id"
echo "Resource Group:  $resource_group"

# List Storage Accounts
if ! storage_accounts=$(az storage account list -g "$resource_group" --subscription "$subscription_id" --query "[].{id:id,name:name,resourceGroup:resourceGroup}" -o json 2>storage_list_err.log); then
    err_msg=$(cat storage_list_err.log)
    rm -f storage_list_err.log

    issues_json=$(echo "$issues_json" | jq \
        --arg title "Failed to List Storage Accounts" \
        --arg details "$err_msg" \
        --arg reason "Could not retrieve storage account list from Azure CLI." \
        --arg nextStep "Ensure correct resource group and CLI permissions." \
        --argjson severity 3 \
        '.issues += [{"title": $title, "details": $details, "reason": $reason, "next_step": $nextStep, "severity": $severity}]')
    echo "$issues_json" > "$OUTPUT_FILE"
    exit 1
fi
rm -f storage_list_err.log

check_and_add_issue() {
  local title="$1"
  local detail="$2"
  local reason="$3"
  local next_step="$4"
  local severity="$5"

  issues_json=$(echo "$issues_json" | jq \
      --arg title "$title" \
      --arg details "$detail" \
      --arg reason "$reason" \
      --arg next_step "$next_step" \
      --argjson severity "$severity" \
      --arg name "$name" \
      --arg resource_url "$url" \
      '.issues += [{"title": $title, "details": $details, "reason": $reason, "next_step": $next_step, "severity": $severity, "name": $name, "resource_url": $resource_url}]')
}

for account in $(echo "$storage_accounts" | jq -c '.[]'); do
    name=$(echo "$account" | jq -r '.name')
    id=$(echo "$account" | jq -r '.id')
    url="https://portal.azure.com/#@/resource${id}"

    echo "\n🔹 Checking: $name"

    if ! props=$(az storage account show --name "$name" --resource-group "$resource_group" --subscription "$subscription_id" -o json 2>prop_err.log); then
        err_msg=$(cat prop_err.log)
        rm -f prop_err.log
        echo "Failed to retrieve properties for $name"
        continue
    fi
    rm -f prop_err.log

    allowBlobPublicAccess=$(echo "$props" | jq -r '.allowBlobPublicAccess // true')
    if [[ "$allowBlobPublicAccess" == "true" ]]; then
        check_and_add_issue \
          "Blob public access enabled in storage account \`$name\`" \
          "allowBlobPublicAccess is true" \
          "Public access to blobs can lead to unauthorized data exposure and compliance violations." \
          "Set \`allowBlobPublicAccess=false\` to block anonymous public access." \
          3
    fi

    allowSharedKeyAccess=$(echo "$props" | jq -r '.allowSharedKeyAccess // true')
    if [[ "$allowSharedKeyAccess" == "true" ]]; then
        check_and_add_issue \
          "Shared key access is enabled in \`$name\`" \
          "allowSharedKeyAccess is true" \
          "Shared keys are less secure and harder to rotate than identity-based methods." \
          "Disable shared key access to enforce authentication via Azure AD or Managed Identity." \
          2
    fi

    defaultToOAuthAuthentication=$(echo "$props" | jq -r '.defaultToOAuthAuthentication // false')
    if [[ "$defaultToOAuthAuthentication" != "true" ]]; then
        check_and_add_issue \
          "OAuth not enforced in \`$name\`" \
          "defaultToOAuthAuthentication is not true" \
          "Using OAuth ensures access is governed via Azure AD, improving traceability and security." \
          "Enable \`defaultToOAuthAuthentication\` to default to Azure AD-based auth." \
          2
    fi

    identityType=$(echo "$props" | jq -r '.identity.type // empty')
    if [[ -z "$identityType" ]]; then
        check_and_add_issue \
          "No Managed Identity configured for \`$name\`" \
          "identity.type is null" \
          "Managed Identity allows secure, credential-free access to other Azure services." \
          "Assign a System or User Assigned Managed Identity." \
          2
    fi

    httpsOnly=$(echo "$props" | jq -r '.enableHttpsTrafficOnly')
    if [[ "$httpsOnly" != "true" ]]; then
        check_and_add_issue \
          "HTTP allowed on storage account \`$name\`" \
          "enableHttpsTrafficOnly is false" \
          "HTTP is insecure and allows plaintext transmission of data." \
          "Enforce HTTPS-only traffic on the storage account." \
          3
    fi

    tlsVersion=$(echo "$props" | jq -r '.minimumTlsVersion')
    if [[ "$tlsVersion" != "TLS1_2" && "$tlsVersion" != "TLS1_3" ]]; then
        check_and_add_issue \
          "Outdated TLS version on \`$name\`" \
          "minimumTlsVersion is $tlsVersion" \
          "Older TLS versions are vulnerable to known attacks like POODLE and BEAST." \
          "Set \`minimumTlsVersion\` to at least TLS1_2." \
          3
    fi

    defaultAction=$(echo "$props" | jq -r '.networkRuleSet.defaultAction')
    ipCount=$(echo "$props" | jq '.networkRuleSet.ipRules | length')
    vnetCount=$(echo "$props" | jq '.networkRuleSet.virtualNetworkRules | length')
    if [[ "$defaultAction" == "Allow" && "$ipCount" == "0" && "$vnetCount" == "0" ]]; then
        check_and_add_issue \
          "Storage account \`$name\` is open to all networks" \
          "defaultAction is Allow with no IP or VNet restrictions" \
          "This allows unrestricted public access to storage endpoints, which is a high risk." \
          "Set \`defaultAction=deny\` and configure appropriate IP or VNet rules." \
          3
    fi

done

echo "$issues_json" > "$OUTPUT_FILE"
echo "\nStorage account posture report saved to: $OUTPUT_FILE"
