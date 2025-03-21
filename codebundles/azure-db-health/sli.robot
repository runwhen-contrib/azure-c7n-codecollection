*** Settings ***
Documentation       Count databases that are publicly accessible, without replication, without high availability configuration, with high CPU usage, high memory usage, and high cache miss rate in Azure
Metadata            Author    saurabh3460
Metadata            Display Name    Azure Database Health
Metadata            Supports    Azure    Database    Health    CloudCustodian
Force Tags          Azure    Database    Health    CloudCustodian    cosmosdb    sql    redis    postgresql

Library    String
Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library    CloudCustodian.Core

Suite Setup         Suite Initialization
*** Tasks ***
Check for Publicly Accessible Databases in resource group `${AZURE_RESOURCE_GROUP}` in Subscription `${AZURE_SUBSCRIPTION_NAME}`
    [Documentation]    Count databases that have public network access enabled
    [Tags]    Database    Azure    Security    access:read-only
    
    ${db_map}=    Evaluate    json.load(open('${CURDIR}/db-map.json'))    json
    ${total_count}=    Set Variable    0
    
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
        
        ${count}=    RW.CLI.Run Cli
        ...    cmd=cat ${OUTPUT_DIR}/azure-c7n-db-health/${policy_name}/metadata.json | jq '.metrics[] | select(.MetricName == "ResourceCount") | .Value';
        
        ${total_count}=    Evaluate    ${total_count} + int(${count.stdout})
        
        RW.CLI.Run Cli    cmd=rm ${CURDIR}/public-access.yaml    # Remove generated policy
    END
    
    ${public_db_score}=    Evaluate    1 if int(${total_count}) <= int(${MAX_PUBLIC_DB}) else 0
    Set Global Variable    ${public_db_score}

Check for Databases Without Replication in resource group `${AZURE_RESOURCE_GROUP}` in Subscription `${AZURE_SUBSCRIPTION_NAME}`
    [Documentation]    Count databases that have no replication configured
    [Tags]    Database    Azure    Replication    access:read-only
    
    ${db_map}=    Evaluate    json.load(open('${CURDIR}/db-map.json'))    json
    ${total_count}=    Set Variable    0
    
    FOR    ${db_type}    IN    @{db_map.keys()}
        ${db_info}=    Set Variable    ${db_map['${db_type}']}
        Continue For Loop If    'replication' not in ${db_info}
        
        ${policy_name}=    Set Variable    ${db_type}-replication-check
        ${display_name}=    Set Variable    ${db_info['display_name']}
        ${replication_config}=    Set Variable    ${db_info['replication']}
        
        CloudCustodian.Core.Generate Policy   
        ...    ${CURDIR}/replication-check.j2
        ...    name=${db_type}
        ...    resource=${db_info['resource']}
        ...    key=${replication_config['key']}
        ...    value=${replication_config['value']}
        ...    resourceGroup=${AZURE_RESOURCE_GROUP}
        RW.CLI.Run Cli    cmd=cat ${CURDIR}/replication-check.yaml
        ${c7n_output}=    RW.CLI.Run Cli
        ...    cmd=custodian run -s ${OUTPUT_DIR}/azure-c7n-db-health ${CURDIR}/replication-check.yaml --cache-period 0
        
        ${count}=    RW.CLI.Run Cli
        ...    cmd=cat ${OUTPUT_DIR}/azure-c7n-db-health/${policy_name}/metadata.json | jq '.metrics[] | select(.MetricName == "ResourceCount") | .Value';
        
        ${total_count}=    Evaluate    ${total_count} + int(${count.stdout})
        
        RW.CLI.Run Cli    cmd=rm ${CURDIR}/replication-check.yaml    # Remove generated policy
    END
    
    ${no_replication_score}=    Evaluate    1 if int(${total_count}) <= int(${MAX_DB_WITHOUT_REPLICATION}) else 0
    Set Global Variable    ${no_replication_score}

