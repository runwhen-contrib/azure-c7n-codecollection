*** Settings ***
Documentation       Count Virtual machines that are publicly accessible, have high CPU usage, underutilized memory, stopped state, unused network interfaces, and unused public IPs in Azure
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
Check for Publicly Accessible MySQL Flexible Servers in resource group `${AZURE_RESOURCE_GROUP}` in Subscription `${AZURE_SUBSCRIPTION_NAME}`
    [Documentation]    Count MySQL Flexible Servers that have public network access enabled
    [Tags]    Database    Azure    MySQL    Security    access:read-only
    ${policy_name}    Set Variable    mysqlfx-public-access
    CloudCustodian.Core.Generate Policy   
    ...    ${CURDIR}/${policy_name}.j2
    ...    resourceGroup=${AZURE_RESOURCE_GROUP}
    ${c7n_output}=    RW.CLI.Run Cli
    ...    cmd=custodian run -s ${OUTPUT_DIR}/azure-c7n-db-health ${CURDIR}/${policy_name}.yaml --cache-period 0
    ${count}=    RW.CLI.Run Cli
    ...    cmd=cat ${OUTPUT_DIR}/azure-c7n-db-health/${policy_name}/metadata.json | jq '.metrics[] | select(.MetricName == "ResourceCount") | .Value';
    ${public_mysql_score}=    Evaluate    1 if int(${count.stdout}) <= int(${MAX_PUBLIC_MYSQL}) else 0
    Set Global Variable    ${public_mysql_score}
    RW.CLI.Run Cli    cmd=rm ${CURDIR}/${policy_name}.yaml    # Remove generated policy

Check for MySQL Flexible Servers Without Replication in resource group `${AZURE_RESOURCE_GROUP}` in Subscription `${AZURE_SUBSCRIPTION_NAME}`
    [Documentation]    Count MySQL Flexible Servers that have no replication configured
    [Tags]    Database    Azure    MySQL    Replication    access:read-only
    ${policy_name}    Set Variable    mysqlfx-no-replication
    CloudCustodian.Core.Generate Policy   
    ...    ${CURDIR}/${policy_name}.j2
    ...    resourceGroup=${AZURE_RESOURCE_GROUP}
    ${c7n_output}=    RW.CLI.Run Cli
    ...    cmd=custodian run -s ${OUTPUT_DIR}/azure-c7n-db-health ${CURDIR}/${policy_name}.yaml --cache-period 0
    ${count}=    RW.CLI.Run Cli
    ...    cmd=cat ${OUTPUT_DIR}/azure-c7n-db-health/${policy_name}/metadata.json | jq '.metrics[] | select(.MetricName == "ResourceCount") | .Value';
    ${no_replication_mysql_score}=    Evaluate    1 if int(${count.stdout}) <= int(${MAX_NO_REPLICATION_MYSQL}) else 0
    Set Global Variable    ${no_replication_mysql_score}
    RW.CLI.Run Cli    cmd=rm ${CURDIR}/${policy_name}.yaml    # Remove generated policy

Check for MySQL Flexible Servers Without High Availability in resource group `${AZURE_RESOURCE_GROUP}` in Subscription `${AZURE_SUBSCRIPTION_NAME}`
    [Documentation]    Count MySQL Flexible Servers that have high availability disabled
    [Tags]    Database    Azure    MySQL    HighAvailability    access:read-only
    ${policy_name}    Set Variable    mysqlfx-ha-check
    CloudCustodian.Core.Generate Policy   
    ...    ${CURDIR}/${policy_name}.j2
    ...    resourceGroup=${AZURE_RESOURCE_GROUP}
    ${c7n_output}=    RW.CLI.Run Cli
    ...    cmd=custodian run -s ${OUTPUT_DIR}/azure-c7n-db-health ${CURDIR}/${policy_name}.yaml --cache-period 0
    ${count}=    RW.CLI.Run Cli
    ...    cmd=cat ${OUTPUT_DIR}/azure-c7n-db-health/${policy_name}/metadata.json | jq '.metrics[] | select(.MetricName == "ResourceCount") | .Value';
    ${no_ha_mysql_score}=    Evaluate    1 if int(${count.stdout}) <= int(${MAX_NO_HA_MYSQL}) else 0
    Set Global Variable    ${no_ha_mysql_score}
    RW.CLI.Run Cli    cmd=rm ${CURDIR}/${policy_name}.yaml    # Remove generated policy

