# Feature request: job alerting for Device Cleanup automation

**Date:** 2026-08-11 · **Requested by:** Adam Gell · **Status:** Phase 1 (email) implemented
2026-08-11 — `terraform/modules/device-cleanup/alerting.tf`, tested in a demo tenant. Phases 2–3 open.

## Ask

Alert on Device Cleanup runbook job outcomes. Start small with **email**, but the design
must grow into **Teams**, **SharePoint lists**, and **arbitrary webhook POSTs** without
rearchitecting.

## What to alert on

| Signal | Priority | Notes |
|---|---|---|
| Job **Failed / Suspended / Stopped** | P1 | e.g. a bare manual start (BackupBLandLAPs with empty KeyVaultName) fails fast and goes unnoticed until output is pulled manually |
| Job **Completed** with summary | P2 | digest of RUN SUMMARY counters (Total / ToDisable / ToDelete / Errors) |
| **Threshold breach** | P2 | would-delete count above N → hold and review before any live run |
| **BackupFailed > 0** on a live run | P1 | secrets not vaulted before delete is a stop-the-line condition |

## Recommended architecture

Route everything through **Azure Monitor: diagnostic settings → Log Analytics →
scheduled query alert rules → action group**. The action group is the extension point —
each new channel is one more receiver, no changes to the runbook or the alert logic.

```
Automation account (JobLogs/JobStreams diagnostics)
        └─> Log Analytics workspace
              └─> Scheduled query alert rules (Failed jobs; counter thresholds)
                    └─> Action group "ag-devicecleanup-<env>"
                          ├─ Phase 1: email receiver(s)
                          ├─ Phase 2: Teams (Workflows incoming-webhook receiver)
                          ├─ Phase 3: Logic App receiver -> SharePoint list item
                          └─ Phase 3: generic webhook receiver (JSON POST, common alert schema)
```

Rejected alternative: sending mail from inside the runbook (`Send-MgUserMail`). It would
require granting the managed identity `Mail.Send` (broad, tenant-wide), couples alerting
to script code, and misses jobs that die before the mail line runs. Platform-side
alerting has none of these problems.

## Phasing

- **Phase 1 (email, now):** Log Analytics workspace, diagnostic setting on the automation
  account, action group with email receiver(s), query alert on
  `AzureDiagnostics | ResultType in ("Failed","Suspended","Stopped")`, 15-min evaluation.
- **Phase 2 (Teams):** customer creates a Teams Workflows incoming webhook; add it as a
  receiver. Config-only change.
- **Phase 3 (SharePoint / generic webhook):** Logic App (managed identity → SharePoint
  list item per run for trend tracking); generic webhook receiver using the Azure Monitor
  common alert schema for anything else (ticketing, SIEM, PSA).

## Terraform surface (module additions)

```hcl
alerting_enabled        = true
alert_email_addresses   = ["ops@customer.com"]
alert_teams_webhook_url = null   # phase 2
alert_webhook_urls      = []     # phase 3
alert_max_delete_count  = 50     # 0 = disabled
log_analytics_workspace_id = null  # bring-your-own, else module creates one
```

All optional, default off — existing deployments unaffected until opted in.

## Cost & prerequisites

- Log Analytics ingestion for job logs is trivial (KB/run); alert rules ~$0.10–1.50/mo
  each; action groups effectively free at this volume.
- No new Graph permissions. Deployer needs Monitoring Contributor on the RG (already
  covered by Contributor).
- Customer dependency (phase 2): a Teams channel owner must create the Workflows webhook.

## Open questions

1. Per-customer alert recipients in tfvars, or a shared internal ops mailbox as well?
2. Should Completed-run digests go to the customer or stay internal-only?
3. SharePoint list schema — mirror the RUN SUMMARY counters, or per-device rows?
