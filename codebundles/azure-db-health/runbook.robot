*** Settings ***
Documentation       List Virtual machines that are publicly accessible, have high CPU usage, underutilized memory, stopped state, unused network interfaces, and unused public IPs in Azure
Metadata            Author    saurabh3460
Metadata            Display Name    Azure Virtual Machine Health
Metadata            Supports    Azure    Virtual Machine    Health    CloudCustodian
Force Tags          Azure    Virtual Machine    Health    CloudCustodian

Library    String
Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library    CloudCustodian.Core

Suite Setup         Suite Initialization


*** Tasks ***
List Publicly Accessible MySQL Flexible Servers in resource group `${AZURE_RESOURCE_GROUP}` in Subscription `${AZURE_SUBSCRIPTION_NAME}`
    [Documentation]    Lists MySQL Flexible Servers that have public network access enabled
    [Tags]    Database    Azure    MySQL    Security    access:read-only
    ${policy_name}    Set Variable    mysqlfx-public-access
    CloudCustodian.Core.Generate Policy   
    ...    ${CURDIR}/${policy_name}.j2
    ...    resourceGroup=${AZURE_RESOURCE_GROUP}
    ${c7n_output}=    RW.CLI.Run Cli
    ...    cmd=custodian run -s ${OUTPUT_DIR}/azure-c7n-db-health ${CURDIR}/${policy_name}.yaml --cache-period 0
    ${report_data}=    RW.CLI.Run Cli
    ...    cmd=cat ${OUTPUT_DIR}/azure-c7n-db-health/${policy_name}/resources.json
    RW.CLI.Run Cli    cmd=rm ${CURDIR}/${policy_name}.yaml    # Remove generated policy
    TRY
        ${server_list}=    Evaluate    json.loads(r'''${report_data.stdout}''')    json
    EXCEPT
        Log    Failed to load JSON payload, defaulting to empty list.    WARN
        ${server_list}=    Create List
    END

    IF    len(@{server_list}) > 0
        ${formatted_results}=    RW.CLI.Run Cli
        ...    cmd=jq -r '["Server_Name", "Resource_Group", "Location", "Server_Link"], (.[] | [ .name, (.resourceGroup | ascii_downcase), (.location | gsub(" "; "_")), ("https://portal.azure.com/#@/resource" + .id + "/overview") ]) | @tsv' ${OUTPUT_DIR}/azure-c7n-db-health/${policy_name}/resources.json | column -t
        RW.Core.Add Pre To Report    Publicly Accessible MySQL Flexible Servers Summary:\n=====================================================\n${formatted_results.stdout}

        FOR    ${server}    IN    @{server_list}
            ${pretty_server}=    Evaluate    pprint.pformat(${server})    modules=pprint
            ${resource_group}=    Set Variable    ${server['resourceGroup'].lower()}
            ${server_name}=    Set Variable    ${server['name']}
            RW.Core.Add Issue
            ...    severity=4
            ...    expected=MySQL Flexible Server `${server_name}` should not have public network access enabled in resource group `${resource_group}` in subscription `${AZURE_SUBSCRIPTION_NAME}`
            ...    actual=MySQL Flexible Server `${server_name}` has public network access enabled in resource group `${resource_group}` in subscription `${AZURE_SUBSCRIPTION_NAME}`
            ...    title=Publicly Accessible MySQL Flexible Server `${server_name}` Detected in Resource Group `${resource_group}` in subscription `${AZURE_SUBSCRIPTION_NAME}`
            ...    reproduce_hint=${c7n_output.cmd}
            ...    details=${pretty_server}
            ...    next_steps=Disable public network access for the MySQL Flexible Server in resource group `${AZURE_RESOURCE_GROUP}` in subscription `${AZURE_SUBSCRIPTION_NAME}`
        END
    ELSE
        RW.Core.Add Pre To Report    "No publicly accessible MySQL Flexible Servers found in resource group `${AZURE_RESOURCE_GROUP}` in subscription `${AZURE_SUBSCRIPTION_NAME}`"
    END


