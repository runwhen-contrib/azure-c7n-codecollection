*** Settings ***
Documentation       Check Azure storage health by identifying unused disks, snapshots, and storage accounts
Metadata            Author    saurabh3460
Metadata            Display Name    Azure    Storage
Metadata            Supports    Azure    Storage    Health
Force Tags          Azure    Storage    Health

Library    String
Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library    CloudCustodian.Core

Suite Setup         Suite Initialization
*** Tasks ***
Count Azure Storage Accounts with Health Status of `Available` in resource group `${AZURE_RESOURCE_GROUP}`
    [Documentation]    Count Azure storage accounts with health status of `Available`
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
    ${count}=    Evaluate    len([health for health in ${health_list} if health['properties']['availabilityState'] == 'Available'])
    ${available_storage_score}=    Evaluate    1 if int(${count}) >= 1 else 0
    Set Global Variable    ${available_storage_score}

Count Unused Disks in resource group `${AZURE_RESOURCE_GROUP}`
    [Documentation]    Count disks that are not attached to any VM
    [Tags]    Disk    Azure    Storage    Cost    access:read-only
    CloudCustodian.Core.Generate Policy   
    ...    ${CURDIR}/unused-disk.j2
    ...    resourceGroup=${AZURE_RESOURCE_GROUP}
    ${c7n_output}=    RW.CLI.Run Cli
    ...    cmd=custodian run -s ${OUTPUT_DIR}/azure-c7n-disk-triage ${CURDIR}/unused-disk.yaml --cache-period 0
    ${count}=    RW.CLI.Run Cli
    ...    cmd=cat ${OUTPUT_DIR}/azure-c7n-disk-triage/unused-disk/metadata.json | jq '.metrics[] | select(.MetricName == "ResourceCount") | .Value';
    ${unused_disk_score}=    Evaluate    1 if int(${count.stdout}) <= int(${MAX_UNUSED_DISK}) else 0
    Set Global Variable    ${unused_disk_score}

Count Unused Snapshots in resource group `${AZURE_RESOURCE_GROUP}`
    [Documentation]    Count snapshots that are not attached to any disk
    [Tags]    Snapshot    Azure    Storage    Cost    access:read-only
    CloudCustodian.Core.Generate Policy   
    ...    ${CURDIR}/unused-snapshot.j2
    ...    resourceGroup=${AZURE_RESOURCE_GROUP}
    ${c7n_output}=    RW.CLI.Run Cli
    ...    cmd=custodian run -s ${OUTPUT_DIR}/azure-c7n-snapshot-triage ${CURDIR}/unused-snapshot.yaml --cache-period 0
    ${count}=    RW.CLI.Run Cli
    ...    cmd=cat ${OUTPUT_DIR}/azure-c7n-snapshot-triage/unused-snapshot/metadata.json | jq '.metrics[] | select(.MetricName == "ResourceCount") | .Value';
    ${unused_snapshot_score}=    Evaluate    1 if int(${count.stdout}) <= int(${MAX_UNUSED_SNAPSHOT}) else 0
    Set Global Variable    ${unused_snapshot_score}

Count Unused Storage Accounts in resource group `${AZURE_RESOURCE_GROUP}`
    [Documentation]    Count storage accounts with no transactions
    [Tags]    Storage    Azure    Cost    access:read-only
    CloudCustodian.Core.Generate Policy   
    ...    ${CURDIR}/unused-storage-account.j2
    ...    timeframe=${UNUSED_STORAGE_ACCOUNT_TIMEFRAME}
    ...    resourceGroup=${AZURE_RESOURCE_GROUP}
    ${c7n_output}=    RW.CLI.Run Cli
    ...    cmd=custodian run -s ${OUTPUT_DIR}/azure-c7n-storage-triage ${CURDIR}/unused-storage-account.yaml --cache-period 0
    ${count}=    RW.CLI.Run Cli
    ...    cmd=cat ${OUTPUT_DIR}/azure-c7n-storage-triage/unused-storage-account/metadata.json | jq '.metrics[] | select(.MetricName == "ResourceCount") | .Value';
    ${unused_storage_account_score}=    Evaluate    1 if int(${count.stdout}) <= int(${MAX_UNUSED_STORAGE_ACCOUNT}) else 0
    Set Global Variable    ${unused_storage_account_score}


