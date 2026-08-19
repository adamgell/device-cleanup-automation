<#
.SYNOPSIS
    Two-stage on-premises AD cleanup for stale HYBRID-JOINED devices, driven by
    the cloud runbook's OnPremRemediationRequired export.

.DESCRIPTION
    Companion to Invoke-StaleDeviceCleanup (Azure Automation). The cloud runbook
    cannot durably disable or delete hybrid-joined devices: Entra Connect
    re-syncs accountEnabled from the on-prem computer account, which reverted
    all 93 hybrid disables at Presbyterian Homes within one day (verified
    2026-08-19, evidence/ph-prod-delete-pass-20260819/FINDINGS.md).

    The durable path for hybrid devices is on-prem:
        AD (this script) -> Entra Connect sync removes/disables the Entra
        device object -> Intune record is mopped up by the Intune device
        cleanup rule (or the cloud runbook, for objects it can still see).

    Stage model (mirrors the cloud runbook):
      1. DISABLE: stale, enabled computer accounts are disabled and stamped
         (description prefix records the date and prior description).
      2. DELETE: only accounts THIS SCRIPT previously disabled (stamp present)
         AND disabled at least -MinDisabledDays ago are deleted.
      Unstamped disabled accounts are never touched.

    Guards:
      - AD-native staleness check: a device is skipped as ALIVE if EITHER
        lastLogonTimestamp OR pwdLastSet is newer than -StaleThresholdDays.
        (Computer accounts rotate their password ~every 30 days; a recent
        pwdLastSet means the machine is alive regardless of Entra sign-in
        telemetry.)
      - DryRun defaults to $true. Nothing changes until -DryRun:$false.
      - SupportsShouldProcess: -WhatIf / -Confirm honored on every write.
      - ProtectedFromAccidentalDeletion objects are reported, never deleted.
      - Devices not found in AD are reported as NotFound, not treated as done.

    Run on a domain-joined machine with RSAT ActiveDirectory, as an account
    with disable/delete rights on the target computer objects. Enable the AD
    Recycle Bin before the first delete pass if it is not already on.

.PARAMETER DeviceListPath
    CSV with at least a DisplayName column (the runbook's hybrid export, or
    any list of computer names). Names are matched to sAMAccountName "<name>$".

.PARAMETER DryRun
    Default $true: report intended actions only. Set $false to act.

.PARAMETER StaleThresholdDays
    A device is only actionable if BOTH lastLogonTimestamp and pwdLastSet are
    older than this many days. Default 120 (matches HardDeleteAfterDays).

.PARAMETER MinDisabledDays
    Minimum days between the stamped disable and the delete. Default 7.

.PARAMETER SearchBase
    Optional OU distinguished name to constrain lookups.

.PARAMETER Server
    Optional domain controller to pin all reads and writes to.

.PARAMETER OutputPath
    Results CSV path. Default: .\AdCleanup-<timestamp>.csv

.EXAMPLE
    .\Invoke-StaleHybridAdCleanup.ps1 -DeviceListPath .\hybrid-stale.csv
    Dry run: shows what would be disabled or deleted, writes the results CSV.

.EXAMPLE
    .\Invoke-StaleHybridAdCleanup.ps1 -DeviceListPath .\hybrid-stale.csv -DryRun:$false -WhatIf
    Live-mode logic with per-object -WhatIf confirmation preview.

.NOTES
    Author: CDW (Adam Gell) - Presbyterian Homes engagement, 2026-08-19.
    Safety: mutating-guarded (DryRun default + SupportsShouldProcess).
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -Path $_ -PathType Leaf })]
    [string] $DeviceListPath,

    [Parameter()] [bool]   $DryRun = $true,
    [Parameter()] [int]    $StaleThresholdDays = 120,
    [Parameter()] [int]    $MinDisabledDays = 7,
    [Parameter()] [string] $SearchBase = '',
    [Parameter()] [string] $Server = '',
    [Parameter()] [string] $OutputPath = ''
)

