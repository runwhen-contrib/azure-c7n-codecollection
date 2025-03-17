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
List VMs With Public IP in resource group `${AZURE_RESOURCE_GROUP}` in Azure Subscription `${AZURE_SUBSCRIPTION_NAME}`
    [Documentation]    Lists VMs with public IP address
    [Tags]    VM    Azure    Network    Security    access:read-only
    CloudCustodian.Core.Generate Policy   
    ...    ${CURDIR}/vm-with-public-ip.j2
    ...    resourceGroup=${AZURE_RESOURCE_GROUP}
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
            ...    expected=Azure VM `${vm_name}` should not be publicly accessible in resource group `${resource_group}` in subscription `${AZURE_SUBSCRIPTION_NAME}`
            ...    actual=Azure VM `${vm_name}` is publicly accessible in resource group `${resource_group}` in subscription `${AZURE_SUBSCRIPTION_NAME}`
            ...    title=Azure VM `${vm_name}` with Public IP Detected in Resource Group `${resource_group}` in subscription `${AZURE_SUBSCRIPTION_NAME}`
            ...    reproduce_hint=${c7n_output.cmd}
            ...    details=${pretty_vm}
            ...    next_steps=Disable the public IP address from azure VM in resource group `${AZURE_RESOURCE_GROUP}` in subscription `${AZURE_SUBSCRIPTION_NAME}`
        END
    ELSE
        RW.Core.Add Pre To Report    "No VMs with public IPs found in resource group `${AZURE_RESOURCE_GROUP}` in subscription `${AZURE_SUBSCRIPTION_NAME}`"
    END

List for Stopped VMs in resource group `${AZURE_RESOURCE_GROUP}` in Subscription `${AZURE_SUBSCRIPTION_NAME}`
    [Documentation]    Lists VMs that are in a stopped state
    [Tags]    VM    Azure    State    Cost    access:read-only
    CloudCustodian.Core.Generate Policy   
    ...    ${CURDIR}/stopped-vm.j2
    ...    timeframe=${STOPPED_VM_TIMEFRAME}
    ...    resourceGroup=${AZURE_RESOURCE_GROUP}
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
            ...    expected=Azure VM `${vm_name}` should be in use in resource group `${resource_group}` in subscription `${AZURE_SUBSCRIPTION_NAME}`
            ...    actual=Azure VM `${vm_name}` is in stopped state more than `${STOPPED_VM_TIMEFRAME}` hours in resource group `${resource_group}` in subscription `${AZURE_SUBSCRIPTION_NAME}`
            ...    title=Stopped Azure VM `${vm_name}` found in Resource Group `${resource_group}` in subscription `${AZURE_SUBSCRIPTION_NAME}`
            ...    reproduce_hint=${c7n_output.cmd}
            ...    details=${pretty_vm}
            ...    next_steps=Delete the stopped azure vm if no longer needed to reduce costs in resource group `${AZURE_RESOURCE_GROUP}` in subscription `${AZURE_SUBSCRIPTION_NAME}`
        END
    ELSE
        RW.Core.Add Pre To Report    "No stopped VMs found in resource group `${AZURE_RESOURCE_GROUP}` in subscription `${AZURE_SUBSCRIPTION_NAME}`"
    END

