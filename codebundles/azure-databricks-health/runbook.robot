*** Settings ***
Documentation       List Databricks changes and cluster status
Metadata            Author    saurabh3460
Metadata            Display Name    Azure Databricks Health
Metadata            Supports    Azure    Databricks    Health    CloudCustodian
Force Tags          Azure    Databricks    Health    CloudCustodian    cosmosdb    sql    redis    postgresql    availability

Library    String
Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library    CloudCustodian.Core
Library    Collections
Library    DateTime

Suite Setup         Suite Initialization


*** Tasks ***
List Databricks Changes in resource group `${AZURE_RESOURCE_GROUP}`
    [Documentation]    Lists Databricks changes in the specified resource group
    [Tags]    Databricks    Azure    Audit    access:read-only
    ${log_file}=    Set Variable    dbx_changes_grouped.json
    ${output}=    RW.CLI.Run Bash File
    ...    bash_file=get-dbx-changes.sh
    ...    env=${env}
    ...    timeout_seconds=200
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ${report_data}=    RW.CLI.Run Cli
    ...    cmd=cat ${log_file}
    TRY
        ${changes_list}=    Evaluate    json.loads(r'''${report_data.stdout}''')    json
    EXCEPT
        Log    Failed to load JSON payload, defaulting to empty list.    WARN
        ${changes_list}=    Create Dictionary
    END

    IF    len(${changes_list}) > 0
        # Loop through each Databricks workspace in the grouped changes
        ${all_changes}=    Create List
        
        FOR    ${dbx_name}    IN    @{changes_list.keys()}
            ${dbx_changes}=    Set Variable    ${changes_list["${dbx_name}"]}
            ${display_name}=    Set Variable    ${dbx_changes[0]["displayName"]}

            
            # Format changes for this specific Databricks workspace
            ${dbx_changes_json}=    Evaluate    json.dumps(${dbx_changes})    json
            ${formatted_dbx_results}=    RW.CLI.Run Cli
            ...    cmd=printf '%s' '${dbx_changes_json}' | jq -r '["Operation", "Timestamp", "Caller", "Status", "ResourceUrl"] as $headers | [$headers] + [.[] | [.operationName, .timestamp, .caller, .changeStatus, .resourceUrl]] | .[] | @tsv' | column -t -s $'\t'
            RW.Core.Add Pre To Report    Changes for ${display_name} (${dbx_name}):\n-----------------------------------------------------\n${formatted_dbx_results.stdout}\n
            
            # Check for recent changes within AZURE_ACTIVITY_LOG_LOOKBACK_FOR_ISSUE timeframe
            ${current_time}=    DateTime.Get Current Date    result_format=datetime
            ${current_time_iso}=    Convert Date    ${current_time}    result_format=%Y-%m-%dT%H:%M:%SZ
            ${recent_changes}=    Create List
            
            FOR    ${change}    IN    @{dbx_changes}
                ${change_time}=    Set Variable    ${change["timestamp"]}
                # Extract just the date and time part without fractional seconds
                ${change_time_simple}=    Evaluate    re.match(r'(\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2})', '${change_time}').group(1)    modules=re
                ${change_time_obj}=    Convert Date    ${change_time_simple}    date_format=%Y-%m-%dT%H:%M:%S
                ${time_diff}=    Subtract Date From Date    ${current_time}    ${change_time_obj}
                
                # Convert AZURE_ACTIVITY_LOG_LOOKBACK_FOR_ISSUE to seconds
                ${lookback_seconds}=    Run Keyword If    '${AZURE_ACTIVITY_LOG_LOOKBACK_FOR_ISSUE}'.endswith('h')    Evaluate    int('${AZURE_ACTIVITY_LOG_LOOKBACK_FOR_ISSUE}'.replace('h', '')) * 3600
                ...    ELSE IF    '${AZURE_ACTIVITY_LOG_LOOKBACK_FOR_ISSUE}'.endswith('m')    Evaluate    int('${AZURE_ACTIVITY_LOG_LOOKBACK_FOR_ISSUE}'.replace('m', '')) * 60
                ...    ELSE IF    '${AZURE_ACTIVITY_LOG_LOOKBACK_FOR_ISSUE}'.endswith('d')    Evaluate    int('${AZURE_ACTIVITY_LOG_LOOKBACK_FOR_ISSUE}'.replace('d', '')) * 86400
                ...    ELSE    Evaluate    int('${AZURE_ACTIVITY_LOG_LOOKBACK_FOR_ISSUE}')
                
                # If change is within lookback period, add to recent changes
                IF    ${time_diff} <= ${lookback_seconds}
                    Append To List    ${recent_changes}    ${change}
                END
            END
            
            # Raise issues for recent changes
            FOR    ${change}    IN    @{recent_changes}
                ${pretty_change}=    Evaluate    pprint.pformat(${change})    modules=pprint
                ${operation}=    Set Variable    ${change['operationName']}
                ${caller}=    Set Variable    ${change['caller']}
                ${timestamp}=    Set Variable    ${change['timestamp']}
                ${resource_url}=    Set Variable    ${change['resourceUrl']}
                
                RW.Core.Add Issue
                ...    severity=4
                ...    expected=Changes to ${display_name} `${dbx_name}` should be reviewed in resource group `${AZURE_RESOURCE_GROUP}`
                ...    actual=Recent change detected: ${operation} by ${caller} at ${timestamp}
                ...    title=Recent Databricks Change: ${operation} on ${display_name} `${dbx_name}` in Resource Group `${AZURE_RESOURCE_GROUP}`
                ...    details=${pretty_change}
                ...    reproduce_hint=${output.cmd}
                ...    next_steps=Review the recent change in Azure Portal: ${resource_url}
            END
        END
    ELSE
        RW.Core.Add Pre To Report    No Databricks changes found in resource group `${AZURE_RESOURCE_GROUP}`
    END
    RW.CLI.Run Cli
    ...    cmd=rm ${log_file}