$ErrorActionPreference = 'Stop'
Import-Module -Name ActiveDirectory -ErrorAction Stop

$stampPrefix = 'CDW-StaleCleanup-Disabled'
$runStamp    = (Get-Date).ToString('yyyyMMdd-HHmmss')
$today       = Get-Date
$staleCutoff = $today.AddDays(-1 * $StaleThresholdDays)
if (-not $OutputPath) { $OutputPath = Join-Path -Path (Get-Location) -ChildPath "AdCleanup-$runStamp.csv" }

function Write-Log {
    param(
        [Parameter(Mandatory)] [string] $Message,
        [ValidateSet('INFO', 'WARN', 'ACTION', 'ERROR')] [string] $Level = 'INFO'
    )
    Write-Output ("[{0}] [{1}] {2}" -f (Get-Date -Format 'u'), $Level, $Message)
}

$adCommon = @{ ErrorAction = 'Stop' }
if ($Server) { $adCommon['Server'] = $Server }

$rows = Import-Csv -Path $DeviceListPath
if (-not ($rows | Get-Member -Name 'DisplayName' -MemberType NoteProperty)) {
    throw "Input CSV '$DeviceListPath' has no DisplayName column."
}

Write-Log "===== RUN $runStamp ====="
Write-Log "Input: $($rows.Count) devices from '$DeviceListPath'"
Write-Log "DryRun=$DryRun  StaleThresholdDays=$StaleThresholdDays  MinDisabledDays=$MinDisabledDays"
if ($DryRun) { Write-Log 'DryRun is ON: no changes will be made.' -Level WARN }

$results  = New-Object -TypeName System.Collections.Generic.List[object]
$counters = [ordered]@{
    Total = 0; NotFound = 0; AliveInAd = 0; Disabled = 0; WouldDisable = 0
    Deleted = 0; WouldDelete = 0; AwaitingDeleteWindow = 0
    DisabledByOther = 0; DeletionProtected = 0; Errors = 0
}

