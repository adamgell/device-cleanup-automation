# Roadmap

Feature tracking for the device-cleanup automation. A feature is **Done** only when it is
built (Terraform in the module, default off unless noted) *and* tested (observed working
end to end in a live demo-tenant deployment). Status values: Planned → Building → Built,
untested → **Done** / Blocked.

| # | Feature | Phase | Status | Test evidence |
|---|---------|-------|--------|---------------|
| 1 | Failed-job email alert (diagnostics → Log Analytics → query alert → action group) | 1 | Built, testing | Test 1 lost to diagnostic-setting activation lag. Test 2 exposed a real bug: PT15M window = PT15M frequency lets late-ingested rows age out un-alerted — fixed to PT30M window. Test 3 in flight under the fix. |
| 2 | Run-completed digest alert (RUN SUMMARY counters, Sev4, `alert_digest_enabled`) | 1.5 | Built, untested | Awaiting apply + DryRun-run test in demo tenant |
| 3 | Would-delete threshold (Sev2, `alert_max_delete_count`) + BackupFailed>0 (Sev1, always on) | 1.5 | Built, untested | Threshold test: demo tenant's 66 would-delete > 50. BackupFailed can only be negative-tested without breaking Key Vault access. |
| 4 | Teams channel notifications (Workflows webhook receiver) | 2 | Built, untested | Mechanism = `alert_webhook_urls` receiver (same as #6). Teams-specific test blocked on a Workflows incoming webhook — channel owner creates it. |
| 5 | SharePoint list run-history via Logic App (+ pretty HTML digest) | 3 | Blocked | SharePoint connector needs interactive OAuth consent — cannot be automated. Owner: Adam, next working session. |
| 6 | Generic webhook receivers (common alert schema, `alert_webhook_urls`) | 3 | Built, untested | Test endpoint ready: HTTP-trigger Logic App in the demo RG; POST arrival observable in run history |
| 7 | Restore truncated tail of `source/` original script | — | Blocked | Original not published anywhere public (verified 2026-08-11). Owner: Adam to request the complete file from the author. Runbook already rebuilds the tail. |

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