List Databricks Cluster Status in resource group `${AZURE_RESOURCE_GROUP}`
    [Documentation]    Lists Databricks cluster status
    [Tags]    Databricks    Azure    Audit    access:read-only
    ${status_file}=    Set Variable    cluster_status.json
    ${output}=    RW.CLI.Run Bash File
    ...    bash_file=get-dbx-cluster-status.sh
    ...    env=${env}
    ...    secret__databricks_host=${DATABRICKS_HOST}
    ...    secret__databricks_token=${DATABRICKS_TOKEN}
    ...    timeout_seconds=200
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    
    ${status_data}=    RW.CLI.Run Cli
    ...    cmd=cat ${status_file}
    TRY
        ${cluster_status}=    Evaluate    json.loads(r'''${status_data.stdout}''')    json
    EXCEPT
        Log    Failed to load JSON payload, defaulting to empty list.    WARN
        ${cluster_status}=    Create List
    END
    
    IF    len(${cluster_status}) > 0
        ${cluster_status_json}=    Evaluate    json.dumps(${cluster_status})    json
        ${formatted_cluster_results}=    RW.CLI.Run Cli
        ...    cmd=printf '%s' '${cluster_status_json}' | jq -r '["Workspace", "Cluster Name", "State", "Message", "Workspace URL"] as $headers | [$headers] + [.[] | [.workspace, .cluster_name, .state, .message, .workspace_url]] | .[] | @tsv' | column -t -s $'\t'
        RW.Core.Add Pre To Report    Databricks Cluster Status in Resource Group `${AZURE_RESOURCE_GROUP}`:\n-----------------------------------------------------\n${formatted_cluster_results.stdout}\n
        
        
        # Process each cluster status entry
        FOR    ${cluster}    IN    @{cluster_status}
            ${workspace}=    Set Variable    ${cluster["workspace"]}
            ${cluster_name}=    Set Variable    ${cluster["cluster_name"]}
            ${state}=    Set Variable    ${cluster["state"]}
            ${status}=    Set Variable    ${cluster["status"]}
            ${message}=    Set Variable    ${cluster["message"]}

            # Raise issues for problematic clusters
            IF    '${state}' == 'PENDING' or '${state}' == 'ERROR'
                ${workspace_url}=    Set Variable    ${cluster["workspace_url"]}
                ${cluster_id}=    Set Variable    ${cluster["cluster_id"]}
                ${dbx_url}=    Set Variable    https://${workspace_url}/#/setting/clusters/${cluster_id}/configuration
                
                RW.Core.Add Issue
                ...    severity=3
                ...    expected=Databricks cluster `${cluster_name}` should be in any of these states: RUNNING, RESIZING, TERMINATED
                ...    actual=Databricks cluster `${cluster_name}` is in `${state}` state
                ...    title=Databricks Cluster `${cluster_name}` is in `${state}` state in Resource Group `${AZURE_RESOURCE_GROUP}`
                ...    details=${cluster}
                ...    reproduce_hint=${output.cmd}
                ...    next_steps=Check the Databricks cluster state in resource group `${AZURE_RESOURCE_GROUP}`
            END
        END
    ELSE
        RW.Core.Add Pre To Report    No Databricks clusters found in resource group `${AZURE_RESOURCE_GROUP}`
    END
    
    # Clean up the temporary files
    RW.CLI.Run Cli
    ...    cmd=rm ${status_file}

