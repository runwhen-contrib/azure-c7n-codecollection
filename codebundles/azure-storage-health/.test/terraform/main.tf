resource "azurerm_resource_group" "test_rg" {
  name     = var.resource_group
  location = var.location
}

resource "azurerm_managed_disk" "orphaned_disk" {
  name                   = "orphaned-test-disk"
  location               = azurerm_resource_group.test_rg.location
  resource_group_name    = azurerm_resource_group.test_rg.name
  storage_account_type   = "Standard_LRS"
  create_option          = "Empty"
  disk_size_gb           = 1
  disk_encryption_set_id = null # No customer-managed encryption set
  tags                   = var.tags
}

# Create a Snapshot of the Disk
resource "azurerm_snapshot" "unused_snapshot" {
  name                = "unused-test-snapshot"
  location            = azurerm_resource_group.test_rg.location
  resource_group_name = azurerm_resource_group.test_rg.name
  create_option       = "Copy"
  source_uri          = azurerm_managed_disk.orphaned_disk.id
  tags                = var.tags
}

resource "azurerm_storage_account" "example" {
  name                     = "c7ntest399332"
  resource_group_name      = azurerm_resource_group.test_rg.name
  location                 = azurerm_resource_group.test_rg.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  tags                     = var.tags
}