Count Storage Containers with Public Access in resource group `${AZURE_RESOURCE_GROUP}`
    [Documentation]    Count storage containers with public access enabled
    [Tags]    Storage    Azure    Security    access:read-only
    CloudCustodian.Core.Generate Policy   
    ...    stg-containers-with-public-access.j2
    ...    resourceGroup=${AZURE_RESOURCE_GROUP}
    ${c7n_output}=    RW.CLI.Run Cli
    ...    cmd=custodian run -s azure-c7n-storage-containers-public-access stg-containers-with-public-access.yaml --cache-period 0
    ${count}=    RW.CLI.Run Cli
    ...    cmd=cat azure-c7n-storage-containers-public-access/storage-container-public/metadata.json | jq '.metrics[] | select(.MetricName == "ResourceCount") | .Value';
    ${public_access_container_score}=    Evaluate    1 if int(${count.stdout}) <= int(${MAX_PUBLIC_ACCESS_STORAGE_ACCOUNT}) else 0
    Set Global Variable    ${public_access_container_score}


Generate Health Score
    ${health_score}=    Evaluate  (${unused_snapshot_score} + ${unused_disk_score} + ${unused_storage_account_score} + ${public_access_container_score} + ${available_storage_score}) / 5
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
    ${MAX_UNUSED_DISK}=    RW.Core.Import User Variable    MAX_UNUSED_DISK
    ...    type=string
    ...    description=The maximum number of unused disks allowed in the subscription.
    ...    pattern=^\d+$
    ...    example=1
    ...    default=0
    ${MAX_UNUSED_SNAPSHOT}=    RW.Core.Import User Variable    MAX_UNUSED_SNAPSHOT
    ...    type=string
    ...    description=The maximum number of unused snapshots allowed in the subscription.
    ...    pattern=^\d+$
    ...    example=1
    ...    default=0
    ${UNUSED_STORAGE_ACCOUNT_TIMEFRAME}=    RW.Core.Import User Variable    UNUSED_STORAGE_ACCOUNT_TIMEFRAME
    ...    type=string
    ...    description=The timeframe in hours to check for unused storage accounts (e.g., 720 for 30 days)
    ...    pattern=\d+
    ...    default=24
    ${MAX_UNUSED_STORAGE_ACCOUNT}=    RW.Core.Import User Variable    MAX_UNUSED_STORAGE_ACCOUNT
    ...    type=string
    ...    description=The maximum number of unused storage accounts allowed in the subscription.
    ...    pattern=^\d+$
    ...    example=1
    ...    default=0
    ${MAX_PUBLIC_ACCESS_STORAGE_ACCOUNT}=    RW.Core.Import User Variable    MAX_PUBLIC_ACCESS_STORAGE_ACCOUNT
    ...    type=string
    ...    description=The maximum number of storage accounts with public access allowed in the subscription.
    ...    pattern=^\d+$
    ...    example=1
    ...    default=0
    Set Suite Variable    ${AZURE_SUBSCRIPTION_ID}    ${AZURE_SUBSCRIPTION_ID}
    Set Suite Variable    ${MAX_UNUSED_DISK}    ${MAX_UNUSED_DISK}
    Set Suite Variable    ${MAX_UNUSED_SNAPSHOT}    ${MAX_UNUSED_SNAPSHOT}
    set Suite Variable    ${UNUSED_STORAGE_ACCOUNT_TIMEFRAME}    ${UNUSED_STORAGE_ACCOUNT_TIMEFRAME}
    Set Suite Variable    ${MAX_UNUSED_STORAGE_ACCOUNT}    ${MAX_UNUSED_STORAGE_ACCOUNT}
    Set Suite Variable    ${MAX_PUBLIC_ACCESS_STORAGE_ACCOUNT}    ${MAX_PUBLIC_ACCESS_STORAGE_ACCOUNT}
    Set Suite Variable    ${AZURE_RESOURCE_GROUP}    ${AZURE_RESOURCE_GROUP}
    Set Suite Variable
    ...    ${env}
    ...    {"AZURE_RESOURCE_GROUP":"${AZURE_RESOURCE_GROUP}", "AZURE_SUBSCRIPTION_ID":"${AZURE_SUBSCRIPTION_ID}"}