Check for MySQL Flexible Servers With High CPU Usage in resource group `${AZURE_RESOURCE_GROUP}` in Subscription `${AZURE_SUBSCRIPTION_NAME}`
    [Documentation]    Count MySQL Flexible Servers that have high CPU usage
    [Tags]    Database    Azure    MySQL    CPU    access:read-only
    ${policy_name}    Set Variable    mysqlfx-high-cpu
    CloudCustodian.Core.Generate Policy   
    ...    ${CURDIR}/${policy_name}.j2
    ...    resourceGroup=${AZURE_RESOURCE_GROUP}
    ...    threshold=${HIGH_CPU_PERCENTAGE_MYSQL}
    ...    timeframe=${HIGH_CPU_TIMEFRAME_MYSQL}
    ${c7n_output}=    RW.CLI.Run Cli
    ...    cmd=custodian run -s ${OUTPUT_DIR}/azure-c7n-db-health ${CURDIR}/${policy_name}.yaml --cache-period 0
    ${count}=    RW.CLI.Run Cli
    ...    cmd=cat ${OUTPUT_DIR}/azure-c7n-db-health/${policy_name}/metadata.json | jq '.metrics[] | select(.MetricName == "ResourceCount") | .Value';
    ${high_cpu_mysql_score}=    Evaluate    1 if int(${count.stdout}) <= int(${MAX_HIGH_CPU_MYSQL}) else 0
    Set Global Variable    ${high_cpu_mysql_score}
    RW.CLI.Run Cli    cmd=rm ${CURDIR}/${policy_name}.yaml    # Remove generated policy

Check for MySQL Flexible Servers With High Memory Usage in resource group `${AZURE_RESOURCE_GROUP}` in Subscription `${AZURE_SUBSCRIPTION_NAME}`
    [Documentation]    Count MySQL Flexible Servers that have high memory usage
    [Tags]    Database    Azure    MySQL    Memory    access:read-only
    ${policy_name}    Set Variable    mysqlfx-high-memory
    CloudCustodian.Core.Generate Policy   
    ...    ${CURDIR}/${policy_name}.j2
    ...    resourceGroup=${AZURE_RESOURCE_GROUP}
    ...    threshold=${HIGH_MEMORY_PERCENTAGE_MYSQL}
    ...    timeframe=${HIGH_MEMORY_TIMEFRAME_MYSQL}
    ${c7n_output}=    RW.CLI.Run Cli
    ...    cmd=custodian run -s ${OUTPUT_DIR}/azure-c7n-db-health ${CURDIR}/${policy_name}.yaml --cache-period 0
    ${count}=    RW.CLI.Run Cli
    ...    cmd=cat ${OUTPUT_DIR}/azure-c7n-db-health/${policy_name}/metadata.json | jq '.metrics[] | select(.MetricName == "ResourceCount") | .Value';
    ${high_memory_mysql_score}=    Evaluate    1 if int(${count.stdout}) <= int(${MAX_HIGH_MEMORY_MYSQL}) else 0
    Set Global Variable    ${high_memory_mysql_score}
    RW.CLI.Run Cli    cmd=rm ${CURDIR}/${policy_name}.yaml    # Remove generated policy


