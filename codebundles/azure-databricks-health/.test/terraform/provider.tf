terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "4.18.0"
    }
    databricks = {
      source  = "databricks/databricks"
      version = "1.80.0"
    }
  }
}

provider "azurerm" {
  features {}
}

provider "azuread" {}

provider "databricks" {
  host      = azurerm_databricks_workspace.databricks.workspace_url
  auth_type = "azure-cli"
}