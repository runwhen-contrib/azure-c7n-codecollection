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
Check Azure VM Health in resource group `${AZURE_RESOURCE_GROUP}`
    [Documentation]    Checks the health status of Azure VMs using the Microsoft.ResourceHealth provider
    [Tags]    VM    Azure    Health    ResourceHealth    access:read-only

    ${output}=    RW.CLI.Run Bash File
    ...    bash_file=vm_health_check.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ${report_data}=    RW.CLI.Run Cli
    ...    cmd=cat vm_health.json
    TRY
        ${health_list}=    Evaluate    json.loads(r'''${report_data.stdout}''')    json
    EXCEPT
        Log    Failed to load JSON payload, defaulting to empty list.    WARN
        ${health_list}=    Create List
    END
    IF    len(@{health_list}) > 0
        ${healthy_count}=    Evaluate    sum(1 for health in ${health_list} if health['properties']['availabilityState'] == 'Available')    json
        ${vm_health_score}=    Evaluate    1 if int(${healthy_count}) == len(${health_list}) else 0
    ELSE
        ${vm_health_score}=    Set Variable    0
    END
    Set Global Variable    ${vm_health_score}

Check for VMs With Public IP in resource group `${AZURE_RESOURCE_GROUP}`
    [Documentation]    Lists VMs with public IP address
    [Tags]    VM    Azure    Network    Security    access:read-only 
    CloudCustodian.Core.Generate Policy   
    ...    ${CURDIR}/vm-with-public-ip.j2
    ...    resourceGroup=${AZURE_RESOURCE_GROUP}
    ...    subscriptionId=${AZURE_SUBSCRIPTION_ID}
    ${c7n_output}=    RW.CLI.Run Cli
    ...    cmd=custodian run -s ${OUTPUT_DIR}/azure-c7n-vm-health ${CURDIR}/vm-with-public-ip.yaml --cache-period 0
    ${count}=    RW.CLI.Run Cli
    ...    cmd=cat ${OUTPUT_DIR}/azure-c7n-vm-health/vm-with-public-ip/metadata.json | jq '.metrics[] | select(.MetricName == "ResourceCount") | .Value';
    ${vm_with_public_ip_score}=    Evaluate    1 if int(${count.stdout}) <= int(${MAX_VM_WITH_PUBLIC_IP}) else 0
    Set Global Variable    ${vm_with_public_ip_score}

Check for Stopped VMs in resource group `${AZURE_RESOURCE_GROUP}`
    [Documentation]    Count VMs that are in a stopped state
    [Tags]    VM    Azure    State    Cost    access:read-only
    CloudCustodian.Core.Generate Policy   
    ...    ${CURDIR}/stopped-vm.j2
    ...    timeframe=${STOPPED_VM_TIMEFRAME}
    ...    resourceGroup=${AZURE_RESOURCE_GROUP}
    ...    subscriptionId=${AZURE_SUBSCRIPTION_ID}
    ${c7n_output}=    RW.CLI.Run Cli
    ...    cmd=custodian run -s ${OUTPUT_DIR}/azure-c7n-vm-health ${CURDIR}/stopped-vm.yaml --cache-period 0
    ${count}=    RW.CLI.Run Cli
    ...    cmd=cat ${OUTPUT_DIR}/azure-c7n-vm-health/stopped-vms/metadata.json | jq '.metrics[] | select(.MetricName == "ResourceCount") | .Value';
    ${stopped_vm_score}=    Evaluate    1 if int(${count.stdout}) <= int(${MAX_STOPPED_VM}) else 0
    Set Global Variable    ${stopped_vm_score}

