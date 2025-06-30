#!/bin/bash

HEALTH_OUTPUT="vm_health.json"
echo "[]" > "$HEALTH_OUTPUT"

# Get or set subscription ID
if [ -z "$AZURE_SUBSCRIPTION_ID" ]; then
    subscription=$(az account show --query "id" -o tsv)
    echo "AZURE_SUBSCRIPTION_ID is not set. Using current subscription ID: $subscription"
else
    subscription="$AZURE_SUBSCRIPTION_ID"
    echo "Using specified subscription ID: $subscription"
fi

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

# Define provider path for virtual machines
provider_path="Microsoft.Compute/virtualMachines"
display_name="Azure Virtual Machine"

echo "Processing resource type: virtual-machine ($display_name)"

# Get list of VMs in the specific resource group
instances=$(az vm list -g "$AZURE_RESOURCE_GROUP" --subscription "$subscription" --query "[].{name:name, resourceGroup:resourceGroup}" -o tsv | sort -u)

# Check if any VMs were found
if [ -z "$instances" ]; then
    echo "No virtual machines found in the subscription."
    exit 0
fi

# Process each VM
echo "Found $(echo "$instances" | wc -l) virtual machines to process..."

echo "$instances" | while read -r vm_name resource_group; do
    echo "Retrieving health status for $display_name: $vm_name in resource group $resource_group..."
    
    # Get health status for current VM
    health_status=$(az rest --method get \
        --url "https://management.azure.com/subscriptions/$subscription/resourceGroups/$resource_group/providers/$provider_path/$vm_name/providers/Microsoft.ResourceHealth/availabilityStatuses/current?api-version=2023-07-01-preview" \
        -o json 2>/dev/null)
    
    # Check if health status retrieval was successful
    if [ $? -eq 0 ]; then
        # Add resource type, name, and resource group to the health status
        health_status=$(echo "$health_status" | jq --arg type "virtual-machine" --arg name "$vm_name" --arg rg "$resource_group" --arg display "$display_name" '. + {resourceType: $type, resourceName: $name, resourceGroup: $rg, displayName: $display}')
        
        # Add the health status to the array in the JSON file
        jq --argjson health "$health_status" '. += [$health]' "$HEALTH_OUTPUT" > temp.json && mv temp.json "$HEALTH_OUTPUT"
    else
        echo "Failed to retrieve health status for $vm_name in resource group $resource_group. This might be due to unsupported resource type or other API limitations."
    fi
done

# Output results
echo "Virtual machine health status retrieved and saved to: $HEALTH_OUTPUT"
cat "$HEALTH_OUTPUT"