Check Databricks DBFS I/O Status in resource group `${AZURE_RESOURCE_GROUP}`
    [Documentation]    Checks the health and performance of DBFS I/O operations for Databricks
    [Tags]    Databricks    Azure    Health    access:read-only
    ${output}=    RW.CLI.Run Bash File
    ...    bash_file=check_dbfs_io.sh
    ...    env=${env}
    ...    secret__databricks_host=${DATABRICKS_HOST}
    ...    secret__databricks_token=${DATABRICKS_TOKEN}
    ...    timeout_seconds=300
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    
    ${status_data}=    RW.CLI.Run Cli
    ...    cmd=cat dbfs_io_status.json
    
    TRY
        ${io_status_raw}=    Evaluate    json.loads(r'''${status_data.stdout}''')    json
        
        # Check if it's an array or a single object
        ${is_array}=    Evaluate    isinstance($io_status_raw, list)    builtins
        
        # Convert to a standard format (list of tests) for processing
        ${io_status}=    Create List
        IF    ${is_array} == True
            ${io_status}=    Set Variable    ${io_status_raw}
        ELSE
            Append To List    ${io_status}    ${io_status_raw}
        END
    EXCEPT    AS    ${error}
        Log    Failed to load JSON payload: ${error}. Defaulting to empty list.    WARN
        ${io_status}=    Create List
    END
    
    IF    len(${io_status}) > 0
        # Extract workspace information if available
        ${workspace_url}=    Set Variable    Unknown
        TRY
            ${workspace_url}=    Set Variable    ${io_status[0]['workspace']['workspace_url']}
        EXCEPT    AS    ${error}
            Log    Could not extract workspace URL from result: ${error}    WARN
        END
        
        # Format output for report
        ${io_status_json}=    Evaluate    json.dumps(${io_status})    json
        ${formatted_io_results}=    RW.CLI.Run Cli
        ...    cmd=printf '%s' '${io_status_json}' | jq -r '["Test", "Status", "Duration (ms)", "Message"] as \$headers | [\$headers] + [.[] | [.name, .status, .duration_ms, .message]] | .[] | @tsv' | column -t -s $'\t'
        
        RW.Core.Add Pre To Report    DBFS I/O Status for ${workspace_url}:\n=====================================================\n${formatted_io_results.stdout}
        
        # Process each test result
        FOR    ${test}    IN    @{io_status}
            ${test_name}=    Set Variable    ${test}[name]
            ${test_status}=    Set Variable    ${test}[status]
            ${test_message}=    Set Variable    ${test}[message]
            ${duration_ms}=    Set Variable    ${test}[duration_ms]
            
            # Handle error details if present
            ${error_details}=    Set Variable    No detailed error information available
            ${has_error_details}=    Evaluate    'error_details' in ${test}
            IF    ${has_error_details}
                ${error_details}=    Set Variable    ${test}[error_details]
            END
            
            # Raise issues for failed or warning statuses
            IF    '${test_status}' == 'ERROR' or '${test_status}' == 'WARNING'
                ${severity}=    Set Variable If    '${test_status}' == 'ERROR'    3    4
                
                ${details}=    Set Variable If    '${error_details}' != ''
                ...    Message: ${test_message}\nDuration: ${duration_ms}ms\nError Details: ${error_details}\nWorkspace: ${workspace_url}
                ...    Message: ${test_message}\nDuration: ${duration_ms}ms\nWorkspace: ${workspace_url}
                
                RW.Core.Add Issue
                ...    severity=${severity}
                ...    expected=DBFS I/O operation '${test_name}' should complete successfully
                ...    actual=DBFS I/O operation '${test_name}' failed with status '${test_status}'
                ...    title=DBFS I/O Issue: ${test_name} - ${test_status}
                ...    details=${details}
                ...    reproduce_hint=${output.cmd}
                ...    next_steps=Check the Databricks workspace health and network connectivity
            END
        END
    ELSE
        RW.Core.Add Pre To Report    No DBFS I/O status information available
    END
    
    # Clean up temporary files
    RW.CLI.Run Cli
    ...    cmd=rm -f dbfs_io_status.json dbfs_io_check.log tmp_dbfs_io_status.json