foreach ($row in $rows) {
    $name = $row.DisplayName.Trim()
    if (-not $name) { continue }
    $counters.Total++

    $result = [pscustomobject]@{
        DisplayName = $name; Found = $false; Enabled = $null
        LastLogonTimestamp = $null; PwdLastSet = $null
        Action = ''; Status = ''; Detail = ''
    }

    try {
        $getParams = @{
            Filter     = "sAMAccountName -eq '$name`$'"
            Properties = @('lastLogonTimestamp', 'pwdLastSet', 'description', 'enabled', 'whenChanged', 'ProtectedFromAccidentalDeletion')
        } + $adCommon
        if ($SearchBase) { $getParams['SearchBase'] = $SearchBase }
        $computer = Get-ADComputer @getParams

        if (-not $computer) {
            $result.Status = 'NotFound'; $counters.NotFound++
            Write-Log "NOT FOUND in AD: '$name' (already removed, renamed, or outside SearchBase)." -Level WARN
            $results.Add($result); continue
        }

        $result.Found   = $true
        $result.Enabled = $computer.Enabled
        $lastLogon = if ($computer.lastLogonTimestamp) { [datetime]::FromFileTime($computer.lastLogonTimestamp) } else { $null }
        $pwdSet    = if ($computer.pwdLastSet)         { [datetime]::FromFileTime($computer.pwdLastSet) }         else { $null }
        $result.LastLogonTimestamp = $lastLogon
        $result.PwdLastSet         = $pwdSet

        if (($lastLogon -and $lastLogon -gt $staleCutoff) -or ($pwdSet -and $pwdSet -gt $staleCutoff)) {
            $result.Status = 'AliveInAd'; $counters.AliveInAd++
            $result.Detail = "AD activity newer than $StaleThresholdDays days (lastLogon=$lastLogon, pwdLastSet=$pwdSet). Cloud staleness signal was wrong for this device."
            Write-Log "ALIVE IN AD, skipping: '$name' -- $($result.Detail)" -Level WARN
            $results.Add($result); continue
        }

        if ($computer.Enabled) {
            $result.Action = 'Disable'
            if ($DryRun) {
                $result.Status = 'WouldDisable'; $counters.WouldDisable++
                Write-Log "DRY-RUN would DISABLE '$name' (lastLogon=$lastLogon, pwdLastSet=$pwdSet)."
            }
            elseif ($PSCmdlet.ShouldProcess($name, 'Disable stale AD computer account')) {
                $newDescription = "{0} {1} (was: {2})" -f $stampPrefix, $today.ToString('yyyy-MM-dd'), $computer.description
                Disable-ADAccount -Identity $computer.DistinguishedName @adCommon
                Set-ADComputer -Identity $computer.DistinguishedName -Description $newDescription @adCommon
                $result.Status = 'Disabled'; $counters.Disabled++
                Write-Log "DISABLED '$name' and stamped description." -Level ACTION
            }
            $results.Add($result); continue
        }

        if ($computer.description -notlike "$stampPrefix*") {
            $result.Status = 'DisabledByOther'; $counters.DisabledByOther++
            $result.Detail = 'Disabled but not stamped by this script; left untouched.'
            Write-Log "SKIP (disabled by someone else): '$name'." -Level WARN
            $results.Add($result); continue
        }

        $stampDate = $null
        if ($computer.description -match "$stampPrefix (\d{4}-\d{2}-\d{2})") {
            $stampDate = [datetime]::ParseExact($Matches[1], 'yyyy-MM-dd', $null)
        }
        if (-not $stampDate -or $stampDate -gt $today.AddDays(-1 * $MinDisabledDays)) {
            $result.Status = 'AwaitingDeleteWindow'; $counters.AwaitingDeleteWindow++
            $result.Detail = "Stamped $stampDate; delete allowed after $MinDisabledDays days."
            Write-Log "HOLD (inside $MinDisabledDays-day window): '$name' stamped $stampDate."
            $results.Add($result); continue
        }

        if ($computer.ProtectedFromAccidentalDeletion) {
            $result.Status = 'DeletionProtected'; $counters.DeletionProtected++
            $result.Detail = 'ProtectedFromAccidentalDeletion is set; clear it manually if deletion is intended.'
            Write-Log "SKIP (deletion-protected): '$name'." -Level WARN
            $results.Add($result); continue
        }

        $result.Action = 'Delete'
        if ($DryRun) {
            $result.Status = 'WouldDelete'; $counters.WouldDelete++
            Write-Log "DRY-RUN would DELETE '$name' (stamped $stampDate)."
        }
        elseif ($PSCmdlet.ShouldProcess($name, "Delete AD computer account (disabled since $stampDate)")) {
            Remove-ADComputer -Identity $computer.DistinguishedName -Confirm:$false @adCommon
            $result.Status = 'Deleted'; $counters.Deleted++
            Write-Log "DELETED '$name'." -Level ACTION
        }
        $results.Add($result)
    }
    catch {
        $result.Status = 'Error'; $result.Detail = $_.Exception.Message; $counters.Errors++
        Write-Log "ERROR on '$name': $($_.Exception.Message)" -Level ERROR
        $results.Add($result)
    }
}

Write-Log '===== RUN SUMMARY ====='
foreach ($key in $counters.Keys) { Write-Log ("  {0,-22} {1}" -f $key, $counters[$key]) }
$results | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8
Write-Log "Results written to $OutputPath"
if ($DryRun) { Write-Log 'DryRun was ON -- re-run with -DryRun:$false to act.' -Level WARN }
Write-Log 'After live disables/deletes: Entra Connect propagates on its next cycle; the Entra device object disables/deletes accordingly. Intune records for deleted devices are mopped up by the Intune device cleanup rule.'