Check for VMs With High CPU Usage in resource group `${AZURE_RESOURCE_GROUP}`
    [Documentation]    Checks for VMs with high CPU usage
    [Tags]    VM    Azure    CPU    Performance    access:read-only
    CloudCustodian.Core.Generate Policy   
    ...    ${CURDIR}/vm-cpu-usage.j2
    ...    cpu_percentage=${HIGH_CPU_PERCENTAGE}
    ...    timeframe=${HIGH_CPU_TIMEFRAME}
    ...    resourceGroup=${AZURE_RESOURCE_GROUP}
    ${c7n_output}=    RW.CLI.Run Cli
    ...    cmd=custodian run -s ${OUTPUT_DIR}/azure-c7n-vm-health ${CURDIR}/vm-cpu-usage.yaml --cache-period 0
    ${report_data}=    RW.CLI.Run Cli
    ...    cmd=cat ${OUTPUT_DIR}/azure-c7n-vm-health/vm-cpu-usage/resources.json

    TRY
        ${vm_list}=    Evaluate    json.loads(r'''${report_data.stdout}''')    json
    EXCEPT
        Log    Failed to load JSON payload, defaulting to empty list.    WARN
        ${vm_list}=    Create List
    END

    ${high_cpu_count}=    Set Variable    ${0}
    ${metrics_unavailable}=    Set Variable    ${False}
    FOR    ${vm}    IN    @{vm_list}
        ${json_str}=    Evaluate    json.dumps(${vm})    json
        ${metrics_available}=    RW.CLI.Run Cli
        ...    cmd=echo '${json_str}' | jq -r '(."c7n:metrics" | to_entries | map(.value.measurement[0]) | first) != null'
        ${metrics_available_clean}=    Strip String    ${metrics_available.stdout}
        IF    "${metrics_available_clean}" == "true"
            ${cpu_percentage_result}=    RW.CLI.Run Cli
            ...    cmd=echo '${json_str}' | jq -r '(."c7n:metrics" | to_entries | map(.value.measurement[0]) | first // "0")'
            ${cpu_percentage}=    Convert To Number    ${cpu_percentage_result.stdout}    2
            IF    ${cpu_percentage} > ${HIGH_CPU_PERCENTAGE}
                ${high_cpu_count}=    Evaluate    ${high_cpu_count} + 1
            END
        ELSE
            ${metrics_unavailable}=    Set Variable    ${True}
        END
    END
    ${cpu_usage_score}=    Evaluate    1 if ${metrics_unavailable} else (1 if ${high_cpu_count} <= int(${MAX_VM_WITH_HIGH_CPU}) else 0)
    Set Global Variable    ${cpu_usage_score}

Check for Underutilized VMs Based on CPU Usage in resource group `${AZURE_RESOURCE_GROUP}`
    [Documentation]    Count VMs that are underutilized based on CPU usage
    [Tags]    VM    Azure    CPU    Utilization    access:read-only
    CloudCustodian.Core.Generate Policy   
    ...    ${CURDIR}/under-utilized-vm-cpu-usage.j2
    ...    cpu_percentage=${LOW_CPU_PERCENTAGE}
    ...    timeframe=${LOW_CPU_TIMEFRAME}
    ...    resourceGroup=${AZURE_RESOURCE_GROUP}
    ...    subscriptionId=${AZURE_SUBSCRIPTION_ID}
    ${c7n_output}=    RW.CLI.Run Cli
    ...    cmd=custodian run -s ${OUTPUT_DIR}/azure-c7n-vm-health ${CURDIR}/under-utilized-vm-cpu-usage.yaml --cache-period 0
    ${report_data}=    RW.CLI.Run Cli
    ...    cmd=cat ${OUTPUT_DIR}/azure-c7n-vm-health/under-utilized-vm-cpu-usage/resources.json

    TRY
        ${vm_list}=    Evaluate    json.loads(r'''${report_data.stdout}''')    json
    EXCEPT
        Log    Failed to load JSON payload, defaulting to empty list.    WARN
        ${vm_list}=    Create List
    END

    ${underutilized_count}=    Set Variable    ${0}
    ${metrics_unavailable}=    Set Variable    ${False}
    FOR    ${vm}    IN    @{vm_list}
        ${json_str}=    Evaluate    json.dumps(${vm})    json
        ${metrics_available}=    RW.CLI.Run Cli
        ...    cmd=echo '${json_str}' | jq -r '(."c7n:metrics" | to_entries | map(.value.measurement[0]) | first) != null'
        ${metrics_available_clean}=    Strip String    ${metrics_available.stdout}
        IF    "${metrics_available_clean}" == "true"
            ${cpu_percentage_result}=    RW.CLI.Run Cli
            ...    cmd=echo '${json_str}' | jq -r '(."c7n:metrics" | to_entries | map(.value.measurement[0]) | first // "0")'
            ${cpu_percentage}=    Convert To Number    ${cpu_percentage_result.stdout}    2
            IF    ${cpu_percentage} < ${LOW_CPU_PERCENTAGE}
                ${underutilized_count}=    Evaluate    ${underutilized_count} + 1
            END
        ELSE
            ${metrics_unavailable}=    Set Variable    ${True}
        END
    END
    ${underutilized_vm_score}=    Evaluate    1 if ${metrics_unavailable} else (1 if ${underutilized_count} <= int(${MAX_UNDERUTILIZED_VM}) else 0)
    Set Global Variable    ${underutilized_vm_score}

