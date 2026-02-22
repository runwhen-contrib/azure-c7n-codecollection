#!/bin/bash

set -euo pipefail

# Configuration
TEST_FILE="/tmp/healthcheck"
TEST_CONTENT="ok"
MAX_LATENCY_MS=5000  # 5 second SLO for each operation (increased from 1s to account for network latency)
EXIT_CODE=0

# Performance thresholds (warn if operation takes longer than this, but don't fail)
WARN_LATENCY_MS=2000

# Output files
OUTPUT_FILE="dbfs_io_status.json"
TMP_OUTPUT="tmp_dbfs_io_status.json"
LOG_FILE="dbfs_io_check.log"
> "$TMP_OUTPUT"
> "$LOG_FILE"  # Create empty log file

# Function to log messages with timestamp
log() {
    local message="[$(date +'%Y-%m-%d %H:%M:%S')] $1"
    # Log to stderr and to log file
    echo "$message" >&2
    echo "$message" >> "$LOG_FILE"
}

# Function to get workspace information
get_workspace_info() {
    log "Getting workspace information..."
    
    # Get workspace URL from the host
    local workspace_url="${DATABRICKS_HOST}"
    
    # Return just the workspace URL in a JSON object
    jq -n --arg url "$workspace_url" '{"workspace_url": $url}'
}

# Function to check if databricks CLI is installed and authenticated
check_prerequisites() {
    if ! command -v databricks &> /dev/null; then
        log "ERROR: Databricks CLI is not installed. Please install it first."
        exit 1
    fi
    
    if [ -z "${DATABRICKS_HOST:-}" ] || [ -z "${DATABRICKS_TOKEN:-}" ]; then
        log "ERROR: DATABRICKS_HOST and DATABRICKS_TOKEN environment variables must be set"
        exit 1
    fi
    
    # Verify authentication - don't suppress error output
    if ! databricks fs ls "dbfs:/"; then
        log "ERROR: Not authenticated with Databricks. Please check your DATABRICKS_TOKEN and DATABRICKS_HOST"
        exit 1
    fi
}

# Function to measure operation time and capture output with detailed error handling
measure_operation() {
    local operation_name=$1
    shift
    local start_time
    local end_time
    local duration
    local output
    local status
    
    log "Starting operation: $operation_name"
    log "Command: $*"
    start_time=$(date +%s%3N)  # milliseconds since epoch
    
    # Execute the command and capture all output
    set +e  # Don't exit on error
    output=$("$@" 2>&1)
    status=$?
    set -e  # Re-enable exit on error
    
    end_time=$(date +%s%3N)
    duration=$((end_time - start_time))
    
    # Always log the full command and its output for debugging
    log "Operation: $operation_name"
    log "Exit status: $status"
    log "Duration: ${duration}ms"
    
    if [ -n "$output" ]; then
        log "Command output:"
        echo "$output" | while IFS= read -r line; do
            log "  $line"
        done
    fi
    
    # Log timing information and set appropriate exit code
    if [ $status -eq 0 ]; then
        if [ $duration -gt $MAX_LATENCY_MS ]; then
            log "ERROR: $operation_name took ${duration}ms (exceeded SLO of ${MAX_LATENCY_MS}ms)"
            EXIT_CODE=1
        elif [ $duration -gt $WARN_LATENCY_MS ]; then
            log "WARNING: $operation_name took ${duration}ms (exceeded warning threshold of ${WARN_LATENCY_MS}ms)"
            log "  Note: Operation succeeded but was slower than expected. This could indicate network or cluster load issues."
        else
            log "SUCCESS: $operation_name completed in ${duration}ms (within SLO of ${MAX_LATENCY_MS}ms)"
        fi
    else
        log "ERROR: $operation_name failed with status $status after ${duration}ms"
        if [ -n "$output" ]; then
            log "Error details:"
            echo "$output" | while IFS= read -r line; do
                log "  $line"
            done
        fi
        EXIT_CODE=1
    fi
    
    # Output the command's stdout for capture by the caller
    if [ $status -eq 0 ] && [ -n "$output" ]; then
        echo "$output"
    fi
    
    return $status
}

