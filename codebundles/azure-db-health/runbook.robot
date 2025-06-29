*** Settings ***
Documentation       List databases that are publicly accessible, without replication, without high availability configuration, with high CPU usage, high memory usage, high cache miss rate, and low availability in Azure
Metadata            Author    saurabh3460
Metadata            Display Name    Azure Database Health
Metadata            Supports    Azure    Database    Health    CloudCustodian
Force Tags          Azure    Database    Health    CloudCustodian    cosmosdb    sql    redis    postgresql    availability

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
List Database Availability in resource group `${AZURE_RESOURCE_GROUP}`
    [Documentation]    Lists databases that have availability below 100%
    [Tags]    Database    Azure    Availability    access:read-only
    ${db_map}=    Evaluate    json.load(open('db-map.json'))    json
    
    FOR    ${db_type}    IN    @{db_map.keys()}
        ${db_info}=    Set Variable    ${db_map['${db_type}']}
        Continue For Loop If    'availability' not in ${db_info}
        ${policy_name}=    Set Variable    ${db_type}-availability
        ${display_name}=    Set Variable    ${db_info['display_name']}
        ${availability_metric}=    Set Variable    ${db_info['availability']}
        
        CloudCustodian.Core.Generate Policy   
        ...    availability.j2        
        ...    name=${db_type}
        ...    resource=${db_info['resource']}
        ...    metric=${availability_metric}
        ...    resourceGroup=${AZURE_RESOURCE_GROUP}
        ...    threshold=${LOW_AVAILABILITY_THRESHOLD}
        ...    timeframe=${LOW_AVAILABILITY_TIMEFRAME}
        ...    interval=${LOW_AVAILABILITY_INTERVAL}    
        ${c7n_output}=    RW.CLI.Run Cli
        ...    cmd=custodian run -s azure-c7n-db-health availability.yaml --cache-period 0
        ...    timeout_seconds=180
        
        ${report_data}=    RW.CLI.Run Cli
        ...    cmd=cat azure-c7n-db-health/${policy_name}/resources.json
        
        RW.CLI.Run Cli    cmd=rm availability.yaml        # Remove generated policy
        
        TRY
            ${db_list}=    Evaluate    json.loads(r'''${report_data.stdout}''')    json
        EXCEPT
            Log    Failed to load JSON payload, defaulting to empty list.    WARN
            ${db_list}=    Create List
        END

        IF    len(@{db_list}) > 0
            ${formatted_results}=    RW.CLI.Run Cli
            ...    cmd=jq -r '["DB_Name", "Resource_Group", "Location", "Availability%", "DB_Link"], (.[] | [ .name, (.resourceGroup | ascii_downcase), (.location | gsub(" "; "_")), (."c7n:metrics" | to_entries | map(.value.measurement[-1]) | first // 0 | tonumber | (. * 100 | round / 100) | tostring), ("https://portal.azure.com/#@/resource" + .id + "/overview") ]) | @tsv' ${OUTPUT_DIR}/azure-c7n-db-health/${policy_name}/resources.json | column -t
            RW.Core.Add Pre To Report    ${display_name} With Low Availability Summary:\n=====================================================\n${formatted_results.stdout}
            
            FOR    ${db}    IN    @{db_list}
                ${pretty_db}=    Evaluate    pprint.pformat(${db})    modules=pprint
                ${resource_group}=    Set Variable    ${db['resourceGroup'].lower()}
                ${db_name}=    Set Variable    ${db['name']}
                ${json_str}=    Evaluate    json.dumps(${db})    json
                ${availability_result}=    RW.CLI.Run Cli
                ...    cmd=echo '${json_str}' | jq -r '(."c7n:metrics" | to_entries | map(.value.measurement[0]) | first // "0")'
                ${availability}=    Convert To Number    ${availability_result.stdout}    2
                RW.Core.Add Issue
                ...    severity=3
                ...    expected=${display_name} `${db_name}` should have availability above 99.99% in resource group `${resource_group}`
                ...    actual=${display_name} `${db_name}` has availability of ${availability}% in resource group `${resource_group}`
                ...    title=Low Availability Detected on ${display_name} `${db_name}` in Resource Group `${resource_group}`
                ...    reproduce_hint=${c7n_output.cmd}
                ...    details=${pretty_db}
                ...    next_steps=Investigate and resolve the availability issues for the ${display_name} in resource group `${AZURE_RESOURCE_GROUP}`
            END
        ELSE
            RW.Core.Add Pre To Report    "No ${display_name} with low availability found in resource group `${AZURE_RESOURCE_GROUP}`"
        END
    END

