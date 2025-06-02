*** Settings ***
Documentation       Count unused resource groups in Azure
Metadata            Author    saurabh3460
Metadata            Display Name    Azure Resource Group Health
Metadata            Supports    Azure    Resource Group    Health    CloudCustodian
Force Tags          Azure    Resource Group    Health    CloudCustodian

Library    String
Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library    CloudCustodian.Core
Library    Collections

Suite Setup         Suite Initialization
*** Tasks ***
Count Unused Resource Groups in resource group `${AZURE_RESOURCE_GROUP}`
    [Documentation]    Count resource groups that are unused (no resources and no activity in the last N days)
    [Tags]    Azure    ResourceGroup    Cost    access:read-only

    ${output}=    RW.CLI.Run Bash File
    ...    bash_file=unused-rg.sh
    ...    env=${env}
    ...    timeout_seconds=300
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true

    ${report_data}=    RW.CLI.Run Cli
    ...    cmd=cat unused-rgs.json

    TRY
        ${rg_report}=    Evaluate    json.loads(r'''${report_data.stdout}''')    json
        ${unused_count}=    Set Variable    ${rg_report['metadata']['unused_resource_groups_count']}
    EXCEPT
        Log    Failed to parse JSON. Defaulting to 0 unused RGs.    WARN
        ${unused_count}=    Set Variable    0
    END

    ${unused_rg_score}=    Evaluate    1 if int(${unused_count}) <= int(${MAX_UNUSED_RG}) else 0
    ${health_score}=    Convert to Number    ${unused_rg_score}    2
    RW.Core.Push Metric    ${health_score}


# Generate Health Score
#     # ${health_score}=    Evaluate  (${unused_rg_score}) / 1
#     # ${health_score}=    Convert to Number    ${health_score}    2
#     # RW.Core.Push Metric    ${health_score}


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
    ${MAX_UNUSED_RG}=    RW.Core.Import User Variable    MAX_UNUSED_RG
    ...    type=string
    ...    description=The maximum number of unused resource groups to allow.
    ...    pattern=^\d+$
    ...    example=1
    ...    default=0
    ${LOOKBACK_DAYS}=    RW.Core.Import User Variable    LOOKBACK_DAYS
    ...    type=string
    ...    description=Number of days to look back for activity.
    ...    pattern=\d*
    ...    example=30
    ...    default=30
    Set Suite Variable    ${AZURE_SUBSCRIPTION_ID}    ${AZURE_SUBSCRIPTION_ID}
    Set Suite Variable    ${AZURE_RESOURCE_GROUP}    ${AZURE_RESOURCE_GROUP}
    Set Suite Variable    ${MAX_UNUSED_RG}    ${MAX_UNUSED_RG}
    Set Suite Variable    ${LOOKBACK_DAYS}    ${LOOKBACK_DAYS}
    Set Suite Variable
    ...    ${env}
    ...    {"AZURE_RESOURCE_GROUP":"${AZURE_RESOURCE_GROUP}", "AZURE_SUBSCRIPTION_ID":"${AZURE_SUBSCRIPTION_ID}", "DAYS":"${LOOKBACK_DAYS}"}