List MySQL Flexible Servers Without Replication in resource group `${AZURE_RESOURCE_GROUP}` in Subscription `${AZURE_SUBSCRIPTION_NAME}`
    [Documentation]    Lists MySQL Flexible Servers that have no replication configured
    [Tags]    Database    Azure    MySQL    Replication    access:read-only
    ${policy_name}    Set Variable    mysqlfx-no-replication
    CloudCustodian.Core.Generate Policy   
    ...    ${CURDIR}/${policy_name}.j2
    ...    resourceGroup=${AZURE_RESOURCE_GROUP}
    ${c7n_output}=    RW.CLI.Run Cli
    ...    cmd=custodian run -s ${OUTPUT_DIR}/azure-c7n-db-health ${CURDIR}/${policy_name}.yaml --cache-period 0
    ${report_data}=    RW.CLI.Run Cli
    ...    cmd=cat ${OUTPUT_DIR}/azure-c7n-db-health/${policy_name}/resources.json
    RW.CLI.Run Cli    cmd=rm ${CURDIR}/${policy_name}.yaml    # Remove generated policy
    TRY
        ${server_list}=    Evaluate    json.loads(r'''${report_data.stdout}''')    json
    EXCEPT
        Log    Failed to load JSON payload, defaulting to empty list.    WARN
        ${server_list}=    Create List
    END

    IF    len(@{server_list}) > 0
        ${formatted_results}=    RW.CLI.Run Cli
        ...    cmd=jq -r '["Server_Name", "Resource_Group", "Location", "Server_Link"], (.[] | [ .name, (.resourceGroup | ascii_downcase), (.location | gsub(" "; "_")), ("https://portal.azure.com/#@/resource" + .id + "/overview") ]) | @tsv' ${OUTPUT_DIR}/azure-c7n-db-health/${policy_name}/resources.json | column -t
        RW.Core.Add Pre To Report    MySQL Flexible Servers Without Replication Summary:\n=====================================================\n${formatted_results.stdout}

        FOR    ${server}    IN    @{server_list}
            ${pretty_server}=    Evaluate    pprint.pformat(${server})    modules=pprint
            ${resource_group}=    Set Variable    ${server['resourceGroup'].lower()}
            ${server_name}=    Set Variable    ${server['name']}
            RW.Core.Add Issue
            ...    severity=3
            ...    expected=MySQL Flexible Server `${server_name}` should have replication configured in resource group `${resource_group}` in subscription `${AZURE_SUBSCRIPTION_NAME}`
            ...    actual=MySQL Flexible Server `${server_name}` has no replication configured in resource group `${resource_group}` in subscription `${AZURE_SUBSCRIPTION_NAME}`
            ...    title=MySQL Flexible Server `${server_name}` Without Replication Detected in Resource Group `${resource_group}` in subscription `${AZURE_SUBSCRIPTION_NAME}`
            ...    reproduce_hint=${c7n_output.cmd}
            ...    details=${pretty_server}
            ...    next_steps=Configure replication for the MySQL Flexible Server in resource group `${AZURE_RESOURCE_GROUP}` in subscription `${AZURE_SUBSCRIPTION_NAME}`
        END
    ELSE
        RW.Core.Add Pre To Report    "All MySQL Flexible Servers have replication configured in resource group `${AZURE_RESOURCE_GROUP}` in subscription `${AZURE_SUBSCRIPTION_NAME}`"
    END


