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
List VMs With Public IP In Azure Subscription `${AZURE_SUBSCRIPTION_ID}`
    [Documentation]    Lists VMs with public IP addresses in the resource group
    [Tags]    VM    Azure    Network    Security
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
        ...    cmd=jq -r '["VM_Name", "Resource_Group", "Location", "Public_IP"], (.[] | [ .name, .resourceGroup, .location, (.properties.networkProfile.networkInterfaces[].properties.ipConfigurations[]?.properties.publicIPAddress?.id // "None") ]) | @tsv' ${OUTPUT_DIR}/azure-c7n-vm-triage/vm-with-public-ip/resources.json | column -t
        RW.Core.Add Pre To Report    Virtual Machines Summary:\n===================================\n${formatted_results.stdout}

        FOR    ${vm}    IN    @{vm_list}
            ${pretty_vm}=    Evaluate    pprint.pformat(${vm})    modules=pprint
            RW.Core.Add Issue
            ...    severity=3
            ...    expected=The VM `${vm['name']}` in resource group `${vm['resourceGroup'].lower()}` should not have a public IP address configured
            ...    actual=The VM `${vm['name']}` in resource group `${vm['resourceGroup'].lower()}` has a public IP address configured
            ...    title=VM with Public IP Detected: `${vm['name']}` in Resource Group `${vm['resourceGroup'].lower()}`
            ...    reproduce_hint=${c7n_output.cmd}
            ...    details=${pretty_vm}
            ...    next_steps=Consider either removing the public IP address from VM `${vm['name']}` or implementing a bastion host for secure access
        END
    ELSE
        RW.Core.Add Pre To Report    "No VMs with public IPs found in subscription `${AZURE_SUBSCRIPTION_ID}`"
    END

Check VMs With High CPU Usage In Subscription `${AZURE_SUBSCRIPTION_ID}`
    [Documentation]    Checks for VMs with high CPU usage in the subscription
    [Tags]    VM    Azure    CPU    Performance
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
        ...    cmd=jq -r '["VM_Name", "Resource_Group", "Location", "CPU_Usage%", "VM_Link"], (.[] | [ .name, .resourceGroup, .location, (."c7n:metrics" | to_entries | map(.value.measurement[0]) | first // "Unknown"), ("https://portal.azure.com/#@/resource" + .id + "/overview") ]) | @tsv' ${OUTPUT_DIR}/azure-c7n-vm-triage/vm-cpu-usage/resources.json | column -t
        RW.Core.Add Pre To Report    High CPU Usage VMs Summary:\n===================================\n${formatted_results.stdout}

        FOR    ${vm}    IN    @{vm_list}
            ${pretty_vm}=    Evaluate    pprint.pformat(${vm})    modules=pprint
            ${cpu_percentage}=    Evaluate    list(${vm['c7n:metrics'].values())[0]['measurement'][0]    modules=math
            ${cpu_percentage}=    Convert To Number    ${cpu_percentage}    2
            RW.Core.Add Issue
            ...    severity=3
            ...    expected=The VM `${vm['name']}` in resource group `${vm['resourceGroup'].lower()}` should have normal CPU usage
            ...    actual=The VM `${vm['name']}` has high CPU usage of `${cpu_percentage}`% in the last `${HIGH_CPU_TIMEFRAME}` hours in resource group `${vm['resourceGroup'].lower()}`
            ...    title=High CPU Usage VM `${vm['name']}` found in Resource Group `${vm['resourceGroup'].lower()}`
            ...    reproduce_hint=${c7n_output.cmd}
            ...    details=${pretty_vm}
            ...    next_steps=Increase the CPU cores by resizing to a larger VM SKU in subscription `${AZURE_SUBSCRIPTION_ID}`
        END
    ELSE
        RW.Core.Add Pre To Report    "No VMs with high CPU usage found in subscription `${AZURE_SUBSCRIPTION_ID}`"
    END

Check for Stopped VMs In Subscription `${AZURE_SUBSCRIPTION_ID}`
    [Documentation]    Lists VMs that are in a stopped state in the subscription
    [Tags]    VM    Azure    State    Cost
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
        ...    cmd=jq -r '["VM_Name", "Resource_Group", "Location", "VM_Link"], (.[] | [ .name, .resourceGroup, .location, ("https://portal.azure.com/#@/resource" + .id + "/overview") ]) | @tsv' ${OUTPUT_DIR}/azure-c7n-vm-triage/stopped-vms/resources.json | column -t
        RW.Core.Add Pre To Report    Stopped VMs Summary:\n========================\n${formatted_results.stdout}

        FOR    ${vm}    IN    @{vm_list}
            ${pretty_vm}=    Evaluate    pprint.pformat(${vm})    modules=pprint
            RW.Core.Add Issue
            ...    severity=4
            ...    expected=The VM `${vm['name']}` in resource group `${vm['resourceGroup'].lower()}` should be running or deleted
            ...    actual=The VM `${vm['name']}` in resource group `${vm['resourceGroup'].lower()}` is in a stopped state since `${STOPPED_VM_TIMEFRAME}` hours
            ...    title=Stopped VM `${vm['name']}` found in Resource Group `${vm['resourceGroup'].lower()}`
            ...    reproduce_hint=${c7n_output.cmd}
            ...    details=${pretty_vm}
            ...    next_steps=Deleting it if no longer needed to reduce costs in subscription `${AZURE_SUBSCRIPTION_ID}`
        END
    ELSE
        RW.Core.Add Pre To Report    "No stopped VMs found in subscription `${AZURE_SUBSCRIPTION_ID}`"
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
    Set Suite Variable    ${AZURE_SUBSCRIPTION_ID}    ${AZURE_SUBSCRIPTION_ID}
    Set Suite Variable    ${HIGH_CPU_PERCENTAGE}    ${HIGH_CPU_PERCENTAGE}
    Set Suite Variable    ${HIGH_CPU_TIMEFRAME}    ${HIGH_CPU_TIMEFRAME}
    Set Suite Variable    ${STOPPED_VM_TIMEFRAME}    ${STOPPED_VM_TIMEFRAME}
    # Set Suite Variable
    # ...    ${env}
    # ...    {"AZURE_TENANT_ID":"${AZURE_TENANT_ID}", "AZURE_SUBSCRIPTION_ID":"${AZURE_SUBSCRIPTION_ID}", "AZURE_CLIENT_ID": "${AZURE_CLIENT_ID}" , "OUTPUT_DIR":"${OUTPUT_DIR}"}