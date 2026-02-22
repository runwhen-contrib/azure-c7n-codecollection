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

  lifecycle {
    ignore_changes = [
      single_user_name
    ]
  }
}

// create PAT token to provision entities within workspace
resource "databricks_token" "pat" {
  provider = databricks
  comment  = "Terraform Provisioning"
  // 24 hour token
  lifetime_seconds = 86400
}


# Simple job that runs successfully
resource "databricks_job" "simple_job" {
  name = "${random_pet.name_prefix.id}-success-job"

  task {
    task_key            = "hello_task"
    existing_cluster_id = databricks_cluster.cluster.id

    notebook_task {
      notebook_path = databricks_notebook.hello_world.path
    }

    max_retries     = 1
    timeout_seconds = 3600
  }
}

# Job that will always fail
resource "databricks_job" "failing_job" {
  name = "${random_pet.name_prefix.id}-failing-job"

  task {
    task_key            = "failing_task"
    existing_cluster_id = databricks_cluster.cluster.id

    notebook_task {
      notebook_path = databricks_notebook.failing_notebook.path
    }

    max_retries     = 0 # No retries to ensure it fails
    timeout_seconds = 300
  }
}

# Job that runs for a long time
resource "databricks_job" "long_running_job" {
  name = "${random_pet.name_prefix.id}-long-running-job"

  task {
    task_key            = "long_running_task"
    existing_cluster_id = databricks_cluster.cluster.id

    notebook_task {
      notebook_path = databricks_notebook.long_running_notebook.path
    }

    max_retries     = 0
    timeout_seconds = 900 # 15 minutes timeout
  }
}

resource "databricks_notebook" "hello_world" {
  path     = "/Shared/hello_world"
  language = "PYTHON"
  content_base64 = base64encode(<<-EOT
    print("Hello from Databricks job")
  EOT
  )
}

# Notebook that will intentionally fail
resource "databricks_notebook" "failing_notebook" {
  path     = "/Shared/failing_notebook"
  language = "PYTHON"
  content_base64 = base64encode(<<-EOT
    # This notebook is designed to fail
    raise Exception("This is an intentional failure for testing purposes")
  EOT
  )
}

# Notebook that runs for a long time (5 minutes)
resource "databricks_notebook" "long_running_notebook" {
  path     = "/Shared/long_running_notebook"
  language = "PYTHON"
  content_base64 = base64encode(<<-EOT
    # This notebook runs for approximately 5 minutes
    import time
    
    print("Starting long running job...")
    for i in range(300):  # 300 seconds = 5 minutes
        time.sleep(1)
        if i % 30 == 0:  # Print every 30 seconds
            print(f"Still running... {i} seconds elapsed")
    print("Long running job completed successfully")
  EOT
  )
}

# Resource to trigger the successful job
resource "null_resource" "trigger_success_job" {
  triggers = {
    job_id     = databricks_job.simple_job.id
    cluster_id = databricks_cluster.cluster.id
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command = templatefile("${path.module}/scripts/trigger_job.sh", {
      databricks_host       = azurerm_databricks_workspace.databricks.workspace_url
      databricks_token      = databricks_token.pat.token_value
      databricks_cluster_id = databricks_cluster.cluster.id
      databricks_job_id     = databricks_job.simple_job.id
    })
  }

  depends_on = [
    databricks_cluster.cluster,
    databricks_job.simple_job,
    databricks_notebook.hello_world
  ]
}

# Resource to trigger the failing job
resource "null_resource" "trigger_failing_job" {
  triggers = {
    job_id     = databricks_job.failing_job.id
    cluster_id = databricks_cluster.cluster.id
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command = templatefile("${path.module}/scripts/trigger_job.sh", {
      databricks_host       = azurerm_databricks_workspace.databricks.workspace_url
      databricks_token      = databricks_token.pat.token_value
      databricks_cluster_id = databricks_cluster.cluster.id
      databricks_job_id     = databricks_job.failing_job.id
    })
  }

  depends_on = [
    databricks_cluster.cluster,
    databricks_job.failing_job,
    databricks_notebook.failing_notebook
  ]
}

# Resource to trigger the long-running job
resource "null_resource" "trigger_long_running_job" {
  triggers = {
    job_id     = databricks_job.long_running_job.id
    cluster_id = databricks_cluster.cluster.id
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command = templatefile("${path.module}/scripts/trigger_job.sh", {
      databricks_host       = azurerm_databricks_workspace.databricks.workspace_url
      databricks_token      = databricks_token.pat.token_value
      databricks_cluster_id = databricks_cluster.cluster.id
      databricks_job_id     = databricks_job.long_running_job.id
    })
  }

  depends_on = [
    databricks_cluster.cluster,
    databricks_job.long_running_job,
    databricks_notebook.long_running_notebook
  ]
}
