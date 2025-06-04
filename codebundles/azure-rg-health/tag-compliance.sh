#!/bin/bash

# Exit on error
set -e

# Check if required environment variables are set
if [ -z "$TAGS" ] || [ -z "$AZURE_RESOURCE_GROUP" ]; then
    echo "Error: Required environment variables TAGS and AZURE_RESOURCE_GROUP must be set"
    exit 1
fi

# Convert comma-separated tags to array
IFS=',' read -ra REQUIRED_TAGS <<< "$TAGS"

echo "Checking resource group '$AZURE_RESOURCE_GROUP' and its resources for missing tags: ${TAGS}"

# Initialize array for non-compliant resources
non_compliant_resources=()

# First, check the resource group itself
echo "Checking tags for resource group: $AZURE_RESOURCE_GROUP"
rg_info=$(az group show --name "$AZURE_RESOURCE_GROUP" --query "{tags: tags, id: id}" -o json)
rg_tags=$(echo "$rg_info" | jq -r '.tags')
rg_id=$(echo "$rg_info" | jq -r '.id')
missing_rg_tags=()
for required_tag in "${REQUIRED_TAGS[@]}"; do
    if ! echo "$rg_tags" | jq -e "has(\"$required_tag\")" > /dev/null; then
        missing_rg_tags+=("$required_tag")
    fi
done

if [ ${#missing_rg_tags[@]} -gt 0 ]; then
    non_compliant_resources+=("{\"resource_name\":\"$AZURE_RESOURCE_GROUP\",\"resource_type\":\"resource_group\",\"resource_id\":\"$rg_id\",\"missing_tags\":[\"${missing_rg_tags[*]// /\",\"}\"]}")
    echo "❌ Resource Group '$AZURE_RESOURCE_GROUP' is missing the following tags: ${missing_rg_tags[*]}"
else
    echo "✅ Resource Group '$AZURE_RESOURCE_GROUP' has all required tags"
fi

# Get all resources in the resource group with their types
resources=$(az resource list --resource-group "$AZURE_RESOURCE_GROUP" --query "[].{name:name, id:id, type:type}" -o json)

# Check each resource
while read -r resource; do
    resource_name=$(echo "$resource" | jq -r '.name')
    resource_id=$(echo "$resource" | jq -r '.id')
    # Get resource type and simplify it (e.g., Microsoft.KeyVault/vaults -> keyvault)
    full_resource_type=$(echo "$resource" | jq -r '.type')
    resource_type=$(echo "$full_resource_type" | awk -F'/' '{print tolower($NF)}')
    echo "Checking tags for resource: $resource_name (Type: $resource_type)"
    
    # Get existing tags for the resource
    existing_tags=$(az resource show --ids "$resource_id" --query "tags" -o json)
    
    # Check for missing tags
    missing_tags=()
    for required_tag in "${REQUIRED_TAGS[@]}"; do
        if ! echo "$existing_tags" | jq -e "has(\"$required_tag\")" > /dev/null; then
            missing_tags+=("$required_tag")
        fi
    done
    
    # If resource has missing tags, add it to non-compliant list
    if [ ${#missing_tags[@]} -gt 0 ]; then
        non_compliant_resources+=("{\"resource_name\":\"$resource_name\",\"resource_type\":\"$resource_type\",\"resource_id\":\"$resource_id\",\"azure_resource_type\":\"$full_resource_type\",\"missing_tags\":[\"${missing_tags[*]// /\",\"}\"]}")
        echo "❌ Resource '$resource_name' (Type: $resource_type) is missing the following tags: ${missing_tags[*]}"
    else
        echo "✅ Resource '$resource_name' has all required tags"
    fi
done < <(echo "$resources" | jq -c '.[]')

# Create final JSON report
if [ ${#non_compliant_resources[@]} -eq 0 ]; then
    report='{"resource_group":"'$AZURE_RESOURCE_GROUP'", "non_compliant_resources":[]}'
else
    # Join array elements with commas
    IFS=, joined_resources="${non_compliant_resources[*]}"
    report="{\"resource_group\":\"$AZURE_RESOURCE_GROUP\",\"non_compliant_resources\":[$joined_resources]}"
fi

# Get the directory where the script is located
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
REPORT_FILE="$SCRIPT_DIR/tag-compliance-report.json"

# Save report to file
echo "Saving report to: $REPORT_FILE"
echo "Report content length: ${#report} characters"

# Write to a temporary file first, then move to final location to ensure atomic write
echo "$report" | jq '.' > "$REPORT_FILE.tmp" && mv "$REPORT_FILE.tmp" "$REPORT_FILE"
if [ $? -ne 0 ]; then
    echo "Error: Failed to write report file" 1>&2
    exit 1
fi

# Exit with status code 1 if any resources are missing tags
if [ ${#non_compliant_resources[@]} -gt 0 ]; then
    echo "Found ${#non_compliant_resources[@]} resources with missing tags. See tag-compliance-report.json for details."
    exit 1
else
    echo "All resources have required tags"
    exit 0
fi