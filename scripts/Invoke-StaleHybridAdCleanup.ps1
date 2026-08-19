<#
.SYNOPSIS
    Two-stage on-premises AD cleanup for stale hybrid-joined devices, selecting
    candidates directly from AD attributes. Run manually on a domain-joined host.

.DESCRIPTION
    Companion to Invoke-StaleDeviceCleanup (Azure Automation). The cloud runbook
    cannot durably disable or delete hybrid-joined devices: Entra Connect
    re-syncs accountEnabled from the on-prem computer account, which reverted
    all 93 hybrid disables at Presbyterian Homes within one day (verified
    2026-08-19, evidence/ph-prod-delete-pass-20260819/FINDINGS.md).

    Candidate selection is AD-native (customer direction, 2026-08-19): staleness
    is judged from lastLogonTimestamp AND pwdLastSet, not from cloud telemetry.
    Cleanup flow per surface:
        AD (this script) -> Entra Connect sync disables/removes the Entra
        device object -> Intune records are mopped up by the Intune device
        cleanup rule.
    Posting status/logs back to the automation service is a planned later
    addition; this version writes a per-run results CSV locally.

    Stage model (mirrors the cloud runbook):
      1. DISABLE: stale, enabled computer accounts are disabled and stamped
         (description prefix records the date and prior description).
      2. DELETE: only accounts THIS SCRIPT previously disabled (stamp present)
         AND stamped at least -MinDisabledDays ago are deleted.
      Disabled accounts without the stamp are never touched.

    Guards:
      - A device is actionable only when BOTH lastLogonTimestamp and pwdLastSet
        are older than -StaleThresholdDays. (Computer accounts rotate their
        password ~every 30 days; a recent pwdLastSet means the machine is
        alive.) Devices with NEITHER attribute set are skipped as NeverLoggedOn
        rather than treated as stale.
      - Server operating systems are excluded unless -IncludeServers. The check
        uses the operatingSystem attribute string, NOT the build number
        (Server 2025 and Windows 11 24H2 share build 26100). Computers with a
        blank operatingSystem attribute are skipped as UnknownOs (pre-staged
        objects, cluster CNO/VCO objects).
      - DryRun defaults to $true. Nothing changes until -DryRun:$false.
      - SupportsShouldProcess: -WhatIf / -Confirm honored on every write.
      - ProtectedFromAccidentalDeletion objects are reported, never deleted.
      - -ExcludeNameLike / -ExcludeOuDnLike carve-outs.

    Run as an account with disable/delete rights on the target computer
    objects. Requires RSAT ActiveDirectory. Enable the AD Recycle Bin before
    the first delete pass if it is not already on.

.PARAMETER SearchBase
    OU distinguished name to discover candidates under. Omitting it sweeps the
    whole domain and the script makes you say so with -ConfirmWholeDomain.

.PARAMETER ConfirmWholeDomain
    Required acknowledgment when running discovery without -SearchBase.

.PARAMETER DeviceListPath
    Optional override: CSV with a DisplayName column. When supplied, only the
    listed computers are processed (each still passes every guard above).

.PARAMETER DryRun
    Default $true: report intended actions only. Set $false to act.

.PARAMETER StaleThresholdDays
    Both lastLogonTimestamp and pwdLastSet must be older than this. Default 120.

.PARAMETER MinDisabledDays
    Minimum days between the stamped disable and the delete. Default 7.

.PARAMETER IncludeServers
    Include server operating systems in scope. Default $false.

.PARAMETER ExcludeNameLike
    Wildcard name patterns to skip, e.g. 'KIOSK*','CONF-*'.

.PARAMETER ExcludeOuDnLike
    Wildcard DN patterns to skip, e.g. '*OU=Servers,*'.

.PARAMETER Server
    Optional domain controller to pin all reads and writes to.

.PARAMETER OutputPath
    Results CSV path. Default: .\AdCleanup-<timestamp>.csv

.EXAMPLE
    .\Invoke-StaleHybridAdCleanup.ps1 -SearchBase 'OU=Workstations,DC=corp,DC=example,DC=org'
    Dry run: discovers stale workstations under the OU, reports intended actions.

.EXAMPLE
    .\Invoke-StaleHybridAdCleanup.ps1 -SearchBase 'OU=Workstations,DC=corp,DC=example,DC=org' -DryRun:$false
    Live pass 1: disables + stamps. Re-run after the window for the delete pass.

.NOTES
    Author: CDW (Adam Gell) - Presbyterian Homes engagement, 2026-08-19.
    Safety: mutating-guarded (DryRun default + SupportsShouldProcess).
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()] [string]   $SearchBase = '',
    [Parameter()] [switch]   $ConfirmWholeDomain,
    [Parameter()] [string]   $DeviceListPath = '',
    [Parameter()] [bool]     $DryRun = $true,
    [Parameter()] [int]      $StaleThresholdDays = 120,
    [Parameter()] [int]      $MinDisabledDays = 7,
    [Parameter()] [bool]     $IncludeServers = $false,
    [Parameter()] [string[]] $ExcludeNameLike = @(),
    [Parameter()] [string[]] $ExcludeOuDnLike = @(),
    [Parameter()] [string]   $Server = '',
    [Parameter()] [string]   $OutputPath = ''
)

