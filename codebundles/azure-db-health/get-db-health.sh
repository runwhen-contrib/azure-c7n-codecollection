#!/bin/bash

HEALTH_OUTPUT="db_health.json"
DB_MAP_FILE="$(dirname "$0")/db-map.json"
echo "[]" > "$HEALTH_OUTPUT"

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

# Check if Microsoft.ResourceHealth provider is registered
echo "Checking registration status of Microsoft.ResourceHealth provider..."
registrationState=$(az provider show --namespace Microsoft.ResourceHealth --subscription "$subscription" --query "registrationState" -o tsv)

if [[ "$registrationState" != "Registered" ]]; then
    echo "Registering Microsoft.ResourceHealth provider..."
    az provider register --namespace Microsoft.ResourceHealth --subscription "$subscription"

    # Wait for registration
    echo "Waiting for Microsoft.ResourceHealth provider to register..."
    for i in {1..10}; do
        registrationState=$(az provider show --namespace Microsoft.ResourceHealth --subscription "$subscription" --query "registrationState" -o tsv)
        if [[ "$registrationState" == "Registered" ]]; then
            echo "Microsoft.ResourceHealth provider registered successfully."
            break
        else
            echo "Current registration state: $registrationState. Retrying in 10 seconds..."
            sleep 10
        fi
    done

    # Exit if registration fails
    if [[ "$registrationState" != "Registered" ]]; then
        echo "Error: Microsoft.ResourceHealth provider could not be registered."
        exit 1
    fi
else
    echo "Microsoft.ResourceHealth provider is already registered."
fi

# Check required environment variables
if [ -z "$AZURE_RESOURCE_GROUP" ]; then
    echo "Error: AZURE_RESOURCE_GROUP environment variable must be set."
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

echo "Resource group '$AZURE_RESOURCE_GROUP' validated successfully."

# Read the db-map.json file
if [ ! -f "$DB_MAP_FILE" ]; then
    echo "Error: db-map.json file not found at $DB_MAP_FILE"
    exit 1
fi

# Get all database types from db-map.json
db_types=$(jq -r 'keys[]' "$DB_MAP_FILE")

# Process each database type
for db_type in $db_types; do
    echo "Processing database type: $db_type"
    
    # Get resource type and provider path from db-map.json
    resource_type=$(jq -r ".[\"$db_type\"].resource" "$DB_MAP_FILE")
    display_name=$(jq -r ".[\"$db_type\"].display_name" "$DB_MAP_FILE")
    provider_path=$(jq -r ".[\"$db_type\"].provider_path" "$DB_MAP_FILE")
    
    # Skip if provider_path is not defined
    if [ "$provider_path" == "null" ] || [ -z "$provider_path" ]; then
        echo "Provider path not defined for $db_type, skipping..."
        continue
    fi
    
    echo "Retrieving $display_name instances in resource group..."
    
    # Get list of database instances in the resource group
    # This command needs to be adjusted based on the resource type
    case "$resource_type" in
        "azure.mysql-flexibleserver")
            instances=$(az mysql flexible-server list -g "$AZURE_RESOURCE_GROUP" --subscription "$subscription" --query "[].name" -o tsv)
            ;;
        "azure.postgresql-flexibleserver")
            instances=$(az postgres flexible-server list -g "$AZURE_RESOURCE_GROUP" --subscription "$subscription" --query "[].name" -o tsv)
            ;;
        "azure.sql-database")
            # For SQL databases, we need to get servers first, then databases
            servers=$(az sql server list -g "$AZURE_RESOURCE_GROUP" --subscription "$subscription" --query "[].name" -o tsv)
            instances=""
            for server in $servers; do
                dbs=$(az sql db list -g "$AZURE_RESOURCE_GROUP" --server "$server" --subscription "$subscription" --query "[].name" -o tsv)
                for db in $dbs; do
                    instances+="$server/$db "
                done
            done
            ;;
        "azure.sqlserver")
            instances=$(az sql server list -g "$AZURE_RESOURCE_GROUP" --subscription "$subscription" --query "[].name" -o tsv)
            ;;
        "azure.postgresql-server")
            instances=$(az postgres server list -g "$AZURE_RESOURCE_GROUP" --subscription "$subscription" --query "[].name" -o tsv)
            ;;
        "azure.cosmosdb")
            instances=$(az cosmosdb list -g "$AZURE_RESOURCE_GROUP" --subscription "$subscription" --query "[].name" -o tsv)
            ;;
        "azure.redis")
            instances=$(az redis list -g "$AZURE_RESOURCE_GROUP" --subscription "$subscription" --query "[].name" -o tsv)
            ;;
        *)
            echo "Unknown resource type: $resource_type, skipping..."
            continue
            ;;
    esac
    
    # Process each instance
    for instance in $instances; do
        echo "Retrieving health status for $display_name: $instance..."
        
        # Special handling for SQL Database which has server/database format
        if [ "$db_type" == "sql-database" ]; then
            # Extract server and database names
            server_name=$(echo "$instance" | cut -d'/' -f1)
            db_name=$(echo "$instance" | cut -d'/' -f2)
            
            # Replace <server> placeholder in provider_path with actual server name
            actual_provider_path=$(echo "$provider_path" | sed "s/<server>/$server_name/g")
            
            # Use database name as the instance name for the API call
            api_instance=$db_name
        else
            actual_provider_path=$provider_path
            api_instance=$instance
        fi
        
        # Get health status for current instance
        health_status=$(az rest --method get \
            --url "https://management.azure.com/subscriptions/$subscription/resourceGroups/$AZURE_RESOURCE_GROUP/providers/$actual_provider_path/$api_instance/providers/Microsoft.ResourceHealth/availabilityStatuses/current?api-version=2023-07-01-preview" \
            -o json 2>/dev/null)
        
        # Check if health status retrieval was successful
        if [ $? -eq 0 ]; then
            # Add database type and name to the health status
            health_status=$(echo "$health_status" | jq --arg type "$db_type" --arg name "$instance" --arg display "$display_name" '. + {dbType: $type, dbName: $name, displayName: $display}')
            
            # Add the health status to the array in the JSON file
            jq --argjson health "$health_status" '. += [$health]' "$HEALTH_OUTPUT" > temp.json && mv temp.json "$HEALTH_OUTPUT"
        else
            echo "Failed to retrieve health status for $instance ($actual_provider_path/$api_instance). This might be due to unsupported resource type or other API limitations."
        fi
    done
done

# Output results
echo "Health status retrieved and saved to: $HEALTH_OUTPUT"
cat "$HEALTH_OUTPUT"
