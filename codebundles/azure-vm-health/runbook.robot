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
Library             Collections
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
                ...    title=Azure VM `${vm_name}` with Health Status of `${health_status}` found in Resource Group `${AZURE_RESOURCE_GROUP}` in subscription `${AZURE_SUBSCRIPTION_NAME}`
                ...    reproduce_hint=${output.cmd}
                ...    details={"details": ${pretty_health}, "subscription_name": "${AZURE_SUBSCRIPTION_NAME}"}
                ...    next_steps=Investigate the health status of the Azure VM in resource group `${AZURE_RESOURCE_GROUP}`
                ...    summary=The Azure VM `${vm_name}` in resource group `${AZURE_RESOURCE_GROUP}` was reported with a health status of `${health_status}`, although it was expected to show `Available`. Resource Health data indicates no platform issues, suggesting the VM may have been intentionally or unexpectedly removed. Further investigation into its health status was initiated and the issue was resolved by listing VM health in `${AZURE_RESOURCE_GROUP}`.
            END
        END
    ELSE
        RW.Core.Add Issue
        ...    severity=4
        ...    expected=Azure VM health should be enabled in resource group `${AZURE_RESOURCE_GROUP}`
        ...    actual=Azure VM health appears unavailable in resource group `${AZURE_RESOURCE_GROUP}`
        ...    title=Azure resource health is unavailable for Azure VMs in resource group `${AZURE_RESOURCE_GROUP}` in subscription `${AZURE_SUBSCRIPTION_NAME}`
        ...    reproduce_hint=${output.cmd}
        ...    details={"details": ${health_list}, "subscription_name": "${AZURE_SUBSCRIPTION_NAME}"}
        ...    next_steps=Please escalate to the Azure service owner to enable provider Microsoft.ResourceHealth.
        ...    summary=Azure VM health was expected to be available for resources in `${AZURE_RESOURCE_GROUP}`, but it appeared unavailable within the `${AZURE_SUBSCRIPTION_NAME}` subscription.
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
    ...    timeout_seconds=180
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
            ...    title=Azure VM `${vm_name}` with Public IP Detected in Resource Group `${resource_group}` in subscription `${AZURE_SUBSCRIPTION_NAME}`
            ...    reproduce_hint=${c7n_output.cmd}
            ...    details={"details": ${pretty_vm}, "subscription_name": "${AZURE_SUBSCRIPTION_NAME}"}
            ...    next_steps=Disable the public IP address from azure VM in resource group `${AZURE_RESOURCE_GROUP}`
            ...    summary=Azure VM `${vm_name}` in resource group `${resource_group}` was found to be publicly accessible, which violates the expectation that it should not expose a public IP. This configuration could allow unintended external access to the VM. Actions are needed to remove its public exposure and review related network and access configurations.
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
    ...    timeout_seconds=180
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
            ...    title=Stopped Azure VM `${vm_name}` found in Resource Group `${resource_group}` in subscription `${AZURE_SUBSCRIPTION_NAME}`
            ...    reproduce_hint=${c7n_output.cmd}
            ...    details={"details": ${pretty_vm}, "subscription_name": "${AZURE_SUBSCRIPTION_NAME}"}
            ...    next_steps=Delete the stopped azure vm if no longer needed to reduce costs in resource group `${AZURE_RESOURCE_GROUP}`
            ...    summary=The Azure VM `${vm_name}` in resource group `${resource_group}` was found in a deallocated state despite being expected to remain in use. Provisioning succeeded, but the VM has remained stopped for over `${STOPPED_VM_TIMEFRAME}` hours, indicating it is not actively needed. Action is required to determine whether the VM should be retained or removed to avoid unnecessary costs.
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
    ...    timeout_seconds=180
    ${report_data}=    RW.CLI.Run Cli
    ...    cmd=cat ${OUTPUT_DIR}/azure-c7n-vm-health/vm-cpu-usage/resources.json

    TRY
        ${vm_list}=    Evaluate    json.loads(r'''${report_data.stdout}''')    json
    EXCEPT
        Log    Failed to load JSON payload, defaulting to empty list.    WARN
        ${vm_list}=    Create List
    END

    ${high_cpu_vms}=    Create List
    ${metrics_unavailable_vms}=    Create List
    
    IF    len(@{vm_list}) > 0
        FOR    ${vm}    IN    @{vm_list}
            ${json_str}=    Evaluate    json.dumps(${vm})    json
            ${metrics_available}=    RW.CLI.Run Cli
            ...    cmd=echo '${json_str}' | jq -r '(."c7n:metrics" | to_entries | map(.value.measurement[0]) | first) != null'
            ${metrics_available_clean}=    Strip String    ${metrics_available.stdout}
            
            IF    "${metrics_available_clean}" == "true"
                ${cpu_percentage_result}=    RW.CLI.Run Cli
                ...    cmd=echo '${json_str}' | jq -r '(."c7n:metrics" | to_entries | map(.value.measurement[0]) | first // "0")'
                ${cpu_percentage}=    Convert To Number    ${cpu_percentage_result.stdout}    2
                
                ${vm_data}=    Create Dictionary
                ...    name=${vm['name']}
                ...    resource_group=${vm['resourceGroup']}
                ...    location=${vm.get('location', 'N/A')}
                ...    cpu_percentage=${cpu_percentage}
                ...    vm_status=${vm['instanceView']['statuses'][0]['code'] if 'instanceView' in ${vm} and 'statuses' in ${vm['instanceView']} and len(${vm['instanceView']['statuses']}) > 0 else 'Unknown'}
                ...    vm_link=https://portal.azure.com/#@/resource${vm['id']}/overview
                
                Append To List    ${high_cpu_vms}    ${vm_data}
            ELSE
                ${vm_data}=    Create Dictionary
                ...    name=${vm['name']}
                ...    resource_group=${vm['resourceGroup']}
                ...    location=${vm.get('location', 'N/A')}
                ...    vm_agent_status=${vm['instanceView']['vmAgent']['statuses'][0]['code'] if 'instanceView' in ${vm} and 'vmAgent' in ${vm['instanceView']} and 'statuses' in ${vm['instanceView']['vmAgent']} and len(${vm['instanceView']['vmAgent']['statuses']}) > 0 else 'Unknown'}
                ...    vm_status=${vm['instanceView']['statuses'][0]['code'] if 'instanceView' in ${vm} and 'statuses' in ${vm['instanceView']} and len(${vm['instanceView']['statuses']}) > 0 else 'Unknown'}
                ...    vm_link=https://portal.azure.com/#@/resource${vm['id']}/overview
                
                Append To List    ${metrics_unavailable_vms}    ${vm_data}
            END
        END
        
        # Process VMs with high CPU usage
        IF    ${high_cpu_vms.__len__()} > 0
            ${report}=    Set Variable    \n=== VMs With High CPU Usage (Last ${HIGH_CPU_TIMEFRAME} hours) ===\n
            # Create a temporary file for jq processing
            ${temp_file}=    Set Variable    ${OUTPUT_DIR}/high_cpu_vms.json
            ${vm_data_json}=    Evaluate    json.dumps(${high_cpu_vms})    json
            RW.CLI.Run Cli    cmd=echo '${vm_data_json.replace("'", "'\\''")}' > ${temp_file}
            
            # Generate formatted table with markdown links for VM names
            ${formatted_results}=    RW.CLI.Run Cli
            ...    cmd=jq -r '["VM Name", "Resource Group", "Location", "CPU Usage %", "Status"], (.[] | ["[" + .name + "](" + .vm_link + ")", .resource_group, .location, .cpu_percentage, .vm_status]) | @tsv' ${temp_file} | column -t -s $'\t'
            ${report}=    Set Variable    ${report}${formatted_results.stdout}
            
            RW.Core.Add To Report    ${report}
            
            # Add single issue with JSON details
            ${vms_json}=    Evaluate    json.dumps(${high_cpu_vms}, indent=4)    json
            ${vms_names_list}=    Evaluate    ["`" + vm['name'] + "`" for vm in ${vms_json}]
            ${vms_names}=    Evaluate    ", ".join(${vms_names_list})    modules=string
            RW.Core.Add Issue
            ...    severity=3
            ...    expected=Azure VMs should have CPU usage below ${HIGH_CPU_PERCENTAGE}% in resource group `${AZURE_RESOURCE_GROUP}`
            ...    actual=Found ${high_cpu_vms.__len__()} VMs with high CPU usage in resource group `${AZURE_RESOURCE_GROUP}`
            ...    title=High CPU Usage Detected in Resource Group `${AZURE_RESOURCE_GROUP}` in subscription `${AZURE_SUBSCRIPTION_NAME}`
            ...    reproduce_hint=${c7n_output.cmd}
            ...    details={"high_cpu_vms": ${vms_json}, "resource_group": "${AZURE_RESOURCE_GROUP}", "subscription_name": "${AZURE_SUBSCRIPTION_NAME}", "timeframe_hours": ${HIGH_CPU_TIMEFRAME}, "threshold_percentage": ${HIGH_CPU_PERCENTAGE}}
            ...    next_steps=Investigate high CPU usage and consider optimizing or resizing the VMs in resource group `${AZURE_RESOURCE_GROUP}`
            ...    summary=The issue identified ${high_cpu_vms.__len__()} VMs in the `${AZURE_RESOURCE_GROUP}` resource group within the `${AZURE_SUBSCRIPTION_NAME}` subscription exhibiting higher-than-expected CPU usage. Azure VMs were expected to maintain optimal utilization, but ${vms_names} showed elevated CPU usage over the past ${HIGH_CPU_TIMEFRAME} hours. Further action is needed to ensure CPU efficiency and assess whether configuration or workload adjustments are required.
            
            # Clean up temporary file
            RW.CLI.Run Cli    cmd=rm -f ${temp_file}
        END
        
        # Process VMs with metrics unavailable
        IF    ${metrics_unavailable_vms.__len__()} > 0
            ${report}=    Set Variable    \n=== VMs With CPU Metrics Unavailable ===\n
            # Create a temporary file for jq processing
            ${temp_file}=    Set Variable    ${OUTPUT_DIR}/cpu_metrics_unavailable_vms.json
            ${vm_data_json}=    Evaluate    json.dumps(${metrics_unavailable_vms})    json
            RW.CLI.Run Cli    cmd=echo '${vm_data_json.replace("'", "'\\''")}' > ${temp_file}
            
            # Generate formatted table
            ${formatted_results}=    RW.CLI.Run Cli
            ...    cmd=jq -r '["VM Name", "Resource Group", "Location", "VM Agent Status", "VM Status"], (.[] | ["[" + .name + "](" + .vm_link + ")", .resource_group, .location, .vm_agent_status, .vm_status]) | @tsv' ${temp_file} | column -t -s $'\t'
            ${report}=    Set Variable    ${report}${formatted_results.stdout}
            
            RW.Core.Add To Report    ${report}
            
            # Add single issue with JSON details
            ${vms_json}=    Evaluate    json.dumps(${metrics_unavailable_vms}, indent=4)    json
            ${vms_names_list}=    Evaluate    ["`" + vm['name'] + "`" for vm in ${vms_json}]
            ${vms_names}=    Evaluate    ", ".join(${vms_names_list})    modules=string
            RW.Core.Add Issue
            ...    severity=2
            ...    expected=Azure VMs should have CPU metrics available in resource group `${AZURE_RESOURCE_GROUP}`
            ...    actual=CPU metrics are not available for ${metrics_unavailable_vms.__len__()} VMs in resource group `${AZURE_RESOURCE_GROUP}`
            ...    title=CPU Metrics Unavailable for VMs in Resource Group `${AZURE_RESOURCE_GROUP}` in subscription `${AZURE_SUBSCRIPTION_NAME}`
            ...    reproduce_hint=${c7n_output.cmd}
            ...    details={"vms_without_metrics": ${vms_json}, "resource_group": "${AZURE_RESOURCE_GROUP}", "subscription_name": "${AZURE_SUBSCRIPTION_NAME}"}
            ...    next_steps=Check VM diagnostics and monitoring configurations in resource group `${AZURE_RESOURCE_GROUP}`
            ...    summary=CPU metrics were missing for ${metrics_unavailable_vms.__len__()} Azure VMs in the `${AZURE_RESOURCE_GROUP}` resource group. This indicates a gap in monitoring or diagnostics configuration that requires corrective action to restore proper metric collection for ${vms_names}.
            # Clean up temporary file
            RW.CLI.Run Cli    cmd=rm -f ${temp_file}
        END
        
        # If no VMs with high CPU usage or metrics unavailable
        IF    ${high_cpu_vms.__len__()} == 0 and ${metrics_unavailable_vms.__len__()} == 0
            RW.Core.Add Pre To Report    "No VMs with high CPU usage found in resource group `${AZURE_RESOURCE_GROUP}`"
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
    ...    timeout_seconds=180
    ${report_data}=    RW.CLI.Run Cli
    ...    cmd=cat ${OUTPUT_DIR}/azure-c7n-vm-health/under-utilized-vm-cpu-usage/resources.json

    TRY
        ${vm_list}=    Evaluate    json.loads(r'''${report_data.stdout}''')    json
    EXCEPT
        Log    Failed to load JSON payload, defaulting to empty list.    WARN
        ${vm_list}=    Create List
    END

    ${underutilized_vms}=    Create List
    ${metrics_unavailable_vms}=    Create List

    # Process VMs and collect data
    FOR    ${vm}    IN    @{vm_list}
        ${vm_name}=    Set Variable    ${vm['name']}
        ${resource_group}=    Set Variable    ${vm['resourceGroup'].lower()}
        ${json_str}=    Evaluate    json.dumps(${vm})    json
        
        # Check if metrics are available
        ${metrics_available}=    RW.CLI.Run Cli
        ...    cmd=echo '${json_str}' | jq -r '(."c7n:metrics" | to_entries | map(.value.measurement[0]) | first) != null'
        
        ${metrics_available_clean}=    Strip String    ${metrics_available.stdout}
        
        IF    "${metrics_available_clean}" == "true"
            ${cpu_percentage_result}=    RW.CLI.Run Cli
            ...    cmd=echo '${json_str}' | jq -r '(."c7n:metrics" | to_entries | map(.value.measurement[0]) | first // "0")'
            ${cpu_percentage}=    Convert To Number    ${cpu_percentage_result.stdout}    2
            
            ${vm_data}=    Create Dictionary
            ...    name=${vm_name}
            ...    resource_group=${resource_group}
            ...    location=${vm.get('location', 'N/A')}
            ...    cpu_percentage=${cpu_percentage}
            ...    vm_link=https://portal.azure.com/#@/resource${vm['id']}/overview
            ...    status=${vm.get('instanceView', {}).get('statuses', [{}])[0].get('code', 'Unknown')}
            ...    id=${vm.get('id', '')}
            
            Append To List    ${underutilized_vms}    ${vm_data}
        ELSE
            ${vm_agent_status}=    RW.CLI.Run Cli
            ...    cmd=echo '${json_str}' | jq -r '(.instanceView.vmAgent.statuses[0].code // "Unknown")'
            ${vm_status}=    RW.CLI.Run Cli
            ...    cmd=echo '${json_str}' | jq -r '(.instanceView.statuses[0].code // "Unknown")'
            
            ${vm_data}=    Create Dictionary
            ...    name=${vm_name}
            ...    resource_group=${resource_group}
            ...    location=${vm.get('location', 'N/A')}
            ...    vm_agent_status=${vm_agent_status.stdout}
            ...    vm_status=${vm_status.stdout}
            ...    vm_link=https://portal.azure.com/#@/resource${vm['id']}/overview
            ...    id=${vm.get('id', '')}
            
            Append To List    ${metrics_unavailable_vms}    ${vm_data}
        END
    END

    # Report underutilized VMs if any
    IF    ${underutilized_vms.__len__()} > 0
        ${report}=    Set Variable    \n=== Underutilized VMs (Low CPU Usage) ===\n
        ${temp_file}=    Set Variable    ${OUTPUT_DIR}/vm_cpu_data.json
        ${vm_data_json}=    Evaluate    json.dumps(${underutilized_vms})    json
        RW.CLI.Run Cli    cmd=echo '${vm_data_json.replace("'", "'\\''")}' > ${temp_file}
        
        ${formatted_results}=    RW.CLI.Run Cli
        ...    cmd=cat ${temp_file} | jq -r '["VM Name", "Resource Group", "Location", "CPU Usage %", "Status"], (.[] | ["[" + .name + "](" + .vm_link + ")", .resource_group, .location, (if .cpu_percentage == null then "N/A" else (.cpu_percentage | tostring + "%") end), .status]) | @tsv' | column -t -s '\t' -o ' | '
        
        ${report}=    Set Variable    ${report}${formatted_results.stdout}
        RW.CLI.Run Cli    cmd=rm -f ${temp_file}
        
        RW.Core.Add To Report    ${report}
        
        # Convert VMs to JSON for details
        ${vms_json}=    Evaluate    json.dumps(${underutilized_vms}, indent=4)    json
        ${vms_names_list}=    Evaluate    ["`" + vm['name'] + "`" for vm in ${vms_json}]
        ${vms_names}=    Evaluate    ", ".join(${vms_names_list})    modules=string
        RW.Core.Add Issue
        ...    severity=4
        ...    expected=Azure VMs should have adequate CPU utilization in resource group `${AZURE_RESOURCE_GROUP}`
        ...    actual=Found ${underutilized_vms.__len__()} underutilized VMs in resource group `${AZURE_RESOURCE_GROUP}`
        ...    title=Underutilized CPU on Azure VMs in Resource Group `${AZURE_RESOURCE_GROUP}` in subscription `${AZURE_SUBSCRIPTION_NAME}`
        ...    reproduce_hint=${c7n_output.cmd}
        ...    details={"underutilized_vms": ${vms_json}, "resource_group": "${AZURE_RESOURCE_GROUP}", "subscription_name": "${AZURE_SUBSCRIPTION_NAME}"}
        ...    next_steps=Consider downsizing or optimizing the VMs listed above to reduce costs
        ...    summary=The issue identified that the virtual machines ${vms_names} in resource group `${AZURE_RESOURCE_GROUP}` under subscription `${AZURE_SUBSCRIPTION_NAME}` showed significantly low CPU utilization compared to expected levels. This indicates the VMs are underutilized and may not be appropriately sized for their workloads. Actions are needed to reassess their configurations and determine if downsizing or workload adjustments are appropriate.
    END

    # Report VMs with metrics unavailable if any
    IF    ${metrics_unavailable_vms.__len__()} > 0
        ${metrics_report}=    Set Variable    \n=== VMs with CPU Metrics Unavailable ===\n\n
        FOR    ${vm}    IN    @{metrics_unavailable_vms}
            ${metrics_report}=    Set Variable    ${metrics_report}${vm['name']} (${vm['resource_group']}):\n
            ${metrics_report}=    Set Variable    ${metrics_report}  - Agent Status: ${vm['vm_agent_status']}\n
            ${metrics_report}=    Set Variable    ${metrics_report}  - VM Status: ${vm['vm_status']}\n\n
        END
        
        RW.Core.Add To Report    ${metrics_report}
        
        # Convert metrics unavailable VMs to JSON for details
        ${metrics_unavailable_json}=    Evaluate    json.dumps(${metrics_unavailable_vms}, indent=4)    json
        ${vms_names_list}=    Evaluate    ["`" + vm['name'] + "`" for vm in ${metrics_unavailable_json}]
        ${vms_names}=    Evaluate    ", ".join(${vms_names_list})    modules=string
        RW.Core.Add Issue
        ...    severity=2
        ...    expected=All VMs should have CPU metrics collection enabled
        ...    actual=Found ${metrics_unavailable_vms.__len__()} VMs with CPU metrics unavailable
        ...    title=${metrics_unavailable_vms.__len__()} VMs with CPU Metrics Unavailable in Resource Group `${AZURE_RESOURCE_GROUP}` in subscription `${AZURE_SUBSCRIPTION_NAME}`
        ...    reproduce_hint=${c7n_output.cmd}
        ...    details={"vms_without_cpu_metrics": ${metrics_unavailable_json}, "resource_group": "${AZURE_RESOURCE_GROUP}", "subscription_name": "${AZURE_SUBSCRIPTION_NAME}"}
        ...    next_steps=Check VM diagnostics and agent status for the VMs listed above
        ...    summary=CPU metrics were missing for ${metrics_unavailable_vms.__len__()} Azure VMs in the `${AZURE_RESOURCE_GROUP}` resource group. This indicates a gap in monitoring or diagnostics configuration that requires corrective action to restore proper metric collection for ${vms_names}.
    END

    # If no issues found
    IF    ${underutilized_vms.__len__()} == 0 and ${metrics_unavailable_vms.__len__()} == 0
        RW.Core.Add Pre To Report    "No underutilized VMs or CPU metrics issues found in resource group `${AZURE_RESOURCE_GROUP}`"
    END

