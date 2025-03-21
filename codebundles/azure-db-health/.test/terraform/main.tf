resource "azurerm_resource_group" "rg" {
  name     = var.resource_group
  location = var.location
  tags     = var.tags
}

resource "azurerm_mysql_flexible_server" "mysqlfx_server" {
  name                   = "yoko-ono-mysqlfx"
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
  tags = var.tags
}

resource "azurerm_postgresql_server" "psql-server" {
  name                = "yoko-ono-psqlserver"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  administrator_login          = "psqladmin"
  administrator_login_password = "H@Sh1CoR3!"

  sku_name   = "B_Gen5_1" # SKU (Basic, 1 vCore)
  version    = "11"
  storage_mb = 5120 # Minimum allowed storage (5GB)

  backup_retention_days        = 7     # Minimum required
  geo_redundant_backup_enabled = false # No expensive geo-redundancy
  auto_grow_enabled            = false # Prevent extra costs from auto-scaling

  public_network_access_enabled    = true
  ssl_enforcement_enabled          = true
  ssl_minimal_tls_version_enforced = "TLS1_2"
  tags = var.tags
}

resource "azurerm_cosmosdb_account" "cosmosdb-account" {
  name                = "yoko-ono-cosmosdb"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  offer_type          = "Standard"
  kind                = "GlobalDocumentDB"

  free_tier_enabled = true # First 400 RU/s free
  consistency_policy {
    consistency_level = "Session" # Lower cost compared to Strong
  }

  geo_location {
    location          = azurerm_resource_group.rg.location
    failover_priority = 0
  }
  tags = var.tags
}

resource "azurerm_cosmosdb_sql_database" "cosmos_sql_database" {
  name                = "cosmosd-db"
  resource_group_name = azurerm_resource_group.rg.name
  account_name        = azurerm_cosmosdb_account.cosmosdb-account.name
}

resource "azurerm_cosmosdb_sql_container" "cosmos_sql_container" {
  name                = "cosmos-sql-container"
  resource_group_name = azurerm_resource_group.rg.name
  account_name        = azurerm_cosmosdb_account.cosmosdb-account.name
  database_name       = azurerm_cosmosdb_sql_database.cosmos_sql_database.name

  partition_key_paths = ["/id"]
  throughput          = null # Uses serverless mode (pay-per-request)
}

resource "azurerm_redis_cache" "redis" {
  name                 = "yoko-ono-redis"
  location             = azurerm_resource_group.rg.location
  resource_group_name  = azurerm_resource_group.rg.name
  capacity             = 0   # C0 (250 MB)
  family               = "C" # Basic Cache family
  sku_name             = "Basic"
  non_ssl_port_enabled = false
  tags = var.tags
}

resource "azurerm_mssql_server" "sql_server" {
  name                         = "yoko-ono-sql"
  resource_group_name          = azurerm_resource_group.rg.name
  location                     = azurerm_resource_group.rg.location
  version                      = "12.0"
  administrator_login          = "sqladmin"
  administrator_login_password = "YourStrongPassword123!"

  # azuread_administrator {
  #   login_username = "sqladmin"
  #   object_id      = "your-azure-ad-object-id"
  # }

  tags = var.tags
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