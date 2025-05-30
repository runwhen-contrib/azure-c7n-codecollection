*** Settings ***
Documentation       List unused Azure resource groups (no resources and no activity in the last N days)
Metadata            Author    saurabh3460
Metadata            Display Name    Azure Resource Group Health
Metadata            Supports    Azure    Resource Group    Health
Force Tags          Azure    Resource Group    Health

Library    String
Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library    Collections

Suite Setup         Suite Initialization


*** Tasks ***
Check For Unused Azure Resource Groups
    [Documentation]    Runs a check to identify unused Azure resource groups (no resources and no activity in the last N days)
    [Tags]    Azure    ResourceGroup    Cleanup    access:read-only

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
        ${unused_rgs}=    Get From Dictionary    ${rg_report}    unused_resource_groups
    EXCEPT
        Log    Failed to parse JSON. Falling back to empty list.    WARN
        ${unused_rgs}=    Create List
    END

    IF    len(@{unused_rgs}) > 0
        ${unused_rg_summary}=    RW.CLI.Run Cli
            ...    cmd=jq -r '["Name", "Location", "Resource_Count", "Activity_Count", "Reason", "Url"], (.unused_resource_groups[] | [ .name, .details.location, (.resource_count|tostring), (.activity_count|tostring), .reason, .portal_url ]) | @tsv' unused-rgs.json | column -t -s $'\t'
        RW.Core.Add Pre To Report    Unused Resource Groups Summary:\n===========================================\n${unused_rg_summary.stdout}
        FOR    ${rg}    IN    @{unused_rgs}
            LOG    "Processing ${rg['name']}"
            ${name}=         Set Variable    ${rg['name']}
            ${reason}=       Set Variable    ${rg['reason']}
            ${resource_count}=    Set Variable    ${rg['resource_count']}
            ${activity_count}=    Set Variable    ${rg['activity_count']}
            ${details}=      Evaluate    pprint.pformat(${rg})    modules=pprint
            
            RW.Core.Add Issue
            ...    severity=3
            ...    expected=Resource group `${name}` should have resources or activity
            ...    actual=Resource group `${name}` is unused
            ...    title=Unused Azure Resource Group `${name}` Found
            ...    reproduce_hint=${output.cmd}
            ...    details=${rg}
            ...    next_steps=Delete the resource group `${name}`
        END
    ELSE
        RW.Core.Add Pre To Report    "No unused resource groups found"
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
    ${LOOKBACK_DAYS}=    RW.Core.Import User Variable    LOOKBACK_DAYS
    ...    type=string
    ...    description=Number of days to look back for activity.
    ...    pattern=\d*
    ...    example=30
    ...    default=30
    Set Suite Variable    ${AZURE_SUBSCRIPTION_ID}    ${AZURE_SUBSCRIPTION_ID}
    Set Suite Variable    ${AZURE_RESOURCE_GROUP}    ${AZURE_RESOURCE_GROUP}
    Set Suite Variable    ${LOOKBACK_DAYS}    ${LOOKBACK_DAYS}
    Set Suite Variable
    ...    ${env}
    ...    {"AZURE_RESOURCE_GROUP":"${AZURE_RESOURCE_GROUP}", "AZURE_SUBSCRIPTION_ID":"${AZURE_SUBSCRIPTION_ID}", "DAYS":"${LOOKBACK_DAYS}"}