$ErrorActionPreference = 'Stop'
Import-Module -Name ActiveDirectory -ErrorAction Stop

$stampPrefix = 'CDW-StaleCleanup-Disabled'
$runStamp    = (Get-Date).ToString('yyyyMMdd-HHmmss')
$today       = Get-Date
$staleCutoff = $today.AddDays(-1 * $StaleThresholdDays)
if (-not $OutputPath) { $OutputPath = Join-Path -Path (Get-Location) -ChildPath "AdCleanup-$runStamp.csv" }
elseif (Test-Path -Path $OutputPath -PathType Container) {
    # A directory was passed; Export-Csv needs a file path and fails with a
    # misleading "access denied" otherwise.
    $OutputPath = Join-Path -Path $OutputPath -ChildPath "AdCleanup-$runStamp.csv"
}

function Write-Log {
    param(
        [Parameter(Mandatory)] [string] $Message,
        [ValidateSet('INFO', 'WARN', 'ACTION', 'ERROR')] [string] $Level = 'INFO'
    )
    Write-Output ("[{0}] [{1}] {2}" -f (Get-Date -Format 'u'), $Level, $Message)
}

$adCommon = @{ ErrorAction = 'Stop' }
if ($Server) { $adCommon['Server'] = $Server }
$adProps = @('lastLogonTimestamp', 'pwdLastSet', 'description', 'enabled', 'operatingSystem', 'whenCreated', 'ProtectedFromAccidentalDeletion')

Write-Log "===== RUN $runStamp ====="
Write-Log "DryRun=$DryRun  StaleThresholdDays=$StaleThresholdDays  MinDisabledDays=$MinDisabledDays  IncludeServers=$IncludeServers"
if ($DryRun) { Write-Log 'DryRun is ON: no changes will be made.' -Level WARN }

# --- Candidate acquisition --------------------------------------------------
$computers = @()
if ($DeviceListPath) {
    if (-not (Test-Path -Path $DeviceListPath -PathType Leaf)) { throw "Device list not found: $DeviceListPath" }
    $rows = Import-Csv -Path $DeviceListPath
    if (-not ($rows | Get-Member -Name 'DisplayName' -MemberType NoteProperty)) {
        throw "Input CSV '$DeviceListPath' has no DisplayName column."
    }
    Write-Log "LIST MODE: $($rows.Count) names from '$DeviceListPath'."
    foreach ($row in $rows) {
        $name = $row.DisplayName.Trim()
        if (-not $name) { continue }
        $getParams = @{ Filter = "sAMAccountName -eq '$name`$'"; Properties = $adProps } + $adCommon
        if ($SearchBase) { $getParams['SearchBase'] = $SearchBase }
        $found = Get-ADComputer @getParams
        if ($found) { $computers += $found }
        else { Write-Log "NOT FOUND in AD: '$name'." -Level WARN }
    }
}
else {
    if (-not $SearchBase -and -not $ConfirmWholeDomain) {
        throw 'Discovery without -SearchBase sweeps the whole domain. Pass -SearchBase, or -ConfirmWholeDomain to proceed deliberately.'
    }
    $getParams = @{ Filter = '*'; Properties = $adProps } + $adCommon
    if ($SearchBase) { $getParams['SearchBase'] = $SearchBase }
    Write-Log ("DISCOVERY MODE: enumerating computers under '{0}'." -f $(if ($SearchBase) { $SearchBase } else { 'ENTIRE DOMAIN' }))
    $computers = Get-ADComputer @getParams
}
Write-Log "Computers in scope: $($computers.Count)"

# --- Processing ---------------------------------------------------------------
$results  = New-Object -TypeName System.Collections.Generic.List[object]
$counters = [ordered]@{
    Total = 0; ExcludedByPattern = 0; ExcludedServer = 0; UnknownOs = 0; NeverLoggedOn = 0
    AliveInAd = 0; Disabled = 0; WouldDisable = 0; Deleted = 0; WouldDelete = 0
    AwaitingDeleteWindow = 0; DisabledByOther = 0; DeletionProtected = 0; Errors = 0
}

