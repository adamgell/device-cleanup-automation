output "automation_account_name" {
  value = azurerm_automation_account.this.name
}

output "automation_account_id" {
  value = azurerm_automation_account.this.id
}

output "managed_identity_principal_id" {
  description = "Object id of the system-assigned managed identity (Graph app roles are granted to this)."
  value       = azurerm_automation_account.this.identity[0].principal_id
}

output "key_vault_uri" {
  value = var.backup_enabled ? azurerm_key_vault.secrets[0].vault_uri : null
}

output "runbook_name" {
  value = azurerm_automation_runbook.cleanup.name
}

output "scheduled_job_parameters" {
  description = "Parameters each scheduled run passes to the runbook."
  value       = local.runbook_parameters
}

output "action_group_id" {
  description = "Alerting action group id — later phases (Teams/SharePoint/webhook) add receivers here."
  value       = var.alerting_enabled ? azurerm_monitor_action_group.alerts[0].id : null
}