Check for Databases Without High Availability in resource group `${AZURE_RESOURCE_GROUP}` in Subscription `${AZURE_SUBSCRIPTION_NAME}`
    [Documentation]    Count databases that have high availability disabled
    [Tags]    Database    Azure    HighAvailability    access:read-only
    
    ${db_map}=    Evaluate    json.load(open('${CURDIR}/db-map.json'))    json
    ${total_count}=    Set Variable    0
    
    FOR    ${db_type}    IN    @{db_map.keys()}
        ${db_info}=    Set Variable    ${db_map['${db_type}']}
        Continue For Loop If    'ha' not in ${db_info}
        
        ${policy_name}=    Set Variable    ${db_type}-ha-check
        ${display_name}=    Set Variable    ${db_info['display_name']}
        ${ha_config}=    Set Variable    ${db_info['ha']}
        
        CloudCustodian.Core.Generate Policy   
        ...    ${CURDIR}/ha-check.j2
        ...    name=${db_type}
        ...    resource=${db_info['resource']}
        ...    key=${ha_config['key']}
        ...    value=${ha_config['value']}
        ...    resourceGroup=${AZURE_RESOURCE_GROUP}
        
        ${c7n_output}=    RW.CLI.Run Cli
        ...    cmd=custodian run -s ${OUTPUT_DIR}/azure-c7n-db-health ${CURDIR}/ha-check.yaml --cache-period 0
        
        ${count}=    RW.CLI.Run Cli
        ...    cmd=cat ${OUTPUT_DIR}/azure-c7n-db-health/${policy_name}/metadata.json | jq '.metrics[] | select(.MetricName == "ResourceCount") | .Value';
        
        ${total_count}=    Evaluate    ${total_count} + int(${count.stdout})
        
        RW.CLI.Run Cli    cmd=rm ${CURDIR}/ha-check.yaml    # Remove generated policy
    END
    
    ${no_ha_score}=    Evaluate    1 if int(${total_count}) <= int(${MAX_DB_WITHOUT_HA}) else 0
    Set Global Variable    ${no_ha_score}

Check for Databases With High CPU Usage in resource group `${AZURE_RESOURCE_GROUP}` in Subscription `${AZURE_SUBSCRIPTION_NAME}`
    [Documentation]    Count databases that have high CPU usage
    [Tags]    Database    Azure    CPU    access:read-only
    
    ${db_map}=    Evaluate    json.load(open('${CURDIR}/db-map.json'))    json
    ${total_count}=    Set Variable    0
    
    FOR    ${db_type}    IN    @{db_map.keys()}
        ${db_info}=    Set Variable    ${db_map['${db_type}']}
        Continue For Loop If    "cpu_metric" not in ${db_info}
        
        ${policy_name}=    Set Variable    ${db_type}-high-cpu
        ${display_name}=    Set Variable    ${db_info['display_name']}
        ${cpu_metric}=    Set Variable    ${db_info['cpu_metric']}
        
        CloudCustodian.Core.Generate Policy   
        ...    ${CURDIR}/high-cpu.j2
        ...    name=${db_type}
        ...    resource=${db_info['resource']}
        ...    resourceGroup=${AZURE_RESOURCE_GROUP}
        ...    threshold=${HIGH_CPU_PERCENTAGE}
        ...    timeframe=${HIGH_CPU_TIMEFRAME}
        ...    metric=${cpu_metric}
        
        ${c7n_output}=    RW.CLI.Run Cli
        ...    cmd=custodian run -s ${OUTPUT_DIR}/azure-c7n-db-health ${CURDIR}/high-cpu.yaml --cache-period 0
        
        ${count}=    RW.CLI.Run Cli
        ...    cmd=cat ${OUTPUT_DIR}/azure-c7n-db-health/${policy_name}/metadata.json | jq '.metrics[] | select(.MetricName == "ResourceCount") | .Value';
        
        ${total_count}=    Evaluate    ${total_count} + int(${count.stdout})
        
        RW.CLI.Run Cli    cmd=rm ${CURDIR}/high-cpu.yaml    # Remove generated policy
    END
    
    ${high_cpu_score}=    Evaluate    1 if int(${total_count}) <= int(${MAX_HIGH_CPU_DB}) else 0
    Set Global Variable    ${high_cpu_score}

