# Phase 1 job alerting (docs/2026-08-11-alerting-request.md): automation job
# diagnostics -> Log Analytics -> scheduled query alert -> action group.
# The action group is the growth point — Teams / SharePoint / generic webhook
# receivers get added to it in later phases with no changes to the alert logic.

locals {
  log_analytics_workspace_id = var.alerting_enabled ? coalesce(
    var.log_analytics_workspace_id,
    try(azurerm_log_analytics_workspace.alerting[0].id, null),
  ) : null

  failed_job_query = <<-KQL
    AzureDiagnostics
    | where ResourceProvider == "MICROSOFT.AUTOMATION" and Category == "JobLogs"
    | where ResultType in ("Failed", "Suspended", "Stopped")
    | project TimeGenerated, RunbookName_s, ResultType, JobId_g, _ResourceId
  KQL
}

# Created only when alerting is on and no workspace was brought in via
# log_analytics_workspace_id.
resource "azurerm_log_analytics_workspace" "alerting" {
  count = var.alerting_enabled && var.log_analytics_workspace_id == null ? 1 : 0

  name                = "log-devicecleanup-${var.environment}-${var.location}"
  location            = var.location
  resource_group_name = data.azurerm_resource_group.target.name
  sku                 = "PerGB2018"
  retention_in_days   = 30

  tags = local.base_tags
}

resource "azurerm_monitor_diagnostic_setting" "automation_jobs" {
  count = var.alerting_enabled ? 1 : 0

  name                       = "job-logs-to-law"
  target_resource_id         = azurerm_automation_account.this.id
  log_analytics_workspace_id = local.log_analytics_workspace_id

  enabled_log {
    category = "JobLogs"
  }

  enabled_log {
    category = "JobStreams"
  }
}

resource "azurerm_monitor_action_group" "alerts" {
  count = var.alerting_enabled ? 1 : 0

  name                = "ag-devicecleanup-${var.environment}"
  resource_group_name = data.azurerm_resource_group.target.name
  short_name          = "devcleanup"

  dynamic "email_receiver" {
    for_each = var.alert_email_addresses
    content {
      name                    = "email-${email_receiver.key}"
      email_address           = email_receiver.value
      use_common_alert_schema = true
    }
  }

  tags = local.base_tags
}

resource "azurerm_monitor_scheduled_query_rules_alert_v2" "job_failed" {
  count = var.alerting_enabled ? 1 : 0

  name                = "alert-devicecleanup-job-failed-${var.environment}"
  display_name        = "Device Cleanup ${var.environment}: runbook job failed"
  description         = "A ${var.runbook_name} job ended Failed/Suspended/Stopped. Check the job output in the Automation account."
  location            = var.location
  resource_group_name = data.azurerm_resource_group.target.name

  scopes    = [local.log_analytics_workspace_id]
  severity  = 1

  evaluation_frequency = "PT15M"
  window_duration      = "PT15M"

  criteria {
    query                   = local.failed_job_query
    time_aggregation_method = "Count"
    operator                = "GreaterThan"
    threshold               = 0
  }

  auto_mitigation_enabled = true

  action {
    action_groups = [azurerm_monitor_action_group.alerts[0].id]
  }

  tags = local.base_tags
}