Check for VMs With High Memory Usage in resource group `${AZURE_RESOURCE_GROUP}`
    [Documentation]    Count VMs that have high memory usage based on available memory percentage
    [Tags]    VM    Azure    Memory    Performance    access:read-only
    CloudCustodian.Core.Generate Policy   
    ...    ${CURDIR}/vm-memory-usage.j2
    ...    memory_threshold=${HIGH_MEMORY_THRESHOLD}
    ...    timeframe=${HIGH_MEMORY_TIMEFRAME}
    ...    resourceGroup=${AZURE_RESOURCE_GROUP}
    ...    subscriptionId=${AZURE_SUBSCRIPTION_ID}
    ${c7n_output}=    RW.CLI.Run Cli
    ...    cmd=custodian run -s ${OUTPUT_DIR}/azure-c7n-vm-health ${CURDIR}/vm-memory-usage.yaml --cache-period 0
    ${report_data}=    RW.CLI.Run Cli
    ...    cmd=cat ${OUTPUT_DIR}/azure-c7n-vm-health/vm-memory-usage/resources.json

    TRY
        ${vm_list}=    Evaluate    json.loads(r'''${report_data.stdout}''')    json
    EXCEPT
        Log    Failed to load JSON payload, defaulting to empty list.    WARN
        ${vm_list}=    Create List
    END

    ${high_memory_count}=    Set Variable    ${0}
    ${metrics_unavailable}=    Set Variable    ${False}
    FOR    ${vm}    IN    @{vm_list}
        ${json_str}=    Evaluate    json.dumps(${vm})    json
        ${metrics_available}=    RW.CLI.Run Cli
        ...    cmd=echo '${json_str}' | jq -r '(."c7n:metrics" | to_entries | map(.value.measurement[0]) | first) != null'
        ${metrics_available_clean}=    Strip String    ${metrics_available.stdout}
        IF    "${metrics_available_clean}" == "true"
            ${memory_percentage_result}=    RW.CLI.Run Cli
            ...    cmd=echo '${json_str}' | jq -r '(."c7n:metrics" | to_entries | map(.value.measurement[0]) | first // "0")'
            ${available_memory}=    Convert To Number    ${memory_percentage_result.stdout}    2
            ${memory_percentage}=    Evaluate    round(100 - ${available_memory}, 2)
            IF    ${memory_percentage} > ${HIGH_MEMORY_PERCENTAGE}
                ${high_memory_count}=    Evaluate    ${high_memory_count} + 1
            END
        ELSE
            ${metrics_unavailable}=    Set Variable    ${True}
        END
    END
    ${high_memory_score}=    Evaluate    1 if ${metrics_unavailable} else (1 if ${high_memory_count} <= int(${MAX_VM_WITH_HIGH_MEMORY}) else 0)
    Set Global Variable    ${high_memory_score}