List VMs With High CPU Usage in resource group `${AZURE_RESOURCE_GROUP}` in Subscription `${AZURE_SUBSCRIPTION_NAME}`
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

    IF    len(@{vm_list}) > 0
        ${formatted_results}=    RW.CLI.Run Cli
        ...    cmd=jq -r '["VM_Name", "Resource_Group", "Location", "CPU_Usage%", "VM_Link"], (.[] | [ .name, (.resourceGroup | ascii_downcase), .location, (."c7n:metrics" | to_entries | map(.value.measurement[0]) | first // 0 | tonumber | (. * 100 | round / 100) | tostring), ("https://portal.azure.com/#@/resource" + .id + "/overview") ]) | @tsv' ${OUTPUT_DIR}/azure-c7n-vm-health/vm-cpu-usage/resources.json | column -t
        RW.Core.Add Pre To Report    High CPU Usage VMs Summary:\n===================================\n${formatted_results.stdout}

        FOR    ${vm}    IN    @{vm_list}
            ${pretty_vm}=    Evaluate    pprint.pformat(${vm})    modules=pprint
            ${resource_group}=    Set Variable    ${vm['resourceGroup'].lower()}
            ${vm_name}=    Set Variable    ${vm['name']}
            ${json_str}=    Evaluate    json.dumps(${vm})    json
            ${cpu_percentage_result}=    RW.CLI.Run Cli
            ...    cmd=echo '${json_str}' | jq -r '(."c7n:metrics" | to_entries | map(.value.measurement[0]) | first // "0")'
            # Convert to a number for further processing
            ${cpu_percentage}=    Convert To Number    ${cpu_percentage_result.stdout}    2
            RW.Core.Add Issue
            ...    severity=3
            ...    expected=Azure VM `${vm_name}` should have CPU usage below `${cpu_percentage}%` in resource group `${resource_group}` in subscription `${AZURE_SUBSCRIPTION_NAME}`
            ...    actual=Azure VM `${vm_name}` has high CPU usage of `${cpu_percentage}%` in the last `${HIGH_CPU_TIMEFRAME}` hours in resource group ` ${resource_group}` in subscription `${AZURE_SUBSCRIPTION_NAME}`
            ...    title=Azure VM `${vm_name}` with high CPU Usage found in Resource Group ` ${resource_group}` in subscription `${AZURE_SUBSCRIPTION_NAME}`
            ...    reproduce_hint=${c7n_output.cmd}
            ...    details=${pretty_vm}
            ...    next_steps=Increase the CPU cores by resizing to a larger azure VM SKU in resource group `${AZURE_RESOURCE_GROUP}` in subscription `${AZURE_SUBSCRIPTION_NAME}`
        END
    ELSE
        RW.Core.Add Pre To Report    "No VMs with high CPU usage found in resource group `${AZURE_RESOURCE_GROUP}` in subscription `${AZURE_SUBSCRIPTION_NAME}`"
    END


List Underutilized VMs Based on CPU Usage in resource group `${AZURE_RESOURCE_GROUP}` in Subscription `${AZURE_SUBSCRIPTION_NAME}`
    [Documentation]    List Azure Virtual Machines (VMs) that have low CPU utilization based on a defined threshold and timeframe.
    [Tags]    VM    Azure    CPU    Performance    access:read-only
    CloudCustodian.Core.Generate Policy   
    ...    ${CURDIR}/under-utilized-vm-cpu-usage.j2
    ...    cpu_percentage=${LOW_CPU_PERCENTAGE}
    ...    timeframe=${LOW_CPU_TIMEFRAME}
    ...    resourceGroup=${AZURE_RESOURCE_GROUP}
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
        ...    cmd=...    cmd=jq -r '["VM_Name", "Resource_Group", "Location", "CPU_Usage%", "VM_Link"], (.[] | [ .name, (.resourceGroup | ascii_downcase), .location, (."c7n:metrics" | to_entries | map(.value.measurement[0]) | first // 0 | tonumber | (. * 100 | round / 100) | tostring), ("https://portal.azure.com/#@/resource" + .id + "/overview") ]) | @tsv' ${OUTPUT_DIR}/azure-c7n-vm-health/under-utilized-vm-cpu-usage/resources.json | column -t
        RW.Core.Add Pre To Report    Underutilized VMs Based on CPU Summary:\n========================\n${formatted_results.stdout}

        FOR    ${vm}    IN    @{vm_list}
            ${pretty_vm}=    Evaluate    pprint.pformat(${vm})    modules=pprint
            ${resource_group}=    Set Variable    ${vm['resourceGroup'].lower()}
            ${vm_name}=    Set Variable    ${vm['name']}
            ${json_str}=    Evaluate    json.dumps(${vm})    json
            ${cpu_percentage_result}=    RW.CLI.Run Cli
            ...    cmd=echo '${json_str}' | jq -r '(."c7n:metrics" | to_entries | map(.value.measurement[0]) | first // "0")'
            # Convert to a number for further processing
            ${cpu_percentage}=    Convert To Number    ${cpu_percentage_result.stdout}    2
            RW.Core.Add Issue
            ...    severity=4
            ...    expected=Azure VM `${vm_name}` should have adequate CPU utilization in resource group `${resource_group}` in subscription `${AZURE_SUBSCRIPTION_NAME}`
            ...    actual=Azure VM `${vm_name}` has low CPU usage of `${cpu_percentage}%` in the last `${HIGH_CPU_TIMEFRAME}` hours in resource group `${resource_group}` in subscription `${AZURE_SUBSCRIPTION_NAME}`
            ...    title=Underutilized Azure VM `${vm_name}` found in Resource Group `${resource_group}` in subscription `${AZURE_SUBSCRIPTION_NAME}`
            ...    reproduce_hint=${c7n_output.cmd}
            ...    details=${pretty_vm}
            ...    next_steps=Resize to a smaller azure VM SKU to optimize costs in resource group `${AZURE_RESOURCE_GROUP}` in subscription `${AZURE_SUBSCRIPTION_NAME}`
        END
    ELSE
        RW.Core.Add Pre To Report    "No underutilized VMs found in resource group `${AZURE_RESOURCE_GROUP}` in subscription `${AZURE_SUBSCRIPTION_NAME}`"
    END