Generate Health Score
    ${health_score}=    Evaluate  (${public_mysql_score} + ${no_replication_mysql_score} + ${no_ha_mysql_score} + ${high_cpu_mysql_score} + ${high_memory_mysql_score}) / 5
    ${health_score}=    Convert to Number    ${health_score}  2
    RW.Core.Push Metric    ${health_score}


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
    ${MAX_PUBLIC_MYSQL}=    RW.Core.Import User Variable    MAX_PUBLIC_MYSQL
    ...    type=string
    ...    description=The maximum number of MySQL servers with public access to allow.
    ...    pattern=^\d+$
    ...    example=0
    ...    default=0
    ${MAX_NO_REPLICATION_MYSQL}=    RW.Core.Import User Variable    MAX_NO_REPLICATION_MYSQL
    ...    type=string
    ...    description=The maximum number of MySQL servers without replication to allow.
    ...    pattern=^\d+$
    ...    example=0
    ...    default=0
    ${MAX_NO_HA_MYSQL}=    RW.Core.Import User Variable    MAX_NO_HA_MYSQL
    ...    type=string
    ...    description=The maximum number of MySQL servers without high availability to allow.
    ...    pattern=^\d+$
    ...    example=0
    ...    default=0
    ${MAX_HIGH_CPU_MYSQL}=    RW.Core.Import User Variable    MAX_HIGH_CPU_MYSQL
    ...    type=string
    ...    description=The maximum number of MySQL servers with high CPU usage to allow.
    ...    pattern=^\d+$
    ...    example=0
    ...    default=0
    ${MAX_HIGH_MEMORY_MYSQL}=    RW.Core.Import User Variable    MAX_HIGH_MEMORY_MYSQL
    ...    type=string
    ...    description=The maximum number of MySQL servers with high memory usage to allow.
    ...    pattern=^\d+$
    ...    example=0
    ...    default=0
    ${HIGH_CPU_PERCENTAGE_MYSQL}=    RW.Core.Import User Variable    HIGH_CPU_PERCENTAGE_MYSQL
    ...    type=string
    ...    description=The CPU percentage threshold to check for high CPU usage.
    ...    pattern=^\d+$
    ...    example=80
    ${HIGH_CPU_TIMEFRAME_MYSQL}=    RW.Core.Import User Variable    HIGH_CPU_TIMEFRAME_MYSQL
    ...    type=string
    ...    description=The timeframe in hours to check for high CPU usage.
    ...    pattern=^\d+$
    ...    example=24
    ${HIGH_MEMORY_PERCENTAGE_MYSQL}=    RW.Core.Import User Variable    HIGH_MEMORY_PERCENTAGE_MYSQL
    ...    type=string
    ...    description=The memory percentage threshold to check for high memory usage.
    ...    pattern=^\d+$
    ...    example=80
    ${HIGH_MEMORY_TIMEFRAME_MYSQL}=    RW.Core.Import User Variable    HIGH_MEMORY_TIMEFRAME_MYSQL
    ...    type=string
    ...    description=The timeframe in hours to check for high memory usage.
    ...    pattern=^\d+$
    ...    example=24
    Set Suite Variable    ${AZURE_SUBSCRIPTION_NAME}    ${AZURE_SUBSCRIPTION_NAME}
    Set Suite Variable    ${AZURE_SUBSCRIPTION_ID}    ${AZURE_SUBSCRIPTION_ID}
    Set Suite Variable    ${AZURE_RESOURCE_GROUP}    ${AZURE_RESOURCE_GROUP}
    Set Suite Variable    ${MAX_PUBLIC_MYSQL}    ${MAX_PUBLIC_MYSQL}
    Set Suite Variable    ${MAX_NO_HA_MYSQL}    ${MAX_NO_HA_MYSQL}
    Set Suite Variable    ${MAX_NO_REPLICATION_MYSQL}    ${MAX_NO_REPLICATION_MYSQL}
    Set Suite Variable    ${MAX_HIGH_CPU_MYSQL}    ${MAX_HIGH_CPU_MYSQL}
    Set Suite Variable    ${MAX_HIGH_MEMORY_MYSQL}    ${MAX_HIGH_MEMORY_MYSQL}
    Set Suite Variable    ${HIGH_CPU_PERCENTAGE_MYSQL}    ${HIGH_CPU_PERCENTAGE_MYSQL}
    Set Suite Variable    ${HIGH_CPU_TIMEFRAME_MYSQL}    ${HIGH_CPU_TIMEFRAME_MYSQL}
    Set Suite Variable    ${HIGH_MEMORY_PERCENTAGE_MYSQL}    ${HIGH_MEMORY_PERCENTAGE_MYSQL}
    Set Suite Variable    ${HIGH_MEMORY_TIMEFRAME_MYSQL}    ${HIGH_MEMORY_TIMEFRAME_MYSQL}