List Publicly Accessible Databases in resource group `${AZURE_RESOURCE_GROUP}`
    [Documentation]    Lists databases that have public network access enabled
    [Tags]    Database    Azure    Security    access:read-only
    
    ${db_map}=    Evaluate    json.load(open('${CURDIR}/db-map.json'))    json
    
    FOR    ${db_type}    IN    @{db_map.keys()}
        ${db_info}=    Set Variable    ${db_map['${db_type}']}
        Continue For Loop If    'publicnetworkaccess' not in ${db_info}
        
        ${policy_name}=    Set Variable    ${db_type}-public-access
        ${display_name}=    Set Variable    ${db_info['display_name']}
        
        CloudCustodian.Core.Generate Policy   
        ...    ${CURDIR}/public-access.j2
        ...    name=${db_type}
        ...    resource=${db_info['resource']}
        ...    key=${db_info['publicnetworkaccess']}
        ...    resourceGroup=${AZURE_RESOURCE_GROUP}
        
        ${c7n_output}=    RW.CLI.Run Cli
        ...    cmd=custodian run -s ${OUTPUT_DIR}/azure-c7n-db-health ${CURDIR}/public-access.yaml --cache-period 0
        
        ${report_data}=    RW.CLI.Run Cli
        ...    cmd=cat ${OUTPUT_DIR}/azure-c7n-db-health/${policy_name}/resources.json
        
        RW.CLI.Run Cli    cmd=rm ${CURDIR}/public-access.yaml    # Remove generated policy
        
        TRY
            ${server_list}=    Evaluate    json.loads(r'''${report_data.stdout}''')    json
        EXCEPT
            Log    Failed to load JSON payload, defaulting to empty list.    WARN
            ${server_list}=    Create List
        END

        IF    len(@{server_list}) > 0
            ${formatted_results}=    RW.CLI.Run Cli
            ...    cmd=jq -r '["Server_Name", "Resource_Group", "Location", "Server_Link"], (.[] | [ .name, (.resourceGroup | ascii_downcase), (.location | gsub(" "; "_")), ("https://portal.azure.com/#@/resource" + .id + "/overview") ]) | @tsv' ${OUTPUT_DIR}/azure-c7n-db-health/${policy_name}/resources.json | column -t
            
            RW.Core.Add Pre To Report    Publicly Accessible ${display_name} Summary:\n=====================================================\n${formatted_results.stdout}

            FOR    ${server}    IN    @{server_list}
                ${pretty_server}=    Evaluate    pprint.pformat(${server})    modules=pprint
                ${resource_group}=    Set Variable    ${server['resourceGroup'].lower()}
                ${server_name}=    Set Variable    ${server['name']}
                
                RW.Core.Add Issue
                ...    severity=4
                ...    expected=${display_name} `${server_name}` should not have public network access enabled in resource group `${resource_group}`
                ...    actual=${display_name} `${server_name}` has public network access enabled in resource group `${resource_group}`
                ...    title=Publicly Accessible ${display_name} `${server_name}` Detected in Resource Group `${resource_group}`
                ...    reproduce_hint=${c7n_output.cmd}
                ...    details=${pretty_server}
                ...    next_steps=Disable public network access for the ${display_name} in resource group `${AZURE_RESOURCE_GROUP}`
            END
        ELSE
            RW.Core.Add Pre To Report    "No publicly accessible ${display_name} found in resource group `${AZURE_RESOURCE_GROUP}`"
        END
    END