List VMs With High Memory Usage in resource group `${AZURE_RESOURCE_GROUP}` in Subscription `${AZURE_SUBSCRIPTION_NAME}`
    [Documentation]    List Azure Virtual Machines (VMs) that have high memory usage based on a defined threshold and timeframe.
    [Tags]    VM    Azure    Memory    Performance    access:read-only
    CloudCustodian.Core.Generate Policy   
    ...    ${CURDIR}/vm-memory-usage.j2
    ...    op=lt
    ...    memory_percentage=${HIGH_MEMORY_PERCENTAGE}
    ...    timeframe=${HIGH_MEMORY_TIMEFRAME}
    ...    resourceGroup=${AZURE_RESOURCE_GROUP}    
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
        ${formatted_results}=    RW.CLI.Run Cli
        ...    cmd=jq -r '["VM_Name", "Resource_Group", "Location", "Available_Memory%", "VM_Link"], (.[] | [ .name, (.resourceGroup | ascii_downcase), .location, (."c7n:metrics" | to_entries | map(.value.measurement[0]) | first // 0 | tonumber | (. * 100 | round / 100) | tostring), ("https://portal.azure.com/#@/resource" + .id + "/overview") ]) | @tsv' ${OUTPUT_DIR}/azure-c7n-vm-health/vm-memory-usage/resources.json | column -t
        RW.Core.Add Pre To Report    VMs With High Memory Usage Summary:\n========================\n${formatted_results.stdout}

        FOR    ${vm}    IN    @{vm_list}
            ${pretty_vm}=    Evaluate    pprint.pformat(${vm})    modules=pprint
            ${resource_group}=    Set Variable    ${vm['resourceGroup'].lower()}
            ${vm_name}=    Set Variable    ${vm['name']}
            ${json_str}=    Evaluate    json.dumps(${vm})    json
            ${memory_percentage_result}=    RW.CLI.Run Cli
            ...    cmd=echo '${json_str}' | jq -r '(."c7n:metrics" | to_entries | map(.value.measurement[0]) | first // "0")'
            # Convert to a number and calculate memory usage percentage (100 - available memory)
            ${available_memory}=    Convert To Number    ${memory_percentage_result.stdout}    2
            ${memory_percentage}=    Evaluate    round(100 - ${available_memory}, 2)
            RW.Core.Add Issue
            ...    severity=3
            ...    expected=Azure VM `${vm_name}` should have adequate available memory in resource group `${resource_group}` in subscription `${AZURE_SUBSCRIPTION_NAME}`
            ...    actual=Azure VM `${vm_name}` has high memory usage of `${memory_percentage}%` in the last `${HIGH_MEMORY_TIMEFRAME}` hours in resource group `${resource_group}` in subscription `${AZURE_SUBSCRIPTION_NAME}`
            ...    title=High Memory Usage on Azure VM `${vm_name}` found in Resource Group `${resource_group}` in subscription `${AZURE_SUBSCRIPTION_NAME}`
            ...    reproduce_hint=${c7n_output.cmd}
            ...    details=${pretty_vm}
            ...    next_steps=Resize to a larger azure VM SKU to better match memory usage requirements in resource group `${AZURE_RESOURCE_GROUP}` in subscription `${AZURE_SUBSCRIPTION_NAME}`
        END
    ELSE
        RW.Core.Add Pre To Report    "No VMs with high memory usage found in resource group `${AZURE_RESOURCE_GROUP}` in subscription `${AZURE_SUBSCRIPTION_NAME}`"
    END

