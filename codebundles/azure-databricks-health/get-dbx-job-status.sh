#!/bin/bash

set -euo pipefail

# Configuration
OUTPUT_FILE="dbx_job_status.json"
TMP_OUTPUT="tmp_job_status.jsonl"
NUM_RECENT_RUNS=${NUM_RECENT_RUNS:-10}  # Default to 10 recent runs per job
MAX_JOB_DURATION_MINUTES=${MAX_JOB_DURATION_MINUTES:-30}  # Default to 30 minutes

# Validate required environment variables
if [ -z "${DATABRICKS_HOST:-}" ]; then
    echo "Error: DATABRICKS_HOST environment variable is not set"
    exit 1
fi

if [ -z "${DATABRICKS_TOKEN:-}" ]; then
    echo "Error: DATABRICKS_TOKEN environment variable is not set"
    exit 1
fi

# Validate DATABRICKS_HOST format
if ! echo "${DATABRICKS_HOST}" | grep -qE '^https://[a-zA-Z0-9-]+\.'; then
    echo "Error: DATABRICKS_HOST must be in format: https://<workspace>.<deployment>.cloud.databricks.com"
    exit 1
fi

echo "Validated DATABRICKS_HOST"
echo "Databricks Host: $(echo "${DATABRICKS_HOST}" | sed 's/\(^https:\/\/[^.]\+\)\.\+$/\1.******/')"
echo "Databricks Token: ********"  # Don't echo the actual token for security

# Initialize output files
> "$TMP_OUTPUT"
echo "[]" > "$OUTPUT_FILE"

# Extract workspace name from the host URL or Azure CLI
workspace_name=""
if command -v az &> /dev/null && [ -n "${AZURE_RESOURCE_GROUP:-}" ]; then
    workspace_name=$(az databricks workspace list -g "$AZURE_RESOURCE_GROUP" --query "[?workspaceUrl=='${DATABRICKS_HOST#https://}'].name" -o tsv)
fi
if [ -z "$workspace_name" ]; then
    workspace_name=$(echo "${DATABRICKS_HOST}" | sed -E 's/https:\/\/([^.]+).*/\1/')
fi
workspace_url=$(echo "${DATABRICKS_HOST}" | sed -E 's/https:\/\///')

echo "Checking job runs in Databricks workspace: $workspace_name..."

# Get all jobs
echo "Retrieving jobs list..."
jobs_json=$(databricks jobs list --output JSON 2>/dev/null) || {
    echo "Failed to retrieve jobs for workspace"
    exit 1
}

# Count jobs (directly use the array from the output)
job_count=$(echo "$jobs_json" | jq 'length')
echo "DEBUG: jobs_json = $jobs_json"
echo "DEBUG: job_count = $job_count"

echo "Found $job_count jobs in workspace"

if [ "$job_count" -eq 0 ]; then
    echo "No Databricks jobs found."
    echo "[]" > "$OUTPUT_FILE"
    exit 0
fi

