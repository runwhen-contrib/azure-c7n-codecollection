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
List VMs Health in resource group `${AZURE_RESOURCE_GROUP}`
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

        FOR    ${health}    IN    @{health_list}
            ${pretty_health}=    Evaluate    pprint.pformat(${health})    modules=pprint
            ${vm_name}=    Set Variable    ${health['resourceName']}
            ${health_status}=    Set Variable    ${health['properties']['availabilityState']}
            IF    "${health_status}" != "Available"
                RW.Core.Add Issue
                ...    severity=3
                ...    expected=Azure VM `${vm_name}` should have health status of `Available` in resource group `${AZURE_RESOURCE_GROUP}`
                ...    actual=Azure VM `${vm_name}` has health status of `${health_status}` in resource group `${AZURE_RESOURCE_GROUP}`
                ...    title=Azure VM `${vm_name}` with Health Status of `${health_status}` found in Resource Group `${AZURE_RESOURCE_GROUP}`
                ...    reproduce_hint=${output.cmd}
                ...    details=${pretty_health}
                ...    next_steps=Investigate the health status of the Azure VM in resource group `${AZURE_RESOURCE_GROUP}`
            END
        END
    ELSE
        RW.Core.Add Issue
        ...    severity=4
        ...    expected=Azure VM health should be enabled in resource group `${AZURE_RESOURCE_GROUP}`
        ...    actual=Azure VM health appears unavailable in resource group `${AZURE_RESOURCE_GROUP}`
        ...    title=Azure resource health is unavailable for Azure VMs in resource group `${AZURE_RESOURCE_GROUP}`
        ...    reproduce_hint=${output.cmd}
        ...    details=${health_list}
        ...    next_steps=Please escalate to the Azure service owner to enable provider Microsoft.ResourceHealth.
    END

List VMs With Public IP in resource group `${AZURE_RESOURCE_GROUP}`
    [Documentation]    Lists VMs with public IP address
    [Tags]    VM    Azure    Network    Security    access:read-only
    CloudCustodian.Core.Generate Policy
    ...    ${CURDIR}/vm-with-public-ip.j2
    ...    resourceGroup=${AZURE_RESOURCE_GROUP}
    ...    subscriptionId=${AZURE_SUBSCRIPTION_ID}
    ${c7n_output}=    RW.CLI.Run Cli
    ...    cmd=custodian run -s ${OUTPUT_DIR}/azure-c7n-vm-health ${CURDIR}/vm-with-public-ip.yaml --cache-period 0
    ${report_data}=    RW.CLI.Run Cli
    ...    cmd=cat ${OUTPUT_DIR}/azure-c7n-vm-health/vm-with-public-ip/resources.json

    TRY
        ${vm_list}=    Evaluate    json.loads(r'''${report_data.stdout}''')    json
    EXCEPT
        Log    Failed to load JSON payload, defaulting to empty list.    WARN
        ${vm_list}=    Create List
    END

    IF    len(@{vm_list}) > 0
        ${formatted_results}=    RW.CLI.Run Cli
        ...    cmd=jq -r '["VM_Name", "Resource_Group", "Location", "VM_Link"], (.[] | [ .name, (.resourceGroup | ascii_downcase), .location, ("https://portal.azure.com/#@/resource" + .id + "/overview") ]) | @tsv' ${OUTPUT_DIR}/azure-c7n-vm-health/vm-with-public-ip/resources.json | column -t
        RW.Core.Add Pre To Report    Virtual Machines Summary:\n===================================\n${formatted_results.stdout}

        FOR    ${vm}    IN    @{vm_list}
            ${pretty_vm}=    Evaluate    pprint.pformat(${vm})    modules=pprint
            ${resource_group}=    Set Variable    ${vm['resourceGroup'].lower()}
            ${vm_name}=    Set Variable    ${vm['name']}
            RW.Core.Add Issue
            ...    severity=4
            ...    expected=Azure VM `${vm_name}` should not be publicly accessible in resource group `${resource_group}`
            ...    actual=Azure VM `${vm_name}` is publicly accessible in resource group `${resource_group}`
            ...    title=Azure VM `${vm_name}` with Public IP Detected in Resource Group `${resource_group}`
            ...    reproduce_hint=${c7n_output.cmd}
            ...    details=${pretty_vm}
            ...    next_steps=Disable the public IP address from azure VM in resource group `${AZURE_RESOURCE_GROUP}`
        END
    ELSE
        RW.Core.Add Pre To Report    "No VMs with public IPs found in resource group `${AZURE_RESOURCE_GROUP}`"
    END

