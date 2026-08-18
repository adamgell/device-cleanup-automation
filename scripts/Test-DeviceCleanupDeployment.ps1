<#
.SYNOPSIS
    Post-apply verification for a device-cleanup deployment. Read-only.

.DESCRIPTION
    Reads a deployment tfvars file and checks the LIVE tenant against what that file
    asked for. Terraform reporting "Apply complete" only proves the API accepted the
    calls; this proves the deployment is actually wired to do its job:

      1. Expected resources exist -- and the optional ones (ACS/Logic App) exist ONLY
         when the tfvars enables them.
      2. Automation account has a managed identity with the six Graph app roles.
      3. Job diagnostics (JobLogs + JobStreams) flow to the Log Analytics workspace.
         Without this every alert rule is silently dead.
      4. Alert rules exist, are ENABLED, and point at the action group.
      5. Action group has at least one enabled receiver -- an alert with no receiver
         is the failure this whole check exists to catch.
      6. Schedule state matches schedule_enabled (report-only deployments have none).
      7. Key Vault: soft delete on, purge protection OFF (the runbook purges backed-up
         secrets after secret_retention_days; purge protection would break that).

    Exits 1 if any check fails, so it can gate a pipeline.

.PARAMETER TfvarsPath
    Path to the deployment tfvars (e.g. terraform/deployments/contoso-prod.tfvars).

.EXAMPLE
    ./Test-DeviceCleanupDeployment.ps1 -TfvarsPath ../terraform/deployments/presbyterian-homes-prod.tfvars
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $TfvarsPath
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

# Graph app role ids the module grants. Names are for the report only.
$GraphRoles = [ordered]@{
    '1138cb37-bd11-4084-a2b7-9f71582aeddb' = 'Device.ReadWrite.All'
    '7ab1d382-f21e-4acd-a863-ba3e13f7da61' = 'Directory.Read.All'
    '57f1cf28-c0c4-4ec3-9a30-19a2eaaf2f6e' = 'BitlockerKey.Read.All'
    '884b599e-4d48-43a5-ba94-15c414d00588' = 'DeviceLocalCredential.Read.All'
    '243333ab-4d21-40cb-a475-36241daa0842' = 'DeviceManagementManagedDevices.ReadWrite.All'
    '5ac13192-7ace-4fcf-b828-1a26f28068ee' = 'DeviceManagementServiceConfig.ReadWrite.All'
}

$script:Failures = 0

function Write-Check {
    param([string] $Name, [bool] $Pass, [string] $Detail)
    if ($Pass) {
        Write-Host ('  [ OK ] {0}' -f $Name) -ForegroundColor Green
    }
    else {
        Write-Host ('  [FAIL] {0}' -f $Name) -ForegroundColor Red
        $script:Failures++
    }
    if ($Detail) { Write-Host ('         {0}' -f $Detail) -ForegroundColor DarkGray }
}

function Get-TfvarValue {
    param([string] $Text, [string] $Name)
    $m = [regex]::Match($Text, ('(?m)^\s*{0}\s*=\s*(.+?)\s*(?:#.*)?$' -f [regex]::Escape($Name)))
    if (-not $m.Success) { return $null }
    $m.Groups[1].Value.Trim().Trim('"')
}

function Invoke-Az {
    param([string[]] $Arguments)
    $out = & az @Arguments 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    if (-not $out) { return $null }
    $out | ConvertFrom-Json
}

if (-not (Test-Path -LiteralPath $TfvarsPath)) { throw "tfvars not found: $TfvarsPath" }
$tf = Get-Content -LiteralPath $TfvarsPath -Raw

