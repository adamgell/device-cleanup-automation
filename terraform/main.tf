module "device_cleanup" {
  source = "./modules/device-cleanup"

  customer                = var.customer
  environment             = var.environment
  location                = var.location
  resource_group_name     = var.resource_group_name
  automation_account_name = var.automation_account_name

  backup_enabled        = var.backup_enabled
  key_vault_name        = var.key_vault_name
  secret_retention_days = var.secret_retention_days

  soft_delete_after_days = var.soft_delete_after_days
  hard_delete_after_days = var.hard_delete_after_days

  alerting_enabled           = var.alerting_enabled
  alert_email_addresses      = var.alert_email_addresses
  alert_digest_enabled       = var.alert_digest_enabled
  alert_max_delete_count     = var.alert_max_delete_count
  alert_webhook_urls         = var.alert_webhook_urls
  pretty_email_enabled       = var.pretty_email_enabled
  pretty_email_recipients    = var.pretty_email_recipients
  log_analytics_workspace_id = var.log_analytics_workspace_id

  enable_apply                   = var.enable_apply
  require_disabled_before_delete = var.require_disabled_before_delete
  schedule_enabled               = var.schedule_enabled
  schedule_week_days             = var.schedule_week_days
  schedule_start_time            = var.schedule_start_time
  schedule_timezone              = var.schedule_timezone
  extra_runbook_parameters       = var.extra_runbook_parameters

  tags = var.tags
}

output "device_cleanup" {
  value = module.device_cleanup
}