List Stopped VMs in resource group `${AZURE_RESOURCE_GROUP}`
    [Documentation]    Lists VMs that are in a stopped state
    [Tags]    VM    Azure    State    Cost    access:read-only
    CloudCustodian.Core.Generate Policy
    ...    ${CURDIR}/stopped-vm.j2
    ...    timeframe=${STOPPED_VM_TIMEFRAME}
    ...    resourceGroup=${AZURE_RESOURCE_GROUP}
    ...    subscriptionId=${AZURE_SUBSCRIPTION_ID}
    ${c7n_output}=    RW.CLI.Run Cli
    ...    cmd=custodian run -s ${OUTPUT_DIR}/azure-c7n-vm-health ${CURDIR}/stopped-vm.yaml --cache-period 0
    ${report_data}=    RW.CLI.Run Cli
    ...    cmd=cat ${OUTPUT_DIR}/azure-c7n-vm-health/stopped-vms/resources.json

    TRY
        ${vm_list}=    Evaluate    json.loads(r'''${report_data.stdout}''')    json
    EXCEPT
        Log    Failed to load JSON payload, defaulting to empty list.    WARN
        ${vm_list}=    Create List
    END

    IF    len(@{vm_list}) > 0
        ${formatted_results}=    RW.CLI.Run Cli
        ...    cmd=jq -r '["VM_Name", "Resource_Group", "Location", "VM_Link"], (.[] | [ .name, (.resourceGroup | ascii_downcase), .location, ("https://portal.azure.com/#@/resource" + .id + "/overview") ]) | @tsv' ${OUTPUT_DIR}/azure-c7n-vm-health/stopped-vms/resources.json | column -t
        RW.Core.Add Pre To Report    Stopped VMs Summary:\n========================\n${formatted_results.stdout}

        FOR    ${vm}    IN    @{vm_list}
            ${pretty_vm}=    Evaluate    pprint.pformat(${vm})    modules=pprint
            ${resource_group}=    Set Variable    ${vm['resourceGroup'].lower()}
            ${vm_name}=    Set Variable    ${vm['name']}
            RW.Core.Add Issue
            ...    severity=4
            ...    expected=Azure VM `${vm_name}` should be in use in resource group `${resource_group}`
            ...    actual=Azure VM `${vm_name}` is in stopped state more than `${STOPPED_VM_TIMEFRAME}` hours in resource group `${resource_group}`
            ...    title=Stopped Azure VM `${vm_name}` found in Resource Group `${resource_group}`
            ...    reproduce_hint=${c7n_output.cmd}
            ...    details=${pretty_vm}
            ...    next_steps=Delete the stopped azure vm if no longer needed to reduce costs in resource group `${AZURE_RESOURCE_GROUP}`
        END
    ELSE
        RW.Core.Add Pre To Report    "No stopped VMs found in resource group `${AZURE_RESOURCE_GROUP}`"
    END

