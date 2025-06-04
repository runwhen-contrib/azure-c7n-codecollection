#!/bin/bash

# Exit on error
set -e

# Check if required environment variables are set
if [ -z "$TAGS" ]; then
    echo "Error: Required environment variable TAGS must be set"
    exit 1
fi

# Convert comma-separated tags to array
IFS=',' read -ra REQUIRED_TAGS <<< "$TAGS"

# Determine which resource groups to check
resource_groups_to_check=()
if [ -n "$RESOURCE_GROUPS" ]; then
    # Use specified resource groups
    IFS=',' read -ra resource_groups_to_check <<< "$RESOURCE_GROUPS"
    echo "Checking specified resource groups: ${RESOURCE_GROUPS}"
else
    # Get all resource groups in the Azure account
    echo "No resource groups specified. Getting all resource groups in the Azure account..."
    mapfile -t resource_groups_to_check < <(az group list --query "[].name" -o tsv)
    echo "Found ${#resource_groups_to_check[@]} resource groups to check"
fi

echo "Required tags to check: ${TAGS}"
echo "=========================================="

# Initialize array for non-compliant resources across all resource groups
all_non_compliant_resources=()

# Function to convert Azure resource ID to portal URL
convert_to_portal_url() {
    local resource_id=$1
    # Azure portal base URL
    local base_url="https://portal.azure.com/#@/resource"
    # URL encode the resource ID
    local encoded_id=$(printf '%s\n' "$resource_id" | jq -sRr @uri)
    echo "${base_url}${encoded_id}"
}