Check for Databases With High Memory Usage in resource group `${AZURE_RESOURCE_GROUP}` in Subscription `${AZURE_SUBSCRIPTION_NAME}`
    [Documentation]    Count databases that have high memory usage
    [Tags]    Database    Azure    Memory    access:read-only
    
    ${db_map}=    Evaluate    json.load(open('${CURDIR}/db-map.json'))    json
    ${total_count}=    Set Variable    0
    
    FOR    ${db_type}    IN    @{db_map.keys()}
        ${db_info}=    Set Variable    ${db_map['${db_type}']}
        Continue For Loop If    "memory_metric" not in ${db_info}
        
        ${policy_name}=    Set Variable    ${db_type}-high-memory
        ${display_name}=    Set Variable    ${db_info['display_name']}
        ${memory_metric}=    Set Variable    ${db_info['memory_metric']}
        
        CloudCustodian.Core.Generate Policy   
        ...    ${CURDIR}/high-memory.j2
        ...    name=${db_type}
        ...    resource=${db_info['resource']}
        ...    resourceGroup=${AZURE_RESOURCE_GROUP}
        ...    threshold=${HIGH_MEMORY_PERCENTAGE}
        ...    timeframe=${HIGH_MEMORY_TIMEFRAME}
        ...    metric=${memory_metric}
        
        ${c7n_output}=    RW.CLI.Run Cli
        ...    cmd=custodian run -s ${OUTPUT_DIR}/azure-c7n-db-health ${CURDIR}/high-memory.yaml --cache-period 0
        
        ${count}=    RW.CLI.Run Cli
        ...    cmd=cat ${OUTPUT_DIR}/azure-c7n-db-health/${policy_name}/metadata.json | jq '.metrics[] | select(.MetricName == "ResourceCount") | .Value';
        
        ${total_count}=    Evaluate    ${total_count} + int(${count.stdout})
        
        RW.CLI.Run Cli    cmd=rm ${CURDIR}/high-memory.yaml    # Remove generated policy
    END
    
    ${high_memory_score}=    Evaluate    1 if int(${total_count}) <= int(${MAX_HIGH_MEMORY_DB}) else 0
    Set Global Variable    ${high_memory_score}


List Redis Caches With High Cache Miss Rate in resource group `${AZURE_RESOURCE_GROUP}` in Subscription `${AZURE_SUBSCRIPTION_NAME}`
    [Documentation]    Count Redis caches that have high cache miss rate
    [Tags]    Database    Azure    Redis    Cache    access:read-only
    ${policy_name}    Set Variable    redis-cache-miss
    CloudCustodian.Core.Generate Policy   
    ...    ${CURDIR}/${policy_name}.j2
    ...    resourceGroup=${AZURE_RESOURCE_GROUP}
    ...    threshold=${HIGH_CACHE_MISS_RATE}
    ...    timeframe=${HIGH_CACHE_MISS_TIMEFRAME}
    ${c7n_output}=    RW.CLI.Run Cli
    ...    cmd=custodian run -s ${OUTPUT_DIR}/azure-c7n-db-health ${CURDIR}/${policy_name}.yaml --cache-period 0
    ${count}=    RW.CLI.Run Cli
    ...    cmd=cat ${OUTPUT_DIR}/azure-c7n-db-health/${policy_name}/metadata.json | jq '.metrics[] | select(.MetricName == "ResourceCount") | .Value';
    ${high_cache_miss_score}=    Evaluate    1 if int(${count.stdout}) <= int(${MAX_HIGH_CACHE_MISS}) else 0
    Set Global Variable    ${high_cache_miss_score}
    RW.CLI.Run Cli    cmd=rm ${CURDIR}/${policy_name}.yaml    # Remove generated policy


Generate Health Score
    ${health_score}=    Evaluate  (${public_db_score} + ${no_replication_score} + ${no_ha_score} + ${high_cpu_score} + ${high_memory_score} + ${high_cache_miss_score}) / 6
    ${health_score}=    Convert to Number    ${health_score}  2
    RW.Core.Push Metric    ${health_score}