List MySQL Flexible Servers Without High Availability in resource group `${AZURE_RESOURCE_GROUP}` in Subscription `${AZURE_SUBSCRIPTION_NAME}`
    [Documentation]    Lists MySQL Flexible Servers that have high availability disabled
    [Tags]    Database    Azure    MySQL    HighAvailability    access:read-only
    ${policy_name}    Set Variable    mysqlfx-ha-check
    CloudCustodian.Core.Generate Policy   
    ...    ${CURDIR}/${policy_name}.j2
    ...    resourceGroup=${AZURE_RESOURCE_GROUP}
    ${c7n_output}=    RW.CLI.Run Cli
    ...    cmd=custodian run -s ${OUTPUT_DIR}/azure-c7n-db-health ${CURDIR}/${policy_name}.yaml --cache-period 0
    ${report_data}=    RW.CLI.Run Cli
    ...    cmd=cat ${OUTPUT_DIR}/azure-c7n-db-health/${policy_name}/resources.json
    RW.CLI.Run Cli    cmd=rm ${CURDIR}/${policy_name}.yaml    # Remove generated policy
    TRY
        ${server_list}=    Evaluate    json.loads(r'''${report_data.stdout}''')    json
    EXCEPT
        Log    Failed to load JSON payload, defaulting to empty list.    WARN
        ${server_list}=    Create List
    END

    IF    len(@{server_list}) > 0
        ${formatted_results}=    RW.CLI.Run Cli
        ...    cmd=jq -r '["Server_Name", "Resource_Group", "Location", "Server_Link"], (.[] | [ .name, (.resourceGroup | ascii_downcase), (.location | gsub(" "; "_")), ("https://portal.azure.com/#@/resource" + .id + "/overview") ]) | @tsv' ${OUTPUT_DIR}/azure-c7n-db-health/${policy_name}/resources.json | column -t
        RW.Core.Add Pre To Report    MySQL Flexible Servers Without High Availability Summary:\n==========================================================\n${formatted_results.stdout}

        FOR    ${server}    IN    @{server_list}
            ${pretty_server}=    Evaluate    pprint.pformat(${server})    modules=pprint
            ${resource_group}=    Set Variable    ${server['resourceGroup'].lower()}
            ${server_name}=    Set Variable    ${server['name']}
            RW.Core.Add Issue
            ...    severity=3
            ...    expected=MySQL Flexible Server `${server_name}` should have high availability enabled in resource group `${resource_group}` in subscription `${AZURE_SUBSCRIPTION_NAME}`
            ...    actual=MySQL Flexible Server `${server_name}` has high availability disabled in resource group `${resource_group}` in subscription `${AZURE_SUBSCRIPTION_NAME}`
            ...    title=MySQL Flexible Server `${server_name}` Without High Availability Detected in Resource Group `${resource_group}` in subscription `${AZURE_SUBSCRIPTION_NAME}`
            ...    reproduce_hint=${c7n_output.cmd}
            ...    details=${pretty_server}
            ...    next_steps=Enable high availability for the MySQL Flexible Server in resource group `${AZURE_RESOURCE_GROUP}` in subscription `${AZURE_SUBSCRIPTION_NAME}`
        END
    ELSE
        RW.Core.Add Pre To Report    "All MySQL Flexible Servers have high availability enabled in resource group `${AZURE_RESOURCE_GROUP}` in subscription `${AZURE_SUBSCRIPTION_NAME}`"
    END

List MySQL Flexible Servers With High CPU Usage in resource group `${AZURE_RESOURCE_GROUP}` in Subscription `${AZURE_SUBSCRIPTION_NAME}`
    [Documentation]    Lists MySQL Flexible Servers that have high CPU usage
    [Tags]    Database    Azure    MySQL    CPU    access:read-only
    ${policy_name}    Set Variable    mysqlfx-high-cpu
    CloudCustodian.Core.Generate Policy   
    ...    ${CURDIR}/${policy_name}.j2
    ...    resourceGroup=${AZURE_RESOURCE_GROUP}
    ...    threshold=${HIGH_CPU_PERCENTAGE_MYSQL}
    ...    timeframe=${HIGH_CPU_TIMEFRAME_MYSQL}
    ${c7n_output}=    RW.CLI.Run Cli
    ...    cmd=custodian run -s ${OUTPUT_DIR}/azure-c7n-db-health ${CURDIR}/${policy_name}.yaml --cache-period 0
    ${report_data}=    RW.CLI.Run Cli
    ...    cmd=cat ${OUTPUT_DIR}/azure-c7n-db-health/${policy_name}/resources.json
    RW.CLI.Run Cli    cmd=rm ${CURDIR}/${policy_name}.yaml    # Remove generated policy
    TRY
        ${server_list}=    Evaluate    json.loads(r'''${report_data.stdout}''')    json
    EXCEPT
        Log    Failed to load JSON payload, defaulting to empty list.    WARN
        ${server_list}=    Create List
    END

    IF    len(@{server_list}) > 0
        ${formatted_results}=    RW.CLI.Run Cli
        ...    cmd=jq -r '["Server_Name", "Resource_Group", "Location", "CPU_Usage%", "Server_Link"], (.[] | [ .name, (.resourceGroup | ascii_downcase), (.location | gsub(" "; "_")), (."c7n:metrics" | to_entries | map(.value.measurement[0]) | first // 0 | tonumber | (. * 100 | round / 100) | tostring), ("https://portal.azure.com/#@/resource" + .id + "/overview") ]) | @tsv' ${OUTPUT_DIR}/azure-c7n-db-health/${policy_name}/resources.json | column -t
        RW.Core.Add Pre To Report    MySQL Flexible Servers With High CPU Usage Summary:\n=====================================================\n${formatted_results.stdout}

        FOR    ${server}    IN    @{server_list}
            ${pretty_server}=    Evaluate    pprint.pformat(${server})    modules=pprint
            ${resource_group}=    Set Variable    ${server['resourceGroup'].lower()}
            ${server_name}=    Set Variable    ${server['name']}
            ${json_str}=    Evaluate    json.dumps(${server})    json
            ${cpu_usage_result}=    RW.CLI.Run Cli
            ...    cmd=echo '${json_str}' | jq -r '(."c7n:metrics" | to_entries | map(.value.measurement[0]) | first // "0")'
            ${cpu_usage}=    Convert To Number    ${cpu_usage_result.stdout}    2
            RW.Core.Add Issue
            ...    severity=3
            ...    expected=MySQL Flexible Server `${server_name}` should have CPU usage below ${HIGH_CPU_PERCENTAGE_MYSQL}% in resource group `${resource_group}` in subscription `${AZURE_SUBSCRIPTION_NAME}`
            ...    actual=MySQL Flexible Server `${server_name}` has CPU usage of ${cpu_usage}% in resource group `${resource_group}` in subscription `${AZURE_SUBSCRIPTION_NAME}`
            ...    title=High CPU Usage Detected on MySQL Flexible Server `${server_name}` in Resource Group `${resource_group}` in subscription `${AZURE_SUBSCRIPTION_NAME}`
            ...    reproduce_hint=${c7n_output.cmd}
            ...    details=${pretty_server}
            ...    next_steps=Investigate and optimize the MySQL Flexible Server's CPU usage in resource group `${AZURE_RESOURCE_GROUP}` in subscription `${AZURE_SUBSCRIPTION_NAME}`
        END
    ELSE
        RW.Core.Add Pre To Report    "No MySQL Flexible Servers with high CPU usage found in resource group `${AZURE_RESOURCE_GROUP}` in subscription `${AZURE_SUBSCRIPTION_NAME}`"
    END


