terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "5.15.0"
    }
  }
}

provider "azurerm" {
  features {}
}

provider "azuread" {}