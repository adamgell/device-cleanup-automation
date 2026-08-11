# Roadmap

Feature tracking for the device-cleanup automation. A feature is **Done** only when it is
built (Terraform in the module, default off unless noted) *and* tested (observed working
end to end in a live demo-tenant deployment). Status values: Planned → Building → Built,
untested → **Done** / Blocked.

| # | Feature | Phase | Status | Test evidence |
|---|---------|-------|--------|---------------|
| 1 | Failed-job email alert (diagnostics → Log Analytics → query alert → action group) | 1 | Built, testing | First test lost to diagnostic-setting activation lag (events before activation are dropped, not backfilled — always wait a few minutes after first apply before failing a test job). Retest in progress. |
| 2 | Run-completed digest alert (RUN SUMMARY counters, Sev4) | 1.5 | Planned | — |
| 3 | Would-delete threshold + BackupFailed>0 alerts | 1.5 | Planned | — |
| 4 | Teams channel notifications (Workflows webhook receiver) | 2 | Planned | Customer dependency: channel owner creates the webhook |
| 5 | SharePoint list run-history via Logic App (+ pretty HTML digest) | 3 | Planned | List schema TBD (open question in alerting request doc) |
| 6 | Generic webhook receivers (common alert schema) | 3 | Planned | — |
| 7 | Restore truncated tail of `source/` original script | — | Planned | Truncated at line 1090; runbook rebuilds the tail |

## Definition of done

1. Terraform applies cleanly on an existing deployment (no unrelated churn beyond the
   known runbook-replace provider quirk).
2. Feature is off by default; existing customer tfvars unaffected until opted in.
3. Observed working end to end in a live demo-tenant deployment (not just plan output).
4. README + `docs/2026-08-11-alerting-request.md` updated; this table updated with
   evidence.

## Known gotchas (carry between customers)

- Manual job starts bypass Terraform's scheduled-job parameter injection — a bare start
  fails the KeyVaultName validation. Pass parameters explicitly, or use it as an alert test.
- Diagnostic settings drop (not backfill) events emitted before the pipeline activates —
  first alert test after an apply needs a fresh job, several minutes later.
- azurerm echoes `runbook_type` as "PowerShell", so every apply on an existing deployment
  plans a harmless runbook replace.