# Process each job
for j in $(seq 0 $((job_count - 1))); do
    echo "DEBUG: Starting job loop for job index $j"
    # Initialize counters for each job
    pending_runs=0
    running_runs=0
    terminating_runs=0
    successful_runs=0
    failed_runs=0
    skipped_runs=0
    other_runs=0
    long_run=0
    
    job=$(echo "$jobs_json" | jq ".[$j]")
    job_id=$(echo "$job" | jq -r '.job_id')
    job_name=$(echo "$job" | jq -r '.settings.name')
    
    # Skip if job_name is empty or null
    if [ -z "$job_name" ] || [ "$job_name" = "null" ]; then
        echo "Skipping job with ID $job_id (no name found)"
        continue
    fi
    
    echo "Processing job: $job_name (ID: $job_id)"
    
    # Get recent runs for this job using jobs list-runs and capture any error output
    error_file=$(mktemp)
    runs_json=$(databricks jobs list-runs --job-id "$job_id" --limit "$NUM_RECENT_RUNS" --output JSON 2>"$error_file")
    echo "DEBUG: jobs list-runs exit code: $? for job $job_id"
    if [ $? -ne 0 ]; then
        error_msg=$(cat "$error_file" | tr -d '"' | tr -d '\n')
        echo "Failed to retrieve runs for job $job_id: $error_msg"
        # Add job with error to output
        job_obj=$(jq -n \
            --arg workspace "$workspace_name" \
            --arg workspace_url "$workspace_url" \
            --arg job_id "$job_id" \
            --arg job_name "$job_name" \
            --arg error_msg "$error_msg" \
            '{
                workspace: $workspace,
                workspace_url: $workspace_url,
                job_id: $job_id,
                job_name: $job_name,
                status: "ERROR",
                message: ("Failed to retrieve runs for this job: " + $error_msg),
                error_details: $error_msg,
                runs: []
            }')
        echo "$job_obj" >> "$TMP_OUTPUT"
        rm -f "$error_file"
        continue
    fi
    rm -f "$error_file"
    
    echo "DEBUG: runs_json for job $job_id = $runs_json"
    # Check if we got a valid response with runs (either direct array or wrapped in runs object)
    if echo "$runs_json" | jq -e 'if type=="array" then true else .runs? | type=="array" end' > /dev/null 2>&1; then
        # If the response is already an array, use it directly
        if echo "$runs_json" | jq -e 'type=="array"' > /dev/null; then
            runs_data="$runs_json"
        else
            # Otherwise, try to extract the runs array
            runs_data=$(echo "$runs_json" | jq -c '.runs // []' 2>/dev/null || echo '[]')
        fi
    else
        echo "Invalid response format for job $job_id runs. Response: $runs_json"
        # Add job with error to output
        job_obj=$(jq -n \
            --arg workspace "$workspace_name" \
            --arg workspace_url "$workspace_url" \
            --arg job_id "$job_id" \
            --arg job_name "$job_name" \
            '{
                workspace: $workspace,
                workspace_url: $workspace_url,
                job_id: $job_id,
                job_name: $job_name,
                status: "ERROR",
                message: "Invalid response format when retrieving runs",
                runs: []
            }')
        echo "$job_obj" >> "$TMP_OUTPUT"
        continue
    fi
    run_count=$(echo "$runs_data" | jq 'length')
    echo "DEBUG: run_count for job $job_id = $run_count"
    
    if [ "$run_count" -eq 0 ]; then
        echo "No runs found for job: $job_name"
        # Add job with no runs to output
        job_obj=$(jq -n \
            --arg workspace "$workspace_name" \
            --arg workspace_url "$workspace_url" \
            --arg job_id "$job_id" \
            --arg job_name "$job_name" \
            '{
                workspace: $workspace,
                workspace_url: $workspace_url,
                job_id: $job_id,
                job_name: $job_name,
                status: "INFO",
                message: "No recent runs found",
                runs: []
            }')
        echo "$job_obj" >> "$TMP_OUTPUT"
        continue
    fi
    
    echo "Found $run_count recent runs for job: $job_name"
    
    # Process each run
    failed_runs=0
    runs_array="[]"
    
    for r in $(seq 0 $((run_count - 1))); do
        run=$(echo "$runs_data" | jq ".[$r]")
        run_id=$(echo "$run" | jq -r '.run_id // .job_run_id')
        
        # Handle both response formats for state
        result_state=$(echo "$run" | jq -r '.state.result_state? // .result_state? // "UNKNOWN"')
        life_cycle_state=$(echo "$run" | jq -r '.state.life_cycle_state? // .state? // "UNKNOWN"')
        
        # Handle both timestamp formats (milliseconds and seconds)
        start_time_ms=$(echo "$run" | jq -r '.start_time? // empty' | grep -E '^[0-9]+$' || true)
        end_time_ms=$(echo "$run" | jq -r '.end_time? // empty' | grep -E '^[0-9]+$' || true)
        
        # If timestamps are in seconds, convert to milliseconds
        if [ -n "$start_time_ms" ] && [ "${#start_time_ms}" -lt 13 ]; then
            start_time_ms=$((start_time_ms * 1000))
        fi
        if [ -n "$end_time_ms" ] && [ "${#end_time_ms}" -lt 13 ]; then
            end_time_ms=$((end_time_ms * 1000))
        fi
        
        start_time=$start_time_ms
        end_time=$end_time_ms
        
        # Format timestamps
        if [ -n "$start_time" ]; then
            start_time_fmt=$(date -d @$((start_time / 1000)) '+%Y-%m-%d %H:%M:%S')
        else
            start_time_fmt="N/A"
        fi
        
        if [ -n "$end_time" ]; then
            end_time_fmt=$(date -d @$((end_time / 1000)) '+%Y-%m-%d %H:%M:%S')
        else
            end_time_fmt="N/A"
        fi
        
        # Calculate duration if both start and end times are available
        if [ -n "$start_time" ] && [ -n "$end_time" ]; then
            duration_sec=$(( (end_time - start_time) / 1000 ))
            duration_min=$(( duration_sec / 60 ))
            duration="$duration_min minutes"
        else
            duration="N/A"
        fi
        
        # Get error details for the run or its tasks
        error_details=""
        error_file=$(mktemp)
        run_details=$(databricks jobs get-run "$run_id" --output json 2>"$error_file")
        echo "DEBUG: run_details for run $run_id: $run_details"
        run_output=$(databricks jobs get-run-output "$run_id" --output JSON 2>/dev/null || echo '{}')

        # Check for tasks array in run_details
        task_errors="[]"
        task_count=$(echo "$run_details" | jq '.tasks | length' 2>/dev/null)
        task_count=${task_count:-0}
        echo "DEBUG: task_count for run $run_id: $task_count"
        if [ "$task_count" -gt 0 ]; then
            for t in $(seq 0 $((task_count - 1))); do
                task=$(echo "$run_details" | jq ".tasks[$t]")
                task_key=$(echo "$task" | jq -r '.task_key // ""')
                task_run_id=$(echo "$task" | jq -r '.run_id // empty')
                if [ -n "$task_run_id" ]; then
                    task_output=$(databricks jobs get-run-output "$task_run_id" --output JSON 2>/dev/null || echo '{}')
                    echo "DEBUG: task_output for $task_key ($task_run_id): $task_output"
                    task_error=$(echo "$task_output" | jq -r '.error // ""')
                    task_error_trace=$(echo "$task_output" | jq -r '.error_trace // ""')
                    echo "DEBUG: task_error for $task_key: $task_error"
                    echo "DEBUG: task_error_trace for $task_key: $task_error_trace"
                    task_state_message=$(echo "$task" | jq -r '.state.state_message // ""')
                    task_status=$(echo "$task" | jq -r '.status.termination_details.code // ""')
                    task_errors=$(echo "$task_errors" | jq --arg key "$task_key" --arg run_id "$task_run_id" --arg msg "$task_state_message" --arg err "$task_error" --arg trace "$task_error_trace" --arg status "$task_status" '. + [{task_key: $key, run_id: $run_id, state_message: $msg, error: $err, error_trace: $trace, status: $status}]')
                fi
            done
        fi

        # If there are task errors, use them as error_details
        if [ "$task_errors" != "[]" ]; then
            # Promote single task error to top-level if only one task
            if [ "$task_count" -eq 1 ]; then
                main_task_error=$(echo "$task_errors" | jq -r '.[0].error')
                main_task_error_trace=$(echo "$task_errors" | jq -r '.[0].error_trace')
                if [ -n "$main_task_error" ] || [ -n "$main_task_error_trace" ]; then
                    error_details=$(jq -n \
                        --arg error "$main_task_error" \
                        --arg error_trace "$main_task_error_trace" \
                        '{error: $error, error_trace: $error_trace}' | tr -d '\n')
                else
                    error_details=$(jq -n --argjson task_errors "$task_errors" '{task_errors: $task_errors}' | tr -d '\n')
                fi
            else
                error_details=$(jq -n --argjson task_errors "$task_errors" '{task_errors: $task_errors}' | tr -d '\n')
            fi
        else
            # Fallback to run-level error extraction
            error_message=$(echo "$run_details" | jq -r '.state.state_message // ""')
            error_trace=$(echo "$run_output" | jq -r '.error_trace // ""')
            error_text=$(echo "$run_output" | jq -r '.error // ""')
            if [ -n "$error_message" ] || [ -n "$error_trace" ] || [ -n "$error_text" ]; then
                error_details=$(jq -n \
                    --arg message "$error_message" \
                    --arg trace "$error_trace" \
                    --arg error "$error_text" \
                    '{error_message: $message, error_trace: $trace, error: $error}' | tr -d '\n')
            fi
        fi
        rm -f "$error_file"
        
        # Create run object with error details if available
        run_obj=$(jq -n \
            --arg run_id "$run_id" \
            --arg result_state "$result_state" \
            --arg life_cycle_state "$life_cycle_state" \
            --arg start_time "$start_time_fmt" \
            --arg end_time "$end_time_fmt" \
            --arg duration "$duration" \
            --argjson error_details "${error_details:-"{}"}" \
            '{
                run_id: $run_id,
                result_state: $result_state,
                life_cycle_state: $life_cycle_state,
                start_time: $start_time,
                end_time: $end_time,
                duration: $duration,
                error_details: $error_details
            }')
        
        runs_array=$(echo "$runs_array" | jq --argjson run "$run_obj" '. + [$run]')
        
        # Determine run status based on life_cycle_state and result_state
        case "$life_cycle_state" in
            "PENDING")
                echo "Run $run_id is pending"
                pending_runs=$((pending_runs + 1))
                ;;
            "RUNNING")
                echo "Run $run_id is running"
                long_run=$((long_run + 1))
                ;;
            "TERMINATING")
                echo "Run $run_id is terminating"
                terminating_runs=$((terminating_runs + 1))
                ;;
            "TERMINATED")
                if [ "$result_state" = "SUCCESS" ]; then
                    echo "Run $run_id completed successfully"
                    successful_runs=$((successful_runs + 1))
                else
                    failed_runs=$((failed_runs + 1))
                    echo "Run $run_id failed with state: $result_state"
                fi
                ;;
            "SKIPPED")
                echo "Run $run_id was skipped"
                skipped_runs=$((skipped_runs + 1))
                ;;
            "INTERNAL_ERROR")
                failed_runs=$((failed_runs + 1))
                echo "Run $run_id encountered an internal error"
                ;;
            *)
                echo "Run $run_id has unknown state: $life_cycle_state"
                other_runs=$((other_runs + 1))
                ;;
        esac
    done
    
    # Initialize counters if not set
    : ${pending_runs:=0} ${running_runs:=0} ${terminating_runs:=0}
    : ${successful_runs:=0} ${failed_runs:=0} ${skipped_runs:=0} ${other_runs:=0}
    
    # Create job status object with detailed status message
    if [ "$failed_runs" -gt 0 ]; then
        status="ERROR"
        message="$failed_runs failed"
    elif [ "$long_run" -gt 0 ]; then
        status="WARNING"
        message="$long_run long-running"
        # Log long-running job details
        echo "Long-running job detected: $job_name (ID: $job_id)"
    elif [ "$running_runs" -gt 0 ] || [ "$pending_runs" -gt 0 ] || [ "$terminating_runs" -gt 0 ]; then
        status="WARNING"
        message="In progress"
    else
        status="OK"
        message="All runs completed successfully"
    fi
    
    # Add detailed status counts
    message+=" (${successful_runs} successful, ${failed_runs} failed, ${running_runs} running, ${pending_runs} pending, ${terminating_runs} terminating, ${skipped_runs} skipped, ${other_runs} other)"
    
    # Calculate long_runs count
    long_run_count=$(echo "$runs_array" | jq 'map(select(.is_long_running == true)) | length')
    
    job_obj=$(jq -n \
        --arg workspace "$workspace_name" \
        --arg workspace_name "$workspace_name" \
        --arg workspace_url "$workspace_url" \
        --arg job_id "$job_id" \
        --arg job_name "$job_name" \
        --arg status "$status" \
        --arg message "$message" \
        --argjson runs "$runs_array" \
        --argjson pending_runs "$pending_runs" \
        --argjson running_runs "$running_runs" \
        --argjson terminating_runs "$terminating_runs" \
        --argjson successful_runs "$successful_runs" \
        --argjson failed_runs "$failed_runs" \
        --argjson skipped_runs "$skipped_runs" \
        --argjson other_runs "$other_runs" \
        --argjson long_runs "$long_run_count" \
        '{
            workspace: $workspace,
            workspace_name: $workspace_name,
            workspace_url: $workspace_url,
            job_id: $job_id,
            job_name: $job_name,
            status: $status,
            message: $message,
            run_counts: {
                total: ($pending_runs + $running_runs + $terminating_runs + $successful_runs + $failed_runs + $skipped_runs + $other_runs),
                pending: $pending_runs,
                running: $running_runs,
                terminating: $terminating_runs,
                successful: $successful_runs,
                failed: $failed_runs,
                skipped: $skipped_runs,
                other: $other_runs,
                long_running: $long_runs
            },
            runs: $runs
        }')
    
    echo "DEBUG: About to write job_obj for $job_id to $TMP_OUTPUT"
    echo "$job_obj" >> "$TMP_OUTPUT"