List Underutilized VMs Based on Memory Usage in resource group `${AZURE_RESOURCE_GROUP}` in Subscription `${AZURE_SUBSCRIPTION_NAME}`
    [Documentation]    List Azure Virtual Machines (VMs) that are underutilized based on memory usage
    [Tags]    VM    Azure    Memory    Utilization    access:read-only
    CloudCustodian.Core.Generate Policy   
    ...    ${CURDIR}/vm-memory-usage.j2
    ...    op=gt
    ...    memory_percentage=${LOW_MEMORY_PERCENTAGE}
    ...    timeframe=${LOW_MEMORY_TIMEFRAME}
    ...    resourceGroup=${AZURE_RESOURCE_GROUP}
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
        ${formatted_results}=    RW.CLI.Run Cli
        ...    cmd=jq -r '["VM_Name", "Resource_Group", "Location", "Available_Memory%", "VM_Link"], (.[] | [ .name, (.resourceGroup | ascii_downcase), .location, (."c7n:metrics" | to_entries | map(.value.measurement[0]) | first // 0 | tonumber | (. * 100 | round / 100) | tostring), ("https://portal.azure.com/#@/resource" + .id + "/overview") ]) | @tsv' ${OUTPUT_DIR}/azure-c7n-vm-health/vm-memory-usage/resources.json | column -t
        RW.Core.Add Pre To Report    Underutilized VMs Based on Memory Usage Summary:\n========================\n${formatted_results.stdout}

        FOR    ${vm}    IN    @{vm_list}
            ${pretty_vm}=    Evaluate    pprint.pformat(${vm})    modules=pprint
            ${resource_group}=    Set Variable    ${vm['resourceGroup'].lower()}
            ${vm_name}=    Set Variable    ${vm['name']}
            ${json_str}=    Evaluate    json.dumps(${vm})    json
            ${memory_percentage_result}=    RW.CLI.Run Cli
            ...    cmd=echo '${json_str}' | jq -r '(."c7n:metrics" | to_entries | map(.value.measurement[0]) | first // "0")'
            # Convert to a number and calculate memory usage percentage (100 - available memory)
            ${available_memory}=    Convert To Number    ${memory_percentage_result.stdout}    2
            ${memory_percentage}=    Evaluate    round(100 - ${available_memory}, 2)
            RW.Core.Add Issue
            ...    severity=4
            ...    expected=Azure VM `${vm_name}` should have optimal memory utilization in resource group `${resource_group}` in subscription `${AZURE_SUBSCRIPTION_NAME}`
            ...    actual=Azure VM `${vm_name}` has high available memory of `${memory_percentage}%` in the last `${LOW_MEMORY_TIMEFRAME}` hours in resource group `${resource_group}` in subscription `${AZURE_SUBSCRIPTION_NAME}`
            ...    title=Underutilized Memory on Azure VM `${vm_name}` found in Resource Group `${resource_group}` in subscription `${AZURE_SUBSCRIPTION_NAME}`
            ...    reproduce_hint=${c7n_output.cmd}
            ...    details=${pretty_vm}
            ...    next_steps=Resize to a smaller azure VM SKU to better match memory usage requirements in resource group `${AZURE_RESOURCE_GROUP}` in subscription `${AZURE_SUBSCRIPTION_NAME}`
        END
    ELSE
        RW.Core.Add Pre To Report    "No underutilized VMs based on memory usage found in resource group `${AZURE_RESOURCE_GROUP}` in subscription `${AZURE_SUBSCRIPTION_NAME}`"
    END

