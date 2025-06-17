# Azure Databricks Health
This codebundle runs a suite of metrics checks for Databricks in Azure. It identifies:
- List Databricks Activity Log
- List Databricks Cluster Status
- List Databricks Job Status
- DBFS I/O Sanity

## Configuration

The TaskSet requires initialization to import necessary secrets, services, and user variables. The following variables should be set:

- `AZ_USERNAME`: Service principal's client ID
- `AZ_SECRET_VALUE`: The credential secret value from the app registration
- `AZ_TENANT`: The Azure tenancy ID
- `AZ_SUBSCRIPTION`: The Azure subscription ID

## Testing 
See the .test directory for infrastructure test code. 

## Notes

This codebundle assumes the service principal authentication flow