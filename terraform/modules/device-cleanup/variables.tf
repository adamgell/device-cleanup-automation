variable "customer" {
  description = "Short customer slug used in naming/tags (e.g. 'contoso')."
  type        = string
}

variable "environment" {
  description = "Deployment environment: dev | prod (free-form for other schemes)."
  type        = string
}

variable "location" {
  description = "Azure region."
  type        = string
  default     = "eastus"
}

variable "resource_group_name" {
  description = "EXISTING resource group to deploy into (not created by this module)."
  type        = string
}

variable "automation_account_name" {
  description = "Automation account name. Defaults to aa-devicecleanup-<env>-<location>-1."
  type        = string
  default     = null
}

variable "runbook_name" {
  description = "Runbook name inside the Automation account."
  type        = string
  default     = "Invoke-StaleDeviceCleanup"
}

variable "graph_module_version" {
  description = "Microsoft.Graph PowerShell module version imported into the account."
  type        = string
  default     = "2.25.0"
}

variable "graph_app_roles" {
  description = "Graph application permissions granted to the managed identity. Matches the original script's scope list."
  type        = list(string)
  default = [
    "Device.ReadWrite.All",
    "Directory.Read.All",
    "BitlockerKey.Read.All",
    "DeviceLocalCredential.Read.All",
    "DeviceManagementManagedDevices.ReadWrite.All",
    "DeviceManagementServiceConfig.ReadWrite.All",
  ]
}

# --- BitLocker / LAPS backup vault -------------------------------------------

variable "backup_enabled" {
  description = "Create the Key Vault and enable BitLocker/LAPS backup (original BackupBLandLAPs)."
  type        = bool
  default     = true
}

variable "key_vault_name" {
  description = "Globally-unique Key Vault name for secret backups. Required when backup_enabled."
  type        = string
  default     = null
}

variable "secret_retention_days" {
  description = "Days to retain backed-up device secrets before the runbook deletes+purges them."
  type        = number
  default     = 4
}

# --- Lifecycle thresholds -----------------------------------------------------

variable "soft_delete_after_days" {
  description = "Days inactive before a device is disabled (stage 1)."
  type        = number
  default     = 90
}

variable "hard_delete_after_days" {
  description = "Days inactive before a device is deleted (stage 2)."
  type        = number
  default     = 120
}

# --- Run mode / schedule --------------------------------------------------------

variable "enable_apply" {
  description = "false = scheduled runs pass DryRun=true (report-only). Flip to true only after sign-off."
  type        = bool
  default     = false
}

variable "schedule_enabled" {
  description = "Create the recurring schedule. Dev instances typically leave this false (manual runs)."
  type        = bool
  default     = false
}

variable "schedule_week_days" {
  description = "Days of week for the schedule."
  type        = list(string)
  default     = ["Sunday"]
}

variable "schedule_start_time" {
  description = "ISO-8601 first occurrence (must be > 5 min in the future at apply time). Sets the time-of-day for the weekly run."
  type        = string
  default     = null
}

variable "schedule_timezone" {
  description = "IANA timezone for the schedule."
  type        = string
  default     = "America/New_York"
}

variable "extra_runbook_parameters" {
  description = <<-EOT
    Additional lowercase runbook parameters merged into the scheduled job, for
    any original option not surfaced as a first-class variable, e.g.:
      { disableonly = "true", operatingsystemfilter = "Windows", deleteautopilotobjects = "false" }
    Boolean values must be the JSON literals "true"/"false".
  EOT
  type        = map(string)
  default     = {}
}

variable "tags" {
  description = "Tags applied to created resources."
  type        = map(string)
  default     = {}
}

# --- Alerting (phase 1: email — docs/2026-08-11-alerting-request.md) -----------

variable "alerting_enabled" {
  description = "Wire automation job diagnostics into Log Analytics and alert (email) on Failed/Suspended/Stopped jobs."
  type        = bool
  default     = false
}

variable "alert_email_addresses" {
  description = "Email recipients on the action group. Required non-empty when alerting_enabled."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for e in var.alert_email_addresses : can(regex("@", e))])
    error_message = "Each entry must be an email address."
  }
}

variable "log_analytics_workspace_id" {
  description = "Existing Log Analytics workspace resource id to reuse. Null = module creates log-devicecleanup-<env>-<location>."
  type        = string
  default     = null
}

variable "alert_digest_enabled" {
  description = "Also alert (Sev4 informational) with the RUN SUMMARY counters after every completed run."
  type        = bool
  default     = false
}

variable "alert_max_delete_count" {
  description = "Alert (Sev2) when a run's ToDelete counter exceeds this. 0 disables the threshold alert."
  type        = number
  default     = 0
}

variable "alert_webhook_urls" {
  description = "name => URL map of webhook receivers on the action group (Teams Workflows incoming-webhook URLs or generic endpoints). Common alert schema."
  type        = map(string)
  default     = {}
}

variable "pretty_email_enabled" {
  description = "Send composed HTML alert emails via ACS + Logic App (in addition to any plain action-group emails)."
  type        = bool
  default     = false
}

variable "pretty_email_recipients" {
  description = "Recipients of the pretty HTML alert emails. Required non-empty when pretty_email_enabled."
  type        = list(string)
  default     = []
}

variable "require_disabled_before_delete" {
  description = <<-EOT
    When true (default), a stale device that is still enabled is DISABLED first and only
    hard-deleted on a later run. Disable is reversible; delete is not. Set false only for a
    cohort that has already been through a disable cycle and been reviewed.
  EOT
  type        = bool
  default     = true
}