List MySQL Flexible Servers With High Memory Usage in resource group `${AZURE_RESOURCE_GROUP}` in Subscription `${AZURE_SUBSCRIPTION_NAME}`
    [Documentation]    Lists MySQL Flexible Servers that have high memory usage
    [Tags]    Database    Azure    MySQL    Memory    access:read-only
    ${policy_name}    Set Variable    mysqlfx-high-memory
    CloudCustodian.Core.Generate Policy   
    ...    ${CURDIR}/${policy_name}.j2
    ...    resourceGroup=${AZURE_RESOURCE_GROUP}
    ...    threshold=${HIGH_MEMORY_PERCENTAGE_MYSQL}
    ...    timeframe=${HIGH_MEMORY_TIMEFRAME_MYSQL}
    ${c7n_output}=    RW.CLI.Run Cli
    ...    cmd=custodian run -s ${OUTPUT_DIR}/azure-c7n-db-health ${CURDIR}/${policy_name}.yaml --cache-period 0
    ${report_data}=    RW.CLI.Run Cli
    ...    cmd=cat ${OUTPUT_DIR}/azure-c7n-db-health/${policy_name}/resources.json
    RW.CLI.Run Cli    cmd=rm ${CURDIR}/${policy_name}.yaml    # Remove generated policy
    TRY
        ${server_list}=    Evaluate    json.loads(r'''${report_data.stdout}''')    json
    EXCEPT
        Log    Failed to load JSON payload, defaulting to empty list.    WARN
        ${server_list}=    Create List
    END

    IF    len(@{server_list}) > 0
        ${formatted_results}=    RW.CLI.Run Cli
        ...    cmd=jq -r '["Server_Name", "Resource_Group", "Location", "Memory_Usage%", "Server_Link"], (.[] | [ .name, (.resourceGroup | ascii_downcase), (.location | gsub(" "; "_")), (."c7n:metrics" | to_entries | map(.value.measurement[0]) | first // 0 | tonumber | (. * 100 | round / 100) | tostring), ("https://portal.azure.com/#@/resource" + .id + "/overview") ]) | @tsv' ${OUTPUT_DIR}/azure-c7n-db-health/${policy_name}/resources.json | column -t
        RW.Core.Add Pre To Report    MySQL Flexible Servers With High Memory Usage Summary:\n=====================================================\n${formatted_results.stdout}

        FOR    ${server}    IN    @{server_list}
            ${pretty_server}=    Evaluate    pprint.pformat(${server})    modules=pprint
            ${resource_group}=    Set Variable    ${server['resourceGroup'].lower()}
            ${server_name}=    Set Variable    ${server['name']}
            ${json_str}=    Evaluate    json.dumps(${server})    json
            ${memory_usage_result}=    RW.CLI.Run Cli
            ...    cmd=echo '${json_str}' | jq -r '(."c7n:metrics" | to_entries | map(.value.measurement[0]) | first // "0")'
            ${memory_usage}=    Convert To Number    ${memory_usage_result.stdout}    2
            RW.Core.Add Issue
            ...    severity=3
            ...    expected=MySQL Flexible Server `${server_name}` should have memory usage below ${HIGH_MEMORY_PERCENTAGE_MYSQL}% in resource group `${resource_group}` in subscription `${AZURE_SUBSCRIPTION_NAME}`
            ...    actual=MySQL Flexible Server `${server_name}` has memory usage of ${memory_usage}% in resource group `${resource_group}` in subscription `${AZURE_SUBSCRIPTION_NAME}`
            ...    title=High Memory Usage Detected on MySQL Flexible Server `${server_name}` in Resource Group `${resource_group}` in subscription `${AZURE_SUBSCRIPTION_NAME}`
            ...    reproduce_hint=${c7n_output.cmd}
            ...    details=${pretty_server}
            ...    next_steps=Investigate and optimize the MySQL Flexible Server's memory usage in resource group `${AZURE_RESOURCE_GROUP}` in subscription `${AZURE_SUBSCRIPTION_NAME}`
        END
    ELSE
        RW.Core.Add Pre To Report    "No MySQL Flexible Servers with high memory usage found in resource group `${AZURE_RESOURCE_GROUP}` in subscription `${AZURE_SUBSCRIPTION_NAME}`"
    END