done

echo "DEBUG: Finished all jobs, check $TMP_OUTPUT"
cat "$TMP_OUTPUT"

# Combine all job status objects into a single JSON array
jq -s '.' "$TMP_OUTPUT" > "$TMP_OUTPUT.combined"

# Process the output to add is_long_running flag, update run statuses, and filter out successful jobs
jq --arg max_duration "$MAX_JOB_DURATION_MINUTES" '
  def minutes_since(timestamp):
    if timestamp == "N/A" then 0
    else (now - (timestamp | strptime("%Y-%m-%d %H:%M:%S") | mktime)) / 60
    end;
    
  def is_long_running(run):
    if run.life_cycle_state == "RUNNING" and run.start_time != "N/A" and run.end_time == "N/A" then
      minutes_since(run.start_time) > ($max_duration | tonumber)
    # Check duration for completed runs
    elif run.start_time != "N/A" and run.end_time != "N/A" then
      (run.end_time | strptime("%Y-%m-%d %H:%M:%S") | mktime - (run.start_time | strptime("%Y-%m-%d %H:%M:%S") | mktime)) / 60 > ($max_duration | tonumber)
    else false
    end;
    
  # Process each job
  map(
    . as $job |
    # Update each run with is_long_running flag and duration
    .runs |= map(
      . as $run |
      $run + {
        is_long_running: is_long_running($run),
        max_allowed_minutes: ($max_duration | tonumber)
      }
    )
  ) | 
  # Only keep jobs that have failed or long-running runs
  map(select(
    .run_counts.failed > 0 or
    (.runs | any(.is_long_running == true))
  ))' "$TMP_OUTPUT.combined" > "$OUTPUT_FILE"