*** Keywords ***
Suite Initialization
    ${azure_credentials}=    RW.Core.Import Secret
    ...    azure_credentials
    ...    type=string
    ...    description=The secret containing AZURE_CLIENT_ID, AZURE_TENANT_ID, AZURE_CLIENT_SECRET, AZURE_SUBSCRIPTION_ID
    ...    pattern=\w*
    ${AZURE_SUBSCRIPTION_ID}=    RW.Core.Import User Variable    AZURE_SUBSCRIPTION_ID
    ...    type=string
    ...    description=The Azure Subscription ID for the resource.  
    ...    pattern=\w*
    ...    default=""
    ${AZURE_RESOURCE_GROUP}=    RW.Core.Import User Variable    AZURE_RESOURCE_GROUP
    ...    type=string
    ...    description=Azure resource group.
    ...    pattern=\w*
    ${DATABRICKS_HOST}=    RW.Core.Import Secret    DATABRICKS_HOST
    ...    type=string
    ...    description=Azure Databricks host.
    ...    pattern=\w*
    ${DATABRICKS_TOKEN}=    RW.Core.Import Secret    DATABRICKS_TOKEN
    ...    type=string
    ...    description=Azure Databricks token.
    ...    pattern=\w*
    ${PENDING_TIMEOUT}=    RW.Core.Import User Variable    PENDING_TIMEOUT
    ...    type=string
    ...    description=The time in minutes to check for pending clusters.
    ...    pattern=^\w+$
    ...    example=30
    ...    default=30
    ${AZURE_ACTIVITY_LOG_LOOKBACK}=    RW.Core.Import User Variable    AZURE_ACTIVITY_LOG_LOOKBACK
    ...    type=string
    ...    description=The time offset to check for activity logs in this formats 24h, 1h, 1d etc.
    ...    pattern=^\w+$
    ...    example=24h
    ...    default=24h
    ${AZURE_ACTIVITY_LOG_LOOKBACK_FOR_ISSUE}=    RW.Core.Import User Variable    AZURE_ACTIVITY_LOG_LOOKBACK_FOR_ISSUE
    ...    type=string
    ...    description=The time offset to check for activity logs to raise an issue in this formats 24h, 1h, 1d etc.
    ...    pattern=^\w+$
    ...    example=1h
    ...    default=1h
    Set Suite Variable    ${AZURE_SUBSCRIPTION_ID}    ${AZURE_SUBSCRIPTION_ID}
    Set Suite Variable    ${AZURE_RESOURCE_GROUP}    ${AZURE_RESOURCE_GROUP}
    Set Suite Variable    ${AZURE_ACTIVITY_LOG_LOOKBACK}    ${AZURE_ACTIVITY_LOG_LOOKBACK}
    Set Suite Variable    ${AZURE_ACTIVITY_LOG_LOOKBACK_FOR_ISSUE}    ${AZURE_ACTIVITY_LOG_LOOKBACK_FOR_ISSUE}
    Set Suite Variable    ${DATABRICKS_HOST}    ${DATABRICKS_HOST}
    Set Suite Variable    ${DATABRICKS_TOKEN}    ${DATABRICKS_TOKEN}
    Set Suite Variable    ${PENDING_TIMEOUT}    ${PENDING_TIMEOUT}
    Set Suite Variable
    ...    ${env}
    ...    {"AZURE_RESOURCE_GROUP":"${AZURE_RESOURCE_GROUP}", "AZURE_SUBSCRIPTION_ID":"${AZURE_SUBSCRIPTION_ID}", "AZURE_ACTIVITY_LOG_LOOKBACK":"${AZURE_ACTIVITY_LOG_LOOKBACK}", "AZURE_ACTIVITY_LOG_LOOKBACK_FOR_ISSUE":"${AZURE_ACTIVITY_LOG_LOOKBACK_FOR_ISSUE}", "PENDING_TIMEOUT":"${PENDING_TIMEOUT}"}