List VMs With High Memory Usage in resource group `${AZURE_RESOURCE_GROUP}`
    [Documentation]    List Azure Virtual Machines (VMs) that have high memory usage based on a defined threshold and timeframe.
    [Tags]    VM    Azure    Memory    Performance    access:read-only
    CloudCustodian.Core.Generate Policy
    ...    ${CURDIR}/vm-memory-usage.j2
    ...    op=lt
    ...    memory_percentage=${HIGH_MEMORY_PERCENTAGE}
    ...    timeframe=${HIGH_MEMORY_TIMEFRAME}
    ...    resourceGroup=${AZURE_RESOURCE_GROUP}
    ...    subscriptionId=${AZURE_SUBSCRIPTION_ID}
    ${c7n_output}=    RW.CLI.Run Cli
    ...    cmd=custodian run -s ${OUTPUT_DIR}/azure-c7n-vm-health ${CURDIR}/vm-memory-usage.yaml --cache-period 0
    ...    timeout_seconds=180
    ${report_data}=    RW.CLI.Run Cli
    ...    cmd=cat ${OUTPUT_DIR}/azure-c7n-vm-health/vm-memory-usage/resources.json

    TRY
        ${vm_list}=    Evaluate    json.loads(r'''${report_data.stdout}''')    json
    EXCEPT
        Log    Failed to load JSON payload, defaulting to empty list.    WARN
        ${vm_list}=    Create List
    END

    ${high_memory_vms}=    Create List
    ${metrics_unavailable_vms}=    Create List
    
    IF    len(@{vm_list}) > 0
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
                
                ${vm_data}=    Create Dictionary
                ...    name=${vm['name']}
                ...    resource_group=${vm['resourceGroup']}
                ...    location=${vm['location']}
                ...    memory_usage_percent=${memory_percentage}
                ...    vm_status=${vm['instanceView']['statuses'][0]['code'] if 'instanceView' in ${vm} and 'statuses' in ${vm['instanceView']} and len(${vm['instanceView']['statuses']}) > 0 else 'Unknown'}
                ...    vm_link=https://portal.azure.com/#@/resource${vm['id']}/overview
                
                Append To List    ${high_memory_vms}    ${vm_data}
            ELSE
                ${vm_data}=    Create Dictionary
                ...    name=${vm['name']}
                ...    resource_group=${vm['resourceGroup']}
                ...    location=${vm['location']}
                ...    vm_agent_status=${vm['instanceView']['vmAgent']['statuses'][0]['code'] if 'instanceView' in ${vm} and 'vmAgent' in ${vm['instanceView']} and 'statuses' in ${vm['instanceView']['vmAgent']} and len(${vm['instanceView']['vmAgent']['statuses']}) > 0 else 'Unknown'}
                ...    vm_status=${vm['instanceView']['statuses'][0]['code'] if 'instanceView' in ${vm} and 'statuses' in ${vm['instanceView']} and len(${vm['instanceView']['statuses']}) > 0 else 'Unknown'}
                ...    vm_link=https://portal.azure.com/#@/resource${vm['id']}/overview
                
                Append To List    ${metrics_unavailable_vms}    ${vm_data}
            END
        END
        
        # Process VMs with high memory usage
        IF    ${high_memory_vms.__len__()} > 0
            ${report}=    Set Variable    \n=== VMs With High Memory Usage (Last ${HIGH_MEMORY_TIMEFRAME} hours) ===\n
            # Create a temporary file for jq processing
            ${temp_file}=    Set Variable    ${OUTPUT_DIR}/high_memory_vms.json
            ${vm_data_json}=    Evaluate    json.dumps(${high_memory_vms})    json
            RW.CLI.Run Cli    cmd=echo '${vm_data_json.replace("'", "'\\''")}' > ${temp_file}
            
            # Generate formatted table
            ${formatted_results}=    RW.CLI.Run Cli
            ...    cmd=jq -r '["VM Name", "Resource Group", "Location", "Memory Usage %", "Status"], (.[] | ["[" + .name + "](" + .vm_link + ")", .resource_group, .location, .memory_usage_percent, .vm_status]) | @tsv' ${temp_file} | column -t -s $'\t'
            ${report}=    Set Variable    ${report}${formatted_results.stdout}
            
            RW.Core.Add To Report    ${report}
            
            # Add single issue with JSON details
            ${vms_json}=    Evaluate    json.dumps(${high_memory_vms}, indent=4)    json
            ${vms_names_list}=    Evaluate    ["`" + vm['name'] + "`" for vm in ${vms_json}]
            ${vms_names}=    Evaluate    ", ".join(${vms_names_list})    modules=string
            RW.Core.Add Issue
            ...    severity=3
            ...    expected=Azure VMs should have optimal memory utilization in resource group `${AZURE_RESOURCE_GROUP}`
            ...    actual=Found ${high_memory_vms.__len__()} VMs with high memory usage in resource group `${AZURE_RESOURCE_GROUP}`
            ...    title=High Memory Usage Detected in Resource Group `${AZURE_RESOURCE_GROUP}` in subscription `${AZURE_SUBSCRIPTION_NAME}`
            ...    reproduce_hint=${c7n_output.cmd}
            ...    details={"high_memory_vms": ${vms_json}, "resource_group": "${AZURE_RESOURCE_GROUP}", "subscription_name": "${AZURE_SUBSCRIPTION_NAME}", "timeframe_hours": ${HIGH_MEMORY_TIMEFRAME}}
            ...    next_steps=Consider resizing the VMs to a larger SKU or optimizing memory usage in resource group `${AZURE_RESOURCE_GROUP}`
            ...    summary=The issue identified ${high_memory_vms.__len__()} VMs in the `${AZURE_RESOURCE_GROUP}` resource group within the `${AZURE_SUBSCRIPTION_NAME}` subscription exhibiting higher-than-expected memory usage. Azure VMs were expected to maintain optimal utilization, but ${vms_names} showed elevated memory consumption over the past ${HIGH_MEMORY_TIMEFRAME} hours. Further action is needed to ensure memory efficiency and assess whether configuration or workload adjustments are required.
            
            # Clean up temporary file
            RW.CLI.Run Cli    cmd=rm -f ${temp_file}
        END
        
        # Process VMs with metrics unavailable
        IF    ${metrics_unavailable_vms.__len__()} > 0
            ${report}=    Set Variable    \n=== VMs With Memory Metrics Unavailable ===\n
            # Create a temporary file for jq processing
            ${temp_file}=    Set Variable    ${OUTPUT_DIR}/metrics_unavailable_vms.json
            ${vm_data_json}=    Evaluate    json.dumps(${metrics_unavailable_vms})    json
            RW.CLI.Run Cli    cmd=echo '${vm_data_json.replace("'", "'\\''")}' > ${temp_file}
            
            # Generate formatted table
            ${formatted_results}=    RW.CLI.Run Cli
            ...    cmd=jq -r '["VM Name", "Resource Group", "Location", "VM Agent Status", "VM Status"], (.[] | ["[" + .name + "](" + .vm_link + ")", .resource_group, .location, .vm_agent_status, .vm_status]) | @tsv' ${temp_file} | column -t -s $'\t'
            ${report}=    Set Variable    ${report}${formatted_results.stdout}
            
            RW.Core.Add To Report    ${report}
            
            # Add single issue with JSON details
            ${vms_json}=    Evaluate    json.dumps(${metrics_unavailable_vms}, indent=4)    json
            ${vms_names_list}=    Evaluate    ["`" + vm['name'] + "`" for vm in ${vms_json}]
            ${vms_names}=    Evaluate    ", ".join(${vms_names_list})    modules=string
            RW.Core.Add Issue
            ...    severity=2
            ...    expected=Azure VMs should have memory metrics available in resource group `${AZURE_RESOURCE_GROUP}`
            ...    actual=Memory metrics are not available for ${metrics_unavailable_vms.__len__()} VMs in resource group `${AZURE_RESOURCE_GROUP}`
            ...    title=Memory Metrics Unavailable for VMs in Resource Group `${AZURE_RESOURCE_GROUP}` in subscription `${AZURE_SUBSCRIPTION_NAME}`
            ...    reproduce_hint=${c7n_output.cmd}
            ...    details={"vms_without_metrics": ${vms_json}, "resource_group": "${AZURE_RESOURCE_GROUP}", "subscription_name": "${AZURE_SUBSCRIPTION_NAME}"}
            ...    next_steps=Check VM diagnostics and monitoring configurations in resource group `${AZURE_RESOURCE_GROUP}`
            ...    summary=Memory metrics were missing for ${metrics_unavailable_vms.__len__()} Azure VMs in the `${AZURE_RESOURCE_GROUP}` resource group. This indicates a gap in monitoring or diagnostics configuration that requires corrective action to restore proper metric collection for ${vms_names}.
            
            # Clean up temporary file
            RW.CLI.Run Cli    cmd=rm -f ${temp_file}
        END
        
        # If no VMs with high memory usage or metrics unavailable
        IF    ${high_memory_vms.__len__()} == 0 and ${metrics_unavailable_vms.__len__()} == 0
            RW.Core.Add Pre To Report    "No VMs with high memory usage found in resource group `${AZURE_RESOURCE_GROUP}`"
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
    ...    timeout_seconds=180
    ${report_data}=    RW.CLI.Run Cli
    ...    cmd=cat ${OUTPUT_DIR}/azure-c7n-vm-health/vm-memory-usage/resources.json

    TRY
        ${vm_list}=    Evaluate    json.loads(r'''${report_data.stdout}''')    json
    EXCEPT
        Log    Failed to load JSON payload, defaulting to empty list.    WARN
        ${vm_list}=    Create List
    END

    ${underutilized_vms}=    Create List
    ${metrics_unavailable_vms}=    Create List

    FOR    ${vm}    IN    @{vm_list}
        ${vm_name}=    Set Variable    ${vm['name']}
        ${resource_group}=    Set Variable    ${vm['resourceGroup'].lower()}
        ${json_str}=    Evaluate    json.dumps(${vm})    json
        
        # Check if metrics are available
        ${metrics_available}=    RW.CLI.Run Cli
        ...    cmd=echo '${json_str}' | jq -r '(."c7n:metrics" | to_entries | map(.value.measurement[0]) | first) != null'
        
        ${metrics_available_clean}=    Strip String    ${metrics_available.stdout}
        
        IF    "${metrics_available_clean}" == "true"
            ${memory_percentage_result}=    RW.CLI.Run Cli
            ...    cmd=echo '${json_str}' | jq -r '(."c7n:metrics" | to_entries | map(.value.measurement[0]) | first // "0")'
            ${available_memory}=    Convert To Number    ${memory_percentage_result.stdout}    2
            ${memory_percentage}=    Evaluate    round(100 - ${available_memory}, 2)
            
            ${vm_data}=    Create Dictionary
            ...    name=${vm_name}
            ...    resource_group=${resource_group}
            ...    location=${vm.get('location', 'N/A')}
            ...    memory_percentage=${memory_percentage}
            ...    status=${vm.get('instanceView', {}).get('statuses', [{}])[0].get('code', 'Unknown')}
            ...    vm_link=https://portal.azure.com/#@/resource${vm['id']}/overview
            ...    id=${vm.get('id', '')}
            
            Append To List    ${underutilized_vms}    ${vm_data}
        ELSE
            ${vm_agent_status}=    RW.CLI.Run Cli
            ...    cmd=echo '${json_str}' | jq -r '(.instanceView.vmAgent.statuses[0].code // "Unknown")'
            ${vm_status}=    RW.CLI.Run Cli
            ...    cmd=echo '${json_str}' | jq -r '(.instanceView.statuses[0].code // "Unknown")'
            
            ${vm_data}=    Create Dictionary
            ...    name=${vm_name}
            ...    resource_group=${resource_group}
            ...    location=${vm.get('location', 'N/A')}
            ...    vm_agent_status=${vm_agent_status.stdout}
            ...    vm_status=${vm_status.stdout}
            ...    vm_link=https://portal.azure.com/#@/resource${vm['id']}/overview
            Append To List    ${metrics_unavailable_vms}    ${vm_data}
        END
    END

    # Report underutilized VMs if any
    IF    ${underutilized_vms.__len__()} > 0
        ${report}=    Set Variable    \n=== Underutilized VMs (High Available Memory) ===\n
        ${temp_file}=    Set Variable    ${OUTPUT_DIR}/vm_memory_data.json
        ${vm_data_json}=    Evaluate    json.dumps(${underutilized_vms})    json
        RW.CLI.Run Cli    cmd=echo '${vm_data_json.replace("'", "'\\''")}' > ${temp_file}
        
        ${formatted_results}=    RW.CLI.Run Cli
        ...    cmd=cat ${temp_file} | jq -r '["VM Name", "Resource Group", "Location", "Memory Used %", "Status"], (.[] | ["[" + .name + "](" + .vm_link + ")", .resource_group, .location, (if .memory_percentage == null then "N/A" else (.memory_percentage | tostring + "%") end), .status]) | @tsv' | column -t -s '\t' -o ' | '
        
        ${report}=    Set Variable    ${report}${formatted_results.stdout}
        RW.CLI.Run Cli    cmd=rm -f ${temp_file}
        
        RW.Core.Add To Report    ${report}
        ${vms_json}=    Evaluate    json.dumps(${underutilized_vms}, indent=4)    json
        ${vms_names_list}=    Evaluate    ["`" + vm['name'] + "`" for vm in ${vms_json}]
        ${vms_names}=    Evaluate    ", ".join(${vms_names_list})    modules=string
        RW.Core.Add Issue
        ...    severity=4
        ...    expected=Azure VMs should have optimal memory utilization in resource group `${resource_group}`
        ...    actual=Found ${underutilized_vms.__len__()} underutilized VMs in resource group `${resource_group}`
        ...    title=Underutilized Azure VMs Found in Resource Group `${AZURE_RESOURCE_GROUP}` in subscription `${AZURE_SUBSCRIPTION_NAME}`
        ...    reproduce_hint=${c7n_output.cmd}
        ...    details={"underutilized_vms": ${vms_json}, "resource_group": "${AZURE_RESOURCE_GROUP}", "subscription_name": "${AZURE_SUBSCRIPTION_NAME}"}
        ...    next_steps=Consider downsizing or optimizing the VMs listed above to reduce costs
        ...    summary=The issue identified ${underutilized_vms.__len__()} Azure VMs in the `${AZURE_RESOURCE_GROUP}` resource group within the `${AZURE_SUBSCRIPTION_NAME}` subscription exhibiting significantly low memory utilization compared to expected levels. Azure VMs were expected to maintain optimal utilization, but ${vms_names} showed low memory consumption over the past ${LOW_MEMORY_TIMEFRAME} hours. Further action is needed to ensure memory efficiency and assess whether configuration or workload adjustments are required.
    END

    # Report VMs with metrics unavailable if any
    IF    ${metrics_unavailable_vms.__len__()} > 0
        ${metrics_report}=    Set Variable    \n=== VMs with Metrics Unavailable ===\n\n
        FOR    ${vm}    IN    @{metrics_unavailable_vms}
            ${metrics_report}=    Set Variable    ${metrics_report}${vm['name']} (${vm['resource_group']}):\n
            ${metrics_report}=    Set Variable    ${metrics_report}  - Agent Status: ${vm['vm_agent_status']}\n
            ${metrics_report}=    Set Variable    ${metrics_report}  - VM Status: ${vm['vm_status']}\n\n
        END
        
        RW.Core.Add To Report    ${metrics_report}
        ${metrics_unavailable_json}=    Evaluate    json.dumps(${metrics_unavailable_vms}, indent=4)    json
        ${vms_names_list}=    Evaluate    ["`" + vm['name'] + "`" for vm in ${metrics_unavailable_json}]
        ${vms_names}=    Evaluate    ", ".join(${vms_names_list})    modules=string
        RW.Core.Add Issue
        ...    severity=2
        ...    expected=All VMs should have metrics collection enabled
        ...    actual=Found ${metrics_unavailable_vms.__len__()} VMs with metrics unavailable
        ...    title=${metrics_unavailable_vms.__len__()} VMs with Metrics Unavailable in Resource Group `${AZURE_RESOURCE_GROUP}` in subscription `${AZURE_SUBSCRIPTION_NAME}`
        ...    reproduce_hint=${c7n_output.cmd}
        ...    details={"metrics_unavailable_vms": ${metrics_unavailable_json}, "resource_group": "${AZURE_RESOURCE_GROUP}", "subscription_name": "${AZURE_SUBSCRIPTION_NAME}"}
        ...    next_steps=Check VM diagnostics and agent status for the VMs listed above
        ...    summary=Memory metrics were missing for ${metrics_unavailable_vms.__len__()} Azure VMs in the `${AZURE_RESOURCE_GROUP}` resource group. This indicates a gap in monitoring or diagnostics configuration that requires corrective action to restore proper metric collection for ${vms_names}.
    END

    # If no issues found
    IF    ${underutilized_vms.__len__()} == 0 and ${metrics_unavailable_vms.__len__()} == 0
        RW.Core.Add Pre To Report    "No underutilized VMs or metrics issues found in resource group `${AZURE_RESOURCE_GROUP}`"
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
    ...    timeout_seconds=180
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
            ...    summary=Network Interface `${nic_name}` in resource group `${resource_group}` was not attached to any virtual machine, although it was expected to be in use. This unused state indicates a misalignment between expected configuration and actual deployment. Action is needed to remove the unused interface to prevent unnecessary resource costs.
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
    ...    timeout_seconds=180
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
            ...    summary=Public IP `${ip_name}` is not attached to any resource in resource group `${resource_group}`, which violates the expectation that it should be attached to a resource or removed if unused. Keeping unused public IPs can incur unnecessary costs and may lead to accidental exposure if later attached without proper review.
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
    ...    timeout_seconds=180
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
            ...    summary=The Azure VM `${vm_name}` in resource group `${resource_group}` reported an unresponsive VM agent despite the VM provisioning and power states being healthy. The VM was expected to have a functioning agent but instead returned a `${vm_agent_status}` status. Further action is required to determine why the VM agent is not responding.
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
    ${AZURE_SUBSCRIPTION_NAME}=    RW.Core.Import User Variable    AZURE_SUBSCRIPTION_NAME
    ...    type=string
    ...    description=Azure subscription name.
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
    Set Suite Variable    ${AZURE_SUBSCRIPTION_NAME}    ${AZURE_SUBSCRIPTION_NAME}
    
    # Set Azure subscription context for Cloud Custodian
    RW.CLI.Run Cli
    ...    cmd=az account set --subscription ${AZURE_SUBSCRIPTION_ID}
    ...    include_in_history=false
    
    Set Suite Variable
    ...    ${env}
    ...    {"AZURE_RESOURCE_GROUP":"${AZURE_RESOURCE_GROUP}", "AZURE_SUBSCRIPTION_ID":"${AZURE_SUBSCRIPTION_ID}"}