#!/bin/bash

CHANGES_OUTPUT="db_changes.json"
DB_MAP_FILE="$(dirname "$0")/db-map.json"
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

# Read the db-map.json file
if [ ! -f "$DB_MAP_FILE" ]; then
    echo "Error: db-map.json file not found at $DB_MAP_FILE"
    exit 1
fi

# Get all database types from db-map.json
db_types=$(jq -r 'keys[]' "$DB_MAP_FILE")

# Set time offset for activity logs (default 24h)
TIME_OFFSET=${AZURE_ACTIVITY_LOG_OFFSET:-"24h"}

# Create a temporary file to collect all changes before deduplication
TEMP_ALL_CHANGES="temp_all_changes.json"
echo "[]" > "$TEMP_ALL_CHANGES"

# Process each database type
for db_type in $db_types; do
    echo "Processing database type: $db_type"
    
    # Get resource type and provider path from db-map.json
    resource_type=$(jq -r ".[\"$db_type\"].resource" "$DB_MAP_FILE")
    display_name=$(jq -r ".[\"$db_type\"].display_name" "$DB_MAP_FILE")
    
    # Skip if resource_type is not defined
    if [ "$resource_type" == "null" ] || [ -z "$resource_type" ]; then
        echo "Resource type not defined for $db_type, skipping..."
        continue
    fi
    
    echo "Retrieving $display_name instances in resource group..."
    
    # Get list of database instances in the resource group
    case "$resource_type" in
        "azure.mysql-flexibleserver")
            instances=$(az mysql flexible-server list -g "$AZURE_RESOURCE_GROUP" --query "[].id" -o tsv)
            ;;
        "azure.postgresql-flexibleserver")
            instances=$(az postgres flexible-server list -g "$AZURE_RESOURCE_GROUP" --query "[].id" -o tsv)
            ;;
        "azure.sql-database")
            # For SQL databases, we need to get servers first, then databases
            servers=$(az sql server list -g "$AZURE_RESOURCE_GROUP" --query "[].name" -o tsv)
            instances=""
            for server in $servers; do
                server_id=$(az sql server show -g "$AZURE_RESOURCE_GROUP" -n "$server" --query "id" -o tsv)
                dbs=$(az sql db list -g "$AZURE_RESOURCE_GROUP" --server "$server" --query "[].name" -o tsv)
                for db in $dbs; do
                    db_id=$(az sql db show -g "$AZURE_RESOURCE_GROUP" --server "$server" -n "$db" --query "id" -o tsv)
                    instances+="$db_id "
                done
                # Also add the server itself
                instances+="$server_id "
            done
            ;;
        "azure.sqlserver")
            instances=$(az sql server list -g "$AZURE_RESOURCE_GROUP" --query "[].id" -o tsv)
            ;;
        "azure.postgresql-server")
            instances=$(az postgres server list -g "$AZURE_RESOURCE_GROUP" --query "[].id" -o tsv)
            ;;
        "azure.cosmosdb")
            instances=$(az cosmosdb list -g "$AZURE_RESOURCE_GROUP" --query "[].id" -o tsv)
            ;;
        "azure.redis")
            instances=$(az redis list -g "$AZURE_RESOURCE_GROUP" --query "[].id" -o tsv)
            ;;
        *)
            echo "Unknown resource type: $resource_type, skipping..."
            continue
            ;;
    esac
    
    # Process each instance
    for instance in $instances; do
        echo "Retrieving activity logs for $display_name: $instance..."
        
        # Get activity logs for the resource
        activity_logs=$(az monitor activity-log list \
            --resource-id "$instance" \
            --offset "$TIME_OFFSET" \
            --output json)
        
        # Check if activity logs retrieval was successful
        if [ $? -eq 0 ]; then
            # Filter important events and add to the changes file
            echo "$activity_logs" | jq --arg type "$db_type" --arg name "$(basename "$instance")" --arg display "$display_name" '
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
                    dbType: $type,
                    dbName: $name,
                    displayName: $display,
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
                    dbType,
                    dbName,
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
        else
            echo "Failed to retrieve activity logs for $instance. This might be due to permissions or other API limitations."
        fi
    done
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
echo "Database changes retrieved and saved to: $CHANGES_OUTPUT"
total_changes=$(jq 'length' "$CHANGES_OUTPUT")
echo "Total changes found: $total_changes"

# Group by database name and handle empty case
if [ "$total_changes" -eq 0 ]; then
    echo "{}" > db_changes_grouped.json
else
    jq 'group_by(.dbName) | 
        map({ (.[0].dbName): . }) | 
        add' "$CHANGES_OUTPUT" > db_changes_grouped.json
fi

rm -rf $CHANGES_OUTPUT
# # If there are many changes, suggest filtering
# if [ "$total_changes" -gt 20 ]; then
#     echo -e "\nTip: To view all changes, run: jq -r '.[] | \"\\(.timestamp) - \\(.displayName) \\(.dbName) - \\(.operation) by \\(.caller)\"' $CHANGES_OUTPUT"
#     echo "Tip: To filter by correlationId, run: jq -r '.[] | select(.correlationId == \"specific-correlation-id\") | \"\\(.timestamp) - \\(.displayName) \\(.dbName) - \\(.operation)\"' $CHANGES_OUTPUT"
# fi