List Databases Without Replication in resource group `${AZURE_RESOURCE_GROUP}`
    [Documentation]    Lists databases that have no replication configured
    [Tags]    Database    Azure    Replication    access:read-only
    
    ${db_types}=    Evaluate    json.load(open('${CURDIR}/db-map.json'))    json
    FOR    ${db_type}    IN    @{db_types.keys()}
        ${replication_config}=    Set Variable    ${db_types["${db_type}"].get("replication", {})}
        IF    not ${replication_config}    CONTINUE
        
        ${policy_name}=    Set Variable    ${db_type}-replication-check
        ${resource}=    Set Variable    ${db_types["${db_type}"]["resource"]}
        ${display_name}=    Set Variable    ${db_types["${db_type}"]["display_name"]}
        
        CloudCustodian.Core.Generate Policy   
        ...    ${CURDIR}/replication-check.j2
        ...    name=${db_type}
        ...    resource=${resource}
        ...    key=${replication_config["key"]}
        ...    value=${replication_config["value"]}
        ...    resourceGroup=${AZURE_RESOURCE_GROUP}
        RW.CLI.Run Cli    cmd=cat ${CURDIR}/replication-check.yaml    # Log generated policy
        ${c7n_output}=    RW.CLI.Run Cli
        ...    cmd=custodian run -s ${OUTPUT_DIR}/azure-c7n-db-health ${CURDIR}/replication-check.yaml --cache-period 0
        ...    timeout_seconds=180
        
        ${report_data}=    RW.CLI.Run Cli
        ...    cmd=cat ${OUTPUT_DIR}/azure-c7n-db-health/${policy_name}/resources.json
        
        RW.CLI.Run Cli    cmd=rm ${CURDIR}/replication-check.yaml    # Remove generated policy
        
        TRY
            ${db_list}=    Evaluate    json.loads(r'''${report_data.stdout}''')    json
        EXCEPT
            Log    Failed to load JSON payload, defaulting to empty list.    WARN
            ${db_list}=    Create List
        END

        IF    len(@{db_list}) > 0
            ${formatted_results}=    RW.CLI.Run Cli
            ...    cmd=jq -r '["DB_Name", "Resource_Group", "Location", "DB_Link"], (.[] | [ .name, (.resourceGroup | ascii_downcase), (.location | gsub(" "; "_")), ("https://portal.azure.com/#@/resource" + .id + "/overview") ]) | @tsv' ${OUTPUT_DIR}/azure-c7n-db-health/${policy_name}/resources.json | column -t
            RW.Core.Add Pre To Report    ${display_name} Without Replication Summary:\n=====================================================\n${formatted_results.stdout}

            FOR    ${db}    IN    @{db_list}
                ${pretty_db}=    Evaluate    pprint.pformat(${db})    modules=pprint
                ${resource_group}=    Set Variable    ${db['resourceGroup'].lower()}
                ${db_name}=    Set Variable    ${db['name']}
                RW.Core.Add Issue
                ...    severity=4
                ...    expected=${display_name} `${db_name}` should have replication configured in resource group `${resource_group}`
                ...    actual=${display_name} `${db_name}` has no replication configured in resource group `${resource_group}`
                ...    title=${display_name} `${db_name}` Without Replication Detected in Resource Group `${resource_group}`
                ...    reproduce_hint=${c7n_output.cmd}
                ...    details=${pretty_db}
                ...    next_steps=Configure replication for the ${display_name} in resource group `${AZURE_RESOURCE_GROUP}`
            END
        ELSE
            RW.Core.Add Pre To Report    "No ${display_name} without replication configured found in resource group `${AZURE_RESOURCE_GROUP}`"
        END
    END


List Databases Without High Availability in resource group `${AZURE_RESOURCE_GROUP}`
    [Documentation]    Lists databases that have high availability disabled
    [Tags]    Database    Azure    HighAvailability    access:read-only
    
    ${db_types}=    Evaluate    json.load(open('${CURDIR}/db-map.json'))    json
    FOR    ${db_type}    IN    @{db_types.keys()}
        ${ha_config}=    Set Variable    ${db_types["${db_type}"].get("ha", {})}
        IF    not ${ha_config}    CONTINUE
        
        ${policy_name}=    Set Variable    ${db_type}-ha-check
        ${resource}=    Set Variable    ${db_types["${db_type}"]["resource"]}
        ${display_name}=    Set Variable    ${db_types["${db_type}"]["display_name"]}
        
        CloudCustodian.Core.Generate Policy   
        ...    ${CURDIR}/ha-check.j2
        ...    name=${db_type}
        ...    resource=${resource}
        ...    key=${ha_config["key"]}
        ...    value=${ha_config["value"]}
        ...    resourceGroup=${AZURE_RESOURCE_GROUP}
        RW.CLI.Run Cli    cmd=cat ${CURDIR}/ha-check.yaml    # Log generated policy
        ${c7n_output}=    RW.CLI.Run Cli
        ...    cmd=custodian run -s ${OUTPUT_DIR}/azure-c7n-db-health ${CURDIR}/ha-check.yaml --cache-period 0
        ...    timeout_seconds=180
        ${report_data}=    RW.CLI.Run Cli
        ...    cmd=cat ${OUTPUT_DIR}/azure-c7n-db-health/${policy_name}/resources.json
        RW.CLI.Run Cli    cmd=rm ${CURDIR}/ha-check.yaml    # Remove generated policy
        
        TRY
            ${db_list}=    Evaluate    json.loads(r'''${report_data.stdout}''')    json
        EXCEPT
            Log    Failed to load JSON payload, defaulting to empty list.    WARN
            ${db_list}=    Create List
        END

        IF    len(@{db_list}) > 0
            ${formatted_results}=    RW.CLI.Run Cli
            ...    cmd=jq -r --arg key "${ha_config["key"]}" --arg value "${ha_config["value"]}" '["DB_Name", "Resource_Group", "Location", $key, "DB_Link"], (.[] | [ .name, (.resourceGroup | ascii_downcase), (.location | gsub(" "; "_")), ($value | tostring), ("https://portal.azure.com/#@/resource" + .id + "/overview") ]) | @tsv' ${OUTPUT_DIR}/azure-c7n-db-health/${policy_name}/resources.json | column -t
            RW.Core.Add Pre To Report    ${display_name} Without High Availability Summary:\n=====================================================\n${formatted_results.stdout}

            FOR    ${db}    IN    @{db_list}
                ${pretty_db}=    Evaluate    pprint.pformat(${db})    modules=pprint
                ${resource_group}=    Set Variable    ${db['resourceGroup'].lower()}
                ${db_name}=    Set Variable    ${db['name']}
                RW.Core.Add Issue
                ...    severity=4
                ...    expected=${display_name} `${db_name}` should have high availability enabled in resource group `${resource_group}`
                ...    actual=${display_name} `${db_name}` has high availability disabled in resource group `${resource_group}`
                ...    title=${display_name} `${db_name}` Without High Availability Detected in Resource Group `${resource_group}`
                ...    reproduce_hint=${c7n_output.cmd}
                ...    details=${pretty_db}
                ...    next_steps=Enable high availability for the ${display_name} in resource group `${AZURE_RESOURCE_GROUP}`
            END
        ELSE
            RW.Core.Add Pre To Report    "No ${display_name} without high availability found in resource group `${AZURE_RESOURCE_GROUP}`"
        END
    END

