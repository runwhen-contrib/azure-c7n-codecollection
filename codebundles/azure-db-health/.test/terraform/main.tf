resource "azurerm_resource_group" "rg" {
  name     = var.resource_group
  location = var.location
  tags     = var.tags
}

# resource "azurerm_virtual_network" "vnet" {
#   name                = "spot-vnet"
#   location            = azurerm_resource_group.rg.location
#   resource_group_name = azurerm_resource_group.rg.name
#   address_space       = ["10.0.0.0/16"]
# }

# resource "azurerm_subnet" "subnet" {
#   name                 = "spot-subnet"
#   resource_group_name  = azurerm_resource_group.rg.name
#   virtual_network_name = azurerm_virtual_network.vnet.name
#   address_prefixes     = ["10.0.1.0/24"]
# }

# resource "azurerm_public_ip" "public_ip" {
#   name                = "spot-vm-public-ip"
#   location            = azurerm_resource_group.rg.location
#   resource_group_name = azurerm_resource_group.rg.name
#   allocation_method   = "Static"
#   sku                 = "Standard"
# }

resource "azurerm_mysql_flexible_server" "mysql_server" {
  name                   = "yoko-ono-mysql"
  resource_group_name    = azurerm_resource_group.rg.name
  location               = azurerm_resource_group.rg.location
  sku_name               = "B_Standard_B1ms"
  version                = "8.0.21"
  administrator_login    = "mysqladmin"
  administrator_password = "YourStrongPassword123!"
  backup_retention_days  = 1
  storage {
    size_gb           = 20
    auto_grow_enabled = false
  }
}