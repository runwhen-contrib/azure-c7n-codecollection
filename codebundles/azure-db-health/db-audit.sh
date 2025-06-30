#!/bin/bash
# db-audit.sh – Audit changes to Azure Database Resources
# Outputs two JSON files:
#   db_changes_success.json – successful operations
#   db_changes_failed.json  – failed operations
# Environment variables:
#   AZURE_SUBSCRIPTION_ID       – subscription to query (default: current)
#   AZURE_RESOURCE_GROUP        – resource group containing databases (required)
#   AZURE_ACTIVITY_LOG_OFFSET   – time window e.g. 24h, 7d (default: 24h)

set -euo pipefail

SUCCESS_OUTPUT="db_changes_success.json"
FAILED_OUTPUT="db_changes_failed.json"
DB_MAP_FILE="$(dirname "$0")/db-map.json"
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

# Validate resource group exists in the current subscription
echo "Validating resource group '$AZURE_RESOURCE_GROUP' exists in subscription '$subscription'..."
resource_group_exists=$(az group show --name "$AZURE_RESOURCE_GROUP" --subscription "$subscription" --query "name" -o tsv 2>/dev/null)

if [ -z "$resource_group_exists" ]; then
  echo "ERROR: Resource group '$AZURE_RESOURCE_GROUP' was not found in subscription '$subscription'."
  echo ""
  echo "Available resource groups in subscription '$subscription':"
  az group list --subscription "$subscription" --query "[].name" -o tsv | sort
  echo ""
  echo "Please verify:"
  echo "1. The resource group name is correct"
  echo "2. You have access to the resource group"
  echo "3. You're using the correct subscription"
  echo "4. The resource group exists in this subscription"
  exit 1
fi

# Read the db-map.json file
if [ ! -f "$DB_MAP_FILE" ]; then
    echo "Error: db-map.json file not found at $DB_MAP_FILE"
    exit 1
fi

TIME_OFFSET="${AZURE_ACTIVITY_LOG_OFFSET:-24h}"
db_types=$(jq -r 'keys[]' "$DB_MAP_FILE")

tmp_success="$(mktemp)"
tmp_failed="$(mktemp)"
echo "{}" > "$tmp_success"
echo "{}" > "$tmp_failed"

