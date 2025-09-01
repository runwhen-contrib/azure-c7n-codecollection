#!/bin/bash

set -euo pipefail

DAYS=${DAYS:-90}
OUTPUT_JSON="unused-rgs.json"
START_DATE=$(date -u -d "-$DAYS days" +"%Y-%m-%dT%H:%M:%SZ")

# Dependencies check
for cmd in jq az; do
    if ! command -v $cmd &> /dev/null; then
        echo "Error: $cmd is required but not installed." >&2
        exit 1
    fi
done

# Get Azure account info
if ! az_account=$(az account show 2>/dev/null); then
    echo "Error: Not logged into Azure CLI. Please run 'az login'" >&2
    exit 1
fi

# Get subscription ID once
SUB_ID=$(echo "$az_account" | jq -r '.id')
if [ -z "$SUB_ID" ]; then
    echo "Error: Could not determine subscription ID" >&2
    exit 1
fi

# Trap cleanup on exit
cleanup() {
    echo -e "\nScript interrupted. Cleaning up..."
    if [ "${#UNUSED_RGS_ARR[@]:-0}" -gt 0 ]; then
        echo "${UNUSED_RGS_ARR[*]}" | jq -s '.' > "$OUTPUT_JSON"
        echo "Partial results written to $OUTPUT_JSON"
    fi
    exit 1
}

trap cleanup INT TERM

echo "Scanning for unused resource groups (no resources + no activity in $DAYS days)..."
echo

declare -a UNUSED_RGS_ARR
TOTAL_RGS=0
UNUSED_RGS=0

# Process each RG
for rg in $(az group list --query "[].name" -o tsv); do
    echo "Checking resource group: $rg"
    rg_info=$(az group show --name "$rg" --query '{name:name, location:location, tags:tags}' -o json)
    TOTAL_RGS=$((TOTAL_RGS + 1))

    if ! resource_count=$(az resource list --resource-group "$rg" --query "length(@)" -o tsv); then
        echo "  Warning: Failed to list resources" >&2
        continue
    fi

    if [ "$resource_count" -eq 0 ]; then
        echo "  No resources found"
        reason="No resources found"

        if ! activity_count=$(az monitor activity-log list \
            --resource-group "$rg" \
            --start-time "$START_DATE" \
            --query "length(@)" -o tsv 2>/dev/null); then
            activity_count=1
            reason="$reason, activity check failed"
            echo "  Warning: Failed to check activity logs" >&2
        fi

        activity_count=${activity_count:-0}

        if [ "$activity_count" -eq 0 ]; then
            echo "  No activity in last $DAYS days - Marked as UNUSED"
            reason="$reason, no activity in last $DAYS days"
            UNUSED_RGS=$((UNUSED_RGS + 1))

            # Create portal URL using the pre-fetched subscription ID
            portal_url="https://portal.azure.com/#@/resource/subscriptions/$SUB_ID/resourceGroups/$rg/overview"
            
            UNUSED_RGS_ARR+=("$(jq -n \
                --arg name "$rg" \
                --argjson resource_count "$resource_count" \
                --argjson activity_count "$activity_count" \
                --arg reason "${reason#, }" \
                --arg portal_url "$portal_url" \
                --argjson details "$rg_info" \
                '{
                    name: $name,
                    resource_count: $resource_count,
                    activity_count: $activity_count,
                    reason: $reason,
                    portal_url: $portal_url,
                    details: $details
                }')")
        else
            echo "  Activity found in last $DAYS days - In use"
        fi
    else
        echo "  Resources found ($resource_count) - In use"
    fi

    echo
done

# Final JSON output
timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
jq -n \
    --arg timestamp "$timestamp" \
    --arg days "$DAYS" \
    --arg total_checked "$TOTAL_RGS" \
    --arg unused_count "$UNUSED_RGS" \
    --arg start_date "$START_DATE" \
    --arg end_date "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
    --argjson unused_rgs "$(echo "${UNUSED_RGS_ARR[@]}" | jq -s '.')" \
    '{
        metadata: {
            generated_at: $timestamp,
            lookback_days: ($days | tonumber),
            start_date: $start_date,
            end_date: $end_date,
            total_resource_groups_checked: ($total_checked | tonumber),
            unused_resource_groups_count: ($unused_count | tonumber)
        },
        unused_resource_groups: $unused_rgs
    }' > "$OUTPUT_JSON"

# Summary
echo "======================================="
echo "Scan complete"
echo "Resource groups checked: $TOTAL_RGS"
echo "Unused resource groups found: $UNUSED_RGS"
echo "Results written to: $OUTPUT_JSON"
echo "======================================="
