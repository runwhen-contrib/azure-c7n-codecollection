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
resource "databricks_cluster" "cluster" {
  cluster_name            = "${random_pet.name_prefix.id}-dbx-cluster"
  spark_version           = "15.4.x-scala2.12"
  node_type_id            = "Standard_D3_v2"
  driver_node_type_id     = "Standard_D3_v2"
  autotermination_minutes = 120
  num_workers             = 0
  data_security_mode      = "LEGACY_SINGLE_USER_STANDARD"
  runtime_engine          = "PHOTON"
  enable_elastic_disk     = true

  spark_conf = {
    "spark.databricks.cluster.profile" = "singleNode"
    "spark.master"                     = "local[*, 4]"
  }

  spark_env_vars = {
    "PYSPARK_PYTHON" = "/databricks/python3/bin/python3"
  }

  azure_attributes {
    first_on_demand    = 1
    availability       = "SPOT_WITH_FALLBACK_AZURE"
    spot_bid_max_price = -1
  }

  custom_tags = {
    "ResourceClass" = "SingleNode"
  }
}

// create PAT token to provision entities within workspace
resource "databricks_token" "pat" {
  provider = databricks
  comment  = "Terraform Provisioning"
  // 24 hour token
  lifetime_seconds = 86400
}