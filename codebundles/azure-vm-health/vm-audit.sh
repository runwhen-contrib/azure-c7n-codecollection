#!/bin/bash
# vm-audit.sh – Audit changes to Azure Virtual Machines
# Outputs two JSON files:
#   vm_changes_success.json – successful operations
#   vm_changes_failed.json  – failed operations
# Environment variables:
#   AZURE_SUBSCRIPTION_ID       – subscription to query (default: current)
#   AZURE_RESOURCE_GROUP        – resource group containing VMs (required)
#   AZURE_ACTIVITY_LOG_OFFSET   – time window e.g. 24h, 7d (default: 24h)

set -euo pipefail

SUCCESS_OUTPUT="vm_changes_success.json"
FAILED_OUTPUT="vm_changes_failed.json"
echo "{}" > "$SUCCESS_OUTPUT"
echo "{}" > "$FAILED_OUTPUT"

# Select subscription
if [ -z "${AZURE_SUBSCRIPTION_ID:-}" ]; then
  subscription=$(az account show --query "id" -o tsv)
else
  subscription="$AZURE_SUBSCRIPTION_ID"
fi
az account set --subscription "$subscription"

# Resource group validation
if [ -z "${AZURE_RESOURCE_GROUP:-}" ]; then
  echo "Error: AZURE_RESOURCE_GROUP must be set" >&2
  exit 1
fi

# Validate resource group exists in the current subscription
echo "Validating resource group '$AZURE_RESOURCE_GROUP' exists in subscription '$subscription'..."
resource_group_exists=$(az group show --name "$AZURE_RESOURCE_GROUP" --subscription "$subscription" --query "name" -o tsv 2>/dev/null)

if [ -z "$resource_group_exists" ]; then
  echo "ERROR: Resource group '$AZURE_RESOURCE_GROUP' was not found in subscription '$subscription'."
  echo ""
  echo "Available resource groups in subscription '$subscription':"
  az group list --subscription "$subscription" --query "[].name" -o tsv | sort
  echo ""
  echo "Please verify:"
  echo "1. The resource group name is correct"
  echo "2. You have access to the resource group"
  echo "3. You're using the correct subscription"
  echo "4. The resource group exists in this subscription"
  exit 1
fi

TIME_OFFSET="${AZURE_ACTIVITY_LOG_OFFSET:-24h}"
vms=$(az vm list -g "$AZURE_RESOURCE_GROUP" --subscription "$subscription" --query "[].id" -o tsv)

if [ -z "$vms" ]; then
  echo "No virtual machines found in resource group $AZURE_RESOURCE_GROUP"
  exit 0
fi

tmp_success="$(mktemp)"
tmp_failed="$(mktemp)"
echo "{}" > "$tmp_success"
echo "{}" > "$tmp_failed"

for vm in $vms; do
  vm_name=$(basename "$vm")
  logs=$(az monitor activity-log list \
    --resource-id "$vm" \
    --offset "$TIME_OFFSET" \
    --subscription "$subscription" \
    --output json)

  echo "$logs" | jq --arg vm "$vm_name" '
    map(select(.operationName.value | test("write|delete|action")) | {
      vmName: $vm,
      operation: (.operationName.value | split("/") | last),
      operationDisplay: .operationName.localizedValue,
      timestamp: .eventTimestamp,
      caller: .caller,
      changeStatus: .status.value,
      resourceId: .resourceId,
      correlationId: .correlationId,
      resourceUrl: ("https://portal.azure.com/#resource" + .resourceId),
      security_classification:
        (if .operationName.value | test("delete") then "Critical"
         elif .operationName.value | test("deallocate|shutdown|stop") then "High"
         elif .operationName.value | test("start|restart|reboot") then "High"
         elif .operationName.value | test("resize|redeploy") then "High"
         elif .operationName.value | test("capture|generalize") then "Critical"
         elif .operationName.value | test("extensions|runCommand") then "Critical"
         elif .operationName.value | test("attachDisk|detachDisk") then "High"
         elif .operationName.value | test("networkInterfaces|publicIPAddresses") then "High"
         elif .operationName.value | test("roleAssignments|permissions") then "Critical"
         elif .operationName.value | test("diagnosticSettings") then "Medium"
         elif .operationName.value | test("write") then "Medium"
         else "Info" end),
      reason:
        (if .operationName.value | test("delete") then "Deleting a VM permanently removes the compute resource and may affect dependent services"
         elif .operationName.value | test("deallocate|shutdown|stop") then "Stopping a VM affects application availability and may impact dependent services"
         elif .operationName.value | test("start|restart|reboot") then "Starting or restarting a VM affects application availability and service continuity"
         elif .operationName.value | test("resize") then "Resizing a VM changes compute capacity and may require downtime"
         elif .operationName.value | test("redeploy") then "Redeploying a VM moves it to new hardware and causes temporary unavailability"
         elif .operationName.value | test("capture|generalize") then "Capturing or generalizing a VM creates images that could be used to provision new instances"
         elif .operationName.value | test("extensions") then "VM extensions can install software, modify configurations, or access sensitive data"
         elif .operationName.value | test("runCommand") then "Run command allows execution of arbitrary scripts on the VM with elevated privileges"
         elif .operationName.value | test("attachDisk|detachDisk") then "Disk operations change storage configuration and may affect data availability"
         elif .operationName.value | test("networkInterfaces|publicIPAddresses") then "Network changes affect VM connectivity and security posture"
         elif .operationName.value | test("roleAssignments|permissions") then "RBAC changes directly control who can access and manage the virtual machine"
         elif .operationName.value | test("diagnosticSettings") then "Diagnostic setting changes affect monitoring and logging capabilities"
         elif .operationName.value | test("write") then "Write operation changed configuration or settings of the virtual machine"
         else "Miscellaneous operation" end)
    })' > _current.json

  jq 'group_by(.vmName) | map({ (.[0].vmName): . }) | add' _current.json > _grouped.json

  jq 'with_entries(.value |= map(select(.changeStatus == "Succeeded")))' _grouped.json > _succ.json

  jq 'with_entries(.value |= map(select(.changeStatus == "Failed")))' _grouped.json > _fail.json

  jq -s 'add' "$tmp_success" _succ.json > _sc.tmp && mv _sc.tmp "$tmp_success"
  jq -s 'add' "$tmp_failed"  _fail.json > _fl.tmp && mv _fl.tmp "$tmp_failed"

  rm -f _current.json _grouped.json _succ.json _fail.json
done

# Sort each group by timestamp (desc)
for file in "$tmp_success" "$tmp_failed"; do
  jq 'with_entries({ key: .key, value: (.value | sort_by(.timestamp) | reverse) })' "$file" > "$file.sorted"
  mv "$file.sorted" "$file"
done

mv "$tmp_success" "$SUCCESS_OUTPUT"
mv "$tmp_failed"  "$FAILED_OUTPUT"

echo "Audit completed:"
echo "  ✅ Successful changes → $SUCCESS_OUTPUT"
echo "  ⚠️  Failed changes     → $FAILED_OUTPUT" 