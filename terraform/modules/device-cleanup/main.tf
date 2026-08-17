locals {
  automation_account_name = coalesce(var.automation_account_name, "aa-devicecleanup-${var.environment}-${var.location}-1")

  base_tags = merge({
    customer    = var.customer
    environment = var.environment
    workload    = "device-cleanup"
    managedBy   = "terraform"
  }, var.tags)

  # Parameters passed to every scheduled job. Keys MUST be lowercase.
  # Boolean values are JSON literals so Automation deserializes them as [bool].
  runbook_parameters = merge(
    {
      dryrun                      = var.enable_apply ? "false" : "true"
      softdeleteafterdays         = tostring(var.soft_delete_after_days)
      harddeleteafterdays         = tostring(var.hard_delete_after_days)
      backupblandlaps             = var.backup_enabled ? "true" : "false"
      keyvaultname                = var.backup_enabled ? var.key_vault_name : ""
      secretretentiondays         = tostring(var.secret_retention_days)
      requiredisabledbeforedelete = var.require_disabled_before_delete ? "true" : "false"
    },
    var.extra_runbook_parameters
  )

  graph_modules = [
    "Microsoft.Graph.Authentication",
    "Microsoft.Graph.Identity.DirectoryManagement",
    "Microsoft.Graph.Identity.SignIns",
  ]
}

data "azurerm_resource_group" "target" {
  name = var.resource_group_name
}

data "azurerm_client_config" "current" {}

resource "azurerm_automation_account" "this" {
  name                = local.automation_account_name
  location            = var.location
  resource_group_name = data.azurerm_resource_group.target.name
  sku_name            = "Basic"
  tags                = local.base_tags

  identity {
    type = "SystemAssigned"
  }
}

# Microsoft.Graph modules for the PowerShell 7.2 runtime. Authentication must
# land first; the other two depend on it.
resource "azurerm_automation_powershell72_module" "graph_authentication" {
  name                  = "Microsoft.Graph.Authentication"
  automation_account_id = azurerm_automation_account.this.id

  module_link {
    uri = "https://www.powershellgallery.com/api/v2/package/Microsoft.Graph.Authentication/${var.graph_module_version}"
  }
}

resource "azurerm_automation_powershell72_module" "graph_directory" {
  name                  = "Microsoft.Graph.Identity.DirectoryManagement"
  automation_account_id = azurerm_automation_account.this.id

  module_link {
    uri = "https://www.powershellgallery.com/api/v2/package/Microsoft.Graph.Identity.DirectoryManagement/${var.graph_module_version}"
  }

  depends_on = [azurerm_automation_powershell72_module.graph_authentication]
}

resource "azurerm_automation_powershell72_module" "graph_signins" {
  name                  = "Microsoft.Graph.Identity.SignIns"
  automation_account_id = azurerm_automation_account.this.id

  module_link {
    uri = "https://www.powershellgallery.com/api/v2/package/Microsoft.Graph.Identity.SignIns/${var.graph_module_version}"
  }

  depends_on = [azurerm_automation_powershell72_module.graph_authentication]
}

resource "azurerm_automation_runbook" "cleanup" {
  name                    = var.runbook_name
  location                = var.location
  resource_group_name     = data.azurerm_resource_group.target.name
  automation_account_name = azurerm_automation_account.this.name
  runbook_type            = "PowerShell72"
  log_verbose             = false
  log_progress            = false
  description             = "Two-stage stale-device cleanup (Entra disable/delete + Intune + Autopilot). Port of Matt Kohut's Div-CleanupEntra-Intune-AP-Devices.ps1."
  content                 = file("${path.module}/../../../runbook/Invoke-StaleDeviceCleanup.ps1")
  tags                    = local.base_tags
}
