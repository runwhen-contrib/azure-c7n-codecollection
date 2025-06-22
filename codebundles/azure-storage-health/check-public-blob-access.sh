#!/bin/bash
set -euo pipefail

echo "Scanning Azure storage containers for public access (Blob / Container)..."

# Get all storage accounts
storage_accounts=$(az storage account list --query '[].{name:name, resourceGroup:resourceGroup}' -o tsv)

# Loop through each storage account
while IFS=$'\t' read -r account rg; do
    echo "Checking storage account: $account in resource group: $rg"

    # Get the account key
    key=$(az storage account keys list \
        --account-name "$account" \
        --resource-group "$rg" \
        --query '[0].value' -o tsv)

    # List containers and their public access
    containers=$(az storage container list \
        --account-name "$account" \
        --account-key "$key" \
        --query '[].{name:name, access:properties.publicAccess}' -o json)

    # Parse and filter results
    echo "$containers" | jq -r --arg acc "$account" --arg rg "$rg" '
        .[] | select(.access != null) |
        "PUBLIC ACCESS FOUND:\nStorage Account: \($acc)\nResource Group : \($rg)\nContainer      : \(.name)\nAccess Level   : \(.access)\n"
    '

done <<< "$storage_accounts"

echo "Scan complete."