# Clean up temporary files
rm -f "$TMP_OUTPUT" "$TMP_OUTPUT.combined" "$error_file" 2>/dev/null || true

# Output results
if [ -s "$OUTPUT_FILE" ] && [ "$(jq 'length' "$OUTPUT_FILE")" -gt 0 ]; then
    failed_count=$(jq 'map(select(.run_counts.failed > 0)) | length' "$OUTPUT_FILE")
    long_running_count=$(jq 'map(select(.long_run > 0)) | length' "$OUTPUT_FILE")
    
    if [ "$failed_count" -gt 0 ] && [ "$long_running_count" -gt 0 ]; then
        echo "$failed_count jobs with failures and $long_running_count long-running jobs detected! Results saved to: $OUTPUT_FILE"
    elif [ "$failed_count" -gt 0 ]; then
        echo "$failed_count jobs with failures detected! Results saved to: $OUTPUT_FILE"
    elif [ "$long_running_count" -gt 0 ]; then
        echo "$long_running_count long-running jobs detected! Results saved to: $OUTPUT_FILE"
    fi
    
    # Set exit code based on severity (failures are more severe than long-running jobs)
    if [ "$failed_count" -gt 0 ]; then
        exit 1
    else
        exit 0  # Warning exit code for long-running jobs
    fi
else
    echo "No issues detected in job runs"
    echo "[]" > "$OUTPUT_FILE"  # Ensure empty array for no issues
    exit 0
fi

echo "Output written to $OUTPUT_FILE"
cat "$OUTPUT_FILE"