List VMs With High CPU Usage in resource group `${AZURE_RESOURCE_GROUP}`
    [Documentation]    Checks for VMs with high CPU usage
    [Tags]    VM    Azure    CPU    Performance    access:read-only
    CloudCustodian.Core.Generate Policy
    ...    ${CURDIR}/vm-cpu-usage.j2
    ...    cpu_percentage=${HIGH_CPU_PERCENTAGE}
    ...    timeframe=${HIGH_CPU_TIMEFRAME}
    ...    resourceGroup=${AZURE_RESOURCE_GROUP}
    ...    subscriptionId=${AZURE_SUBSCRIPTION_ID}
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

    IF    len(@{vm_list}) > 0
        FOR    ${vm}    IN    @{vm_list}
            ${pretty_vm}=    Evaluate    pprint.pformat(${vm})    modules=pprint
            ${resource_group}=    Set Variable    ${vm['resourceGroup'].lower()}
            ${vm_name}=    Set Variable    ${vm['name']}
            ${json_str}=    Evaluate    json.dumps(${vm})    json
            
            # Check if metrics are available
            ${metrics_available}=    RW.CLI.Run Cli
            ...    cmd=echo '${json_str}' | jq -r '(."c7n:metrics" | to_entries | map(.value.measurement[0]) | first) != null'
            
            ${metrics_available_clean}=    Strip String    ${metrics_available.stdout}
            IF    "${metrics_available_clean}" == "true"
                ${formatted_results}=    RW.CLI.Run Cli
                ...    cmd=jq -r '["VM_Name", "Resource_Group", "Location", "CPU_Usage%", "VM_Status", "VM_Link"], (.[] | [ .name, (.resourceGroup | ascii_downcase), .location, (."c7n:metrics" | to_entries | map(.value.measurement[0]) | first // "N/A" | tonumber | (. * 100 | round / 100) | tostring), (.instanceView.statuses[0].code // "Unknown"), ("https://portal.azure.com/#@/resource" + .id + "/overview") ]) | @tsv' ${OUTPUT_DIR}/azure-c7n-vm-health/vm-cpu-usage/resources.json | column -t
                RW.Core.Add Pre To Report    High CPU Usage VMs Summary:\n===================================\n${formatted_results.stdout}

                ${cpu_percentage_result}=    RW.CLI.Run Cli
                ...    cmd=echo '${json_str}' | jq -r '(."c7n:metrics" | to_entries | map(.value.measurement[0]) | first // "0")'
                # Convert to a number for further processing
                ${cpu_percentage}=    Convert To Number    ${cpu_percentage_result.stdout}    2
                RW.Core.Add Issue
                ...    severity=3
                ...    expected=Azure VM `${vm_name}` should have CPU usage below `${cpu_percentage}%` in resource group `${resource_group}`
                ...    actual=Azure VM `${vm_name}` has high CPU usage of `${cpu_percentage}%` in the last `${HIGH_CPU_TIMEFRAME}` hours in resource group `${resource_group}`
                ...    title=High CPU Usage on Azure VM `${vm_name}` found in Resource Group `${resource_group}`
                ...    reproduce_hint=${c7n_output.cmd}
                ...    details=${pretty_vm}
                ...    next_steps=Investigate high CPU usage and consider resizing the VM in resource group `${AZURE_RESOURCE_GROUP}`
            ELSE
                # Check VM agent status when metrics are not available
                ${vm_agent_status}=    RW.CLI.Run Cli
                ...    cmd=echo '${json_str}' | jq -r '(.instanceView.vmAgent.statuses[0].code // "Unknown")'
                ${vm_status}=    RW.CLI.Run Cli
                ...    cmd=echo '${json_str}' | jq -r '(.instanceView.statuses[0].code // "Unknown")'
                
                RW.Core.Add Issue
                ...    severity=4
                ...    expected=Azure VM `${vm_name}` should have available CPU metrics in resource group `${resource_group}`
                ...    actual=CPU metrics are not available for VM `${vm_name}`. VM Agent Status: ${vm_agent_status.stdout}, VM Status: ${vm_status.stdout}
                ...    title=CPU Metrics Unavailable for Azure VM `${vm_name}` in Resource Group `${resource_group}`
                ...    reproduce_hint=${c7n_output.cmd}
                ...    details=${pretty_vm}
                ...    next_steps=Check VM diagnostics settings in resource group `${AZURE_RESOURCE_GROUP}`
            END
        END
    ELSE
        RW.Core.Add Pre To Report    "No VMs with high CPU usage found in resource group `${AZURE_RESOURCE_GROUP}`"
    END

