resource "random_pet" "name_prefix" {
  prefix = var.resource_group
  length = 1
}

resource "azurerm_resource_group" "rg" {
  name     = var.resource_group
  location = var.location
  tags     = var.tags
}

# Databricks resources
resource "azurerm_databricks_workspace" "databricks" {
  name                = "${random_pet.name_prefix.id}-databricks"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  sku                 = "standard"
  tags                = var.tags
}

# Create a Databricks cluster
# resource "azurerm_databricks_cluster" "cluster" {
#   name                   = "test-cluster"
#   workspace_id           = azurerm_databricks_workspace.databricks.id
#   spark_version          = "11.3.x-scala2.12"
#   node_type_id           = "Standard_DS3_v2"
#   autotermination_minutes = 20
#   min_workers            = 1
#   max_workers            = 2

#   spark_conf = {
#     "spark.databricks.cluster.profile" = "singleNode"
#     "spark.master"                      = "local[*]"
#   }

#   custom_tags = {
#     "ResourceClass" = "SingleNode"
#   }
# }
