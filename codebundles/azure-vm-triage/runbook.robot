*** Settings ***
Documentation       List Virtual machines that are publicly accessible and have high CPU usage in Azure  
Metadata            Author    saurabh3460
Metadata            Display Name    Azure    Triage
Metadata            Supports    Azure    Virtual Machine    Triage    Health
Force Tags          Azure    Virtual Machine    Health

Library    String
Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library    CloudCustodian.Core

Suite Setup         Suite Initialization


*** Tasks ***
List VMs With Public IP In Azure Subscription `${AZURE_SUBSCRIPTION_NAME}`
    [Documentation]    Lists VMs with public IP address
    [Tags]    VM    Azure    Network    Security    access:read-only
    ${c7n_output}=    RW.CLI.Run Cli
    ...    cmd=custodian run -s ${OUTPUT_DIR}/azure-c7n-vm-triage ${CURDIR}/vm-with-public-ip.yaml --cache-period 0
    ${report_data}=    RW.CLI.Run Cli
    ...    cmd=cat ${OUTPUT_DIR}/azure-c7n-vm-triage/vm-with-public-ip/resources.json

    TRY
        ${vm_list}=    Evaluate    json.loads(r'''${report_data.stdout}''')    json
    EXCEPT
        Log    Failed to load JSON payload, defaulting to empty list.    WARN
        ${vm_list}=    Create List
    END

    IF    len(@{vm_list}) > 0
        ${formatted_results}=    RW.CLI.Run Cli
        ...    cmd=jq -r '["VM_Name", "Resource_Group", "Location", "VM_Link"], (.[] | [ .name, (.resourceGroup | ascii_downcase), .location, ("https://portal.azure.com/#@/resource" + .id + "/overview") ]) | @tsv' ${OUTPUT_DIR}/azure-c7n-vm-triage/vm-with-public-ip/resources.json | column -t
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
            ...    next_steps=Disable the public IP address from azure VM in subscription `${AZURE_SUBSCRIPTION_NAME}`
        END
    ELSE
        RW.Core.Add Pre To Report    "No VMs with public IPs found in subscription `${AZURE_SUBSCRIPTION_NAME}`"
    END