List Underutilized VMs Based on CPU Usage in resource group `${AZURE_RESOURCE_GROUP}`
    [Documentation]    List Azure Virtual Machines (VMs) that have low CPU utilization based on a defined threshold and timeframe.
    [Tags]    VM    Azure    CPU    Performance    access:read-only
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

    IF    len(@{vm_list}) > 0
        ${formatted_results}=    RW.CLI.Run Cli
        ...    cmd=jq -r '["VM_Name", "Resource_Group", "Location", "CPU_Usage%", "VM_Status", "VM_Link"], (.[] | [ .name, (.resourceGroup | ascii_downcase), .location, (."c7n:metrics" | to_entries | map(.value.measurement[0]) | first // "N/A" | tonumber | (. * 100 | round / 100) | tostring), (.instanceView.statuses[0].code // "Unknown"), ("https://portal.azure.com/#@/resource" + .id + "/overview") ]) | @tsv' ${OUTPUT_DIR}/azure-c7n-vm-health/under-utilized-vm-cpu-usage/resources.json | column -t
        RW.Core.Add Pre To Report    Underutilized VMs Based on CPU Summary:\n========================\n${formatted_results.stdout}

        FOR    ${vm}    IN    @{vm_list}
            ${pretty_vm}=    Evaluate    pprint.pformat(${vm})    modules=pprint
            ${resource_group}=    Set Variable    ${vm['resourceGroup'].lower()}
            ${vm_name}=    Set Variable    ${vm['name']}
            ${json_str}=    Evaluate    json.dumps(${vm})    json
            
            # Check if metrics are available
            ${metrics_available}=    RW.CLI.Run Cli
            ...    cmd=echo '${json_str}' | jq -r '(."c7n:metrics" | to_entries | map(.value.measurement[0]) | first) != null'
            
            ${metrics_available_clean}=    Strip String    ${metrics_available.stdout}
            IF    "${metrics_available_clean}" == "true"
                ${cpu_percentage_result}=    RW.CLI.Run Cli
                ...    cmd=echo '${json_str}' | jq -r '(."c7n:metrics" | to_entries | map(.value.measurement[0]) | first // "0")'
                # Convert to a number for further processing
                ${cpu_percentage}=    Convert To Number    ${cpu_percentage_result.stdout}    2
                RW.Core.Add Issue
                ...    severity=4
                ...    expected=Azure VM `${vm_name}` should have adequate CPU utilization in resource group `${resource_group}`
                ...    actual=Azure VM `${vm_name}` has low CPU usage of `${cpu_percentage}%` in the last `${LOW_CPU_TIMEFRAME}` hours in resource group `${resource_group}`
                ...    title=Underutilized CPU on Azure VM `${vm_name}` found in Resource Group `${resource_group}`
                ...    reproduce_hint=${c7n_output.cmd}
                ...    details=${pretty_vm}
                ...    next_steps=Consider downsizing the VM to optimize costs in resource group `${AZURE_RESOURCE_GROUP}`
            ELSE
                # Check VM agent status when metrics are not available
                ${vm_agent_status}=    RW.CLI.Run Cli
                ...    cmd=echo '${json_str}' | jq -r '(.instanceView.vmAgent.statuses[0].code // "Unknown")'
                ${vm_status}=    RW.CLI.Run Cli
                ...    cmd=echo '${json_str}' | jq -r '(.instanceView.statuses[0].code // "Unknown")'
                
                RW.Core.Add Issue
                ...    severity=4
                ...    expected=Azure VM `${vm_name}` should have available CPU metrics in resource group `${resource_group}`
                ...    actual=CPU metrics are not available for VM `${vm_name}`. VM Agent Status: ${vm_agent_status.stdout}, VM Status: ${vm_status.stdout}
                ...    title=CPU Metrics Unavailable for Azure VM `${vm_name}` in Resource Group `${resource_group}`
                ...    reproduce_hint=${c7n_output.cmd}
                ...    details=${pretty_vm}
                ...    next_steps=Check VM diagnostics settings in resource group `${AZURE_RESOURCE_GROUP}`
            END
        END
    ELSE
        RW.Core.Add Pre To Report    "No underutilized VMs found in resource group `${AZURE_RESOURCE_GROUP}`"
    END