Check for Underutilized VMs Based on Memory Usage in resource group `${AZURE_RESOURCE_GROUP}`
    [Documentation]    Count VMs that are underutilized based on memory usage
    [Tags]    VM    Azure    Memory    Utilization    access:read-only
    CloudCustodian.Core.Generate Policy   
    ...    ${CURDIR}/vm-memory-usage.j2
    ...    memory_percentage=${LOW_MEMORY_PERCENTAGE}
    ...    timeframe=${LOW_MEMORY_TIMEFRAME}
    ...    resourceGroup=${AZURE_RESOURCE_GROUP}
    ...    subscriptionId=${AZURE_SUBSCRIPTION_ID}
    ${c7n_output}=    RW.CLI.Run Cli
    ...    cmd=custodian run -s ${OUTPUT_DIR}/azure-c7n-vm-health ${CURDIR}/vm-memory-usage.yaml --cache-period 0
    ${report_data}=    RW.CLI.Run Cli
    ...    cmd=cat ${OUTPUT_DIR}/azure-c7n-vm-health/vm-memory-usage/resources.json

    TRY
        ${vm_list}=    Evaluate    json.loads(r'''${report_data.stdout}''')    json
    EXCEPT
        Log    Failed to load JSON payload, defaulting to empty list.    WARN
        ${vm_list}=    Create List
    END

    ${underutilized_memory_count}=    Set Variable    ${0}
    ${metrics_unavailable}=    Set Variable    ${False}
    FOR    ${vm}    IN    @{vm_list}
        ${json_str}=    Evaluate    json.dumps(${vm})    json
        ${metrics_available}=    RW.CLI.Run Cli
        ...    cmd=echo '${json_str}' | jq -r '(."c7n:metrics" | to_entries | map(.value.measurement[0]) | first) != null'
        ${metrics_available_clean}=    Strip String    ${metrics_available.stdout}
        IF    "${metrics_available_clean}" == "true"
            ${memory_percentage_result}=    RW.CLI.Run Cli
            ...    cmd=echo '${json_str}' | jq -r '(."c7n:metrics" | to_entries | map(.value.measurement[0]) | first // "0")'
            ${available_memory}=    Convert To Number    ${memory_percentage_result.stdout}    2
            ${memory_percentage}=    Evaluate    round(100 - ${available_memory}, 2)
            IF    ${memory_percentage} < ${LOW_MEMORY_PERCENTAGE}
                ${underutilized_memory_count}=    Evaluate    ${underutilized_memory_count} + 1
            END
        ELSE
            ${metrics_unavailable}=    Set Variable    ${True}
        END
    END
    ${underutilized_memory_score}=    Evaluate    1 if ${metrics_unavailable} else (1 if ${underutilized_memory_count} <= int(${MAX_UNDERUTILIZED_VM_MEMORY}) else 0)
    Set Global Variable    ${underutilized_memory_score}

Check for Unused Network Interfaces in resource group `${AZURE_RESOURCE_GROUP}`
    [Documentation]    Count network interfaces that are not attached to any virtual machine
    [Tags]    Network    Azure    NIC    Cost    access:read-only
    CloudCustodian.Core.Generate Policy   
    ...    ${CURDIR}/unused-nic.j2
    ...    resourceGroup=${AZURE_RESOURCE_GROUP}
    ...    subscriptionId=${AZURE_SUBSCRIPTION_ID}
    ${c7n_output}=    RW.CLI.Run Cli
    ...    cmd=custodian run -s ${OUTPUT_DIR}/azure-c7n-vm-health ${CURDIR}/unused-nic.yaml --cache-period 0
    ${count}=    RW.CLI.Run Cli
    ...    cmd=cat ${OUTPUT_DIR}/azure-c7n-vm-health/unused-nic/metadata.json | jq '.metrics[] | select(.MetricName == "ResourceCount") | .Value';
    ${unused_nic_score}=    Evaluate    1 if int(${count.stdout}) <= int(${MAX_UNUSED_NIC}) else 0
    Set Global Variable    ${unused_nic_score}


Check for Unused Public IPs in resource group `${AZURE_RESOURCE_GROUP}`
    [Documentation]    Count public IP addresses that are not attached to any resource
    [Tags]    Network    Azure    PublicIP    Cost    access:read-only
    CloudCustodian.Core.Generate Policy   
    ...    ${CURDIR}/unused-public-ip.j2
    ...    resourceGroup=${AZURE_RESOURCE_GROUP}
    ...    subscriptionId=${AZURE_SUBSCRIPTION_ID}
    ${c7n_output}=    RW.CLI.Run Cli
    ...    cmd=custodian run -s ${OUTPUT_DIR}/azure-c7n-vm-health ${CURDIR}/unused-public-ip.yaml --cache-period 0
    ${count}=    RW.CLI.Run Cli
    ...    cmd=cat ${OUTPUT_DIR}/azure-c7n-vm-health/unused-publicip/metadata.json | jq '.metrics[] | select(.MetricName == "ResourceCount") | .Value';
    ${unused_public_ip_score}=    Evaluate    1 if int(${count.stdout}) <= int(${MAX_UNUSED_PUBLIC_IP}) else 0
    Set Global Variable    ${unused_public_ip_score}

Check VMs Agent Status in resource group `${AZURE_RESOURCE_GROUP}`
    [Documentation]    Lists VMs that have VM agent status issues
    [Tags]    VM    Azure    Agent    Health    access:read-only
    CloudCustodian.Core.Generate Policy
    ...    vm-agent-status.j2
    ...    resourceGroup=${AZURE_RESOURCE_GROUP}
    ...    subscriptionId=${AZURE_SUBSCRIPTION_ID}
    ${c7n_output}=    RW.CLI.Run Cli
    ...    cmd=custodian run -s azure-c7n-vm-health vm-agent-status.yaml --cache-period 0
    ${count}=    RW.CLI.Run Cli
    ...    cmd=cat azure-c7n-vm-health/vm-agent-status/metadata.json | jq '.metrics[] | select(.MetricName == "ResourceCount") | .Value';
    ${vm_agent_status_score}=    Evaluate    1 if int(${count.stdout}) <= int(${MAX_VM_AGENT_STATUS}) else 0
    Set Global Variable    ${vm_agent_status_score}


