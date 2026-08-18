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

output "email_sender_address" {
  description = "From: address the pretty HTML alerts are sent as."
  value       = var.pretty_email_enabled ? "${var.email_sender_username}@${azurerm_email_communication_service_domain.pretty[0].from_sender_domain}" : null
}

output "email_domain_verification_records" {
  description = <<-EOT
    DNS records the customer must publish to verify a CustomerManaged sender domain
    (empty for AzureManaged / Exchange-Online-verified domains).
  EOT
  value       = var.pretty_email_enabled && var.email_domain_management == "CustomerManaged" ? try(azurerm_email_communication_service_domain.pretty[0].verification_records, null) : null
}