List Databases With High CPU Usage in resource group `${AZURE_RESOURCE_GROUP}`
    [Documentation]    Lists databases that have high CPU usage
    [Tags]    Database    Azure    CPU    access:read-only
    
    ${db_types}=    Evaluate    json.load(open('${CURDIR}/db-map.json'))    json
    FOR    ${db_type}    IN    @{db_types.keys()}
        Continue For Loop If    "cpu_metric" not in ${db_types["${db_type}"]}
        
        ${policy_name}=    Set Variable    ${db_type}-high-cpu
        ${resource}=    Set Variable    ${db_types["${db_type}"]["resource"]}
        ${display_name}=    Set Variable    ${db_types["${db_type}"]["display_name"]}
        ${cpu_metric}=    Set Variable    ${db_types["${db_type}"]["cpu_metric"]}
        
        CloudCustodian.Core.Generate Policy
        ...    ${CURDIR}/high-cpu.j2
        ...    name=${db_type}
        ...    resource=${resource}
        ...    resourceGroup=${AZURE_RESOURCE_GROUP}
        ...    threshold=${HIGH_CPU_PERCENTAGE}
        ...    timeframe=${HIGH_CPU_TIMEFRAME}
        ...    metric=${cpu_metric}
        RW.CLI.Run Cli    cmd=cat ${CURDIR}/high-cpu.yaml    # Log generated policy
        ${c7n_output}=    RW.CLI.Run Cli
        ...    cmd=custodian run -s ${OUTPUT_DIR}/azure-c7n-db-health ${CURDIR}/high-cpu.yaml --cache-period 0
        ...    timeout_seconds=180
        ${report_data}=    RW.CLI.Run Cli
        ...    cmd=cat ${OUTPUT_DIR}/azure-c7n-db-health/${policy_name}/resources.json
        RW.CLI.Run Cli    cmd=rm ${CURDIR}/high-cpu.yaml    # Remove generated policy
        
        TRY
            ${db_list}=    Evaluate    json.loads(r'''${report_data.stdout}''')    json
        EXCEPT
            Log    Failed to load JSON payload, defaulting to empty list.    WARN
            ${db_list}=    Create List
        END

        IF    len(@{db_list}) > 0
            ${formatted_results}=    RW.CLI.Run Cli
            ...    cmd=jq -r '["DB_Name", "Resource_Group", "Location", "CPU_Usage%", "DB_Link"], (.[] | [ .name, (.resourceGroup | ascii_downcase), (.location | gsub(" "; "_")), (."c7n:metrics" | to_entries | map(.value.measurement[0]) | first // 0 | tonumber | (. * 100 | round / 100) | tostring), ("https://portal.azure.com/#@/resource" + .id + "/overview") ]) | @tsv' ${OUTPUT_DIR}/azure-c7n-db-health/${policy_name}/resources.json | column -t
            RW.Core.Add Pre To Report    ${display_name} With High CPU Usage Summary:\n=====================================================\n${formatted_results.stdout}

            FOR    ${db}    IN    @{db_list}
                ${pretty_db}=    Evaluate    pprint.pformat(${db})    modules=pprint
                ${resource_group}=    Set Variable    ${db['resourceGroup'].lower()}
                ${db_name}=    Set Variable    ${db['name']}
                ${json_str}=    Evaluate    json.dumps(${db})    json
                ${cpu_usage_result}=    RW.CLI.Run Cli
                ...    cmd=echo '${json_str}' | jq -r '(."c7n:metrics" | to_entries | map(.value.measurement[0]) | first // "0")'
                ${cpu_usage}=    Convert To Number    ${cpu_usage_result.stdout}    2
                RW.Core.Add Issue
                ...    severity=3
                ...    expected=${display_name} `${db_name}` should have CPU usage below ${HIGH_CPU_PERCENTAGE}% in resource group `${resource_group}`
                ...    actual=${display_name} `${db_name}` has CPU usage of ${cpu_usage}% in resource group `${resource_group}`
                ...    title=High CPU Usage Detected on ${display_name} `${db_name}` in Resource Group `${resource_group}`
                ...    reproduce_hint=${c7n_output.cmd}
                ...    details=${pretty_db}
                ...    next_steps=Increase the CPU cores for the ${display_name} in resource group `${AZURE_RESOURCE_GROUP}`
            END
        ELSE
            RW.Core.Add Pre To Report    "No ${display_name} with high CPU usage found in resource group `${AZURE_RESOURCE_GROUP}`"
        END
    END