$sub = Get-TfvarValue $tf 'subscription_id'
$rg = Get-TfvarValue $tf 'resource_group_name'
$env = Get-TfvarValue $tf 'environment'
$aa = Get-TfvarValue $tf 'automation_account_name'
$kv = Get-TfvarValue $tf 'key_vault_name'
$alerting = (Get-TfvarValue $tf 'alerting_enabled') -eq 'true'
$prettyMail = (Get-TfvarValue $tf 'pretty_email_enabled') -eq 'true'
$scheduled = (Get-TfvarValue $tf 'schedule_enabled') -eq 'true'
$applyOn = (Get-TfvarValue $tf 'enable_apply') -eq 'true'

Write-Host ''
Write-Host ('Verifying {0} / {1} (environment: {2})' -f $rg, $sub, $env) -ForegroundColor Cyan
Write-Host ('  tfvars: {0}' -f (Resolve-Path -LiteralPath $TfvarsPath)) -ForegroundColor DarkGray
Write-Host ''

# --- 1. resources -------------------------------------------------------------
Write-Host 'Resources' -ForegroundColor Cyan
$resources = Invoke-Az @('resource', 'list', '--subscription', $sub, '-g', $rg, '-o', 'json')
if ($null -eq $resources) { throw "Cannot read resource group '$rg'. Wrong subscription, or the apply did not run." }
$names = @($resources | ForEach-Object { $_.name })

Write-Check 'Automation account' ($names -contains $aa) $aa
Write-Check 'Key Vault' ($names -contains $kv) $kv
if ($alerting) {
    Write-Check 'Log Analytics workspace' ([bool]($names -match '^log-devicecleanup-'))
    Write-Check 'Action group' ($names -contains "ag-devicecleanup-$env")
}