List Unused Network Interfaces in resource group `${AZURE_RESOURCE_GROUP}` in Subscription `${AZURE_SUBSCRIPTION_NAME}`
    [Documentation]    Lists network interfaces that are not attached to any virtual machine
    [Tags]    Network    Azure    NIC    Cost    access:read-only
    CloudCustodian.Core.Generate Policy   
    ...    ${CURDIR}/unused-nic.j2
    ...    resourceGroup=${AZURE_RESOURCE_GROUP}
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
            ...    expected=Network Interface `${nic_name}` should be attached to a virtual machine in resource group `${resource_group}` in subscription `${AZURE_SUBSCRIPTION_NAME}`
            ...    actual=Network Interface `${nic_name}` is not attached to any virtual machine in resource group `${resource_group}` in subscription `${AZURE_SUBSCRIPTION_NAME}`
            ...    title=Unused Network Interface `${nic_name}` found in Resource Group `${resource_group}` in subscription `${AZURE_SUBSCRIPTION_NAME}`
            ...    reproduce_hint=${c7n_output.cmd}
            ...    details=${pretty_nic}
            ...    next_steps=Delete the unused network interface to reduce costs in resource group `${AZURE_RESOURCE_GROUP}` in subscription `${AZURE_SUBSCRIPTION_NAME}`
        END
    ELSE
        RW.Core.Add Pre To Report    "No unused network interfaces found in resource group `${AZURE_RESOURCE_GROUP}` in subscription `${AZURE_SUBSCRIPTION_NAME}`"
    END

List Unused Public IPs in resource group `${AZURE_RESOURCE_GROUP}` in Subscription `${AZURE_SUBSCRIPTION_NAME}`
    [Documentation]    Lists public IP addresses that are not attached to any resource
    [Tags]    Network    Azure    PublicIP    Cost    access:read-only
    CloudCustodian.Core.Generate Policy   
    ...    ${CURDIR}/unused-public-ip.j2
    ...    resourceGroup=${AZURE_RESOURCE_GROUP}
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
            ...    expected=Public IP `${ip_name}` should be attached to a resource in resource group `${resource_group}` in subscription `${AZURE_SUBSCRIPTION_NAME}`
            ...    actual=Public IP `${ip_name}` is not attached to any resource in resource group `${resource_group}` in subscription `${AZURE_SUBSCRIPTION_NAME}`
            ...    title=Unused Public IP `${ip_name}` found in Resource Group `${resource_group}` in subscription `${AZURE_SUBSCRIPTION_NAME}`
            ...    reproduce_hint=${c7n_output.cmd}
            ...    details=${pretty_ip}
            ...    next_steps=Delete the unused public IP to reduce costs in resource group `${AZURE_RESOURCE_GROUP}` in subscription `${AZURE_SUBSCRIPTION_NAME}`
        END
    ELSE
        RW.Core.Add Pre To Report    "No unused public IPs found in resource group `${AZURE_RESOURCE_GROUP}` in subscription `${AZURE_SUBSCRIPTION_NAME}`"
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
    Set Suite Variable    ${AZURE_SUBSCRIPTION_NAME}    ${AZURE_SUBSCRIPTION_NAME}
    Set Suite Variable    ${AZURE_SUBSCRIPTION_ID}    ${AZURE_SUBSCRIPTION_ID}
    Set Suite Variable    ${AZURE_RESOURCE_GROUP}    ${AZURE_RESOURCE_GROUP}
    Set Suite Variable    ${HIGH_CPU_PERCENTAGE}    ${HIGH_CPU_PERCENTAGE}
    Set Suite Variable    ${HIGH_CPU_TIMEFRAME}    ${HIGH_CPU_TIMEFRAME}
    Set Suite Variable    ${LOW_CPU_PERCENTAGE}    ${LOW_CPU_PERCENTAGE}
    Set Suite Variable    ${LOW_CPU_TIMEFRAME}    ${LOW_CPU_TIMEFRAME}
    Set Suite Variable    ${STOPPED_VM_TIMEFRAME}    ${STOPPED_VM_TIMEFRAME}
    Set Suite Variable    ${HIGH_MEMORY_PERCENTAGE}    ${HIGH_MEMORY_PERCENTAGE}
    Set Suite Variable    ${HIGH_MEMORY_TIMEFRAME}    ${HIGH_MEMORY_TIMEFRAME}
    Set Suite Variable    ${LOW_MEMORY_PERCENTAGE}    ${LOW_MEMORY_PERCENTAGE}
    Set Suite Variable    ${LOW_MEMORY_TIMEFRAME}    ${LOW_MEMORY_TIMEFRAME}