List All Databases With High Memory Usage in resource group `${AZURE_RESOURCE_GROUP}`
    [Documentation]    Lists all database types that have high memory usage
    [Tags]    Database    Azure    Memory    access:read-only
    
    ${db_map}=    Evaluate    json.load(open('${CURDIR}/db-map.json'))    json
    FOR    ${db_type}    IN    @{db_map.keys()}
        Continue For Loop If    "cpu_metric" not in ${db_map["${db_type}"]}
        ${resource}=    Set Variable    ${db_map["${db_type}"]["resource"]}
        ${display_name}=    Set Variable    ${db_map["${db_type}"]["display_name"]}
        ${policy_name}=    Set Variable    ${db_type}-high-memory
        ${memory_metric}=    Set Variable    ${db_map["${db_type}"]["memory_metric"]}
        
        CloudCustodian.Core.Generate Policy   
        ...    ${CURDIR}/high-memory.j2
        ...    name=${db_type}
        ...    resource=${resource}
        ...    resourceGroup=${AZURE_RESOURCE_GROUP}
        ...    threshold=${HIGH_MEMORY_PERCENTAGE}
        ...    timeframe=${HIGH_MEMORY_TIMEFRAME}
        ...    metric=${memory_metric}
        RW.CLI.Run Cli    cmd=cat ${CURDIR}/high-memory.yaml    # Log generated policy
        ${c7n_output}=    RW.CLI.Run Cli
        ...    cmd=custodian run -s ${OUTPUT_DIR}/azure-c7n-db-health ${CURDIR}/high-memory.yaml --cache-period 0
        ...    timeout_seconds=180
        ${report_data}=    RW.CLI.Run Cli
        ...    cmd=cat ${OUTPUT_DIR}/azure-c7n-db-health/${policy_name}/resources.json
        RW.CLI.Run Cli    cmd=rm ${CURDIR}/high-memory.yaml    # Remove generated policy
        
        TRY
            ${server_list}=    Evaluate    json.loads(r'''${report_data.stdout}''')    json
        EXCEPT
            Log    Failed to load JSON payload, defaulting to empty list.    WARN
            ${server_list}=    Create List
        END

        IF    len(@{server_list}) > 0
            ${formatted_results}=    RW.CLI.Run Cli
            ...    cmd=jq -r '["Server_Name", "Resource_Group", "Location", "Memory_Usage%", "Server_Link"], (.[] | [ .name, (.resourceGroup | ascii_downcase), (.location | gsub(" "; "_")), (."c7n:metrics" | to_entries | map(.value.measurement[0]) | first // 0 | tonumber | (. * 100 | round / 100) | tostring), ("https://portal.azure.com/#@/resource" + .id + "/overview") ]) | @tsv' ${OUTPUT_DIR}/azure-c7n-db-health/${policy_name}/resources.json | column -t
            RW.Core.Add Pre To Report    ${display_name} With High Memory Usage Summary:\n=====================================================\n${formatted_results.stdout}

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
                ...    expected=${display_name} `${server_name}` should have memory usage below ${HIGH_MEMORY_PERCENTAGE}% in resource group `${resource_group}`
                ...    actual=${display_name} `${server_name}` has memory usage of ${memory_usage}% in resource group `${resource_group}`
                ...    title=High Memory Usage Detected on ${display_name} `${server_name}` in Resource Group `${resource_group}`
                ...    reproduce_hint=${c7n_output.cmd}
                ...    details=${pretty_server}
                ...    next_steps=Investigate and optimize the ${display_name}'s memory usage in resource group `${AZURE_RESOURCE_GROUP}`
            END
        ELSE
            RW.Core.Add Pre To Report    "No ${display_name} with high memory usage found in resource group `${AZURE_RESOURCE_GROUP}`"
        END
    END


