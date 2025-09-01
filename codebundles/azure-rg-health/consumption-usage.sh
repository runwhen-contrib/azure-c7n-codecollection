#!/bin/bash
set -euo pipefail

# Cleanup function
cleanup() {
    [ -f "${TEMP_JSON:-}" ] && rm -f "$TEMP_JSON"
}
trap cleanup EXIT

# Help function
show_usage() {
    cat <<EOF
Azure Cost Analysis Script

Usage: DAYS=<number> $0

Environment Variables:
  DAYS      Number of days to analyze (default: 30)
  SUB_ID    Azure Subscription ID (optional, will use default if not set)
EOF
}

# Check for help flag
if [[ "$#" -gt 0 && ("$1" == "-h" || "$1" == "--help") ]]; then
    show_usage
    exit 0
fi

# Check for required commands
for cmd in jq az; do
    if ! command -v "$cmd" &> /dev/null; then
        echo "{\"error\": \"$cmd is not installed. Please install it first.\"}" | jq .
        exit 1
    fi
done

# Set default days if not provided
DAYS=${COST_DAYS:-30}

# Validate DAYS is a positive integer
if ! [[ "$DAYS" =~ ^[0-9]+$ ]] || [ "$DAYS" -lt 1 ]; then
    echo '{"error": "DAYS must be a positive integer"}' | jq .
    exit 1
fi

# Calculate dates
END_DATE=$(date -u +"%Y-%m-%d")
START_DATE=$(date -u -d "$END_DATE - $DAYS days" +"%Y-%m-%d")

# Output file
OUTPUT_FILE="azure_cost_analysis.json"
TEMP_JSON=$(mktemp)

# Get subscription ID if not provided
if [ -z "${SUB_ID:-}" ]; then
    SUB_ID=$(az account show --query id -o tsv 2>/dev/null || true)
    if [ -z "$SUB_ID" ]; then
        echo '{"error": "Could not get Azure subscription ID. Please run az login or set SUB_ID."}' | jq . > "$OUTPUT_FILE"
        exit 1
    fi
fi

# Fetch consumption data with retry logic
MAX_RETRIES=3
RETRY_DELAY=5
retry=0

while [ $retry -lt $MAX_RETRIES ]; do
    echo "Fetching consumption data from $START_DATE to $END_DATE (Attempt $((retry + 1))/$MAX_RETRIES)..."

    if az rest \
        --method get \
        --url "https://management.azure.com/subscriptions/${SUB_ID}/providers/Microsoft.Consumption/usageDetails?api-version=2021-10-01&\$filter=properties/usageStart ge '${START_DATE}' and properties/usageEnd le '${END_DATE}'" \
        > "$TEMP_JSON" 2>/dev/null && jq -e . "$TEMP_JSON" >/dev/null 2>&1; then
        break
    fi

    retry=$((retry + 1))
    if [ $retry -lt $MAX_RETRIES ]; then
        sleep $RETRY_DELAY
    else
        echo "{\"error\": \"Failed to fetch valid data from Azure API after $MAX_RETRIES attempts\"}" | jq . > "$OUTPUT_FILE"
        echo "Last API Response:" >&2
        cat "$TEMP_JSON" >&2
        exit 1
    fi
done

# Process the data with jq
jq -n --arg timestamp "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
  --arg start_date "$START_DATE" \
  --arg end_date "$END_DATE" \
  --arg days "$DAYS" \
  --arg subscription_id "$SUB_ID" \
  --arg billing_currency "$(jq -r '.value[0].properties.billingCurrency // "USD"' "$TEMP_JSON")" \
  --argjson total_cost "$(jq -r '[.value[].properties.cost] | add // 0 | . * 100 | round / 100' "$TEMP_JSON")" \
  --argjson services "$(jq -c '
    [.value | group_by(.properties.consumedService)[] | {
      service: .[0].properties.consumedService,
      cost: (map(.properties.cost) | add | . * 100 | round / 100)
    }] | sort_by(-.cost)
  ' "$TEMP_JSON")" \
  --argjson top_resources "$(jq -c '
    [.value | group_by(.properties.resourceName)[] | {
      resource: .[0].properties.resourceName,
      resourceGroup: .[0].properties.resourceGroup,
      billingCurrency: .[0].properties.billingCurrency,
      cost: (map(.properties.cost) | add | . * 100 | round / 100),
      hours: (map(.properties.quantity) | add | . * 100 | round / 100),
      portal_url: ("https://portal.azure.com/#resource" +
        "/subscriptions/" + (.[0].properties.subscriptionId // "") +
        "/resourceGroups/" + (.[0].properties.resourceGroup // "") +
        "/providers/" + (.[0].properties.consumedService // "") +
        "/" + .[0].properties.resourceName)
    }] | sort_by(-.cost) | .[0:5]
  ' "$TEMP_JSON")" \
  --argjson daily_summary "$(jq -c '
    # Group by date and sum costs per day
    [.value[] | 
      select(.properties.date) |  # Use .properties.date instead of .properties.usageStart
      { 
        date: (.properties.date | split("T")[0]),
        cost: (.properties.cost | tonumber)
      }
    ] | 
    group_by(.date) | 
    map({
      date: .[0].date,
      cost: map(.cost) | add
    }) |
    sort_by(.date) |
    if length > 0 then
      {
        date_range: {
          start: first.date,
          end: last.date,
          total_days: length
        },
        average_daily_cost: (map(.cost) | add / length * 100 | round / 100),
        peak_day: (max_by(.cost) | {date: .date, cost: (.cost * 100 | round / 100)}),
        total_days_with_cost: (map(select(.cost > 0)) | length)
      }
    else
      null
    end
  ' "$TEMP_JSON")" \
  '{
    metadata: {
      generated_at: $timestamp,
      subscription_id: $subscription_id,
      date_range: {
        start: $start_date,
        end: $end_date,
        days: ($days | tonumber)
      },
      billing_currency: $billing_currency,
      output_file: "azure_cost_analysis.json"
    },
    summary: {
      total_cost: ($total_cost | tonumber),
      estimated_on_demand_cost: (($total_cost | tonumber) * 3 * 100 | round / 100),
      estimated_savings: (($total_cost | tonumber) * 2 * 100 | round / 100)
    },
    cost_breakdown: {
      by_service: $services,
      top_resources: $top_resources
    },
    cost_summary: $daily_summary
  }' > "$OUTPUT_FILE"

echo "Analysis complete. Results saved to $OUTPUT_FILE"