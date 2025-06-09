*** Settings ***
Documentation       Check for unused Azure resource groups and tag compliance
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
Library             OperatingSystem

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

Check For Azure Resource Tag Compliance
    [Documentation]    Runs a check to identify Azure resources missing required tags across resource groups
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
        ${non_compliant_resources}=    Get From Dictionary    ${tag_report}    non_compliant_resources
        ${checked_resource_groups}=    Get From Dictionary    ${tag_report}    checked_resource_groups
        ${total_checked}=    Get From Dictionary    ${tag_report}    total_checked
    EXCEPT
        Log    Failed to parse JSON. Falling back to empty list.    WARN
        ${non_compliant_resources}=    Create List
        ${checked_resource_groups}=    Create List
        ${total_checked}=    Set Variable    0
    END

    # Group non-compliant resources by resource group
    ${rg_issues}=    Create Dictionary
    FOR    ${resource}    IN    @{non_compliant_resources}
        ${rg_name}=    Set Variable If    
        ...    'resource_group' in ${resource}    ${resource['resource_group']}
        ...    ${resource['resource_name']}
        
        ${current_rg_resources}=    Get From Dictionary    ${rg_issues}    ${rg_name}    default=${EMPTY}
        IF    "${current_rg_resources}" == "${EMPTY}"
            ${current_rg_resources}=    Create List
        END
        Append To List    ${current_rg_resources}    ${resource}
        Set To Dictionary    ${rg_issues}    ${rg_name}    ${current_rg_resources}
    END

    IF    len(@{non_compliant_resources}) > 0
        ${total_non_compliant}=    Get Length    ${non_compliant_resources}
        
        # Create formatted summary report using jq
        # ${summary_cmd}=    Set Variable    
        # ...    echo '${report_data.stdout}' | jq -r '"Resource Group Tag Compliance Summary\\n=============================================\\n\\nTotal Resource Groups Checked: " + (.total_checked|tostring) + "\\nResource Groups with Issues: " + ([.non_compliant_resources[] | select(.resource_group != null) | .resource_group] | unique | length | tostring)'

        # ${summary_output}=    RW.CLI.Run Cli    cmd=${summary_cmd}
        # RW.Core.Add Pre To Report    ${summary_output.stdout}

        # Create detailed report per resource group
        FOR    ${rg_name}    IN    @{rg_issues.keys()}
            ${rg_resources}=    Get From Dictionary    ${rg_issues}    ${rg_name}
            ${rg_resource_count}=    Get Length    ${rg_resources}
            
            # Generate table header
            # RW.Core.Add Pre To Report    Resource Group: ${rg_name}\nNon-Compliant Resources: ${rg_resource_count}\n---\n
            
            # Generate table using jq directly from the resources
            ${json_str}=    Evaluate    json.dumps({"resources": ${rg_resources}})    json
            ${table_cmd}=    Set Variable    echo '${json_str}' | jq -r '["Resource Name", "Resource Type", "Missing Tags", "Portal URL"], (.resources[] | [.resource_name, .resource_type, (.missing_tags | join(", ")), .portal_url]) | @tsv' | column -t -s $'\t'
            
            ${table_output}=    RW.CLI.Run Cli    cmd=${table_cmd}
            RW.Core.Add Pre To Report    ${table_output.stdout}\n

            # Create issue for this resource group
            ${rg_details}=    Create Dictionary
            Set To Dictionary    ${rg_details}    resource_group    ${rg_name}
            Set To Dictionary    ${rg_details}    non_compliant_count    ${rg_resource_count}
            Set To Dictionary    ${rg_details}    resources    ${rg_resources}
            ${pretty_rg_details}=    Evaluate    pprint.pformat(${rg_details})    modules=pprint
            # Process missing tags for summary
            ${all_missing_tags}=    Create List
            FOR    ${resource}    IN    @{rg_resources}
                ${tags}=    Set Variable    ${resource['missing_tags']}
                # Handle tag list processing
                ${processed_tags}=    Run Keyword If    len($tags) == 1 and ' ' in $tags[0]
                ...    Evaluate    $tags[0].split()
                ...    ELSE    Set Variable    ${tags}
                
                FOR    ${tag}    IN    @{processed_tags}
                    Append To List    ${all_missing_tags}    ${tag}
                END
            END
            
            ${unique_missing_tags}=    Evaluate    sorted(list(set($all_missing_tags)))
            ${unique_tags_str}=    Evaluate    ', '.join(map(str, $unique_missing_tags))
            
            RW.Core.Add Issue
            ...    severity=4
            ...    expected=All resources in resource group `${rg_name}` should have required tags: ${unique_tags_str}
            ...    actual=Resource group `${rg_name}` has ${rg_resource_count} resources missing required tags
            ...    title=Tag Compliance Issues in Resource Group `${rg_name}`
            ...    reproduce_hint=${output.cmd}
            ...    details=${pretty_rg_details}
            ...    next_steps=Add missing tags (${unique_tags_str}) to resources in resource group `${rg_name}`. Use the portal URLs in the detailed report to navigate to each resource.
        END
    ELSE
        RW.Core.Add Pre To Report    "All checked resources have required tags - compliance check passed"
    END

