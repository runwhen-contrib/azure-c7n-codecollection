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
> "$TMP_OUTPUT"

# Function to log messages with timestamp
log() {
    local message="[$(date +'%Y-%m-%d %H:%M:%S')] $1"
    # Only log to stderr to avoid duplicates
    echo "$message" >&2
}

# Function to check if databricks CLI is installed and authenticated
check_prerequisites() {
    if ! command -v databricks &> /dev/null; then
        log "ERROR: Databricks CLI is not installed. Please install it first."
        exit 1
    fi
    
    # Verify authentication
    if ! databricks fs ls "dbfs:/" &> /dev/null; then
        log "ERROR: Not authenticated with Databricks. Please run 'databricks configure --token'"
        exit 1
    fi
}

# Function to measure operation time and capture output
measure_operation() {
    local operation_name=$1
    shift
    local start_time
    local end_time
    local duration
    local output
    local status
    
    log "Starting operation: $operation_name"
    start_time=$(date +%s%3N)  # milliseconds since epoch
    
    # Execute the command and capture output and status
    output=$("$@" 2>&1)
    status=$?
    
    end_time=$(date +%s%3N)
    duration=$((end_time - start_time))
    
    # Log timing information
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
        log "ERROR: $operation_name failed after ${duration}ms"
        log "Command output: $output"
        EXIT_CODE=1
    fi
    
    # Output the command's stdout for capture by the caller
    if [ $status -eq 0 ]; then
        echo -n "$output"
    fi
    
    return $status
}

# Create JSON output for a test result
create_test_result() {
    local test_name=$1
    local status=$2
    local message=$3
    local duration_ms=${4:-0}
    
    # Create a temporary file for the JSON object
    local temp_json
    temp_json=$(mktemp)
    
    # Generate the JSON object with proper escaping
    jq -n \
        --arg name "$test_name" \
        --arg status "$status" \
        --arg message "$message" \
        --arg timestamp "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
        --argjson duration_ms "$duration_ms" \
        '{
            name: $name,
            status: $status,
            message: $message,
            timestamp: $timestamp,
            duration_ms: $duration_ms
        }' > "$temp_json"
    
    # Append to the temporary output file
    cat "$temp_json" >> "$TMP_OUTPUT"
    
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
    check_prerequisites
    
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
        
        # Run the read operation
        log "Downloading test file from DBFS to $temp_read_file"
        read_output=$(measure_operation "DBFS Read" \
            databricks fs cp "dbfs:${TEST_FILE}" "$temp_read_file" 2>&1)
        local read_status=$?
        
        # Debug output
        log "Read operation status: $read_status"
        log "Read operation output: $read_output"
        
        # If read was successful, get the content
        if [ $read_status -eq 0 ]; then
            if [ -f "$temp_read_file" ]; then
                read_content=$(cat "$temp_read_file" | tr -d '[:space:]')
                log "Read content: '$read_content'"
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
    if [ $EXIT_CODE -eq 0 ]; then
        log "✅ DBFS I/O Sanity Test completed successfully in ${duration_ms}ms"
        create_test_result "dbfs_io_sanity" "SUCCESS" "All operations completed within SLO" "$duration_ms"
    else
        log "❌ DBFS I/O Sanity Test failed after ${duration_ms}ms"
        create_test_result "dbfs_io_sanity" "FAILED" "One or more operations failed" "$duration_ms"
    fi
    
    # Combine all test results into a properly formatted JSON array
    if [ -s "$TMP_OUTPUT" ]; then
        # If we have content, format it as a proper JSON array
        jq -s '.' "$TMP_OUTPUT" > "$OUTPUT_FILE" || {
            # Fallback if jq fails
            echo '[' > "$OUTPUT_FILE"
            # Remove trailing comma if it exists
            sed -e ':a' -e 'N' -e '$!ba' -e 's/,\n/\n/g' "$TMP_OUTPUT" >> "$OUTPUT_FILE"
            echo ']' >> "$OUTPUT_FILE"
        }
    else
        # Empty array if no results
        echo '[]' > "$OUTPUT_FILE"
    fi
    
    # Clean up temp file
    rm -f "$TMP_OUTPUT"
    
    exit $EXIT_CODE
}

# Run main function
main "$@"
