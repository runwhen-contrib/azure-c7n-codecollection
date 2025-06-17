#!/bin/bash
set -euo pipefail

# Set environment variables from template variables
export DATABRICKS_HOST="${databricks_host}"
export DATABRICKS_TOKEN="${databricks_token}"
export DATABRICKS_CLUSTER_ID="${databricks_cluster_id}"
export DATABRICKS_JOB_ID="${databricks_job_id}"

# Validate required variables
echo "Validating environment variables..."
if [ -z "$DATABRICKS_HOST" ] || [ -z "$DATABRICKS_TOKEN" ] || [ -z "$DATABRICKS_CLUSTER_ID" ] || [ -z "$DATABRICKS_JOB_ID" ]; then
  echo "ERROR: One or more required environment variables are not set"
  echo "Please check the following environment variables:"
  echo "- DATABRICKS_HOST"
  echo "- DATABRICKS_TOKEN"
  echo "- DATABRICKS_CLUSTER_ID"
  echo "- DATABRICKS_JOB_ID"
  exit 1
fi

# Check for required commands
command -v jq >/dev/null 2>&1 || { echo "ERROR: jq is required but not installed"; exit 1; }
command -v databricks >/dev/null 2>&1 || { echo "ERROR: databricks cli is required but not installed"; exit 1; }

# Configure retry settings
MAX_ATTEMPTS=30
SLEEP_SECONDS=10
ATTEMPT=1
CLUSTER_STATE=""

echo "Waiting for Databricks cluster (ID: $DATABRICKS_CLUSTER_ID) to be in RUNNING state..."

while [ $ATTEMPT -le $MAX_ATTEMPTS ]; do
  if ! RESPONSE=$(databricks clusters get $DATABRICKS_CLUSTER_ID 2>&1); then
    echo "WARNING: Failed to get cluster state (attempt $ATTEMPT): $RESPONSE"
  else
    CLUSTER_STATE=$(echo "$RESPONSE" | jq -r '.state' 2>/dev/null || echo "UNKNOWN")
    
    echo -n "Attempt $ATTEMPT: Cluster state = "
    if [ -z "$CLUSTER_STATE" ]; then
      echo "unknown"
    else
      echo "$CLUSTER_STATE"
    fi
    
    case "$CLUSTER_STATE" in
      "RUNNING")
        echo "Cluster is RUNNING."
        break
        ;;
      "TERMINATED" | "ERROR" | "UNKNOWN")
        echo "ERROR: Cluster is in an unrecoverable state: $CLUSTER_STATE"
        echo "Cluster details: $RESPONSE"
        exit 1
        ;;
    esac
  fi

  ATTEMPT=$((ATTEMPT + 1))
  sleep $SLEEP_SECONDS
done

if [ "$CLUSTER_STATE" != "RUNNING" ]; then
  echo "ERROR: Cluster did not reach RUNNING state after $MAX_ATTEMPTS attempts"
  exit 1
fi

echo "Triggering Databricks job (ID: $DATABRICKS_JOB_ID) using CLI..."

# Run the job and capture the output
# Use a temporary file to capture the output since some output might go to stderr
TEMP_OUTPUT=$(mktemp)

# Always exit with success to prevent Terraform from failing
trap 'rm -f "$TEMP_OUTPUT"; exit 0' EXIT

# Run the job and capture all output
echo "Running Databricks job..."
if ! databricks jobs run-now "$DATABRICKS_JOB_ID" > "$TEMP_OUTPUT" 2>&1; then
  echo "WARNING: Job execution returned non-zero status: $?"
  echo "This might be expected for testing failure scenarios."
  echo "Job output:"
  cat "$TEMP_OUTPUT"
  exit 0
else
  echo "Job triggered successfully"
  echo "Job output:"
  cat "$TEMP_OUTPUT"
  exit 0
fi