List Redis Caches With High Cache Miss Rate in resource group `${AZURE_RESOURCE_GROUP}`
    [Documentation]    Lists Redis caches with high cache miss rate
    [Tags]    Redis    Azure    Cache    access:read-only
    
    ${policy_name}=    Set Variable    redis-cache-miss
    ${resource}=    Set Variable    azure.redis
    ${display_name}=    Set Variable    Redis Cache
    
    CloudCustodian.Core.Generate Policy   
    ...    ${CURDIR}/redis-cache-miss.j2
    ...    resource=${resource}
    ...    threshold=${HIGH_CACHE_MISS_RATE}
    ...    timeframe=${HIGH_CACHE_MISS_TIMEFRAME}
    ...    resourceGroup=${AZURE_RESOURCE_GROUP}
    
    RW.CLI.Run Cli    cmd=cat ${CURDIR}/redis-cache-miss.yaml    # Log generated policy
    ${c7n_output}=    RW.CLI.Run Cli
    ...    cmd=custodian run -s ${OUTPUT_DIR}/azure-c7n-db-health ${CURDIR}/redis-cache-miss.yaml --cache-period 0
    ...    timeout_seconds=180
    
    ${report_data}=    RW.CLI.Run Cli
    ...    cmd=cat ${OUTPUT_DIR}/azure-c7n-db-health/${policy_name}/resources.json
    
    RW.CLI.Run Cli    cmd=rm ${CURDIR}/redis-cache-miss.yaml    # Remove generated policy
    
    TRY
        ${cache_list}=    Evaluate    json.loads(r'''${report_data.stdout}''')    json
    EXCEPT
        Log    Failed to load JSON payload, defaulting to empty list.    WARN
        ${cache_list}=    Create List
    END

    IF    len(@{cache_list}) > 0
        ${formatted_results}=    RW.CLI.Run Cli
        ...    cmd=jq -r '["Cache_Name", "Resource_Group", "Location", "Cache_Miss_Rate%", "Cache_Link"], (.[] | [ .name, (.resourceGroup | ascii_downcase), (.location | gsub(" "; "_")), (."c7n:metrics" | to_entries | map(.value.measurement[0]) | first // 0 | tonumber | (. * 100 | round / 100) | tostring), ("https://portal.azure.com/#@/resource" + .id + "/overview") ]) | @tsv' ${OUTPUT_DIR}/azure-c7n-db-health/${policy_name}/resources.json | column -t
        
        RW.Core.Add Pre To Report    ${display_name} With High Cache Miss Rate Summary:\n=====================================================\n${formatted_results.stdout}

        FOR    ${cache}    IN    @{cache_list}
            ${pretty_cache}=    Evaluate    pprint.pformat(${cache})    modules=pprint
            ${resource_group}=    Set Variable    ${cache['resourceGroup'].lower()}
            ${cache_name}=    Set Variable    ${cache['name']}
            ${json_str}=    Evaluate    json.dumps(${cache})    json
            ${cache_miss_result}=    RW.CLI.Run Cli
            ...    cmd=echo '${json_str}' | jq -r '(."c7n:metrics" | to_entries | map(.value.measurement[0]) | first // "0")'
            ${cache_miss_rate}=    Convert To Number    ${cache_miss_result.stdout}    2
            RW.Core.Add Issue
            ...    severity=4
            ...    expected=${display_name} `${cache_name}` should have low cache miss rate in resource group `${resource_group}`
            ...    actual=${display_name} `${cache_name}` has cache miss rate of ${cache_miss_rate}% in resource group `${resource_group}`
            ...    title=High Cache Miss Rate Detected on ${display_name} `${cache_name}` in Resource Group `${resource_group}`
            ...    reproduce_hint=${c7n_output.cmd}
            ...    details=${pretty_cache}
            ...    next_steps=Investigate and optimize the ${display_name}'s cache configuration in resource group `${AZURE_RESOURCE_GROUP}`
        END
    ELSE
        RW.Core.Add Pre To Report    "No ${display_name} with high cache miss rate found in resource group `${AZURE_RESOURCE_GROUP}`"
    END


