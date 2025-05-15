resource "random_pet" "name_prefix" {
  prefix = var.resource_group
  length = 1
}

resource "azurerm_resource_group" "rg" {
  name     = var.resource_group
  location = var.location
  tags     = var.tags
}

resource "azurerm_mysql_flexible_server" "mysqlfx_server" {
  name                   = "${random_pet.name_prefix.id}-mysqlfx"
  resource_group_name    = azurerm_resource_group.rg.name
  location               = azurerm_resource_group.rg.location
  sku_name               = "B_Standard_B1ms"
  version                = "8.0.21"
  administrator_login    = "mysqladmin"
  administrator_password = "YourStrongPassword123!"
  zone                   = null

  backup_retention_days = 1

  storage {
    size_gb           = 20
    auto_grow_enabled = false
  }

  tags = var.tags
}

resource "azurerm_postgresql_flexible_server" "psql" {
  name                   = "${random_pet.name_prefix.id}-pgsql"
  resource_group_name    = azurerm_resource_group.rg.name
  location               = azurerm_resource_group.rg.location
  administrator_login    = "psqladmin"
  administrator_password = "H@Sh1CoR3!"
  version                = "11"
  sku_name               = "B_Standard_B1ms"
  storage_mb             = 32768
  zone                   = null

  backup_retention_days         = 7
  geo_redundant_backup_enabled  = false
  public_network_access_enabled = true

  tags = var.tags
}

resource "azurerm_postgresql_flexible_server_configuration" "require_ssl" {
  server_id = azurerm_postgresql_flexible_server.psql.id
  name      = "require_secure_transport"
  value     = "ON"
}

resource "azurerm_postgresql_flexible_server_firewall_rule" "all_ips" {
  server_id        = azurerm_postgresql_flexible_server.psql.id
  name             = "allow-all"
  start_ip_address = "0.0.0.0"
  end_ip_address   = "255.255.255.255"
}

resource "azurerm_cosmosdb_account" "cosmosdb_account" {
  name                = "${random_pet.name_prefix.id}-cosmosdb"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  offer_type          = "Standard"
  kind                = "GlobalDocumentDB"
  free_tier_enabled   = true

  consistency_policy {
    consistency_level = "Session"
  }

  geo_location {
    location          = azurerm_resource_group.rg.location
    failover_priority = 0
  }

  tags = var.tags
}

resource "azurerm_cosmosdb_sql_database" "cosmos_sql_database" {
  name                = "cosmosdb-sql"
  resource_group_name = azurerm_resource_group.rg.name
  account_name        = azurerm_cosmosdb_account.cosmosdb_account.name
}

resource "azurerm_cosmosdb_sql_container" "cosmos_sql_container" {
  name                = "cosmos-sql-container"
  resource_group_name = azurerm_resource_group.rg.name
  account_name        = azurerm_cosmosdb_account.cosmosdb_account.name
  database_name       = azurerm_cosmosdb_sql_database.cosmos_sql_database.name

  partition_key_paths = ["/id"]
  throughput          = null
}

resource "azurerm_redis_cache" "redis" {
  name                 = "${random_pet.name_prefix.id}-redis"
  location             = azurerm_resource_group.rg.location
  resource_group_name  = azurerm_resource_group.rg.name
  capacity             = 0
  family               = "C"
  sku_name             = "Basic"
  non_ssl_port_enabled = false
  tags                 = var.tags
}

resource "azurerm_mssql_server" "sql_server" {
  name                         = "${random_pet.name_prefix.id}-sql"
  resource_group_name          = azurerm_resource_group.rg.name
  location                     = azurerm_resource_group.rg.location
  version                      = "12.0"
  administrator_login          = "sqladmin"
  administrator_login_password = "YourStrongPassword123!"
  tags                         = var.tags
}

resource "azurerm_mssql_database" "sql_db" {
  name                 = "my-sqldb"
  server_id            = azurerm_mssql_server.sql_server.id
  sku_name             = "Basic"
  collation            = "SQL_Latin1_General_CP1_CI_AS"
  max_size_gb          = 1
  storage_account_type = "Local"
  zone_redundant       = false
  geo_backup_enabled   = false
}
