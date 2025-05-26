#!/bin/bash

set -euo pipefail

# Configuration
OUTPUT_FILE="dbx_job_status.json"
TMP_OUTPUT="tmp_job_status.jsonl"
NUM_RECENT_RUNS=${NUM_RECENT_RUNS:-10}  # Default to 10 recent runs per job

echo "Databricks Host: ${DATABRICKS_HOST}"
echo "Databricks Token: ${DATABRICKS_TOKEN}"

# Initialize output files
> "$TMP_OUTPUT"
echo "[]" > "$OUTPUT_FILE"

# Extract workspace name from the host URL
workspace_name=$(echo "${DATABRICKS_HOST}" | sed -E 's/https:\/\/([^.]+).*/\1/')
workspace_url=$(echo "${DATABRICKS_HOST}" | sed -E 's/https:\/\///')

echo "🔍 Checking job runs in Databricks workspace: $workspace_name..."

# Get all jobs
echo "Retrieving jobs list..."
jobs_json=$(databricks jobs list --output JSON 2>/dev/null) || {
    echo "⚠️ Failed to retrieve jobs for workspace"
    exit 1
}

# Count jobs (directly use the array from the output)
job_count=$(echo "$jobs_json" | jq 'length')
echo "Found $job_count jobs in workspace"

if [ "$job_count" -eq 0 ]; then
    echo "No Databricks jobs found."
    echo "[]" > "$OUTPUT_FILE"
    exit 0
fi

# Process each job
for j in $(seq 0 $((job_count - 1))); do
    # Initialize counters for each job
    pending_runs=0
    running_runs=0
    terminating_runs=0
    successful_runs=0
    failed_runs=0
    skipped_runs=0
    other_runs=0
    
    job=$(echo "$jobs_json" | jq ".[$j]")
    job_id=$(echo "$job" | jq -r '.job_id')
    job_name=$(echo "$job" | jq -r '.settings.name')
    
    # Skip if job_name is empty or null
    if [ -z "$job_name" ] || [ "$job_name" = "null" ]; then
        echo "⚠️ Skipping job with ID $job_id (no name found)"
        continue
    fi
    
    echo "Processing job: $job_name (ID: $job_id)"
    
    # Get recent runs for this job using jobs list-runs and capture any error output
    error_file=$(mktemp)
    runs_json=$(databricks jobs list-runs --job-id "$job_id" --limit "$NUM_RECENT_RUNS" --output JSON 2>"$error_file")
    if [ $? -ne 0 ]; then
        error_msg=$(cat "$error_file" | tr -d '"' | tr -d '\n')
        echo "⚠️ Failed to retrieve runs for job $job_id: $error_msg"
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
        echo "⚠️ Invalid response format for job $job_id runs. Response: $runs_json"
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
        
        # Get error details if the run failed
        error_details=""
        if [ "$result_state" != "SUCCESS" ] && [ "$life_cycle_state" = "TERMINATED" ]; then
            # Get detailed run information for failed runs
            error_file=$(mktemp)
            run_details=$(databricks runs get --run-id "$run_id" --output JSON 2>"$error_file")
            
            if [ $? -eq 0 ]; then
                # Extract error message and stack trace if available
                error_message=$(echo "$run_details" | jq -r '.state.state_message // ""')
                error_trace=$(echo "$run_details" | jq -r '.state.user_exception // .state.error // ""')
                
                if [ -n "$error_message" ] || [ -n "$error_trace" ]; then
                    error_details=$(jq -n \
                        --arg message "$error_message" \
                        --arg trace "$error_trace" \
                        '{
                            error_message: $message,
                            error_trace: $trace
                        }' | tr -d '\n')
                fi
            else
                error_msg=$(cat "$error_file" | tr -d '"' | tr -d '\n')
                error_details=$(jq -n --arg msg "$error_msg" '{error_fetching_details: $msg}' | tr -d '\n')
            fi
            rm -f "$error_file"
        fi
        
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
        
        # Add run to array
        runs_array=$(echo "$runs_array" | jq --argjson run "$run_obj" '. + [$run]')
        
        # Determine run status based on life_cycle_state and result_state
        case "$life_cycle_state" in
            "PENDING")
                echo "⏳ Run $run_id is pending"
                pending_runs=$((pending_runs + 1))
                ;;
            "RUNNING")
                echo "🔄 Run $run_id is running"
                running_runs=$((running_runs + 1))
                ;;
            "TERMINATING")
                echo "🛑 Run $run_id is terminating"
                terminating_runs=$((terminating_runs + 1))
                ;;
            "TERMINATED")
                if [ "$result_state" = "SUCCESS" ]; then
                    echo "✅ Run $run_id completed successfully"
                    successful_runs=$((successful_runs + 1))
                else
                    failed_runs=$((failed_runs + 1))
                    echo "❌ Run $run_id failed with state: $result_state"
                fi
                ;;
            "SKIPPED")
                echo "⏭️  Run $run_id was skipped"
                skipped_runs=$((skipped_runs + 1))
                ;;
            "INTERNAL_ERROR")
                failed_runs=$((failed_runs + 1))
                echo "💥 Run $run_id encountered an internal error"
                ;;
            *)
                echo "❓ Run $run_id has unknown state: $life_cycle_state"
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
    elif [ "$running_runs" -gt 0 ] || [ "$pending_runs" -gt 0 ] || [ "$terminating_runs" -gt 0 ]; then
        status="WARNING"
        message="In progress"
    else
        status="OK"
        message="All runs completed successfully"
    fi
    
    # Add detailed status counts
    message+=" (${successful_runs}✅, ${failed_runs}❌, ${running_runs}🔄, ${pending_runs}⏳, ${terminating_runs}🛑, ${skipped_runs}⏭️, ${other_runs}❓)"
    
    job_obj=$(jq -n \
        --arg workspace "$workspace_name" \
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
        '{
            workspace: $workspace,
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
                other: $other_runs
            },
            runs: $runs
        }')
    
    echo "$job_obj" >> "$TMP_OUTPUT"
done

# Combine all job status objects into a single JSON array
jq -s '.' "$TMP_OUTPUT" > "$TMP_OUTPUT.combined"

# Filter out successful jobs and jobs with no failed runs
jq '
  map(select(
    .status == "ERROR" or 
    (.run_counts.failed > 0) or
    (.runs | any(.result_state != "SUCCESS" and .life_cycle_state == "TERMINATED"))
  ))
' "$TMP_OUTPUT.combined" > "$OUTPUT_FILE"

# Clean up temporary files
rm -f "$TMP_OUTPUT" "$TMP_OUTPUT.combined" "$error_file" 2>/dev/null || true

# Output results
if [ -s "$OUTPUT_FILE" ] && [ "$(jq 'length' "$OUTPUT_FILE")" -gt 0 ]; then
    echo "⚠️ Failed job runs detected! Results saved to: $OUTPUT_FILE"
    exit 1
else
    echo "✅ No failed job runs detected"
    echo "[]" > "$OUTPUT_FILE"  # Ensure empty array for no failures
    exit 0
fi
