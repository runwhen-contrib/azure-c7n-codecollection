*** Settings ***
Documentation       Check Azure storage health by identifying unused disks, snapshots, and storage accounts
Metadata            Author    saurabh3460
Metadata            Display Name    Azure    Storage Health
Metadata            Supports    Azure    Storage Health
Force Tags          Azure    Storage Health

Library    String
Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library    CloudCustodian.Core

Suite Setup         Suite Initialization


*** Tasks ***
List Azure Storage Health in resource group `${AZURE_RESOURCE_GROUP}`
    [Documentation]    List Azure storage health by identifying unused disks, snapshots, and storage accounts
    [Tags]    Storage    Azure    Health    access:read-only
    ${output}=    RW.CLI.Run Bash File
    ...    bash_file=azure_storage_health_check.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ${report_data}=    RW.CLI.Run Cli
    ...    cmd=cat storage_health.json
    TRY
        ${health_list}=    Evaluate    json.loads(r'''${report_data.stdout}''')    json
    EXCEPT
        Log    Failed to load JSON payload, defaulting to empty list.    WARN
        ${health_list}=    Create List
    END
    IF    len(@{health_list}) > 0

        FOR    ${health}    IN    @{health_list}
            ${pretty_health}=    Evaluate    pprint.pformat(${health})    modules=pprint
            ${storage_name}=    Set Variable    ${health['resourceName']}
            ${health_status}=    Set Variable    ${health['properties']['availabilityState']}
            IF    "${health_status}" != "Available"
                RW.Core.Add Issue
                ...    severity=3
                ...    expected=Azure storage account `${storage_name}` should have health status of `Available` in resource group `${AZURE_RESOURCE_GROUP}` 
                ...    actual=Azure storage account `${storage_name}` has health status of `${health_status}` in resource group `${AZURE_RESOURCE_GROUP}` 
                ...    title=Azure Storage Account `${storage_name}` with Health Status of `${health_status}` found in Resource Group `${AZURE_RESOURCE_GROUP}` 
                ...    reproduce_hint=${output.cmd}
                ...    details=${pretty_health}
                ...    next_steps=Investigate the health status of the Azure Storage Account in resource group `${AZURE_RESOURCE_GROUP}` 
            END
        END
    ELSE
        RW.Core.Add Issue
        ...    severity=4
        ...    expected=Azure Storage account health should be enabled in resource group `${AZURE_RESOURCE_GROUP}` in subscription `${AZURE_RESOURCE_GROUP}`
        ...    actual=Azure Storage account health appears unavailable in resource group `${AZURE_RESOURCE_GROUP}` in subscription `${AZURE_RESOURCE_GROUP}`
        ...    title=Azure resource health is unavailable for Azure Storage account in resource group `${AZURE_RESOURCE_GROUP}`
        ...    reproduce_hint=$${output.cmd}
        ...    details=${health_list}
        ...    next_steps=Please escalate to the Azure service owner to enable provider Microsoft.ResourceHealth.
    END

