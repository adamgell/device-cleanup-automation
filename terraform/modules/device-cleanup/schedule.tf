# Resource addresses retain the historical "weekly" label to preserve existing state.
resource "azurerm_automation_schedule" "weekly" {
  count = var.schedule_enabled ? 1 : 0

  name                    = "sched-${var.runbook_name}-${var.schedule_frequency == "Day" ? "daily" : "weekly"}"
  resource_group_name     = data.azurerm_resource_group.target.name
  automation_account_name = azurerm_automation_account.this.name
  frequency               = var.schedule_frequency
  interval                = 1
  week_days               = var.schedule_frequency == "Week" ? var.schedule_week_days : null
  timezone                = var.schedule_timezone
  start_time              = var.schedule_start_time
  description             = "Recurring stale-device cleanup run. DryRun governed by enable_apply."
}

resource "azurerm_automation_job_schedule" "weekly" {
  count = var.schedule_enabled ? 1 : 0

  resource_group_name     = data.azurerm_resource_group.target.name
  automation_account_name = azurerm_automation_account.this.name
  schedule_name           = azurerm_automation_schedule.weekly[0].name
  runbook_name            = azurerm_automation_runbook.cleanup.name
  parameters              = local.runbook_parameters
}