List VMs With High Memory Usage in resource group `${AZURE_RESOURCE_GROUP}`
    [Documentation]    List Azure Virtual Machines (VMs) that have high memory usage based on a defined threshold and timeframe.
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

    IF    len(@{vm_list}) > 0
        FOR    ${vm}    IN    @{vm_list}
            ${pretty_vm}=    Evaluate    pprint.pformat(${vm})    modules=pprint
            ${resource_group}=    Set Variable    ${vm['resourceGroup'].lower()}
            ${vm_name}=    Set Variable    ${vm['name']}
            ${json_str}=    Evaluate    json.dumps(${vm})    json
            
            # Check if metrics are available
            ${metrics_available}=    RW.CLI.Run Cli
            ...    cmd=echo '${json_str}' | jq -r '(."c7n:metrics" | to_entries | map(.value.measurement[0]) | first) != null'
            ${metrics_available_clean}=    Strip String    ${metrics_available.stdout}
            IF    "${metrics_available.stdout}" == "true"
                ${formatted_results}=    RW.CLI.Run Cli
                ...    cmd=jq -r '["VM_Name", "Resource_Group", "Location", "Available_Memory%", "VM_Status", "VM_Link"], (.[] | [ .name, (.resourceGroup | ascii_downcase), .location, (."c7n:metrics" | to_entries | map(.value.measurement[0]) | first // "N/A" | tonumber | (. * 100 | round / 100) | tostring), (.instanceView.statuses[0].code // "Unknown"), ("https://portal.azure.com/#@/resource" + .id + "/overview") ]) | @tsv' ${OUTPUT_DIR}/azure-c7n-vm-health/vm-memory-usage/resources.json | column -t
                RW.Core.Add Pre To Report    VMs With High Memory Usage Summary:\n========================\n${formatted_results.stdout}

                ${memory_percentage_result}=    RW.CLI.Run Cli
                ...    cmd=echo '${json_str}' | jq -r '(."c7n:metrics" | to_entries | map(.value.measurement[0]) | first // "0")'
                # Convert to a number and calculate memory usage percentage (100 - available memory)
                ${available_memory}=    Convert To Number    ${memory_percentage_result.stdout}    2
                ${memory_percentage}=    Evaluate    round(100 - ${available_memory}, 2)
                RW.Core.Add Issue
                ...    severity=3
                ...    expected=Azure VM `${vm_name}` should have adequate available memory in resource group `${resource_group}`
                ...    actual=Azure VM `${vm_name}` has high memory usage of `${memory_percentage}%` in the last `${HIGH_MEMORY_TIMEFRAME}` hours in resource group `${resource_group}`
                ...    title=High Memory Usage on Azure VM `${vm_name}` found in Resource Group `${resource_group}`
                ...    reproduce_hint=${c7n_output.cmd}
                ...    details=${pretty_vm}
                ...    next_steps=Consider resizing to a larger VM SKU in resource group `${AZURE_RESOURCE_GROUP}`
            ELSE
                # Check VM agent status when metrics are not available
                ${vm_agent_status}=    RW.CLI.Run Cli
                ...    cmd=echo '${json_str}' | jq -r '(.instanceView.vmAgent.statuses[0].code // "Unknown")'
                ${vm_status}=    RW.CLI.Run Cli
                ...    cmd=echo '${json_str}' | jq -r '(.instanceView.statuses[0].code // "Unknown")'
                
                RW.Core.Add Issue
                ...    severity=4
                ...    expected=Azure VM `${vm_name}` should have available memory metrics in resource group `${resource_group}`
                ...    actual=Memory metrics are not available for VM `${vm_name}`. VM Agent Status: ${vm_agent_status.stdout}, VM Status: ${vm_status.stdout}
                ...    title=Memory Metrics Unavailable for Azure VM `${vm_name}` in Resource Group `${resource_group}`
                ...    reproduce_hint=${c7n_output.cmd}
                ...    details=${pretty_vm}
                ...    next_steps=Check VM diagnostics settings in resource group `${AZURE_RESOURCE_GROUP}`
            END
        END
    ELSE
        RW.Core.Add Pre To Report    "No VMs with high memory usage found in resource group `${AZURE_RESOURCE_GROUP}`"
    END