List VMs With High CPU Usage In Subscription `${AZURE_SUBSCRIPTION_NAME}`
    [Documentation]    Checks for VMs with high CPU usage
    [Tags]    VM    Azure    CPU    Performance    access:read-only
    CloudCustodian.Core.Generate Policy   
    ...    ${CURDIR}/vm-cpu-usage.j2
    ...    cpu_percentage=${HIGH_CPU_PERCENTAGE}
    ...    timeframe=${HIGH_CPU_TIMEFRAME}
    ${c7n_output}=    RW.CLI.Run Cli
    ...    cmd=custodian run -s ${OUTPUT_DIR}/azure-c7n-vm-triage ${CURDIR}/vm-cpu-usage.yaml --cache-period 0
    ${report_data}=    RW.CLI.Run Cli
    ...    cmd=cat ${OUTPUT_DIR}/azure-c7n-vm-triage/vm-cpu-usage/resources.json

    TRY
        ${vm_list}=    Evaluate    json.loads(r'''${report_data.stdout}''')    json
    EXCEPT
        Log    Failed to load JSON payload, defaulting to empty list.    WARN
        ${vm_list}=    Create List
    END

    IF    len(@{vm_list}) > 0
        ${formatted_results}=    RW.CLI.Run Cli
        ...    cmd=jq -r '["VM_Name", "Resource_Group", "Location", "CPU_Usage%", "VM_Link"], (.[] | [ .name, (.resourceGroup | ascii_downcase), .location, (."c7n:metrics" | to_entries | map(.value.measurement[0]) | first // "Unknown"), ("https://portal.azure.com/#@/resource" + .id + "/overview") ]) | @tsv' ${OUTPUT_DIR}/azure-c7n-vm-triage/vm-cpu-usage/resources.json | column -t
        RW.Core.Add Pre To Report    High CPU Usage VMs Summary:\n===================================\n${formatted_results.stdout}

        FOR    ${vm}    IN    @{vm_list}
            ${pretty_vm}=    Evaluate    pprint.pformat(${vm})    modules=pprint
            ${cpu_percentage}=    Evaluate    list(${vm['c7n:metrics'].values())[0]['measurement'][0]    modules=math
            ${cpu_percentage}=    Convert To Number    ${cpu_percentage}    2
            ${resource_group}=    Set Variable    ${vm['resourceGroup'].lower()}
            ${vm_name}=    Set Variable    ${vm['name']}
            RW.Core.Add Issue
            ...    severity=3
            ...    expected=Azure VM `${vm_name}` should have CPU usage below `${cpu_percentage}%` in resource group ` ${resource_group}` in subscription `${AZURE_SUBSCRIPTION_NAME}`
            ...    actual=Azure VM `${vm_name}` has high CPU usage of `${cpu_percentage}%` in the last `${HIGH_CPU_TIMEFRAME}` hours in resource group ` ${resource_group}` in subscription `${AZURE_SUBSCRIPTION_NAME}`
            ...    title=Azure VM `${vm_name}` with high CPU Usage found in Resource Group ` ${resource_group}` in subscription `${AZURE_SUBSCRIPTION_NAME}`
            ...    reproduce_hint=${c7n_output.cmd}
            ...    details=${pretty_vm}
            ...    next_steps=Increase the CPU cores by resizing to a larger azure VM SKU in subscription `${AZURE_SUBSCRIPTION_NAME}`
        END
    ELSE
        RW.Core.Add Pre To Report    "No VMs with high CPU usage found in subscription `${AZURE_SUBSCRIPTION_NAME}`"
    END

List for Stopped VMs In Subscription `${AZURE_SUBSCRIPTION_NAME}`
    [Documentation]    Lists VMs that are in a stopped state
    [Tags]    VM    Azure    State    Cost    access:read-only
    CloudCustodian.Core.Generate Policy   
    ...    ${CURDIR}/stopped-vm.j2
    ...    timeframe=${STOPPED_VM_TIMEFRAME}
    ${c7n_output}=    RW.CLI.Run Cli
    ...    cmd=custodian run -s ${OUTPUT_DIR}/azure-c7n-vm-triage ${CURDIR}/stopped-vm.yaml --cache-period 0
    ${report_data}=    RW.CLI.Run Cli
    ...    cmd=cat ${OUTPUT_DIR}/azure-c7n-vm-triage/stopped-vms/resources.json

    TRY
        ${vm_list}=    Evaluate    json.loads(r'''${report_data.stdout}''')    json
    EXCEPT
        Log    Failed to load JSON payload, defaulting to empty list.    WARN
        ${vm_list}=    Create List
    END

    IF    len(@{vm_list}) > 0
        ${formatted_results}=    RW.CLI.Run Cli
        ...    cmd=jq -r '["VM_Name", "Resource_Group", "Location", "VM_Link"], (.[] | [ .name, (.resourceGroup | ascii_downcase), .location, ("https://portal.azure.com/#@/resource" + .id + "/overview") ]) | @tsv' ${OUTPUT_DIR}/azure-c7n-vm-triage/stopped-vms/resources.json | column -t
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
            ...    next_steps=Delete the stopped azure vm if no longer needed to reduce costs in subscription `${AZURE_SUBSCRIPTION_NAME}`
        END
    ELSE
        RW.Core.Add Pre To Report    "No stopped VMs found in subscription `${AZURE_SUBSCRIPTION_NAME}`"
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
    ${STOPPED_VM_TIMEFRAME}=    RW.Core.Import User Variable    STOPPED_VM_TIMEFRAME
    ...    type=string
    ...    description=The timeframe since the VM was stopped.
    ...    pattern=^\d+$
    ...    example=24
    ...    default=24
    ${subscription_name}=    RW.CLI.Run Cli
    ...    cmd=az account show --subscription ${AZURE_SUBSCRIPTION_ID} --query name -o tsv
    Set Suite Variable    ${AZURE_SUBSCRIPTION_NAME}    ${subscription_name.stdout.strip()}
    Set Suite Variable    ${AZURE_SUBSCRIPTION_ID}    ${AZURE_SUBSCRIPTION_ID}
    Set Suite Variable    ${HIGH_CPU_PERCENTAGE}    ${HIGH_CPU_PERCENTAGE}
    Set Suite Variable    ${HIGH_CPU_TIMEFRAME}    ${HIGH_CPU_TIMEFRAME}
    Set Suite Variable    ${STOPPED_VM_TIMEFRAME}    ${STOPPED_VM_TIMEFRAME}