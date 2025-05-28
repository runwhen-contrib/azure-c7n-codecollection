#!/bin/bash

CHANGES_OUTPUT="dbx_changes.json"
DBX_MAP_FILE="$(dirname "$0")/dbx-map.json"
echo "[]" > "$CHANGES_OUTPUT"

# Get or set subscription ID
if [ -z "$AZURE_SUBSCRIPTION_ID" ]; then
    subscription=$(az account show --query "id" -o tsv)
    echo "AZURE_SUBSCRIPTION_ID is not set. Using current subscription ID: $subscription"
else
    subscription="$AZURE_SUBSCRIPTION_ID"
    echo "Using specified subscription ID: $subscription"
fi

# Set the subscription ID
echo "Switching to subscription ID: $subscription"
az account set --subscription "$subscription" || { echo "Failed to set subscription."; exit 1; }

# Check required environment variables
if [ -z "$AZURE_RESOURCE_GROUP" ]; then
    echo "Error: AZURE_RESOURCE_GROUP environment variable must be set."
    exit 1
fi

# Set time offset for activity logs (default 24h)
TIME_OFFSET=${AZURE_ACTIVITY_LOG_OFFSET:-"24h"}

# Create a temporary file to collect all changes before deduplication
TEMP_ALL_CHANGES="temp_all_changes.json"
echo "[]" > "$TEMP_ALL_CHANGES"

# Get all Databricks workspaces in the resource group
workspaces=$(az databricks workspace list -g "$AZURE_RESOURCE_GROUP" --query "[].id" -o tsv 2>&1) || { echo "$workspaces"; exit 1; }

if [ -z "$workspaces" ]; then
    exit 0
fi

# Process each Databricks workspace
for workspace in $workspaces; do
    workspace_name=$(basename "$workspace")
    echo "Retrieving activity logs for Databricks workspace: $workspace_name..."
    
    activity_logs=$(az monitor activity-log list \
        --resource-id "$workspace" \
        --offset "$TIME_OFFSET" \
        --output json 2>&1) || { echo "$activity_logs"; continue; }
        # Filter important events and add to the changes file
        echo "$activity_logs" | jq --arg name "$workspace_name" '
            . | map(select(
                # Filter for important operations
                (.operationName.value | contains("/write") or contains("/delete") or contains("/action")) and
                # Filter out monitoring operations
                (.operationName.value | contains("diagnosticSettings") or contains("metrics") | not) and
                # Filter for successful operations
                (.status.value == "Succeeded") and
                # Ensure we have a correlationId for deduplication
                (.correlationId != null) and
                # Ensure we have a caller for deduplication
                (.caller != null)
            )) | map(. + {
                dbxName: $name,
                displayName: "Azure Databricks",
                # Extract simplified operation
                operation: (.operationName.value | split("/") | last),
                operationName: .operationName.localizedValue,
                # Extract simplified timestamp
                timestamp: .eventTimestamp,
                # Extract caller info (use empty string if null)
                caller: .caller,
                # Extract simplified status
                changeStatus: .status.value,
                operationValue: .operationName.value,
                resourceUrl: ("https://portal.azure.com/#resource" + .resourceId)
            } | {
                dbxName,
                displayName,
                operation,
                operationName,
                timestamp,
                caller,
                changeStatus,
                resourceId: .resourceId,
                correlationId: .correlationId,
                operationValue,
                resourceUrl
            })
        ' > temp_changes.json
        
        # Add the filtered changes to the temporary all changes file
        jq -s '.[0] + .[1]' "$TEMP_ALL_CHANGES" temp_changes.json > temp_combined.json && mv temp_combined.json "$TEMP_ALL_CHANGES"
        rm temp_changes.json
    # Skip to next workspace if no activity logs
    if [ -z "$activity_logs" ]; then continue; fi
done

# Deduplicate changes based on correlationId, resourceId, and operationValue
jq '
  map(. + {
    resourceId: (.resourceId | ascii_downcase),
    dedupeKey: (.correlationId + "|" + (.resourceId | ascii_downcase) + "|" + .operationValue)
  }) |
  group_by(.dedupeKey) |
  map(sort_by(.timestamp) | reverse | .[0]) |
  map(del(.dedupeKey)) |
  sort_by(.timestamp) | reverse
' "$TEMP_ALL_CHANGES" > "$CHANGES_OUTPUT"

# Clean up temporary file
rm "$TEMP_ALL_CHANGES"

# Output results
echo "Databricks changes retrieved and saved to: $CHANGES_OUTPUT"
total_changes=$(jq 'length' "$CHANGES_OUTPUT")
echo "Total changes found: $total_changes"

jq 'group_by(.dbxName) | 
    map({ (.[0].dbxName): . }) | 
    add' "$CHANGES_OUTPUT" > dbx_changes_grouped.json

rm -rf $CHANGES_OUTPUT