Check Azure Cost Analysis
    [Documentation]    Analyzes Azure consumption and provides cost insights
    [Tags]    Azure    Cost    Analysis    access:read-only

    ${output}=    RW.CLI.Run Bash File
    ...    bash_file=consumption-usage.sh
    ...    env=${env}
    ...    timeout_seconds=600
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true

    ${report_data}=    RW.CLI.Run Cli
    ...    cmd=cat azure_cost_analysis.json

    TRY
        ${cost_report}=    Evaluate    json.loads(r'''${report_data.stdout}''')    json
        ${metadata}=    Get From Dictionary    ${cost_report}    metadata
        ${summary}=    Get From Dictionary    ${cost_report}    summary
        ${cost_breakdown}=    Get From Dictionary    ${cost_report}    cost_breakdown
        ${cost_summary}=    Get From Dictionary    ${cost_report}    cost_summary
    EXCEPT
        Log    Failed to parse cost analysis JSON. Check the script output.    WARN
        RETURN
    END

    # Generate summary report
    ${summary_cmd}=    Set Variable    
    ...    echo '${report_data.stdout}' | jq -r '"Azure Cost Analysis Summary\\n=================================\\n\\nDate Range: \\(.metadata.date_range.start) to \\(.metadata.date_range.end) (\\(.metadata.date_range.days) days)\\nTotal Cost: \\(.summary.total_cost) \\(.metadata.billing_currency)\\nEstimated On-Demand Cost: \\(.summary.estimated_on_demand_cost) \\(.metadata.billing_currency)\\nEstimated Savings: \\(.summary.estimated_savings) \\(.metadata.billing_currency) (\\((.summary.estimated_savings / .summary.estimated_on_demand_cost * 100) | round)%%)\\n\\nTop Cost Services:\\n" + ([.cost_breakdown.by_service[] | "• \\(.service): \\(.cost) \\(.metadata.billing_currency) (\\((.cost / .summary.total_cost * 100) | round)%%)"] | join("\\n")) + "\\n\\nCost Summary:\\n• Average Daily Cost: \\(.cost_summary.average_daily_cost) \\(.metadata.billing_currency)\\n• Peak Day: \\(.cost_summary.peak_day.date) (\\(.cost_summary.peak_day.cost) \\(.metadata.billing_currency))\\n• Days with Cost: \\(.cost_summary.total_days_with_cost)/\\(.cost_summary.date_range.total_days)"'
    
    ${summary_output}=    RW.CLI.Run Cli    cmd=${summary_cmd}
    RW.Core.Add Pre To Report    ${summary_output.stdout}

    # Add detailed cost breakdown
    ${details_cmd}=    Set Variable    
    ...    echo '${report_data.stdout}' | jq -r '"\\nTop Resources Consumption:\\n" + ([.cost_breakdown.top_resources[] | "• \\(.resource) (\\(.resourceGroup)): \\(.cost) \\(.billingCurrency) (\\(.hours) hours)\\n  Portal: \\(.portal_url)"] | join("\\n"))'
    
    ${details_output}=    RW.CLI.Run Cli    cmd=${details_cmd}
    RW.Core.Add Pre To Report    ${details_output.stdout}

    # Check for cost anomalies
    ${peak_day_multiplier}=    Evaluate    float(${cost_summary['peak_day']['cost']}) / float(${cost_summary['average_daily_cost']}) if ${cost_summary['average_daily_cost']} > 0 else 1
    ${peak_day_multiplier_rounded}=    Evaluate    round(${peak_day_multiplier}, 1)
    ${anomaly_threshold}=    Set Variable    ${2.0}  # 2x daily average is considered an anomaly

    IF    ${peak_day_multiplier} > ${anomaly_threshold}
        RW.Core.Add Issue
        ...    severity=3
        ...    expected=Daily costs should be relatively stable
        ...    actual=Peak day cost (${cost_summary['peak_day']['cost']} ${metadata['billing_currency']}) is ${peak_day_multiplier_rounded}x the daily average
        ...    title=Cost Anomaly Detected on ${cost_summary['peak_day']['date']}
        ...    reproduce_hint=${output.cmd}
        ...    details=Peak day: ${cost_summary['peak_day']['date']} (${cost_summary['peak_day']['cost']} ${metadata['billing_currency']})\nAverage daily cost: ${cost_summary['average_daily_cost']} ${metadata['billing_currency']}
        ...    next_steps=Investigate the spike in costs on ${cost_summary['peak_day']['date']}. Check the top costly resources for unusual activity.
    END

    # Check for high-cost resources
    FOR    ${resource}    IN    @{cost_breakdown['top_resources']}
        ${cost_percentage}=    Evaluate    (float(${resource['cost']}) / float(${summary['total_cost']}) * 100)
        ${cost_percentage_rounded}=    Evaluate    round(${cost_percentage}, 1)
        IF    ${cost_percentage} > 20  # Flag resources that account for >20% of total cost
            RW.Core.Add Issue
            ...    severity=4
            ...    expected=No single resource should consume a large portion of the total cost
            ...    actual=Resource ${resource['resource']} accounts for ${cost_percentage_rounded}% of total costs
            ...    title=High Cost Resource: ${resource['resource']}
            ...    reproduce_hint=${output.cmd}
            ...    details=Cost: ${resource['cost']} ${resource['billingCurrency']} (${cost_percentage_rounded}% of total)\nResource Group: ${resource['resourceGroup']}\nPortal URL: ${resource['portal_url']}
            ...    next_steps=Review the resource usage and consider optimization or right-sizing. Check if the resource is still needed or if there are more cost-effective alternatives.
        END
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
    Set Suite Variable    ${AZURE_SUBSCRIPTION_ID}    ${AZURE_SUBSCRIPTION_ID}
    Set Suite Variable    ${AZURE_RESOURCE_GROUP}    ${AZURE_RESOURCE_GROUP}
    Set Suite Variable    ${LOOKBACK_DAYS}    ${LOOKBACK_DAYS}
    Set Suite Variable    ${RESOURCE_GROUPS}    ${RESOURCE_GROUPS}
    Set Suite Variable
    ...    ${env}
    ...    {"AZURE_RESOURCE_GROUP":"${AZURE_RESOURCE_GROUP}", "AZURE_SUBSCRIPTION_ID":"${AZURE_SUBSCRIPTION_ID}", "DAYS":"${LOOKBACK_DAYS}", "RESOURCE_GROUPS":"${RESOURCE_GROUPS}", "TAGS":"${TAGS}"}