# Process each database type
for db_type in $db_types; do
    echo "Processing database type: $db_type"
    
    # Get resource type and display name from db-map.json
    resource_type=$(jq -r ".[\"$db_type\"].resource" "$DB_MAP_FILE")
    display_name=$(jq -r ".[\"$db_type\"].display_name" "$DB_MAP_FILE")
    
    # Skip if resource_type is not defined
    if [ "$resource_type" == "null" ] || [ -z "$resource_type" ]; then
        echo "Resource type not defined for $db_type, skipping..."
        continue
    fi
    
    echo "Retrieving $display_name instances in resource group..."
    
    # Get list of database instances based on resource type
    instances=""
    case "$resource_type" in
        "azure.mysql-flexibleserver")
            instances=$(az mysql flexible-server list -g "$AZURE_RESOURCE_GROUP" --subscription "$subscription" --query "[].id" -o tsv)
            ;;
        "azure.postgresql-flexibleserver")
            instances=$(az postgres flexible-server list -g "$AZURE_RESOURCE_GROUP" --subscription "$subscription" --query "[].id" -o tsv)
            ;;
        "azure.sql-database")
            # For SQL databases, get both servers and databases
            servers=$(az sql server list -g "$AZURE_RESOURCE_GROUP" --subscription "$subscription" --query "[].name" -o tsv)
            for server in $servers; do
                server_id=$(az sql server show -g "$AZURE_RESOURCE_GROUP" -n "$server" --subscription "$subscription" --query "id" -o tsv)
                dbs=$(az sql db list -g "$AZURE_RESOURCE_GROUP" --server "$server" --subscription "$subscription" --query "[].name" -o tsv)
                for db in $dbs; do
                    db_id=$(az sql db show -g "$AZURE_RESOURCE_GROUP" --server "$server" -n "$db" --subscription "$subscription" --query "id" -o tsv)
                    instances+="$db_id "
                done
                instances+="$server_id "
            done
            ;;
        "azure.sqlserver")
            instances=$(az sql server list -g "$AZURE_RESOURCE_GROUP" --subscription "$subscription" --query "[].id" -o tsv)
            ;;
        "azure.postgresql-server")
            instances=$(az postgres server list -g "$AZURE_RESOURCE_GROUP" --subscription "$subscription" --query "[].id" -o tsv)
            ;;
        "azure.cosmosdb")
            instances=$(az cosmosdb list -g "$AZURE_RESOURCE_GROUP" --subscription "$subscription" --query "[].id" -o tsv)
            ;;
        "azure.redis")
            instances=$(az redis list -g "$AZURE_RESOURCE_GROUP" --subscription "$subscription" --query "[].id" -o tsv)
            ;;
        *)
            echo "Unknown resource type: $resource_type, skipping..."
            continue
            ;;
    esac
    
    # Skip if no instances found
    if [ -z "$instances" ]; then
        echo "No $display_name instances found in resource group $AZURE_RESOURCE_GROUP"
        continue
    fi
    
    # Process each instance
    for instance in $instances; do
        db_name=$(basename "$instance")
        logs=$(az monitor activity-log list \
            --resource-id "$instance" \
            --offset "$TIME_OFFSET" \
            --subscription "$subscription" \
            --output json)

        echo "$logs" | jq --arg type "$db_type" --arg name "$db_name" --arg display "$display_name" '
            map(select(.operationName.value | test("write|delete|action")) | {
                dbType: $type,
                dbName: $name,
                displayName: $display,
                operation: (.operationName.value | split("/") | last),
                operationDisplay: .operationName.localizedValue,
                timestamp: .eventTimestamp,
                caller: .caller,
                changeStatus: .status.value,
                resourceId: .resourceId,
                correlationId: .correlationId,
                resourceUrl: ("https://portal.azure.com/#resource" + .resourceId),
                security_classification:
                    (if .operationName.value | test("delete") then "Critical"
                     elif .operationName.value | test("listKeys|regenerateKey|listConnectionStrings") then "Critical"
                     elif .operationName.value | test("backup|restore") then "High"
                     elif .operationName.value | test("failover|switchover") then "Critical"
                     elif .operationName.value | test("firewallRules|virtualNetworkRules") then "High"
                     elif .operationName.value | test("privateEndpointConnections") then "High"
                     elif .operationName.value | test("configurations|parameters") then "High"
                     elif .operationName.value | test("administrators|users") then "Critical"
                     elif .operationName.value | test("encryption|transparentDataEncryption") then "High"
                     elif .operationName.value | test("roleAssignments|permissions") then "Critical"
                     elif .operationName.value | test("diagnosticSettings|auditSettings") then "Medium"
                     elif .operationName.value | test("replica|sync") then "High"
                     elif .operationName.value | test("write") then "Medium"
                     else "Info" end),
                reason:
                    (if .operationName.value | test("delete") then "Deleting a database permanently removes data and may affect dependent applications"
                     elif .operationName.value | test("listKeys|regenerateKey") then "Key operations expose credentials that grant full database access"
                     elif .operationName.value | test("listConnectionStrings") then "Connection strings reveal access credentials and endpoint information"
                     elif .operationName.value | test("backup") then "Backup operations access all database data and may indicate data exfiltration attempts"
                     elif .operationName.value | test("restore") then "Restore operations can overwrite existing data or create unauthorized database copies"
                     elif .operationName.value | test("failover|switchover") then "Failover operations affect database availability and may indicate incident response"
                     elif .operationName.value | test("firewallRules|virtualNetworkRules") then "Network access control changes can expose databases to unauthorized networks"
                     elif .operationName.value | test("privateEndpointConnections") then "Private endpoint changes affect network isolation and security boundaries"
                     elif .operationName.value | test("configurations|parameters") then "Configuration changes can affect performance, security, and data protection settings"
                     elif .operationName.value | test("administrators|users") then "User and administrator changes directly control database access and permissions"
                     elif .operationName.value | test("encryption|transparentDataEncryption") then "Encryption setting changes affect data protection and compliance requirements"
                     elif .operationName.value | test("roleAssignments|permissions") then "RBAC changes directly control who can access and manage the database"
                     elif .operationName.value | test("diagnosticSettings|auditSettings") then "Diagnostic and audit setting changes affect monitoring and compliance capabilities"
                     elif .operationName.value | test("replica|sync") then "Replication operations affect data consistency and may indicate disaster recovery activities"
                     elif .operationName.value | test("write") then "Write operation changed configuration or settings of the database"
                     else "Miscellaneous operation" end)
            })' > _current.json

        jq 'group_by(.dbName) | map({ (.[0].dbName): . }) | add' _current.json > _grouped.json

        jq 'with_entries(.value |= map(select(.changeStatus == "Succeeded")))' _grouped.json > _succ.json

        jq 'with_entries(.value |= map(select(.changeStatus == "Failed")))' _grouped.json > _fail.json

        jq -s 'add' "$tmp_success" _succ.json > _sc.tmp && mv _sc.tmp "$tmp_success"
        jq -s 'add' "$tmp_failed"  _fail.json > _fl.tmp && mv _fl.tmp "$tmp_failed"

        rm -f _current.json _grouped.json _succ.json _fail.json
    done
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