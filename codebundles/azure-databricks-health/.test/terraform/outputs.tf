output "resource_group_name" {
  value = azurerm_resource_group.rg.name
}

output "databricks_workspace_name" {
  value = azurerm_databricks_workspace.databricks.name
}

output "databricks_workspace_url" {
  value = azurerm_databricks_workspace.databricks.workspace_url
}

# output "databricks_cluster_id" {
#   value = azurerm_databricks_cluster.cluster.id
# }

# output "databricks_cluster_name" {
#   value = azurerm_databricks_cluster.cluster.name
# }

output "export_commands" {
  value = join("\n", [
    "export AZURE_RESOURCE_GROUP=${azurerm_resource_group.rg.name}",
    "export DATABRICKS_WORKSPACE=${azurerm_databricks_workspace.databricks.name}",
    "export DATABRICKS_URL=${azurerm_databricks_workspace.databricks.workspace_url}"
    # "export DATABRICKS_CLUSTER_ID=${azurerm_databricks_cluster.cluster.id}",
    # "export DATABRICKS_CLUSTER_NAME=${azurerm_databricks_cluster.cluster.name}"
  ])
  description = "Copy-paste ready export commands for use in shell or Robot Framework env block"
}
