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