# Function to check tags for a single resource group
check_resource_group() {
    local rg_name=$1
    echo ""
    echo "Processing Resource Group: $rg_name"
    echo "----------------------------------------"
    
    # Check if resource group exists
    if ! az group show --name "$rg_name" &>/dev/null; then
        echo "Resource group '$rg_name' does not exist or is not accessible. Skipping..."
        return
    fi
    
    # Initialize array for non-compliant resources in this RG
    local non_compliant_resources=()
    
    # First, check the resource group itself
    echo "Checking tags for resource group: $rg_name"
    local rg_info=$(az group show --name "$rg_name" --query "{tags: tags, id: id}" -o json)
    local rg_tags=$(echo "$rg_info" | jq -r '.tags')
    local rg_id=$(echo "$rg_info" | jq -r '.id')
    local missing_rg_tags=()
    
    for required_tag in "${REQUIRED_TAGS[@]}"; do
        if [ "$rg_tags" = "null" ] || ! echo "$rg_tags" | jq -e "has(\"$required_tag\")" > /dev/null 2>&1; then
            missing_rg_tags+=("$required_tag")
        fi
    done

    if [ ${#missing_rg_tags[@]} -gt 0 ]; then
        local rg_portal_url=$(convert_to_portal_url "$rg_id")
        non_compliant_resources+=("{\"resource_name\":\"$rg_name\",\"resource_type\":\"resource_group\",\"resource_id\":\"$rg_id\",\"portal_url\":\"$rg_portal_url\",\"missing_tags\":[\"${missing_rg_tags[*]// /\",\"}\"]}")
        echo "Resource Group '$rg_name' is missing the following tags: ${missing_rg_tags[*]}"
    else
        echo "Resource Group '$rg_name' has all required tags"
    fi

    # Get all resources in the resource group with their types
    local resources=$(az resource list --resource-group "$rg_name" --query "[].{name:name, id:id, type:type}" -o json)
    local resource_count=$(echo "$resources" | jq length)
    
    if [ "$resource_count" -eq 0 ]; then
        echo "No resources found in resource group '$rg_name'"
    else
        echo "Found $resource_count resources in '$rg_name'"
        
        # Check each resource
        while read -r resource; do
            local resource_name=$(echo "$resource" | jq -r '.name')
            local resource_id=$(echo "$resource" | jq -r '.id')
            # Get resource type and simplify it (e.g., Microsoft.KeyVault/vaults -> keyvault)
            local full_resource_type=$(echo "$resource" | jq -r '.type')
            local resource_type=$(echo "$full_resource_type" | awk -F'/' '{print tolower($NF)}')
            echo "  Checking tags for resource: $resource_name (Type: $resource_type)"
            
            # Get existing tags for the resource
            local existing_tags=$(az resource show --ids "$resource_id" --query "tags" -o json 2>/dev/null || echo "null")
            
            # Check for missing tags
            local missing_tags=()
            for required_tag in "${REQUIRED_TAGS[@]}"; do
                # Check if tags are null, empty string, empty object, or missing the specific tag
                if [ -z "$existing_tags" ] || [ "$existing_tags" = "null" ] || [ "$existing_tags" = "{}" ] || [ "$existing_tags" = '""' ] || ! echo "$existing_tags" | jq -e "has(\"$required_tag\")" > /dev/null 2>&1; then
                    missing_tags+=("$required_tag")
                fi
            done
            
            # If resource has missing tags, add it to non-compliant list
            if [ ${#missing_tags[@]} -gt 0 ]; then
                local resource_portal_url=$(convert_to_portal_url "$resource_id")
                non_compliant_resources+=("{\"resource_name\":\"$resource_name\",\"resource_type\":\"$resource_type\",\"resource_id\":\"$resource_id\",\"azure_resource_type\":\"$full_resource_type\",\"resource_group\":\"$rg_name\",\"portal_url\":\"$resource_portal_url\",\"missing_tags\":[\"${missing_tags[*]// /\",\"}\"]}")
                echo "  Resource '$resource_name' (Type: $resource_type) is missing the following tags: ${missing_tags[*]}"
            else
                echo "  Resource '$resource_name' has all required tags"
            fi
        done < <(echo "$resources" | jq -c '.[]')
    fi
    
    # Add this RG's non-compliant resources to the global array
    all_non_compliant_resources+=("${non_compliant_resources[@]}")
    
    echo "Resource Group '$rg_name' summary: ${#non_compliant_resources[@]} non-compliant resources"
}

# Process each resource group
for rg in "${resource_groups_to_check[@]}"; do
    check_resource_group "$rg"
done

echo ""
echo "=========================================="
echo "FINAL SUMMARY"
echo "=========================================="

# Create final JSON report
if [ ${#all_non_compliant_resources[@]} -eq 0 ]; then
    if [ -n "$RESOURCE_GROUPS" ]; then
        report="{\"checked_resource_groups\":[\"${resource_groups_to_check[*]// /\",\"}\"],\"total_checked\":${#resource_groups_to_check[@]},\"non_compliant_resources\":[]}"
    else
        report="{\"checked_resource_groups\":\"all\",\"total_checked\":${#resource_groups_to_check[@]},\"non_compliant_resources\":[]}"
    fi
else
    # Join array elements with commas
    IFS=, joined_resources="${all_non_compliant_resources[*]}"
    if [ -n "$RESOURCE_GROUPS" ]; then
        report="{\"checked_resource_groups\":[\"${resource_groups_to_check[*]// /\",\"}\"],\"total_checked\":${#resource_groups_to_check[@]},\"non_compliant_resources\":[$joined_resources]}"
    else
        report="{\"checked_resource_groups\":\"all\",\"total_checked\":${#resource_groups_to_check[@]},\"non_compliant_resources\":[$joined_resources]}"
    fi
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

# Final summary
echo "Checked ${#resource_groups_to_check[@]} resource group(s)"
echo "Found ${#all_non_compliant_resources[@]} total resources with missing tags"

# Exit with status code 1 if any resources are missing tags
if [ ${#all_non_compliant_resources[@]} -gt 0 ]; then
    echo "COMPLIANCE CHECK FAILED: Found ${#all_non_compliant_resources[@]} resources with missing tags. See tag-compliance-report.json for details."
    exit 1
else
    echo "COMPLIANCE CHECK PASSED: All resources have required tags"
    exit 0
fi