List Unused Azure Disks in resource group `${AZURE_RESOURCE_GROUP}`
    [Documentation]    List Azure disks that are not attached to any VM
    [Tags]    Disk    Azure    Storage    Cost    access:read-only
    CloudCustodian.Core.Generate Policy   
    ...    ${CURDIR}/unused-disk.j2
    ...    resourceGroup=${AZURE_RESOURCE_GROUP}
    ${c7n_output}=    RW.CLI.Run Cli
    ...    cmd=custodian run -s ${OUTPUT_DIR}/azure-c7n-disk-triage ${CURDIR}/unused-disk.yaml --cache-period 0
    ${report_data}=    RW.CLI.Run Cli
    ...    cmd=cat ${OUTPUT_DIR}/azure-c7n-disk-triage/unused-disk/resources.json

    TRY
        ${disk_list}=    Evaluate    json.loads(r'''${report_data.stdout}''')    json
    EXCEPT
        Log    Failed to load JSON payload, defaulting to empty list.    WARN
        ${disk_list}=    Create List
    END

    IF    len(@{disk_list}) > 0
        ${formatted_results}=    RW.CLI.Run Cli
        ...    cmd=jq -r '["Disk_Name", "Resource_Group", "Location", "Size_GB", "Disk_Link"], (.[] | [ .name, (.resourceGroup | ascii_downcase), .location, .properties.diskSizeGB, ("https://portal.azure.com/#@/resource" + .id + "/overview") ]) | @tsv' ${OUTPUT_DIR}/azure-c7n-disk-triage/unused-disk/resources.json | column -t
        RW.Core.Add Pre To Report    Unused Disks Summary:\n========================\n${formatted_results.stdout}

        FOR    ${disk}    IN    @{disk_list}
            ${pretty_disk}=    Evaluate    pprint.pformat(${disk})    modules=pprint
            ${resource_group}=    Set Variable    ${disk['resourceGroup'].lower()}
            ${disk_name}=    Set Variable    ${disk['name']}
            ${disk_size}=    Set Variable    ${disk['properties']['diskSizeGB']}
            RW.Core.Add Issue
            ...    severity=4
            ...    expected=Azure disk `${disk_name}` should be attached to a VM in resource group `${resource_group}` 
            ...    actual=Azure disk `${disk_name}` is not attached to any VM in resource group `${resource_group}` 
            ...    title=Unused Azure Disk `${disk_name}` found in Resource Group `${resource_group}` 
            ...    reproduce_hint=${c7n_output.cmd}
            ...    details=${pretty_disk}
            ...    next_steps=Delete the unused disk to reduce storage costs in resource group `${resource_group}` 
        END
    ELSE
        RW.Core.Add Pre To Report    "No unused disks found in resource group `${AZURE_RESOURCE_GROUP}`"
    END

List Unused Azure Snapshots in resource group `${AZURE_RESOURCE_GROUP}`
    [Documentation]    List Azure snapshots that are not attached
    [Tags]    Snapshot    Azure    Storage    Cost    access:read-only
    CloudCustodian.Core.Generate Policy   
    ...    ${CURDIR}/unused-snapshot.j2
    ...    resourceGroup=${AZURE_RESOURCE_GROUP}
    ${c7n_output}=    RW.CLI.Run Cli
    ...    cmd=custodian run -s ${OUTPUT_DIR}/azure-c7n-snapshot-triage ${CURDIR}/unused-snapshot.yaml --cache-period 0
    ${report_data}=    RW.CLI.Run Cli
    ...    cmd=cat ${OUTPUT_DIR}/azure-c7n-snapshot-triage/unused-snapshot/resources.json

    TRY
        ${snapshot_list}=    Evaluate    json.loads(r'''${report_data.stdout}''')    json
    EXCEPT
        Log    Failed to load JSON payload, defaulting to empty list.    WARN
        ${snapshot_list}=    Create List
    END

    IF    len(@{snapshot_list}) > 0
        ${formatted_results}=    RW.CLI.Run Cli
        ...    cmd=jq -r '["Snapshot_Name", "Resource_Group", "Location", "Size_GB", "Snapshot_Link"], (.[] | [ .name, (.resourceGroup | ascii_downcase), .location, .properties.diskSizeGB, ("https://portal.azure.com/#@/resource" + .id + "/overview") ]) | @tsv' ${OUTPUT_DIR}/azure-c7n-snapshot-triage/unused-snapshot/resources.json | column -t
        RW.Core.Add Pre To Report    Unused Snapshots Summary:\n========================\n${formatted_results.stdout}

        FOR    ${snapshot}    IN    @{snapshot_list}
            ${pretty_snapshot}=    Evaluate    pprint.pformat(${snapshot})    modules=pprint
            ${resource_group}=    Set Variable    ${snapshot['resourceGroup'].lower()}
            ${snapshot_name}=    Set Variable    ${snapshot['name']}
            ${snapshot_size}=    Set Variable    ${snapshot['properties']['diskSizeGB']}
            RW.Core.Add Issue
            ...    severity=4
            ...    expected=Azure snapshot `${snapshot_name}` should be attached to a disk in resource group `${resource_group}` 
            ...    actual=Azure snapshot `${snapshot_name}` is not attached to any disk in resource group `${resource_group}` 
            ...    title=Unused Azure Snapshot `${snapshot_name}` found in Resource Group `${resource_group}` 
            ...    reproduce_hint=${c7n_output.cmd}
            ...    details=${pretty_snapshot}
            ...    next_steps=Delete the unused snapshot to reduce storage costs in resource group `${resource_group}` 
        END
    ELSE
        RW.Core.Add Pre To Report    "No unused snapshots found in resource group `${AZURE_RESOURCE_GROUP}`"
    END