*** Keywords ***
Suite Initialization
    ${azure_credentials}=    RW.Core.Import Secret
    ...    azure_credentials
    ...    type=string
    ...    description=The secret containing AZURE_CLIENT_ID, AZURE_TENANT_ID, AZURE_CLIENT_SECERT, AZURE_SUBSCRIPTION_ID
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
    ${MAX_PUBLIC_DB}=    RW.Core.Import User Variable    MAX_PUBLIC_DB
    ...    type=string
    ...    description=The maximum number of database with public access to allow.
    ...    pattern=^\d+$
    ...    example=0
    ...    default=0
    ${MAX_DB_WITHOUT_REPLICATION}=    RW.Core.Import User Variable    MAX_DB_WITHOUT_REPLICATION
    ...    type=string
    ...    description=The maximum number of database without replication to allow.
    ...    pattern=^\d+$
    ...    example=0
    ...    default=0
    ${MAX_DB_WITHOUT_HA}=    RW.Core.Import User Variable    MAX_DB_WITHOUT_HA
    ...    type=string
    ...    description=The maximum number of database without high availability to allow.
    ...    pattern=^\d+$
    ...    example=0
    ...    default=0
    ${MAX_HIGH_CPU_DB}=    RW.Core.Import User Variable    MAX_HIGH_CPU_DB
    ...    type=string
    ...    description=The maximum number of database with high CPU usage to allow.
    ...    pattern=^\d+$
    ...    example=0
    ...    default=0
    ${MAX_HIGH_MEMORY_DB}=    RW.Core.Import User Variable    MAX_HIGH_MEMORY_DB
    ...    type=string
    ...    description=The maximum number of database with high memory usage to allow.
    ...    pattern=^\d+$
    ...    example=0
    ...    default=0
    ${HIGH_CACHE_MISS_RATE}=    RW.Core.Import User Variable    HIGH_CACHE_MISS_RATE
    ...    type=string
    ...    description=The cache miss rate threshold to check for high cache miss rate.
    ...    pattern=^\d+$
    ...    example=80
    ...    default=80
    ${HIGH_CACHE_MISS_TIMEFRAME}=    RW.Core.Import User Variable    HIGH_CACHE_MISS_TIMEFRAME
    ...    type=string
    ...    description=The timeframe in hours to check for high cache miss rate.
    ...    pattern=^\d+$
    ...    example=24
    ...    default=24
    ${MAX_HIGH_CACHE_MISS}=    RW.Core.Import User Variable    MAX_HIGH_CACHE_MISS
    ...    type=string
    ...    description=The maximum number of Redis caches with high cache miss rate to allow.
    ...    pattern=^\d+$
    ...    example=0
    ...    default=0
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
    Set Suite Variable    ${AZURE_SUBSCRIPTION_NAME}    ${AZURE_SUBSCRIPTION_NAME}
    Set Suite Variable    ${AZURE_SUBSCRIPTION_ID}    ${AZURE_SUBSCRIPTION_ID}
    Set Suite Variable    ${AZURE_RESOURCE_GROUP}    ${AZURE_RESOURCE_GROUP}
    Set Suite Variable    ${MAX_PUBLIC_DB}    ${MAX_PUBLIC_DB}
    Set Suite Variable    ${MAX_DB_WITHOUT_HA}    ${MAX_DB_WITHOUT_HA}
    Set Suite Variable    ${MAX_DB_WITHOUT_REPLICATION}    ${MAX_DB_WITHOUT_REPLICATION}
    Set Suite Variable    ${MAX_HIGH_CPU_DB}    ${MAX_HIGH_CPU_DB}
    Set Suite Variable    ${MAX_HIGH_MEMORY_DB}    ${MAX_HIGH_MEMORY_DB}
    Set Suite Variable    ${HIGH_CACHE_MISS_RATE}    ${HIGH_CACHE_MISS_RATE}
    Set Suite Variable    ${HIGH_CACHE_MISS_TIMEFRAME}    ${HIGH_CACHE_MISS_TIMEFRAME}
    Set Suite Variable    ${MAX_HIGH_CACHE_MISS}    ${MAX_HIGH_CACHE_MISS}
    Set Suite Variable    ${HIGH_CPU_PERCENTAGE}    ${HIGH_CPU_PERCENTAGE}
    Set Suite Variable    ${HIGH_CPU_TIMEFRAME}    ${HIGH_CPU_TIMEFRAME}
    Set Suite Variable    ${HIGH_MEMORY_PERCENTAGE}    ${HIGH_MEMORY_PERCENTAGE}
    Set Suite Variable    ${HIGH_MEMORY_TIMEFRAME}    ${HIGH_MEMORY_TIMEFRAME}