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

  # RUN SUMMARY counter lines from the runbook's Write-Output stream, e.g.
  # "[2026-08-11 19:48:16Z] [INFO]   ToDelete                 66"
  run_digest_query = <<-KQL
    AzureDiagnostics
    | where ResourceProvider == "MICROSOFT.AUTOMATION" and Category == "JobStreams" and StreamType_s == "Output"
    | where ResultDescription matches regex @"\[INFO\]\s+(Total|ToDisable|Disabled|ToDelete|Deleted|IntuneDeleted|AutopilotDeleted|BackupFailed|Errors)\s+\d+"
    | project TimeGenerated, JobId_g, ResultDescription
  KQL

  delete_threshold_query = <<-KQL
    AzureDiagnostics
    | where ResourceProvider == "MICROSOFT.AUTOMATION" and Category == "JobStreams" and StreamType_s == "Output"
    | extend ToDelete = toint(extract(@"\[INFO\]\s+ToDelete\s+(\d+)", 1, ResultDescription))
    | where isnotnull(ToDelete) and ToDelete > ${var.alert_max_delete_count}
    | project TimeGenerated, JobId_g, ToDelete, ResultDescription
  KQL

  backup_failed_query = <<-KQL
    AzureDiagnostics
    | where ResourceProvider == "MICROSOFT.AUTOMATION" and Category == "JobStreams" and StreamType_s == "Output"
    | extend BackupFailed = toint(extract(@"\[INFO\]\s+BackupFailed\s+(\d+)", 1, ResultDescription))
    | where isnotnull(BackupFailed) and BackupFailed > 0
    | project TimeGenerated, JobId_g, BackupFailed, ResultDescription
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

  # Serves both Teams (a Workflows incoming-webhook URL) and generic
  # endpoints (SIEM/ticketing/PSA). Common alert schema either way.
  dynamic "webhook_receiver" {
    for_each = merge(
      var.alert_webhook_urls,
      var.pretty_email_enabled ? { prettymail = azurerm_logic_app_trigger_http_request.pretty_email[0].callback_url } : {},
    )
    content {
      name                    = "webhook-${webhook_receiver.key}"
      service_uri             = webhook_receiver.value
      use_common_alert_schema = true
    }
  }

  tags = local.base_tags
}

resource "azurerm_monitor_scheduled_query_rules_alert_v2" "job_failed" {
  count = var.alerting_enabled ? 1 : 0

  name                = "alert-devicecleanup-job-failed-${var.environment}"
  display_name        = "Device Cleanup ${var.environment}: runbook job failed"
  description         = "The device cleanup job did not finish -- it ended Failed, Suspended or Stopped, so nothing after that point ran. The run log is attached."
  location            = var.location
  resource_group_name = data.azurerm_resource_group.target.name

  scopes   = [local.log_analytics_workspace_id]
  severity = 1

  evaluation_frequency = "PT15M"
  # Window is 2x frequency on purpose: JobLogs rows land in Log Analytics
  # several minutes after their TimeGenerated, so a window equal to the
  # frequency lets late-arriving rows age out un-alerted. Auto-mitigation
  # absorbs the overlap.
  window_duration = "PT30M"

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

# Sev4 informational digest: fires (and auto-resolves) whenever a run emits its
# RUN SUMMARY counters. The email's search-results table carries the counters.
resource "azurerm_monitor_scheduled_query_rules_alert_v2" "run_digest" {
  count = var.alerting_enabled && var.alert_digest_enabled ? 1 : 0

  name                = "alert-devicecleanup-run-digest-${var.environment}"
  display_name        = "Device Cleanup ${var.environment}: run completed"
  description         = "The device cleanup run finished. The numbers below are what it did -- or, on a dry run, what it would have done. The full device list is attached."
  location            = var.location
  resource_group_name = data.azurerm_resource_group.target.name

  scopes   = [local.log_analytics_workspace_id]
  severity = 4

  evaluation_frequency = "PT15M"
  window_duration      = "PT30M"

  criteria {
    query                   = local.run_digest_query
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

# Sev2 review gate: a run wants to delete more devices than expected.
resource "azurerm_monitor_scheduled_query_rules_alert_v2" "delete_threshold" {
  count = var.alerting_enabled && var.alert_max_delete_count > 0 ? 1 : 0

  name                = "alert-devicecleanup-delete-threshold-${var.environment}"
  display_name        = "Device Cleanup ${var.environment}: would-delete count above ${var.alert_max_delete_count}"
  description         = "This run wanted to permanently delete more than ${var.alert_max_delete_count} device objects. Every one of them is listed in the attached delete-candidates.csv -- review it before anyone runs this for real."
  location            = var.location
  resource_group_name = data.azurerm_resource_group.target.name

  scopes   = [local.log_analytics_workspace_id]
  severity = 2

  evaluation_frequency = "PT15M"
  window_duration      = "PT30M"

  criteria {
    query                   = local.delete_threshold_query
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

# Sev1 stop-the-line: a live run deleted (or would delete) devices whose
# BitLocker/LAPS secrets could not be backed up first.
resource "azurerm_monitor_scheduled_query_rules_alert_v2" "backup_failed" {
  count = var.alerting_enabled ? 1 : 0

  name                = "alert-devicecleanup-backup-failed-${var.environment}"
  display_name        = "Device Cleanup ${var.environment}: secret backup failures"
  description         = "Device secrets (BitLocker recovery keys and LAPS passwords) could not be saved to Key Vault before deletion. Do not run this live until Key Vault access is fixed -- deleting these devices would lose the keys."
  location            = var.location
  resource_group_name = data.azurerm_resource_group.target.name

  scopes   = [local.log_analytics_workspace_id]
  severity = 1

  evaluation_frequency = "PT15M"
  window_duration      = "PT30M"

  criteria {
    query                   = local.backup_failed_query
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
