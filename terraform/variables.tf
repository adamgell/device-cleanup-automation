variable "subscription_id" {
  description = "Target Azure subscription."
  type        = string
}

variable "customer" {
  type = string
}

variable "environment" {
  type = string
}

variable "location" {
  type    = string
  default = "eastus"
}

variable "resource_group_name" {
  type = string
}

variable "automation_account_name" {
  type    = string
  default = null
}

variable "backup_enabled" {
  type    = bool
  default = true
}

variable "key_vault_name" {
  type    = string
  default = null
}

variable "secret_retention_days" {
  type    = number
  default = 4
}

variable "soft_delete_after_days" {
  type    = number
  default = 90
}

variable "hard_delete_after_days" {
  type    = number
  default = 120
}

variable "enable_apply" {
  type    = bool
  default = false
}

variable "schedule_enabled" {
  type    = bool
  default = false
}

variable "schedule_week_days" {
  type    = list(string)
  default = ["Sunday"]
}

variable "schedule_start_time" {
  type    = string
  default = null
}

variable "schedule_timezone" {
  type    = string
  default = "America/New_York"
}

variable "extra_runbook_parameters" {
  type    = map(string)
  default = {}
}

variable "tags" {
  type    = map(string)
  default = {}
}

variable "alerting_enabled" {
  type    = bool
  default = false
}

variable "alert_email_addresses" {
  type    = list(string)
  default = []
}

variable "log_analytics_workspace_id" {
  type    = string
  default = null
}

variable "alert_digest_enabled" {
  type    = bool
  default = false
}

variable "alert_max_delete_count" {
  type    = number
  default = 0
}

variable "alert_webhook_urls" {
  type    = map(string)
  default = {}
}

variable "pretty_email_enabled" {
  type    = bool
  default = false
}

variable "pretty_email_recipients" {
  type    = list(string)
  default = []
}

variable "require_disabled_before_delete" {
  description = "Disable stale devices before any hard delete. Reversible step first; see module variable."
  type        = bool
  default     = true
}

# --- ACS sender domain / least-privilege (pass-through to the module) ----------

variable "email_domain_management" {
  description = "AzureManaged | CustomerManaged | CustomerManagedInExchangeOnline. See module variables.tf."
  type        = string
  default     = "AzureManaged"
}

variable "email_custom_domain_name" {
  description = "Sender domain, e.g. 'notify.contoso.org'. Required unless email_domain_management is AzureManaged."
  type        = string
  default     = null
}

variable "email_sender_username" {
  description = "Local part of the sender address. Default DoNotReply."
  type        = string
  default     = "DoNotReply"
}

variable "acs_email_role_definition_name" {
  description = "Role granted to the Logic App identity on the ACS resource. Default Contributor."
  type        = string
  default     = "Contributor"
}