List Database Resource Health in resource group `${AZURE_RESOURCE_GROUP}`
    [Documentation]    Lists unhealthy databases using Azure ResourceHealth API
    [Tags]    Database    Azure    Health    ResourceHealth    access:read-only
    ${json_file}=    Set Variable    db_health.json
    # Run the get-db-health.sh script to retrieve health status
    ${script_result}=    RW.CLI.Run Bash File
    ...    bash_file=get-db-health.sh
    ...    env=${env}
    ...    timeout_seconds=200
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    
    # Load the health data from the generated JSON file
    ${health_data}=    RW.CLI.Run Cli
    ...    cmd=cat db_health.json
    
    TRY
        ${health_list}=    Evaluate    json.loads(r'''${health_data.stdout}''')    json
    EXCEPT
        Log    Failed to load JSON payload, defaulting to empty list.    WARN
        ${health_list}=    Create List
    END
    
    # Filter for unhealthy databases
    ${unhealthy_dbs}=    Create List
    ${total_count}=    Evaluate    len(@{health_list})
    
    FOR    ${db}    IN    @{health_list}
        ${availability_state}=    Set Variable    ${db['properties']['availabilityState']}
        
        # Add to unhealthy list if not Available
        IF    '${availability_state}' != 'Available'
            Append To List    ${unhealthy_dbs}    ${db}
        END
    END

    ${formatted_results}=    RW.CLI.Run Cli
    ...    cmd=jq -r '["DatabaseName", "Type", "ResourceGroup", "Status", "Reason"] as $headers | [$headers] + [.[] | [.dbName, (.displayName | gsub(" "; "_")), "${AZURE_RESOURCE_GROUP}", .properties.availabilityState, (.properties.reasonType // "Unknown")]] | .[] | @tsv' ${json_file} | column -t
    RW.Core.Add Pre To Report    Database Summary:\n=====================================================\n${formatted_results.stdout}

    # Report on unhealthy databases and add issues
    IF    len(@{unhealthy_dbs}) > 0
        # Write unhealthy databases to a temporary JSON file for jq processing
        ${unhealthy_json}=    Evaluate    json.dumps(${unhealthy_dbs})    json
        
        # Use jq to format the table
        FOR    ${db}    IN    @{unhealthy_dbs}
            ${pretty_db}=    Evaluate    pprint.pformat(${db})    modules=pprint
            ${resource_group}=    Set Variable    ${AZURE_RESOURCE_GROUP}
            ${db_name}=    Set Variable    ${db['dbName']}
            ${display_name}=    Set Variable    ${db['displayName']}
            ${status}=    Set Variable    ${db['properties']['availabilityState']}
            RW.Core.Add Issue
            ...    severity=3
            ...    expected=${display_name} `${db_name}` should be available in resource group `${resource_group}`
            ...    actual=${display_name} `${db_name}` is in ${status} state in resource group `${resource_group}`
            ...    title=Unhealthy Database Detected: ${display_name} `${db_name}` in Resource Group `${resource_group}`
            ...    details=${pretty_db}
            ...    reproduce_hint=${script_result.cmd}
            ...    next_steps=Investigate the database health issue in Azure Portal: https://portal.azure.com/#@/resource${db['id']}/overview
        END
        
        # Clean up temporary file
        RW.CLI.Run Cli
        ...    cmd=rm unhealthy_dbs.json
    ELSE
        RW.Core.Add Pre To Report    No unhealthy databases found in resource group `${AZURE_RESOURCE_GROUP}`
    END
    
    # Summary
    ${unhealthy_count}=    Evaluate    len(@{unhealthy_dbs})
    ${healthy_count}=    Evaluate    ${total_count} - ${unhealthy_count}
    
    RW.Core.Add Pre To Report    Database Health Summary:\n=====================================================\nTotal Databases: ${total_count}\nHealthy Databases: ${healthy_count}\nUnhealthy Databases: ${unhealthy_count}