List Unused Azure Storage Accounts in resource group `${AZURE_RESOURCE_GROUP}`
    [Documentation]    List Azure storage accounts with no transactions
    [Tags]    Storage    Azure    Cost    access:read-only
    CloudCustodian.Core.Generate Policy   
    ...    ${CURDIR}/unused-storage-account.j2
    ...    timeframe=${UNUSED_STORAGE_ACCOUNT_TIMEFRAME}
    ...    resourceGroup=${AZURE_RESOURCE_GROUP}
    ${c7n_output}=    RW.CLI.Run Cli
    ...    cmd=custodian run -s ${OUTPUT_DIR}/azure-c7n-storage-triage ${CURDIR}/unused-storage-account.yaml --cache-period 0
    ${report_data}=    RW.CLI.Run Cli
    ...    cmd=cat ${OUTPUT_DIR}/azure-c7n-storage-triage/unused-storage-account/resources.json

    TRY
        ${storage_list}=    Evaluate    json.loads(r'''${report_data.stdout}''')    json
    EXCEPT
        Log    Failed to load JSON payload, defaulting to empty list.    WARN
        ${storage_list}=    Create List
    END

    IF    len(@{storage_list}) > 0
        ${formatted_results}=    RW.CLI.Run Cli
        ...    cmd=jq -r '["Storage_Name", "Resource_Group", "Location", "Transactions", "Storage_Link"], (.[] | [ .name, (.resourceGroup | ascii_downcase), .location, (."c7n:metrics" | to_entries | map(.value.measurement[0]) | first // 0 | tonumber | (. * 100 | round / 100) | tostring), ("https://portal.azure.com/#@/resource" + .id + "/overview") ]) | @tsv' ${OUTPUT_DIR}/azure-c7n-storage-triage/unused-storage-account/resources.json | column -t
        RW.Core.Add Pre To Report    Unused Storage Accounts Summary:\n========================\n${formatted_results.stdout}

        FOR    ${storage}    IN    @{storage_list}
            ${pretty_storage}=    Evaluate    pprint.pformat(${storage})    modules=pprint
            ${resource_group}=    Set Variable    ${storage['resourceGroup'].lower()}
            ${storage_name}=    Set Variable    ${storage['name']}
            RW.Core.Add Issue
            ...    severity=4
            ...    expected=Azure storage account `${storage_name}` should have transactions in resource group `${resource_group}` 
            ...    actual=Azure storage account `${storage_name}` has no transactions in the last `${UNUSED_STORAGE_ACCOUNT_TIMEFRAME}` hours in resource group `${resource_group}` 
            ...    title=Unused Azure Storage Account `${storage_name}` found in Resource Group `${resource_group}` 
            ...    reproduce_hint=${c7n_output.cmd}
            ...    details=${pretty_storage}
            ...    next_steps=Delete the unused storage account to reduce storage costs in resource group ``${resource_group}` 
        END
    ELSE
        RW.Core.Add Pre To Report    "No unused storage accounts found in resource group `${AZURE_RESOURCE_GROUP}`"
    END

List Public Accessible Azure Storage Accounts in resource group `${AZURE_RESOURCE_GROUP}`
    [Documentation]    List Azure storage accounts with public access enabled
    [Tags]    Storage    Azure    Security    access:read-only
    CloudCustodian.Core.Generate Policy   
    ...    ${CURDIR}/storage-accounts-with-public-access.j2
    ...    resourceGroup=${AZURE_RESOURCE_GROUP}
    ${c7n_output}=    RW.CLI.Run Cli
    ...    cmd=custodian run -s ${OUTPUT_DIR}/azure-c7n-storage-public-access ${CURDIR}/storage-accounts-with-public-access.yaml --cache-period 0
    ${report_data}=    RW.CLI.Run Cli
    ...    cmd=cat ${OUTPUT_DIR}/azure-c7n-storage-public-access/storage-accounts-with-public-access/resources.json

    TRY
        ${storage_list}=    Evaluate    json.loads(r'''${report_data.stdout}''')    json
    EXCEPT
        Log    Failed to load JSON payload, defaulting to empty list.    WARN
        ${storage_list}=    Create List
    END

    IF    len(@{storage_list}) > 0
        ${formatted_results}=    RW.CLI.Run Cli
        ...    cmd=jq -r '["Storage_Name", "Resource_Group", "Location", "Public_Access", "Storage_Link"], (.[] | [ .name, (.resourceGroup | ascii_downcase), .location, (.properties.networkAcls.defaultAction), ("https://portal.azure.com/#@/resource" + .id + "/overview") ]) | @tsv' ${OUTPUT_DIR}/azure-c7n-storage-public-access/storage-accounts-with-public-access/resources.json | column -t
        RW.Core.Add Pre To Report    Public Accessible Storage Accounts Summary:\n========================\n${formatted_results.stdout}

        FOR    ${storage}    IN    @{storage_list}
            ${pretty_storage}=    Evaluate    pprint.pformat(${storage})    modules=pprint
            ${resource_group}=    Set Variable    ${storage['resourceGroup'].lower()}
            ${storage_name}=    Set Variable    ${storage['name']}
            RW.Core.Add Issue
            ...    severity=4
            ...    expected=Azure storage account `${storage_name}` should have restricted public access in resource group `${resource_group}` 
            ...    actual=Azure storage account `${storage_name}` has public access enabled in resource group `${resource_group}` 
            ...    title=Public Accessible Azure Storage Account `${storage_name}` found in Resource Group `${resource_group}` 
            ...    reproduce_hint=${c7n_output.cmd}
            ...    details=${pretty_storage}
            ...    next_steps=Restrict public access to the storage account to improve security in resource group `${resource_group}`
        END
    ELSE
        RW.Core.Add Pre To Report    "No public accessible storage accounts found in resource group `${AZURE_RESOURCE_GROUP}`"
    END


*** Keywords ***
Suite Initialization
    ${azure_credentials}=    RW.Core.Import Secret
    ...    azure_credentials
    ...    type=string
    ...    description=The secret containing AZURE_CLIENT_ID, AZURE_TENANT_ID, AZURE_CLIENT_SECRET, AZURE_SUBSCRIPTION_ID
    ...    pattern=\w*
    ${AZURE_RESOURCE_GROUP}=    RW.Core.Import User Variable    AZURE_RESOURCE_GROUP
    ...    type=string
    ...    description=Azure resource group.
    ...    pattern=\w*
    ${AZURE_SUBSCRIPTION_ID}=    RW.Core.Import User Variable    AZURE_SUBSCRIPTION_ID
    ...    type=string
    ...    description=The Azure Subscription ID for the resource.  
    ...    pattern=\w*
    ...    default=""
    ${UNUSED_STORAGE_ACCOUNT_TIMEFRAME}=    RW.Core.Import User Variable    UNUSED_STORAGE_ACCOUNT_TIMEFRAME
    ...    type=string
    ...    description=The timeframe in hours to check for unused storage accounts (e.g., 720 for 30 days)
    ...    pattern=\d+
    ...    default=24
    Set Suite Variable    ${AZURE_SUBSCRIPTION_ID}    ${AZURE_SUBSCRIPTION_ID}
    Set Suite Variable    ${AZURE_RESOURCE_GROUP}    ${AZURE_RESOURCE_GROUP}
    Set Suite Variable    ${UNUSED_STORAGE_ACCOUNT_TIMEFRAME}    ${UNUSED_STORAGE_ACCOUNT_TIMEFRAME}
    Set Suite Variable
    ...    ${env}
    ...    {"AZURE_RESOURCE_GROUP":"${AZURE_RESOURCE_GROUP}", "AZURE_SUBSCRIPTION_ID":"${AZURE_SUBSCRIPTION_ID}"}
