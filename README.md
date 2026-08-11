# Device Cleanup Automation

Reusable Azure Automation deployment of Matt Kohut's two-stage stale-device cleanup
(Entra disable at 90 days → hard delete at 120 days, with Intune managedDevice + Autopilot
record cleanup and BitLocker/LAPS backup). Terraform-provisioned, managed-identity
authenticated, multi-customer via tfvars.

Customer-specific configuration (`terraform/deployments/*.tfvars`) is gitignored and
stays local — copy `deployments/example.tfvars` to start a new environment. Nothing
tenant-identifying belongs in tracked files.
Alerting: `docs/2026-08-11-alerting-request.md` — phase 1 (email) shipped; Teams /
SharePoint / webhook phases add receivers to the same action group.

## Layout

- `source/Div-CleanupEntra-Intune-AP-Devices.ps1` — Matt's original delegated/interactive
  script, preserved verbatim. NOTE: this copy is truncated at line 1090 (mid "secrets CSV"
  comment); the runbook rebuilds the missing summary/disconnect tail.
- `runbook/Invoke-StaleDeviceCleanup.ps1` — the Automation port. Every original configuration
  option survives as a runbook parameter with the same default. Environment-forced changes only:
  managed-identity auth, job-stream output, Key Vault secret backup with retention cleanup,
  and `-DeviceListBlobUrl` (blob CSV, same columns/semantics) replacing the local `-DeviceListCsv`.
- `terraform/modules/device-cleanup/` — the reusable module.
- `terraform/deployments/*.tfvars` — one file per customer/environment. New customer = new tfvars.

## What Terraform creates (per environment)

- Automation account (`aa-devicecleanup-<env>-<location>-1` by default) with a
  **system-assigned managed identity**, PowerShell 7.2 runbook, and the pinned
  Microsoft.Graph modules (Authentication, Identity.DirectoryManagement, Identity.SignIns).
- Six Graph **application** role grants to the identity (same list as the original script's
  delegated scopes).
- Key Vault (RBAC, purge protection off) + `Key Vault Secrets Officer` for the identity —
  the runbook stores one JSON secret per hard-deleted device (BitLocker keys + LAPS creds),
  then deletes + purges anything past `secret_retention_days` (e.g. 4 days for a
  customer wanting a short rollback window and no long-term secret storage). Skippable
  entirely with `backup_enabled = false`.
- Optional weekly schedule. `enable_apply = false` (the default) keeps every scheduled run
  in DryRun — flip it in tfvars only after sign-off.
- Optional job alerting (`alerting_enabled = true`, default off): automation job diagnostics
  → Log Analytics (module-created, or bring your own via `log_analytics_workspace_id`) →
  scheduled query alert on Failed/Suspended/Stopped jobs (15-min cadence, auto-mitigating)
  → action group emailing `alert_email_addresses`. Later phases (Teams / SharePoint /
  generic webhook) add receivers to the same action group — see
  `docs/2026-08-11-alerting-request.md`. Note: manual portal/CLI job starts bypass
  Terraform's parameter injection, so a bare start fails the KeyVaultName validation —
  which is also a handy way to test the alert.

## Deploying

Deployer needs: **Contributor** + **User Access Administrator** (or Owner) on the target RG,
and a privileged directory role (Global Administrator / Privileged Role Administrator) for
the Graph app-role grants. A read-only app registration cannot deploy this.

```bash
az login --tenant <customer-tenant>
cd terraform
terraform init
terraform plan  -var-file=deployments/<customer>-dev.tfvars
terraform apply -var-file=deployments/<customer>-dev.tfvars
```

Prod is the same with the prod tfvars (check `schedule_start_time` is still in the
future). All environments share local state — use one `terraform workspace` per
tfvars file if you apply more than one from this directory.

## Validation flow (per customer)

1. Dev apply → start a manual job in the portal (defaults are DryRun).
2. Diff the DRY-RUN would-DELETE/DISABLE list against the customer's existing
   stale/non-compliant device inventory.
3. Prod apply → let the scheduled DryRun produce output for customer sign-off.
4. Flip `enable_apply = true` in the prod tfvars, re-apply.

## Notes for reuse

- All original script knobs not surfaced as first-class variables can be set per-customer via
  `extra_runbook_parameters` (lowercase keys, JSON-literal booleans), e.g.
  `{ disableonly = "true" }` for a customer that never wants hard deletes.
- Curated-list runs: upload a CSV (`DisplayName`/`DeviceId` columns) to a blob the identity
  can read (grant `Storage Blob Data Reader`) and start a job with `devicelistbloburl`.
- Operating-system filtering: pass `OperatingSystemFilter=Windows` for a Windows-only run.
  The filter is applied after age-based or curated-list resolution and before classification.
  For a live Windows-only run, also set `DisableOnly=true` for the first pass unless deletion
  has separately been approved; this filters non-Windows candidates out before any action logic.
  Supported values are `Windows`, `Android`, `AndroidForWork`, `AndroidAOSP`, `iOS`, `IPhone`,
  `IPad`, `macOS`, `Linux`, `Unknown`, and `Other`. Empty is the backward-compatible all-OS default.
- Scheduled Terraform jobs can pass the filter through `extra_runbook_parameters`, for example:
  `{ operatingsystemfilter = "Windows" }`. Always run a fresh DryRun before a live run.
- The runbook never writes secret material to job output — Key Vault only.
- Provider quirk: the Automation API echoes `runbook_type` back as "PowerShell", so azurerm
  plans a runbook replace on already-deployed environments. Harmless (same content re-uploaded,
  schedules relink), but expect `1 to destroy` on the next apply of an existing deployment.
