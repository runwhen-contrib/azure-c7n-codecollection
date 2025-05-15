output "resource_group_name" {
  value = azurerm_resource_group.rg.name
}

output "mysql_flexible_server_name" {
  value = azurerm_mysql_flexible_server.mysqlfx_server.name
}

output "postgresql_flexible_server_name" {
  value = azurerm_postgresql_flexible_server.psql.name
}

output "cosmosdb_account_name" {
  value = azurerm_cosmosdb_account.cosmosdb_account.name
}

output "cosmosdb_sql_database_name" {
  value = azurerm_cosmosdb_sql_database.cosmos_sql_database.name
}

output "cosmosdb_sql_container_name" {
  value = azurerm_cosmosdb_sql_container.cosmos_sql_container.name
}

output "redis_cache_name" {
  value = azurerm_redis_cache.redis.name
}

output "mssql_server_name" {
  value = azurerm_mssql_server.sql_server.name
}

output "mssql_database_name" {
  value = azurerm_mssql_database.sql_db.name
}

output "export_commands" {
  value = join("\n", [
    "export AZURE_RESOURCE_GROUP=${azurerm_resource_group.rg.name}",
    "export MYSQL_SERVER=${azurerm_mysql_flexible_server.mysqlfx_server.name}",
    "export POSTGRES_SERVER=${azurerm_postgresql_flexible_server.psql.name}",
    "export COSMOS_ACCOUNT=${azurerm_cosmosdb_account.cosmosdb_account.name}",
    "export COSMOS_DB=${azurerm_cosmosdb_sql_database.cosmos_sql_database.name}",
    "export COSMOS_CONTAINER=${azurerm_cosmosdb_sql_container.cosmos_sql_container.name}",
    "export REDIS_NAME=${azurerm_redis_cache.redis.name}",
    "export SQL_SERVER=${azurerm_mssql_server.sql_server.name}",
    "export SQL_DB=${azurerm_mssql_database.sql_db.name}"
  ])
  description = "Copy-paste ready export commands for use in shell or Robot Framework env block"
}