List Database Changes in resource group `${AZURE_RESOURCE_GROUP}`
    [Documentation]    Lists database changes in the specified resource group
    [Tags]    Database    Azure    Audit    access:read-only
    ${log_file}=    Set Variable    db_changes_grouped.json
    ${output}=    RW.CLI.Run Bash File
    ...    bash_file=get-db-changes.sh
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
        # Loop through each database in the grouped changes
        ${all_changes}=    Create List
        
        FOR    ${db_name}    IN    @{changes_list.keys()}
            ${db_changes}=    Set Variable    ${changes_list["${db_name}"]}
            ${db_type}=    Set Variable    ${db_changes[0]["dbType"]}
            ${display_name}=    Set Variable    ${db_changes[0]["displayName"]}

            
            # Format changes for this specific database
            ${db_changes_json}=    Evaluate    json.dumps(${db_changes})    json
            ${formatted_db_results}=    RW.CLI.Run Cli
            ...    cmd=printf '%s' '${db_changes_json}' | jq -r '["Operation", "Timestamp", "Caller", "Status", "ResourceUrl"] as $headers | [$headers] + [.[] | [.operationName, .timestamp, .caller, .changeStatus, .resourceUrl]] | .[] | @tsv' | column -t -s $'\t'
            RW.Core.Add Pre To Report    Changes for ${display_name} (${db_name}):\n-----------------------------------------------------\n${formatted_db_results.stdout}\n
            
            # Check for recent changes within AZURE_ACTIVITY_LOG_LOOKBACK_FOR_ISSUE timeframe
            ${current_time}=    DateTime.Get Current Date    result_format=datetime
            ${current_time_iso}=    Convert Date    ${current_time}    result_format=%Y-%m-%dT%H:%M:%SZ
            ${recent_changes}=    Create List
            
            FOR    ${change}    IN    @{db_changes}
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
                ...    expected=Changes to ${display_name} `${db_name}` should be reviewed in resource group `${AZURE_RESOURCE_GROUP}`
                ...    actual=Recent change detected: ${operation} by ${caller} at ${timestamp}
                ...    title=Recent Database Change: ${operation} on ${display_name} `${db_name}` in Resource Group `${AZURE_RESOURCE_GROUP}`
                ...    details=${pretty_change}
                ...    reproduce_hint=${output.cmd}
                ...    next_steps=Review the recent change in Azure Portal: ${resource_url}
            END
        END
    ELSE
        RW.Core.Add Pre To Report    No database changes found in resource group `${AZURE_RESOURCE_GROUP}`
    END
    RW.CLI.Run Cli
    ...    cmd=rm ${log_file}


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
    ${HIGH_CPU_PERCENTAGE}=    RW.Core.Import User Variable    HIGH_CPU_PERCENTAGE
    ...    type=string
    ...    description=The CPU percentage threshold to check for high CPU usage.
    ...    pattern=^\d+$
    ...    example=80
    ...    default=80
    ${HIGH_CPU_TIMEFRAME}=    RW.Core.Import User Variable    HIGH_CPU_TIMEFRAME
    ...    type=string
    ...    description=The timeframe to check for high CPU usage in hours.
    ...    pattern=^\d+$
    ...    example=24
    ...    default=24
    ${HIGH_MEMORY_PERCENTAGE}=    RW.Core.Import User Variable    HIGH_MEMORY_PERCENTAGE
    ...    type=string
    ...    description=The memory percentage threshold to check for high memory usage.
    ...    pattern=^\d+$
    ...    example=80
    ...    default=80
    ${HIGH_MEMORY_TIMEFRAME}=    RW.Core.Import User Variable    HIGH_MEMORY_TIMEFRAME
    ...    type=string
    ...    description=The timeframe to check for high memory usage in hours.
    ...    pattern=^\d+$
    ...    example=24
    ...    default=24
    ${HIGH_CACHE_MISS_RATE}=    RW.Core.Import User Variable    HIGH_CACHE_MISS_RATE
    ...    type=string
    ...    description=The cache miss rate threshold to check for high cache miss rate.
    ...    pattern=^\d+$
    ...    example=80
    ...    default=80
    ${HIGH_CACHE_MISS_TIMEFRAME}=    RW.Core.Import User Variable    HIGH_CACHE_MISS_TIMEFRAME
    ...    type=string
    ...    description=The timeframe to check for high cache miss rate in hours.
    ...    pattern=^\d+$
    ...    example=24
    ...    default=24
    ${LOW_AVAILABILITY_THRESHOLD}=    RW.Core.Import User Variable    LOW_AVAILABILITY_THRESHOLD
    ...    type=string
    ...    description=The availability percentage threshold to check for low availability.
    ...    pattern=^\d+$
    ...    example=100
    ...    default=100
    ${LOW_AVAILABILITY_TIMEFRAME}=    RW.Core.Import User Variable    LOW_AVAILABILITY_TIMEFRAME
    ...    type=string
    ...    description=The timeframe to check for low availability in hours.
    ...    pattern=^\d+$
    ...    example=24
    ...    default=24
    ${LOW_AVAILABILITY_INTERVAL}=    RW.Core.Import User Variable    LOW_AVAILABILITY_INTERVAL
    ...    type=string
    ...    description=The interval to check for low availability in this formats PT1H, PT1M, PT1S etc.
    ...    pattern=^\w+$
    ...    example=PT1H
    ...    default=PT1H
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
    Set Suite Variable    ${HIGH_CPU_PERCENTAGE}    ${HIGH_CPU_PERCENTAGE}
    Set Suite Variable    ${HIGH_CPU_TIMEFRAME}    ${HIGH_CPU_TIMEFRAME}
    Set Suite Variable    ${HIGH_MEMORY_PERCENTAGE}    ${HIGH_MEMORY_PERCENTAGE}
    Set Suite Variable    ${HIGH_MEMORY_TIMEFRAME}    ${HIGH_MEMORY_TIMEFRAME}
    Set Suite Variable    ${HIGH_CACHE_MISS_RATE}    ${HIGH_CACHE_MISS_RATE}
    Set Suite Variable    ${HIGH_CACHE_MISS_TIMEFRAME}    ${HIGH_CACHE_MISS_TIMEFRAME}
    Set Suite Variable    ${LOW_AVAILABILITY_THRESHOLD}    ${LOW_AVAILABILITY_THRESHOLD}
    Set Suite Variable    ${LOW_AVAILABILITY_TIMEFRAME}    ${LOW_AVAILABILITY_TIMEFRAME}
    Set Suite Variable    ${LOW_AVAILABILITY_INTERVAL}    ${LOW_AVAILABILITY_INTERVAL}
    Set Suite Variable    ${AZURE_ACTIVITY_LOG_LOOKBACK}    ${AZURE_ACTIVITY_LOG_LOOKBACK}
    Set Suite Variable    ${AZURE_ACTIVITY_LOG_LOOKBACK_FOR_ISSUE}    ${AZURE_ACTIVITY_LOG_LOOKBACK_FOR_ISSUE}
    Set Suite Variable
    ...    ${env}
    ...    {"AZURE_RESOURCE_GROUP":"${AZURE_RESOURCE_GROUP}", "AZURE_SUBSCRIPTION_ID":"${AZURE_SUBSCRIPTION_ID}", "AZURE_ACTIVITY_LOG_OFFSET":"${AZURE_ACTIVITY_LOG_LOOKBACK}", "AZURE_ACTIVITY_LOG_LOOKBACK_FOR_ISSUE":"${AZURE_ACTIVITY_LOG_LOOKBACK_FOR_ISSUE}"}