Generate Health Score
    ${health_score}=    Evaluate  (${vm_with_public_ip_score} + ${cpu_usage_score} + ${stopped_vm_score} + ${underutilized_vm_score} + ${high_memory_score} + ${underutilized_memory_score} + ${unused_nic_score} + ${unused_public_ip_score} + ${vm_health_score} + ${vm_agent_status_score}) / 10
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
    ...    description=The available memory percentage threshold to check for high memory usage (e.g., 20 means 20% memory available).
    ...    pattern=^\d+$
    ...    example=20
    ...    default=20
    ${HIGH_MEMORY_TIMEFRAME}=    RW.Core.Import User Variable    HIGH_MEMORY_TIMEFRAME
    ...    type=string
    ...    description=The timeframe to check for high memory usage in hours.
    ...    pattern=^\d+$
    ...    example=24
    ...    default=24
    ${HIGH_MEMORY_THRESHOLD}=    RW.Core.Import User Variable    HIGH_MEMORY_THRESHOLD
    ...    type=string
    ...    description=The memory threshold in bytes to check for high memory usage.
    ...    pattern=^\d+$
    ...    example=1073741824
    ...    default=1073741824
    ${MAX_VM_WITH_PUBLIC_IP}=    RW.Core.Import User Variable    MAX_VM_WITH_PUBLIC_IP
    ...    type=string
    ...    description=The maximum number of VMs with public IP addresses to allow.
    ...    pattern=^\d+$
    ...    example=1
    ...    default=0
    ${MAX_VM_WITH_HIGH_CPU}=    RW.Core.Import User Variable    MAX_VM_WITH_HIGH_CPU
    ...    type=string
    ...    description=The maximum number of VMs with high CPU usage to allow.
    ...    pattern=^\d+$
    ...    example=1
    ...    default=0
    ${MAX_STOPPED_VM}=    RW.Core.Import User Variable    MAX_STOPPED_VM
    ...    type=string
    ...    description=The maximum number of stopped VMs to allow.
    ...    pattern=^\d+$
    ...    example=1
    ...    default=0
    ${STOPPED_VM_TIMEFRAME}=    RW.Core.Import User Variable    STOPPED_VM_TIMEFRAME
    ...    type=string
    ...    description=The timeframe since the VM was stopped.
    ...    pattern=^\d+$
    ...    example=24
    ...    default=24
    ${LOW_CPU_PERCENTAGE}=    RW.Core.Import User Variable    LOW_CPU_PERCENTAGE
    ...    type=string
    ...    description=The CPU percentage threshold to identify underutilized VMs.
    ...    pattern=^\d+$
    ...    example=10
    ...    default=10
    ${LOW_CPU_TIMEFRAME}=    RW.Core.Import User Variable    LOW_CPU_TIMEFRAME
    ...    type=string
    ...    description=The timeframe (in hours) to evaluate low CPU usage.
    ...    pattern=^\d+$
    ...    example=24
    ...    default=24
    ${MAX_UNDERUTILIZED_VM}=    RW.Core.Import User Variable    MAX_UNDERUTILIZED_VM
    ...    type=string
    ...    description=The maximum number of underutilized VMs to allow.
    ...    pattern=^\d+$
    ...    example=1
    ...    default=0
    ${MAX_VM_WITH_HIGH_MEMORY}=    RW.Core.Import User Variable    MAX_VM_WITH_HIGH_MEMORY
    ...    type=string
    ...    description=The maximum number of VMs with high memory usage to allow.
    ...    pattern=^\d+$
    ...    example=1
    ...    default=0
    ${LOW_MEMORY_PERCENTAGE}=    RW.Core.Import User Variable    LOW_MEMORY_PERCENTAGE
    ...    type=string
    ...    description=The available memory percentage threshold to check for low memory usage (e.g., 80 means 80% memory available).
    ...    pattern=^\d+$
    ...    example=90
    ...    default=90
    ${LOW_MEMORY_TIMEFRAME}=    RW.Core.Import User Variable    LOW_MEMORY_TIMEFRAME
    ...    type=string
    ...    description=The timeframe to check for low memory usage in hours.
    ...    pattern=^\d+$
    ...    example=24
    ...    default=24
    ${MAX_UNDERUTILIZED_VM_MEMORY}=    RW.Core.Import User Variable    MAX_UNDERUTILIZED_VM_MEMORY
    ...    type=string
    ...    description=The maximum number of VMs with underutilized memory to allow.
    ...    pattern=^\d+$
    ...    example=1
    ...    default=0
    ${MAX_UNUSED_NIC}=    RW.Core.Import User Variable    MAX_UNUSED_NIC
    ...    type=string
    ...    description=The maximum number of unused network interfaces to allow.
    ...    pattern=^\d+$
    ...    example=1
    ...    default=0
    ${MAX_UNUSED_PUBLIC_IP}=    RW.Core.Import User Variable    MAX_UNUSED_PUBLIC_IP
    ...    type=string
    ...    description=The maximum number of unused public IPs to allow.
    ...    pattern=^\d+$
    ...    example=1
    ...    default=0
    ${MAX_VM_AGENT_STATUS}=    RW.Core.Import User Variable    MAX_VM_AGENT_STATUS
    ...    type=string
    ...    description=The maximum number of VMs with agent status issues to allow.
    ...    pattern=^\d+$
    ...    example=1
    ...    default=0
    Set Suite Variable    ${AZURE_SUBSCRIPTION_ID}    ${AZURE_SUBSCRIPTION_ID}
    Set Suite Variable    ${AZURE_RESOURCE_GROUP}    ${AZURE_RESOURCE_GROUP}
    Set Suite Variable    ${HIGH_CPU_PERCENTAGE}    ${HIGH_CPU_PERCENTAGE}
    Set Suite Variable    ${HIGH_CPU_TIMEFRAME}    ${HIGH_CPU_TIMEFRAME}
    Set Suite Variable    ${LOW_CPU_PERCENTAGE}    ${LOW_CPU_PERCENTAGE}
    Set Suite Variable    ${LOW_CPU_TIMEFRAME}    ${LOW_CPU_TIMEFRAME}
    Set Suite Variable    ${MAX_VM_WITH_PUBLIC_IP}    ${MAX_VM_WITH_PUBLIC_IP}
    Set Suite Variable    ${MAX_VM_WITH_HIGH_CPU}    ${MAX_VM_WITH_HIGH_CPU}
    Set Suite Variable    ${MAX_STOPPED_VM}    ${MAX_STOPPED_VM}
    Set Suite Variable    ${MAX_UNDERUTILIZED_VM}    ${MAX_UNDERUTILIZED_VM}
    Set Suite Variable    ${STOPPED_VM_TIMEFRAME}    ${STOPPED_VM_TIMEFRAME}
    Set Suite Variable    ${HIGH_MEMORY_PERCENTAGE}    ${HIGH_MEMORY_PERCENTAGE}
    Set Suite Variable    ${HIGH_MEMORY_TIMEFRAME}    ${HIGH_MEMORY_TIMEFRAME}
    Set Suite Variable    ${HIGH_MEMORY_THRESHOLD}    ${HIGH_MEMORY_THRESHOLD}
    Set Suite Variable    ${LOW_MEMORY_PERCENTAGE}    ${LOW_MEMORY_PERCENTAGE}
    Set Suite Variable    ${LOW_MEMORY_TIMEFRAME}    ${LOW_MEMORY_TIMEFRAME}
    Set Suite Variable    ${MAX_UNDERUTILIZED_VM_MEMORY}    ${MAX_UNDERUTILIZED_VM_MEMORY}
    Set Suite Variable    ${MAX_UNUSED_NIC}    ${MAX_UNUSED_NIC}
    Set Suite Variable    ${MAX_UNUSED_PUBLIC_IP}    ${MAX_UNUSED_PUBLIC_IP}
    Set Suite Variable    ${MAX_VM_AGENT_STATUS}    ${MAX_VM_AGENT_STATUS}
    Set Suite Variable
    ...    ${env}
    ...    {"AZURE_RESOURCE_GROUP":"${AZURE_RESOURCE_GROUP}", "AZURE_SUBSCRIPTION_ID":"${AZURE_SUBSCRIPTION_ID}"}