List Underutilized VMs Based on Memory Usage in resource group `${AZURE_RESOURCE_GROUP}`
    [Documentation]    List Azure Virtual Machines (VMs) that are underutilized based on memory usage
    [Tags]    VM    Azure    Memory    Utilization    access:read-only
    CloudCustodian.Core.Generate Policy
    ...    ${CURDIR}/vm-memory-usage.j2
    ...    op=gt
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

    IF    len(@{vm_list}) > 0
        FOR    ${vm}    IN    @{vm_list}
            ${pretty_vm}=    Evaluate    pprint.pformat(${vm})    modules=pprint
            ${resource_group}=    Set Variable    ${vm['resourceGroup'].lower()}
            ${vm_name}=    Set Variable    ${vm['name']}
            ${json_str}=    Evaluate    json.dumps(${vm})    json
            
            # Check if metrics are available
            ${metrics_available}=    RW.CLI.Run Cli
            ...    cmd=echo '${json_str}' | jq -r '(."c7n:metrics" | to_entries | map(.value.measurement[0]) | first) != null'
            
            ${metrics_available_clean}=    Strip String    ${metrics_available.stdout}
            IF    "${metrics_available_clean}" == "true"
                ${formatted_results}=    RW.CLI.Run Cli
                ...    cmd=jq -r '["VM_Name", "Resource_Group", "Location", "Available_Memory%", "VM_Status", "VM_Link"], (.[] | [ .name, (.resourceGroup | ascii_downcase), .location, (."c7n:metrics" | to_entries | map(.value.measurement[0]) | first // "N/A" | tonumber | (. * 100 | round / 100) | tostring), (.instanceView.statuses[0].code // "Unknown"), ("https://portal.azure.com/#@/resource" + .id + "/overview") ]) | @tsv' ${OUTPUT_DIR}/azure-c7n-vm-health/vm-memory-usage/resources.json | column -t
                RW.Core.Add Pre To Report    Underutilized VMs Based on Memory Usage Summary:\n========================\n${formatted_results.stdout}

                ${memory_percentage_result}=    RW.CLI.Run Cli
                ...    cmd=echo '${json_str}' | jq -r '(."c7n:metrics" | to_entries | map(.value.measurement[0]) | first // "0")'
                # Convert to a number and calculate memory usage percentage (100 - available memory)
                ${available_memory}=    Convert To Number    ${memory_percentage_result.stdout}    2
                ${memory_percentage}=    Evaluate    round(100 - ${available_memory}, 2)
                RW.Core.Add Issue
                ...    severity=4
                ...    expected=Azure VM `${vm_name}` should have optimal memory utilization in resource group `${resource_group}`
                ...    actual=Azure VM `${vm_name}` has high available memory of `${memory_percentage}%` in the last `${LOW_MEMORY_TIMEFRAME}` hours in resource group `${resource_group}`
                ...    title=Underutilized Memory on Azure VM `${vm_name}` found in Resource Group `${resource_group}`
                ...    reproduce_hint=${c7n_output.cmd}
                ...    details=${pretty_vm}
                ...    next_steps=Consider downsizing the VM to optimize costs in resource group `${AZURE_RESOURCE_GROUP}`
            ELSE
                # Check VM agent status when metrics are not available
                ${vm_agent_status}=    RW.CLI.Run Cli
                ...    cmd=echo '${json_str}' | jq -r '(.instanceView.vmAgent.statuses[0].code // "Unknown")'
                ${vm_status}=    RW.CLI.Run Cli
                ...    cmd=echo '${json_str}' | jq -r '(.instanceView.statuses[0].code // "Unknown")'
                
                RW.Core.Add Issue
                ...    severity=2
                ...    expected=Azure VM `${vm_name}` should have available memory metrics in resource group `${resource_group}`
                ...    actual=Memory metrics are not available for VM `${vm_name}`. VM Agent Status: ${vm_agent_status.stdout}, VM Status: ${vm_status.stdout}
                ...    title=Memory Metrics Unavailable for Azure VM `${vm_name}` in Resource Group `${resource_group}`
                ...    reproduce_hint=${c7n_output.cmd}
                ...    details=${pretty_vm}
                ...    next_steps=Check VM diagnostics settings in resource group `${AZURE_RESOURCE_GROUP}`
            END
        END
    ELSE
        RW.Core.Add Pre To Report    "No underutilized VMs based on memory usage found in resource group `${AZURE_RESOURCE_GROUP}`"
    END

List Unused Network Interfaces in resource group `${AZURE_RESOURCE_GROUP}`
    [Documentation]    Lists network interfaces that are not attached to any virtual machine
    [Tags]    Network    Azure    NIC    Cost    access:read-only
    CloudCustodian.Core.Generate Policy
    ...    ${CURDIR}/unused-nic.j2
    ...    resourceGroup=${AZURE_RESOURCE_GROUP}
    ...    subscriptionId=${AZURE_SUBSCRIPTION_ID}
    ${c7n_output}=    RW.CLI.Run Cli
    ...    cmd=custodian run -s ${OUTPUT_DIR}/azure-c7n-vm-health ${CURDIR}/unused-nic.yaml --cache-period 0
    ${report_data}=    RW.CLI.Run Cli
    ...    cmd=cat ${OUTPUT_DIR}/azure-c7n-vm-health/unused-nic/resources.json

    TRY
        ${nic_list}=    Evaluate    json.loads(r'''${report_data.stdout}''')    json
    EXCEPT
        Log    Failed to load JSON payload, defaulting to empty list.    WARN
        ${nic_list}=    Create List
    END

    IF    len(@{nic_list}) > 0
        ${formatted_results}=    RW.CLI.Run Cli
        ...    cmd=jq -r '["NIC_Name", "Resource_Group", "Location", "NIC_Link"], (.[] | [ .name, (.resourceGroup | ascii_downcase), .location, ("https://portal.azure.com/#@/resource" + .id + "/overview") ]) | @tsv' ${OUTPUT_DIR}/azure-c7n-vm-health/unused-nic/resources.json | column -t
        RW.Core.Add Pre To Report    Unused Network Interfaces Summary:\n===============================\n${formatted_results.stdout}

        FOR    ${nic}    IN    @{nic_list}
            ${pretty_nic}=    Evaluate    pprint.pformat(${nic})    modules=pprint
            ${resource_group}=    Set Variable    ${nic['resourceGroup'].lower()}
            ${nic_name}=    Set Variable    ${nic['name']}
            RW.Core.Add Issue
            ...    severity=4
            ...    expected=Network Interface `${nic_name}` should be attached to a virtual machine in resource group `${resource_group}`
            ...    actual=Network Interface `${nic_name}` is not attached to any virtual machine in resource group `${resource_group}`
            ...    title=Unused Network Interface `${nic_name}` found in Resource Group `${resource_group}`
            ...    reproduce_hint=${c7n_output.cmd}
            ...    details=${pretty_nic}
            ...    next_steps=Delete the unused network interface to reduce costs in resource group `${AZURE_RESOURCE_GROUP}`
        END
    ELSE
        RW.Core.Add Pre To Report    "No unused network interfaces found in resource group `${AZURE_RESOURCE_GROUP}`"
    END