# ACS/Logic App must be absent when pretty email is off -- leftovers mean a stale apply.
$acs = @($names | Where-Object { $_ -match '^acs' -or $_ -match '^logic-devicecleanup' })
if ($prettyMail) {
    Write-Check 'ACS + Logic App present' ($acs.Count -ge 2) ($acs -join ', ')
}
else {
    Write-Check 'No ACS/Logic App (pretty email off)' ($acs.Count -eq 0) `
        $(if ($acs.Count) { 'Leftover: ' + ($acs -join ', ') } else { 'none, as expected' })
}

# --- 2. managed identity + Graph roles ----------------------------------------
Write-Host ''
Write-Host 'Managed identity' -ForegroundColor Cyan
$aaObj = Invoke-Az @('resource', 'show', '--subscription', $sub, '-g', $rg, '-n', $aa,
    '--resource-type', 'Microsoft.Automation/automationAccounts', '-o', 'json')
$mi = if ($aaObj -and $aaObj.identity) { $aaObj.identity.principalId } else { $null }
Write-Check 'System-assigned identity' ([bool]$mi) $mi

if ($mi) {
    $assigned = Invoke-Az @('rest', '--method', 'get', '--url',
        "https://graph.microsoft.com/v1.0/servicePrincipals/$mi/appRoleAssignments", '-o', 'json')
    $ids = @($assigned.value | ForEach-Object { $_.appRoleId })
    foreach ($id in $GraphRoles.Keys) {
        Write-Check ('Graph role: {0}' -f $GraphRoles[$id]) ($ids -contains $id)
    }
    $extra = @($ids | Where-Object { $_ -notin $GraphRoles.Keys })
    if ($extra.Count) {
        Write-Host ('  [WARN] {0} unexpected Graph role(s) granted: {1}' -f $extra.Count, ($extra -join ', ')) -ForegroundColor Yellow
    }
}

# --- 3-5. alerting chain ------------------------------------------------------
if ($alerting) {
    Write-Host ''
    Write-Host 'Alerting' -ForegroundColor Cyan

    $aaId = "/subscriptions/$sub/resourceGroups/$rg/providers/Microsoft.Automation/automationAccounts/$aa"
    $diag = Invoke-Az @('monitor', 'diagnostic-settings', 'list', '--subscription', $sub, '--resource', $aaId, '-o', 'json')
    # az returns {value:[...]} on some versions and a bare array on others; absent = $null.
    $settings = if ($null -eq $diag) { @() }
    elseif ($diag.PSObject.Properties.Name -contains 'value') { @($diag.value) }
    else { @($diag) }
    $enabledCats = @($settings | ForEach-Object { $_.logs } | Where-Object { $_ -and $_.enabled } | ForEach-Object { $_.category })
    Write-Check 'JobLogs -> Log Analytics' ($enabledCats -contains 'JobLogs') 'without this, every alert rule is dead'
    Write-Check 'JobStreams -> Log Analytics' ($enabledCats -contains 'JobStreams') 'source of the RUN SUMMARY counters'

    $agName = "ag-devicecleanup-$env"
    $ag = Invoke-Az @('monitor', 'action-group', 'show', '--subscription', $sub, '-g', $rg, '-n', $agName, '-o', 'json')
    $live = if ($ag -and $ag.PSObject.Properties.Name -contains 'emailReceivers') {
        @($ag.emailReceivers | Where-Object { $_.status -eq 'Enabled' })
    } else { @() }
    Write-Check 'Action group has an enabled recipient' ($live.Count -gt 0) `
        (($live | ForEach-Object { $_.emailAddress }) -join ', ')

    foreach ($rule in @('job-failed', 'run-digest', 'delete-threshold', 'backup-failed')) {
        $name = "alert-devicecleanup-$rule-$env"
        $r = Invoke-Az @('monitor', 'scheduled-query', 'show', '--subscription', $sub, '-g', $rg, '-n', $name, '-o', 'json')
        if ($null -eq $r) { Write-Check "Alert rule: $rule" $false 'not found'; continue }
        $wired = $null -ne $ag -and @($r.actions.actionGroups) -contains $ag.id
        Write-Check "Alert rule: $rule" ($r.enabled -and $wired) `
            ('severity {0}, enabled={1}, wired to action group={2}' -f $r.severity, $r.enabled, $wired)
    }
}

# --- 6. run mode --------------------------------------------------------------
Write-Host ''
Write-Host 'Run mode' -ForegroundColor Cyan
$schedules = Invoke-Az @('automation', 'schedule', 'list', '--subscription', $sub, '-g', $rg,
    '--automation-account-name', $aa, '-o', 'json')
$count = if ($schedules) { @($schedules).Count } else { 0 }
Write-Check ('Schedule state matches schedule_enabled={0}' -f $scheduled.ToString().ToLower()) `
    (($scheduled -and $count -gt 0) -or (-not $scheduled -and $count -eq 0)) `
    ('{0} schedule(s) found' -f $count)

if ($applyOn) {
    Write-Host '  [WARN] enable_apply = true -- scheduled runs will MAKE CHANGES, not dry-run.' -ForegroundColor Yellow
}
else {
    Write-Host '  [INFO] enable_apply = false -- report-only.' -ForegroundColor DarkGray
}

# --- 7. key vault -------------------------------------------------------------
Write-Host ''
Write-Host 'Key Vault' -ForegroundColor Cyan
$vault = Invoke-Az @('keyvault', 'show', '--subscription', $sub, '-n', $kv, '-o', 'json')
if ($vault) {
    Write-Check 'Soft delete enabled' ([bool]$vault.properties.enableSoftDelete)
    # The runbook deletes AND purges backed-up secrets after secret_retention_days.
    # Purge protection would block the purge, so it must stay off by design.
    $purge = $vault.properties.enablePurgeProtection
    Write-Check 'Purge protection off (required by the purge step)' (-not $purge)
}

Write-Host ''
if ($script:Failures -eq 0) {
    Write-Host 'All checks passed.' -ForegroundColor Green
    Write-Host 'Still unproven: that the runbook can actually reach Graph. Run one manual dry run.' -ForegroundColor DarkGray
    exit 0
}
Write-Host ('{0} check(s) FAILED.' -f $script:Failures) -ForegroundColor Red
exit 1