foreach ($computer in $computers) {
    $counters.Total++
    $name = $computer.Name
    $lastLogon = if ($computer.lastLogonTimestamp) { [datetime]::FromFileTime($computer.lastLogonTimestamp) } else { $null }
    $pwdSet    = if ($computer.pwdLastSet)         { [datetime]::FromFileTime($computer.pwdLastSet) }         else { $null }

    $result = [pscustomobject]@{
        DisplayName = $name; DistinguishedName = $computer.DistinguishedName
        OperatingSystem = $computer.operatingSystem; Enabled = $computer.Enabled
        LastLogonTimestamp = $lastLogon; PwdLastSet = $pwdSet
        Action = ''; Status = ''; Detail = ''
    }

    try {
        $patternHit = $ExcludeNameLike | Where-Object { $name -like $_ } | Select-Object -First 1
        $ouHit      = $ExcludeOuDnLike | Where-Object { $computer.DistinguishedName -like $_ } | Select-Object -First 1
        if ($patternHit -or $ouHit) {
            $result.Status = 'ExcludedByPattern'; $counters.ExcludedByPattern++
            $result.Detail = "Matched exclusion '$patternHit$ouHit'."
            $results.Add($result); continue
        }

        if (-not $computer.operatingSystem) {
            $result.Status = 'UnknownOs'; $counters.UnknownOs++
            $result.Detail = 'Blank operatingSystem attribute (pre-staged object or cluster CNO/VCO). Review manually.'
            $results.Add($result); continue
        }
        if (-not $IncludeServers -and $computer.operatingSystem -like '*Server*') {
            $result.Status = 'ExcludedServer'; $counters.ExcludedServer++
            $results.Add($result); continue
        }

        if (-not $lastLogon -and -not $pwdSet) {
            $result.Status = 'NeverLoggedOn'; $counters.NeverLoggedOn++
            $result.Detail = 'Neither lastLogonTimestamp nor pwdLastSet is set. Not proof of staleness. Review manually.'
            $results.Add($result); continue
        }
        if (($lastLogon -and $lastLogon -gt $staleCutoff) -or ($pwdSet -and $pwdSet -gt $staleCutoff)) {
            $result.Status = 'AliveInAd'; $counters.AliveInAd++
            $result.Detail = "AD activity newer than $StaleThresholdDays days (lastLogon=$lastLogon, pwdLastSet=$pwdSet)."
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
            $results.Add($result); continue
        }

        $stampDate = $null
        if ($computer.description -match "$stampPrefix (\d{4}-\d{2}-\d{2})") {
            $stampDate = [datetime]::ParseExact($Matches[1], 'yyyy-MM-dd', $null)
        }
        if (-not $stampDate -or $stampDate -gt $today.AddDays(-1 * $MinDisabledDays)) {
            $result.Status = 'AwaitingDeleteWindow'; $counters.AwaitingDeleteWindow++
            $result.Detail = "Stamped $stampDate; delete allowed after $MinDisabledDays days."
            $results.Add($result); continue
        }

        if ($computer.ProtectedFromAccidentalDeletion) {
            $result.Status = 'DeletionProtected'; $counters.DeletionProtected++
            $result.Detail = 'ProtectedFromAccidentalDeletion is set; clear it manually if deletion is intended.'
            Write-Log "SKIP (deletion-protected): '$name'." -Level WARN
            $results.Add($result); continue
        }

        $result.Action = 'Delete'
        # Computer objects are often NOT leaf objects: BitLocker recovery info
        # (msFVE-RecoveryInformation) and service connection points live under
        # them, and Remove-ADComputer refuses non-leaf objects ("can perform
        # the requested operation only on a leaf object" -- hit live at PH,
        # 77 of 95, 2026-08-19). Children are enumerated and recorded, then
        # the subtree is removed; the AD Recycle Bin retains parent AND
        # children, so recovery of the whole object stays possible.
        $children = @(Get-ADObject -Filter '*' -SearchBase $computer.DistinguishedName -SearchScope OneLevel @adCommon)
        if ($children.Count -gt 0) {
            $childSummary = ($children | Group-Object -Property ObjectClass | ForEach-Object { "$($_.Count)x $($_.Name)" }) -join ', '
            $result.Detail = "Child objects removed with parent: $childSummary"
        }
        if ($DryRun) {
            $result.Status = 'WouldDelete'; $counters.WouldDelete++
            Write-Log "DRY-RUN would DELETE '$name' (stamped $stampDate)$(if ($children.Count) { " incl. $childSummary" })."
        }
        elseif ($PSCmdlet.ShouldProcess($name, "Delete AD computer account (disabled since $stampDate)")) {
            if ($children.Count -gt 0) {
                Remove-ADObject -Identity $computer.DistinguishedName -Recursive -Confirm:$false @adCommon
            }
            else {
                Remove-ADComputer -Identity $computer.DistinguishedName -Confirm:$false @adCommon
            }
            $result.Status = 'Deleted'; $counters.Deleted++
            Write-Log "DELETED '$name'$(if ($children.Count) { " (with $childSummary)" })." -Level ACTION
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
Write-Log 'Propagation: Entra Connect applies the AD state on its next cycle (Entra device object follows); Intune records for deleted devices are removed by the Intune device cleanup rule.'
Write-Log 'TODO (agreed 2026-08-19): later revision posts this summary/log back to the automation service.'