List MySQL Flexible Servers With High Memory Usage in resource group `${AZURE_RESOURCE_GROUP}` in Subscription `${AZURE_SUBSCRIPTION_NAME}`
    [Documentation]    Lists MySQL Flexible Servers that have high memory usage
    [Tags]    Database    Azure    MySQL    Memory    access:read-only
    ${policy_name}    Set Variable    mysqlfx-high-memory
    CloudCustodian.Core.Generate Policy   
    ...    ${CURDIR}/${policy_name}.j2
    ...    resourceGroup=${AZURE_RESOURCE_GROUP}
    ...    threshold=${HIGH_MEMORY_PERCENTAGE_MYSQL}
    ...    timeframe=${HIGH_MEMORY_TIMEFRAME_MYSQL}
    ${c7n_output}=    RW.CLI.Run Cli
    ...    cmd=custodian run -s ${OUTPUT_DIR}/azure-c7n-db-health ${CURDIR}/${policy_name}.yaml --cache-period 0
    ${report_data}=    RW.CLI.Run Cli
    ...    cmd=cat ${OUTPUT_DIR}/azure-c7n-db-health/${policy_name}/resources.json
    RW.CLI.Run Cli    cmd=rm ${CURDIR}/${policy_name}.yaml    # Remove generated policy
    TRY
        ${server_list}=    Evaluate    json.loads(r'''${report_data.stdout}''')    json
    EXCEPT
        Log    Failed to load JSON payload, defaulting to empty list.    WARN
        ${server_list}=    Create List
    END

    IF    len(@{server_list}) > 0
        ${formatted_results}=    RW.CLI.Run Cli
        ...    cmd=jq -r '["Server_Name", "Resource_Group", "Location", "Memory_Usage%", "Server_Link"], (.[] | [ .name, (.resourceGroup | ascii_downcase), (.location | gsub(" "; "_")), (."c7n:metrics" | to_entries | map(.value.measurement[0]) | first // 0 | tonumber | (. * 100 | round / 100) | tostring), ("https://portal.azure.com/#@/resource" + .id + "/overview") ]) | @tsv' ${OUTPUT_DIR}/azure-c7n-db-health/${policy_name}/resources.json | column -t
        RW.Core.Add Pre To Report    MySQL Flexible Servers With High Memory Usage Summary:\n=====================================================\n${formatted_results.stdout}

        FOR    ${server}    IN    @{server_list}
            ${pretty_server}=    Evaluate    pprint.pformat(${server})    modules=pprint
            ${resource_group}=    Set Variable    ${server['resourceGroup'].lower()}
            ${server_name}=    Set Variable    ${server['name']}
            ${json_str}=    Evaluate    json.dumps(${server})    json
            ${memory_usage_result}=    RW.CLI.Run Cli
            ...    cmd=echo '${json_str}' | jq -r '(."c7n:metrics" | to_entries | map(.value.measurement[0]) | first // "0")'
            ${memory_usage}=    Convert To Number    ${memory_usage_result.stdout}    2
            RW.Core.Add Issue
            ...    severity=3
            ...    expected=MySQL Flexible Server `${server_name}` should have memory usage below ${HIGH_MEMORY_PERCENTAGE_MYSQL}% in resource group `${resource_group}` in subscription `${AZURE_SUBSCRIPTION_NAME}`
            ...    actual=MySQL Flexible Server `${server_name}` has memory usage of ${memory_usage}% in resource group `${resource_group}` in subscription `${AZURE_SUBSCRIPTION_NAME}`
            ...    title=High Memory Usage Detected on MySQL Flexible Server `${server_name}` in Resource Group `${resource_group}` in subscription `${AZURE_SUBSCRIPTION_NAME}`
            ...    reproduce_hint=${c7n_output.cmd}
            ...    details=${pretty_server}
            ...    next_steps=Investigate and optimize the MySQL Flexible Server's memory usage in resource group `${AZURE_RESOURCE_GROUP}` in subscription `${AZURE_SUBSCRIPTION_NAME}`
        END
    ELSE
        RW.Core.Add Pre To Report    "No MySQL Flexible Servers with high memory usage found in resource group `${AZURE_RESOURCE_GROUP}` in subscription `${AZURE_SUBSCRIPTION_NAME}`"
    END


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
    ${AZURE_SUBSCRIPTION_NAME}=    RW.Core.Import User Variable    AZURE_SUBSCRIPTION_NAME
    ...    type=string
    ...    description=The Azure Subscription Name.  
    ...    pattern=\w*
    ...    default=""
    ${AZURE_RESOURCE_GROUP}=    RW.Core.Import User Variable    AZURE_RESOURCE_GROUP
    ...    type=string
    ...    description=Azure resource group.
    ...    pattern=\w*
    ${HIGH_CPU_PERCENTAGE_MYSQL}=    RW.Core.Import User Variable    HIGH_CPU_PERCENTAGE_MYSQL
    ...    type=string
    ...    description=The CPU percentage threshold to check for high CPU usage.
    ...    pattern=^\d+$
    ...    example=80
    ...    default=80
    ${HIGH_CPU_TIMEFRAME_MYSQL}=    RW.Core.Import User Variable    HIGH_CPU_TIMEFRAME_MYSQL
    ...    type=string
    ...    description=The timeframe to check for high CPU usage in hours.
    ...    pattern=^\d+$
    ...    example=24
    ...    default=24
    ${HIGH_MEMORY_PERCENTAGE_MYSQL}=    RW.Core.Import User Variable    HIGH_MEMORY_PERCENTAGE_MYSQL
    ...    type=string
    ...    description=The memory percentage threshold to check for high memory usage.
    ...    pattern=^\d+$
    ...    example=80
    ...    default=80
    ${HIGH_MEMORY_TIMEFRAME_MYSQL}=    RW.Core.Import User Variable    HIGH_MEMORY_TIMEFRAME_MYSQL
    ...    type=string
    ...    description=The timeframe to check for high memory usage in hours.
    ...    pattern=^\d+$
    ...    example=24
    ...    default=24
    Set Suite Variable    ${AZURE_SUBSCRIPTION_NAME}    ${AZURE_SUBSCRIPTION_NAME}
    Set Suite Variable    ${AZURE_SUBSCRIPTION_ID}    ${AZURE_SUBSCRIPTION_ID}
    Set Suite Variable    ${AZURE_RESOURCE_GROUP}    ${AZURE_RESOURCE_GROUP}
    Set Suite Variable    ${HIGH_CPU_PERCENTAGE_MYSQL}    ${HIGH_CPU_PERCENTAGE_MYSQL}
    Set Suite Variable    ${HIGH_CPU_TIMEFRAME_MYSQL}    ${HIGH_CPU_TIMEFRAME_MYSQL}
    Set Suite Variable    ${HIGH_MEMORY_PERCENTAGE_MYSQL}    ${HIGH_MEMORY_PERCENTAGE_MYSQL}
    Set Suite Variable    ${HIGH_MEMORY_TIMEFRAME_MYSQL}    ${HIGH_MEMORY_TIMEFRAME_MYSQL}