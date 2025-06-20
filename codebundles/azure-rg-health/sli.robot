*** Settings ***
Documentation       Count unused Azure resource groups and tag compliance
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
    Set Global Variable    ${unused_rg_score}
    RW.CLI.Run Cli    cmd=rm unused-rgs.json

Count Azure Resource Tag Compliance
    [Documentation]    Count resources that are missing required tags across resource groups
    [Tags]    Azure    ResourceGroup    Tags    Compliance    access:read-only

    ${output}=    RW.CLI.Run Bash File
    ...    bash_file=tag-compliance.sh
    ...    env=${env}
    ...    timeout_seconds=600
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true

    ${report_data}=    RW.CLI.Run Cli
    ...    cmd=cat tag-compliance-report.json

    TRY
        ${tag_report}=    Evaluate    json.loads(r'''${report_data.stdout}''')    json
        ${non_compliant_count}=    Get Length    ${tag_report['non_compliant_resources']}
    EXCEPT
        Log    Failed to parse JSON. Defaulting to 0 non-compliant resources.    WARN
        ${non_compliant_count}=    Set Variable    0
    END

    ${non_compliant_score}=    Evaluate    1 if int(${non_compliant_count}) <= int(${MAX_NON_COMPLIANT}) else 0
    Set Global Variable    ${non_compliant_score}
    RW.CLI.Run Cli    cmd=rm tag-compliance-report.json

Generate Health Score
    ${health_score}=    Evaluate  (${unused_rg_score} + ${non_compliant_score}) / 2
    ${health_score}=    Convert to Number    ${health_score}    2
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
    ${TAGS}=    RW.Core.Import User Variable    TAGS
    ...    type=string
    ...    description=Tags to check for tag compliance
    ...    pattern=\w*
    ...    default=Name,Environment,Owner
    ...    example=Name,Environment,Owner
    ${RESOURCE_GROUPS}=    RW.Core.Import User Variable    RESOURCE_GROUPS
    ...    type=string
    ...    description=Azure resource group to check tag compliance
    ...    pattern=\w*
    ...    default=DefaultResourceGroup-CCAN
    ...    example=rg1,rg2
    ${MAX_NON_COMPLIANT}=    RW.Core.Import User Variable    MAX_NON_COMPLIANT
    ...    type=string
    ...    description=The maximum number of non-compliant resources to allow.
    ...    pattern=^\d+$
    ...    example=1
    ...    default=0
    Set Suite Variable    ${AZURE_SUBSCRIPTION_ID}    ${AZURE_SUBSCRIPTION_ID}
    Set Suite Variable    ${AZURE_RESOURCE_GROUP}    ${AZURE_RESOURCE_GROUP}
    Set Suite Variable    ${MAX_UNUSED_RG}    ${MAX_UNUSED_RG}
    Set Suite Variable    ${LOOKBACK_DAYS}    ${LOOKBACK_DAYS}
    Set Suite Variable    ${TAGS}    ${TAGS}
    Set Suite Variable    ${RESOURCE_GROUPS}    ${RESOURCE_GROUPS}
    Set Suite Variable    ${MAX_NON_COMPLIANT}    ${MAX_NON_COMPLIANT}
    Set Suite Variable
    ...    ${env}
    ...    {"AZURE_RESOURCE_GROUP":"${AZURE_RESOURCE_GROUP}", "AZURE_SUBSCRIPTION_ID":"${AZURE_SUBSCRIPTION_ID}", "DAYS":"${LOOKBACK_DAYS}", "TAGS":"${TAGS}", "RESOURCE_GROUPS":"${RESOURCE_GROUPS}", "MAX_NON_COMPLIANT":"${MAX_NON_COMPLIANT}"}