List Unused Public IPs in resource group `${AZURE_RESOURCE_GROUP}`
    [Documentation]    Lists public IP addresses that are not attached to any resource
    [Tags]    Network    Azure    PublicIP    Cost    access:read-only
    CloudCustodian.Core.Generate Policy
    ...    ${CURDIR}/unused-public-ip.j2
    ...    resourceGroup=${AZURE_RESOURCE_GROUP}
    ...    subscriptionId=${AZURE_SUBSCRIPTION_ID}
    ${c7n_output}=    RW.CLI.Run Cli
    ...    cmd=custodian run -s ${OUTPUT_DIR}/azure-c7n-vm-health ${CURDIR}/unused-public-ip.yaml --cache-period 0
    ${report_data}=    RW.CLI.Run Cli
    ...    cmd=cat ${OUTPUT_DIR}/azure-c7n-vm-health/unused-publicip/resources.json

    TRY
        ${ip_list}=    Evaluate    json.loads(r'''${report_data.stdout}''')    json
    EXCEPT
        Log    Failed to load JSON payload, defaulting to empty list.    WARN
        ${ip_list}=    Create List
    END

    IF    len(@{ip_list}) > 0
        ${formatted_results}=    RW.CLI.Run Cli
        ...    cmd=jq -r '["IP_Name", "Resource_Group", "Location", "IP_Address", "IP_Link"], (.[] | [ .name, (.resourceGroup | ascii_downcase), .location, .properties.ipAddress, ("https://portal.azure.com/#@/resource" + .id + "/overview") ]) | @tsv' ${OUTPUT_DIR}/azure-c7n-vm-health/unused-publicip/resources.json | column -t
        RW.Core.Add Pre To Report    Unused Public IPs Summary:\n==========================\n${formatted_results.stdout}

        FOR    ${ip}    IN    @{ip_list}
            ${pretty_ip}=    Evaluate    pprint.pformat(${ip})    modules=pprint
            ${resource_group}=    Set Variable    ${ip['resourceGroup'].lower()}
            ${ip_name}=    Set Variable    ${ip['name']}
            RW.Core.Add Issue
            ...    severity=4
            ...    expected=Public IP `${ip_name}` should be attached to a resource in resource group `${resource_group}`
            ...    actual=Public IP `${ip_name}` is not attached to any resource in resource group `${resource_group}`
            ...    title=Unused Public IP `${ip_name}` found in Resource Group `${resource_group}`
            ...    reproduce_hint=${c7n_output.cmd}
            ...    details=${pretty_ip}
            ...    next_steps=Delete the unused public IP to reduce costs in resource group `${AZURE_RESOURCE_GROUP}`
        END
    ELSE
        RW.Core.Add Pre To Report    "No unused public IPs found in resource group `${AZURE_RESOURCE_GROUP}`"
    END

