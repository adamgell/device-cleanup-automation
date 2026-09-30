# Purge safety

Live cleanup now requires `OperatingSystemFilter=Windows`, comma-separated Entra **object IDs** in `ApprovedDeviceObjectIds`, backup enabled, active-hardware protection enabled and lookup bypass disabled. Existing scheduled live jobs without this scope will stop at preflight. `DryRun=true` remains the default. `PurgeOnly=true` excludes disable candidates; `MaxLiveActions` defaults to five (range 1–100). `RequireDisabledBeforeDelete=true` remains the shared default: an enabled device is classified for disable first. Use false only when the approved cohort can be deleted directly.

Complete Intune/Autopilot/activity inventory collection must succeed before any action. Recent or unknown linked Intune activity, non-Windows linked enrollments, missing Autopilot serials and recent or unknown same-serial Intune activity hold the entire candidate. The check-in cutoff follows `HardDeleteAfterDays`. `ExcludedDeviceNamePattern` is an optional regular expression for local asset holds; configure it in private deployment parameters. Existing `HybridDeviceHandling=ReportOnly` suppresses all hybrid device actions.

Missing, empty or undecodable recovery material holds the device. DryRun retrieves recovery material without writing secrets. Live mode writes the backup and reads the exact version back before deleting Intune records, then Autopilot records, then Entra. A backup failure skips that device; a device action failure stops the batch. Partial deletion is possible when a later step fails and is not automatically rolled back. Existing cleanup-success counters named IntuneDeleted/AutopilotDeleted also count already-absent records; verify actual removed records independently.

Supply `KeyVaultName` explicitly when starting a manual job. The shared runbook validates and normalizes the name and retains a blank default; customer-specific hardcoded vault defaults belong only in private deployment copies. Terraform injects the configured vault name into scheduled jobs. Never publish device inventories, recovery material, customer configurations or production job requests.

`RunVaultRetentionCleanup=false` is the default. Enabling it deletes/purges expired backups based on retention tags. The tags do not automatically expire secrets, and an Entra restore does not restore Intune or Autopilot registrations.

## Daily preview configuration

```hcl
schedule_enabled   = true
schedule_frequency = "Day"
enable_apply       = false
# Set schedule_start_time to a future ISO-8601 time and select schedule_timezone.
extra_runbook_parameters = {
  operatingsystemfilter    = "Windows"
  purgeonly                = "true"
  runvaultretentioncleanup = "false"
}
```

Weekly is the module default for compatibility; example.tfvars selects Day. Historical Terraform resource addresses retain the `weekly` label. Switching frequency changes the schedule name and may replace/relink it. An existing daily schedule created outside Terraform requires state reconciliation/import before apply. This code update does not apply Terraform or change any live schedules.

## Validation

`pwsh -NoProfile -File tests/Test-PurgeSafety.ps1` parses the runbook and mocks network calls. It tests incomplete serial lookup, inventory streaming, missing recovery material, dry-run vault isolation, vault failures/read-back mismatch, active hardware, configured exclusions, action ordering, batch limits and hybrid report-only preservation. Production hardening was also exercised in a fresh preview and bounded live batches; customer evidence stays private.