# Function to create JSON output for a test result with error details
create_test_result() {
    local test_name=$1
    local status=$2
    local message=$3
    local duration_ms=${4:-0}
    local error_details="${5:-}"
    
    # Get workspace info
    local workspace_info
    workspace_info=$(get_workspace_info)
    
    # Create a temporary file for the JSON output
    local temp_json
    temp_json=$(mktemp)
    
    # Create the JSON object with error details if available
    if [ -n "$error_details" ]; then
        jq -n \
            --arg name "$test_name" \
            --arg status "$status" \
            --arg message "$message" \
            --arg timestamp "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
            --argjson duration_ms "$duration_ms" \
            --argjson workspace "$workspace_info" \
            --arg error_details "$error_details" \
            '{
                name: $name,
                status: $status,
                message: $message,
                timestamp: $timestamp,
                duration_ms: $duration_ms,
                workspace: $workspace,
                error_details: $error_details
            }' > "$temp_json"
    else
        jq -n \
            --arg name "$test_name" \
            --arg status "$status" \
            --arg message "$message" \
            --arg timestamp "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
            --argjson duration_ms "$duration_ms" \
            --argjson workspace "$workspace_info" \
            '{
                name: $name,
                status: $status,
                message: $message,
                timestamp: $timestamp,
                duration_ms: $duration_ms,
                workspace: $workspace
            }' > "$temp_json"
    fi
    
    # Append to the output file
    cat "$temp_json" >> "$TMP_OUTPUT"
    
    # Add a newline for better readability
    echo "" >> "$TMP_OUTPUT"
    
    # Clean up
    rm -f "$temp_json"
}