List VMs Agent Status in resource group `${AZURE_RESOURCE_GROUP}`
    [Documentation]    Lists VMs that have VM agent status issues
    [Tags]    VM    Azure    Agent    Health    access:read-only
    CloudCustodian.Core.Generate Policy
    ...    vm-agent-status.j2
    ...    resourceGroup=${AZURE_RESOURCE_GROUP}
    ...    subscriptionId=${AZURE_SUBSCRIPTION_ID}
    RW.CLI.Run Cli
    ...    cmd=cat vm-agent-status.yaml
    ${c7n_output}=    RW.CLI.Run Cli
    ...    cmd=custodian run -s azure-c7n-vm-health vm-agent-status.yaml --cache-period 0
    ${report_data}=    RW.CLI.Run Cli
    ...    cmd=cat azure-c7n-vm-health/vm-agent-status/resources.json

    TRY
        ${vm_list}=    Evaluate    json.loads(r'''${report_data.stdout}''')    json
    EXCEPT
        Log    Failed to load JSON payload, defaulting to empty list.    WARN
        ${vm_list}=    Create List
    END

    IF    len(@{vm_list}) > 0
        ${formatted_results}=    RW.CLI.Run Cli
        ...    cmd=jq -r '["VM_Name", "VM_Agent_Status", "Resource_Group", "Location", "VM_Link"], (.[] | [ .name, .instanceView.vmAgent.statuses[0].code, (.resourceGroup | ascii_downcase), .location, ("https://portal.azure.com/#@/resource" + .id + "/overview") ]) | @tsv' azure-c7n-vm-health/vm-agent-status/resources.json | column -t -s $'\t'
        RW.Core.Add Pre To Report    VMs With VM Agent Status Issues Summary:\n===================================\n${formatted_results.stdout}

        FOR    ${vm}    IN    @{vm_list}
            ${pretty_vm}=    Evaluate    pprint.pformat(${vm})    modules=pprint
            ${resource_group}=    Set Variable    ${vm['resourceGroup'].lower()}
            ${vm_name}=    Set Variable    ${vm['name']}
            ${vm_agent_status}=    Set Variable    ${vm['instanceView']['vmAgent']['statuses'][0]['code']}
            RW.Core.Add Issue
            ...    severity=3
            ...    expected=Azure VM `${vm_name}` should have a healthy VM agent status in resource group `${resource_group}`
            ...    actual=Azure VM `${vm_name}` has VM agent status issues in resource group `${resource_group}`
            ...    title=VM Agent Status is ${vm_agent_status} on Azure VM `${vm_name}` found in Resource Group `${resource_group}`
            ...    reproduce_hint=${c7n_output.cmd}
            ...    details=${pretty_vm}
            ...    next_steps=Check VM agent logs on the VM in resource group `${AZURE_RESOURCE_GROUP}`
        END
    ELSE
        RW.Core.Add Pre To Report    "No VMs with VM agent status issues found in resource group `${AZURE_RESOURCE_GROUP}`"
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
    ${STOPPED_VM_TIMEFRAME}=    RW.Core.Import User Variable    STOPPED_VM_TIMEFRAME
    ...    type=string
    ...    description=The timeframe since the VM was stopped.
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
    ${MAX_VM_WITH_PUBLIC_IP}=    RW.Core.Import User Variable    MAX_VM_WITH_PUBLIC_IP
    ...    type=string
    ...    description=The maximum number of VMs with public IPs allowed in the resource group.
    ...    pattern=^\d+$
    ...    example=10
    ...    default=10
    Set Suite Variable    ${AZURE_SUBSCRIPTION_ID}    ${AZURE_SUBSCRIPTION_ID}
    Set Suite Variable    ${AZURE_RESOURCE_GROUP}    ${AZURE_RESOURCE_GROUP}
    Set Suite Variable    ${HIGH_CPU_PERCENTAGE}    ${HIGH_CPU_PERCENTAGE}
    Set Suite Variable    ${HIGH_CPU_TIMEFRAME}    ${HIGH_CPU_TIMEFRAME}
    Set Suite Variable    ${LOW_CPU_PERCENTAGE}    ${LOW_CPU_PERCENTAGE}
    Set Suite Variable    ${LOW_CPU_TIMEFRAME}    ${LOW_CPU_TIMEFRAME}
    Set Suite Variable    ${STOPPED_VM_TIMEFRAME}    ${STOPPED_VM_TIMEFRAME}
    Set Suite Variable    ${HIGH_MEMORY_PERCENTAGE}    ${HIGH_MEMORY_PERCENTAGE}
    Set Suite Variable    ${HIGH_MEMORY_TIMEFRAME}    ${HIGH_MEMORY_TIMEFRAME}
    Set Suite Variable    ${HIGH_MEMORY_THRESHOLD}    ${HIGH_MEMORY_THRESHOLD}
    Set Suite Variable    ${LOW_MEMORY_PERCENTAGE}    ${LOW_MEMORY_PERCENTAGE}
    Set Suite Variable    ${LOW_MEMORY_TIMEFRAME}    ${LOW_MEMORY_TIMEFRAME}
    Set Suite Variable    ${MAX_VM_WITH_PUBLIC_IP}    ${MAX_VM_WITH_PUBLIC_IP}
    
    # Set Azure subscription context for Cloud Custodian
    RW.CLI.Run Cli
    ...    cmd=az account set --subscription ${AZURE_SUBSCRIPTION_ID}
    ...    include_in_history=false
    
    Set Suite Variable
    ...    ${env}
    ...    {"AZURE_RESOURCE_GROUP":"${AZURE_RESOURCE_GROUP}", "AZURE_SUBSCRIPTION_ID":"${AZURE_SUBSCRIPTION_ID}"}