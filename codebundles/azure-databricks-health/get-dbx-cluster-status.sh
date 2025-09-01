#!/bin/bash

set -euo pipefail

PENDING_TIMEOUT=${PENDING_TIMEOUT:-30}
CHANGES_OUTPUT="cluster_status.json"
TMP_OUTPUT="tmp_cluster_status.jsonl"
> "$TMP_OUTPUT"

echo "Databricks Host: ${DATABRICKS_HOST}"
echo "Databricks Token: ${DATABRICKS_TOKEN}"

# Since DATABRICKS_HOST is provided directly, we don't need to query Azure for workspaces
CURRENT_TIME=$(date +%s)
EXIT_CODE=0

echo "🔍 Checking clusters in Databricks workspace using provided host..."

# Extract workspace name from the host URL (optional)
workspace_name=$(echo "${DATABRICKS_HOST}" | sed -E 's/https:\/\/([^.]+).*/\1/')
workspace_url=$(echo "${DATABRICKS_HOST}" | sed -E 's/https:\/\///')

if ! clusters_json=$(databricks clusters list --output JSON 2>&1); then
    echo "$clusters_json"
    exit 1
fi

# Debug: Print raw response
# echo "Raw response: $clusters_json"

# Check if we got a valid JSON response
if ! echo "$clusters_json" | jq -e . >/dev/null 2>&1; then
    echo "Error: Invalid JSON response from Databricks API"
    echo "$clusters_json"
    exit 1
fi

# Try to extract cluster count, handling different response formats
cluster_count=$(echo "$clusters_json" | jq -r 'if type=="array" then length else .clusters? | length end' 2>/dev/null)
if [ -z "$cluster_count" ] || [ "$cluster_count" = "null" ]; then
    echo "Error: Unexpected response format from Databricks API"
    echo "$clusters_json"
    exit 1
fi

if [ "$cluster_count" -eq 0 ]; then
    echo "No Databricks clusters found."
    echo "[]" > "$CHANGES_OUTPUT"
    exit 0
fi

for j in $(seq 0 $((cluster_count - 1))); do
    # Handle both direct array and clusters.array response formats
    cluster=$(echo "$clusters_json" | jq -c 'if type=="array" then .['"$j"'] else .clusters?['"$j"'] end' 2>/dev/null)
    if [ -z "$cluster" ] || [ "$cluster" = "null" ]; then
        continue
    fi
    
    cluster_source=$(echo "$cluster" | jq -r '.cluster_source // "UNKNOWN"')

    # Only filter if cluster_source is defined and not empty
    if [ -n "$cluster_source" ] && [ "$cluster_source" != "UNKNOWN" ] && [ "$cluster_source" != "UI" ] && [ "$cluster_source" != "JOB" ]; then
        continue
    fi

    CLUSTER_ID=$(echo "$cluster" | jq -r '.cluster_id')
    CLUSTER_NAME=$(echo "$cluster" | jq -r '.cluster_name')
    STATE=$(echo "$cluster" | jq -r '.state')
    START_TIME=$(echo "$cluster" | jq -r '.start_time // empty')

    if [ -n "$START_TIME" ]; then
        START_TIME_SEC=$((START_TIME / 1000))
        PENDING_DURATION_MIN=$(( (CURRENT_TIME - START_TIME_SEC) / 60 ))
    else
        PENDING_DURATION_MIN=0
    fi

    status_obj=$(jq -n \
        --arg workspace "$workspace_name" \
        --arg workspace_url "$workspace_url" \
        --arg cluster_id "$CLUSTER_ID" \
        --arg cluster_name "$CLUSTER_NAME" \
        --arg state "$STATE" \
        --arg start_time "$START_TIME" \
        --arg pending_duration_min "$PENDING_DURATION_MIN" \
        '{
            workspace: $workspace,
            workspace_url: $workspace_url,
            cluster_id: $cluster_id,
            cluster_name: $cluster_name,
            state: $state,
            start_time: $start_time,
            pending_duration_min: $pending_duration_min
        }')

    case $STATE in
        "RUNNING"|"RESIZING"|"TERMINATED")
            echo "✅ $CLUSTER_NAME is in state: $STATE"
            echo "$status_obj" | jq '. + {status: "OK", message: "Valid state"}' >> "$TMP_OUTPUT"
            ;;
        "PENDING")
            if [ "$PENDING_DURATION_MIN" -gt "$PENDING_TIMEOUT" ]; then
                echo "❌ $CLUSTER_NAME stuck in PENDING for $PENDING_DURATION_MIN minutes"
                echo "$status_obj" | jq --arg msg "Stuck in PENDING state for $PENDING_DURATION_MIN minutes" '. + {status: "WARNING", message: $msg}' >> "$TMP_OUTPUT"
                EXIT_CODE=1
            else
                echo "ℹ️ $CLUSTER_NAME is in normal PENDING state"
                echo "$status_obj" | jq '. + {status: "INFO", message: "Normal PENDING state"}' >> "$TMP_OUTPUT"
            fi
            ;;
        "ERROR")
            echo "❌ $CLUSTER_NAME is in ERROR state"
            echo "$status_obj" | jq '. + {status: "ERROR", message: "Cluster in ERROR state"}' >> "$TMP_OUTPUT"
            EXIT_CODE=1
            ;;
        *)
            echo "❌ $CLUSTER_NAME is in unexpected state: $STATE"
            echo "$status_obj" | jq '. + {status: "WARNING", message: "Unexpected state"}' >> "$TMP_OUTPUT"
            EXIT_CODE=1
            ;;
    esac
done

jq -s '.' "$TMP_OUTPUT" > "$CHANGES_OUTPUT"
echo "✅ Cluster status check completed. Results saved to: $CHANGES_OUTPUT"
exit $EXIT_CODE