# Main execution
main() {
    local temp_file
    local read_content
    local start_time
    local end_time
    local duration_ms
    
    log "Starting DBFS I/O Sanity Test"
    
    # Initialize temporary output file
    > "$TMP_OUTPUT"
    
    check_prerequisites
    
    # Get workspace info for logging
    local workspace_url
    workspace_url=$(get_workspace_info | jq -r '.workspace_url')
    log "Workspace URL: $workspace_url"
    
    # Start timing the entire test
    start_time=$(date +%s%3N)
    
    # Create a temporary file with test content
    temp_file=$(mktemp)
    echo "$TEST_CONTENT" > "$temp_file"
    
    # Create directory if it doesn't exist
    TEST_DIR=$(dirname "$TEST_FILE")
    if [ "$TEST_DIR" != "." ] && [ "$TEST_DIR" != "/" ]; then
        measure_operation "Create DBFS Directory" \
            databricks fs mkdirs "dbfs:${TEST_DIR}" || {
                log "ERROR: Failed to create directory dbfs:${TEST_DIR}"
                exit 1
            }
    fi
    
    # Write test file to DBFS
    measure_operation "DBFS Write" \
        databricks fs cp "$temp_file" "dbfs:${TEST_FILE}" --overwrite
    
    # Read test file from DBFS
    if [ $EXIT_CODE -eq 0 ]; then
        local read_content
        local read_output
        local temp_read_file
        
        # Create a temporary directory for our operations
        local temp_dir
        temp_dir=$(mktemp -d)
        temp_read_file="${temp_dir}/healthcheck_read"
        
        # Run the read operation - show command output
        log "Downloading test file from DBFS to $temp_read_file"
        set +e  # Don't exit on error
        read_output=$(measure_operation "DBFS Read" \
            databricks fs cp "dbfs:${TEST_FILE}" "$temp_read_file" 2>&1)
        read_status=$?
        set -e  # Re-enable exit on error
        
        # Always log the operation details
        log "Read operation status: $read_status"
        if [ $read_status -ne 0 ]; then
            log "ERROR: Read operation failed with status $read_status"
            log "Command output: $read_output"
        else
            log "Read operation succeeded"
            [ -n "$read_output" ] && log "Command output: $read_output"
        fi
        
        # If read was successful, get the content
        if [ $read_status -eq 0 ]; then
            if [ -f "$temp_read_file" ]; then
                if ! read_content=$(cat "$temp_read_file" 2>&1); then
                    log "ERROR: Failed to read temporary file: $read_content"
                    read_status=1
                else
                    read_content=$(echo "$read_content" | tr -d '[:space:]')
                    log "Read content: '$read_content'"
                fi
            else
                log "ERROR: File was not downloaded: $temp_read_file"
                read_status=1
            fi
        fi
        
        # Clean up
        rm -rf "$temp_dir"
        
        # Verify content if read was successful
        if [ $read_status -eq 0 ]; then
            if [ "$read_content" != "$TEST_CONTENT" ]; then
                log "ERROR: Content verification failed. Expected '$TEST_CONTENT', got '$read_content'"
                EXIT_CODE=1
            fi
        else
            log "ERROR: Failed to read file from DBFS"
            EXIT_CODE=1
        fi
    fi
    
    # Clean up test file - always attempt to clean up, even if previous steps failed
    log "Attempting to clean up test file: dbfs:${TEST_FILE}"
    cleanup_output=$(databricks fs rm "dbfs:${TEST_FILE}" --recursive 2>&1)
    cleanup_status=$?
    if [ $cleanup_status -eq 0 ]; then
        log "Successfully cleaned up test file"
    else
        log "WARNING: Failed to clean up test file: $cleanup_output"
    fi
    
    # Clean up local temp file
    rm -f "$temp_file"
    
    # Calculate total duration
    end_time=$(date +%s%3N)
    duration_ms=$((end_time - start_time))
    
    # Final status
    local final_status="SUCCESS"
    local final_message="All operations completed successfully"
    local error_messages=""
    
    # Check for any errors in the execution
    if [ $EXIT_CODE -ne 0 ]; then
        final_status="ERROR"
        final_message="One or more operations failed"
        # If log file exists and has errors, extract them
        if [ -f "$LOG_FILE" ] && grep -qi 'ERROR:' "$LOG_FILE" 2>/dev/null; then
            error_messages=$(grep -i 'ERROR:' "$LOG_FILE" | head -n 5 | sed 's/^[^:]*: //' | tr '\n' '; ')
        else
            error_messages="Operation failed with exit code $EXIT_CODE"
        fi
        log "❌ DBFS I/O Sanity Test completed with errors in ${duration_ms}ms"
        log "Error details: $error_messages"
    else
        log "✅ DBFS I/O Sanity Test completed successfully in ${duration_ms}ms"
    fi
    
    # Create the final test result
    create_test_result \
        "dbfs_io_sanity" \
        "$final_status" \
        "$final_message" \
        $duration_ms \
        "$error_messages"
    
    # Create a direct final JSON output
    log "Generating JSON output..."
    
    if [ -s "$TMP_OUTPUT" ]; then
        # Write the final JSON directly
        cat "$TMP_OUTPUT" > "$OUTPUT_FILE"
        log "JSON output created successfully"
    else
        log "WARNING: No test results were generated in temporary file"
        # Create a simple JSON result based on exit code
        if [ $EXIT_CODE -eq 0 ]; then
            log "Creating success result JSON"
            # Get workspace info
            local workspace_info
            workspace_info=$(get_workspace_info)
            
            # Create success JSON
            jq -n --argjson ws "$workspace_info" \
                --arg ts "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
                --arg duration "$duration_ms" \
                --arg message "$final_message" \
                '[{
                    "name": "dbfs_io_sanity",
                    "status": "SUCCESS",
                    "message": $message,
                    "timestamp": $ts,
                    "duration_ms": ($duration | tonumber),
                    "workspace": $ws
                }]' > "$OUTPUT_FILE"
        else
            log "Creating error result JSON"
            # Get workspace info
            local workspace_info
            workspace_info=$(get_workspace_info)
            
            # Create error JSON with error details
            jq -n --argjson ws "$workspace_info" \
                --arg ts "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
                --arg duration "$duration_ms" \
                --arg message "$final_message" \
                --arg error_details "$error_messages" \
                '[{
                    "name": "dbfs_io_sanity",
                    "status": "ERROR",
                    "message": $message,
                    "timestamp": $ts,
                    "duration_ms": ($duration | tonumber),
                    "workspace": $ws,
                    "error_details": $error_details
                }]' > "$OUTPUT_FILE"
        fi
    fi
    
    # Log completion
    log "DBFS I/O test completed. Results saved to $OUTPUT_FILE"
    rm -f "$TMP_OUTPUT"
    
    exit $EXIT_CODE
}

# Run main function
main "$@"
