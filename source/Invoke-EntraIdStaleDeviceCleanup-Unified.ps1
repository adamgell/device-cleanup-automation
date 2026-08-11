<#
.SYNOPSIS
    Two-stage stale-device cleanup for Entra ID. Single script supporting three
    auth modes via $AuthMode: AppRegistration, Delegated, or ManagedIdentity.

.DESCRIPTION
    Set $AuthMode at the top of the config block to pick the auth flow, then
    fill in only the variables for that mode. The body (staleness query, safety
    rails, BL/LAPS backup, Intune/AP deletion, CSV override) is identical across
    modes. See README.md next to this script for operator instructions.

    Required Microsoft Graph permissions (grant the type matching your mode --
    Application for AppRegistration / ManagedIdentity, Delegated for Delegated):
      - Device.ReadWrite.All
      - Directory.Read.All
      - BitlockerKey.Read.All
      - DeviceLocalCredential.Read.All
      - DeviceManagementManagedDevices.ReadWrite.All  (only if $DeleteIntuneObjects)
      - DeviceManagementServiceConfig.ReadWrite.All   (only if $DeleteAutopilotObjects)

    For ManagedIdentity mode in Azure Automation, set $StorageAccountName /
    $StorageContainerName so transcript + CSVs upload to blob storage after
    the run (sandbox filesystem is ephemeral). Leave blank for local testing.

.PARAMETER Apply
    Forces $DryRun = $false for this run.

.PARAMETER UseDeviceCode
    Delegated mode only: device-code flow instead of a browser pop-up
    (headless / SSH / PSRemoting). Ignored in other modes.

.PARAMETER LogPath
    Output directory for transcript + CSVs. Defaults to <scriptdir>\logs for
    AppRegistration and Delegated; defaults to a per-job folder under $env:TEMP
    for ManagedIdentity (uploaded to blob storage afterwards).

.PARAMETER DeviceListCsv
    Path to a CSV with 'DisplayName' and/or 'DeviceId' columns. Skips age-based
    staleness; forces HardDelete on every listed device (safety rails still apply).

.EXAMPLE
    .\Invoke-EntraIdStaleDeviceCleanup-Unified.ps1 -Apply
.EXAMPLE
    # set $AuthMode = 'Delegated' in the script first
    .\Invoke-EntraIdStaleDeviceCleanup-Unified.ps1 -Apply -UseDeviceCode
.EXAMPLE
    .\Invoke-EntraIdStaleDeviceCleanup-Unified.ps1 -DeviceListCsv .\targets.csv -Apply
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory = $false)] [switch] $Apply,
    [Parameter(Mandatory = $false)] [switch] $UseDeviceCode,
    [Parameter(Mandatory = $false)] [string] $LogPath,
    [Parameter(Mandatory = $false)] [string] $DeviceListCsv
)

# ============================================================================
# Configuration -- edit before running. See README.md for guidance.
# ============================================================================

# --- Auth mode --------------------------------------------------------------
# Pick one. Only the matching block below needs to be filled in.
#   'AppRegistration' = client credentials (secret OR cert), non-interactive.
#   'Delegated'       = interactive sign-in via Connect-MgGraph -Scopes.
#   'ManagedIdentity' = system- or user-assigned MI (Azure Automation runbook).
$AuthMode = 'Delegated'

# --- Auth: AppRegistration --------------------------------------------------
# Cert wins over secret if both are set.
$AppRegTenantId              = ''
$AppRegClientId              = ''
$AppRegClientSecret          = ''
$AppRegCertificateThumbprint = ''

# --- Auth: Delegated --------------------------------------------------------
# $DelegatedTenantId blank = user's home tenant.
# $DelegatedClientId blank = built-in "Microsoft Graph PowerShell" app.
$DelegatedTenantId = ''
$DelegatedClientId = ''
$DelegatedScopes   = @(
    'Device.ReadWrite.All',
    'Directory.Read.All',
    'BitlockerKey.Read.All',
    'DeviceLocalCredential.Read.All',
    'DeviceManagementManagedDevices.ReadWrite.All',
    'DeviceManagementServiceConfig.ReadWrite.All'
)

# --- Auth: ManagedIdentity --------------------------------------------------
# Blank $ManagedIdentityClientId = system-assigned MI.
# Storage settings: both set to upload outputs to blob after the run, both
# blank to skip (local testing). MI needs Storage Blob Data Contributor on
# the storage account or container.
$ManagedIdentityClientId = ''
$StorageAccountName      = ''
$StorageContainerName    = ''

# --- Lifecycle thresholds (days) --------------------------------------------
# $HardDeleteAfterDays must be >= $SoftDeleteAfterDays.
$SoftDeleteAfterDays = 90
$HardDeleteAfterDays = 120

# --- Run mode ---------------------------------------------------------------
# -Apply on the command line forces $DryRun = $false. Disable $ConfirmActions
# for non-interactive runs (scheduled tasks / Automation).
$DryRun         = $true
$ConfirmActions = $true

# --- Safety rails -----------------------------------------------------------
# $DisableOnly downgrades every HardDelete to a disable for this run.
# $RequireDisabledBeforeDelete refuses to hard-delete a still-enabled device.
$DisableOnly                 = $false
$RequireDisabledBeforeDelete = $false

# --- BitLocker / LAPS backup ------------------------------------------------
# Master switch + two refinements for what gets captured and when.
$BackupBLandLAPs            = $true   # $false skips retrieval + CSV entirely
$PreviewSecretsBackup       = $true   # also capture for HardDelete devices downgraded by the rails
$BackupOnlyBeforeHardDelete = $true   # skip preview; only capture immediately before a real delete

# --- Intune / Autopilot deletion (opt-in, all default $false) ---------------
# Intune: deletes /deviceManagement/managedDevices matched by azureADDeviceId.
# AP:     deletes /deviceManagement/windowsAutopilotDeviceIdentities, then lets
#         the Entra object proceed through the normal HardDelete path.
# Escape hatch: when the Autopilot endpoint is consistently 5xx (a known
# DeviceEnrollmentFE backend issue), $true lets the Entra delete proceed
# anyway after logging an ERROR. Operator must verify AP cleanup manually.
$DeleteIntuneObjects             = $true
$DeleteAutopilotObjects          = $true
$ProceedOnAutopilotLookupFailure = $true
# $true puts client-side enumeration FIRST. Use when your tenant's filtered
# AP lookup is consistently broken (DeviceEnrollmentFE proxy returning 5xx).
$AutopilotLookupPreferEnumeration = $true
# Cross-linked AP records (AP record's azureActiveDirectoryDeviceId points to
# a DIFFERENT Entra object than the one being processed). This happens most
# often in HYBRID Autopilot deployments, where AD sync + Autopilot enrollment
# produce two Entra device objects for the same hardware, and after wipe +
# re-enroll the AP record still links to the older/sibling Entra object.
#   $true  = honor the cross-link and delete the AP record anyway (the
#            sibling Entra object loses its Autopilot link). Correct for
#            hybrid AP cleanups where the sibling is also being decommissioned.
#   $false = skip the AP delete on cross-link, log a clear WARN, and still
#            proceed with the Entra delete so the orphan Entra object is
#            cleaned up without touching the AP record. Safer default for
#            standard (non-hybrid) Autopilot setups.
$HybridAutopilot = $true

# --- CSV override (-DeviceListCsv) ------------------------------------------
# $OnDuplicateMatch: behavior when one CSV row matches multiple Entra devices.
# $CsvRespectsAgeThresholds: $true skips CSV devices fresher than $SoftDeleteAfterDays.
$OnDuplicateMatch         = 'ProcessAll'   # 'Skip' or 'ProcessAll'
$CsvRespectsAgeThresholds = $false   # $true = CSV devices still age-checked

# --- Output file modes ------------------------------------------------------
# $true = fixed filename + run-separator banner; $false = timestamped per-run file.
$AppendLog                 = $true   # EntraCleanup-Log.log
$AppendDevicesCleanedUpCsv = $true   # EntraCleanup-DevicesCleanedUp.csv
$AppendAutopilotCsv        = $true   # EntraCleanup-StaleAutopilotDevices.csv
$AppendBLLAPSCsv           = $true   # EntraCleanup-BL-LAPSBackup.csv

# ============================================================================
# End configuration.
# ============================================================================

if ($Apply) { $DryRun = $false }

# Validate $AuthMode and the variables it needs.
if ($AuthMode -notin @('AppRegistration', 'Delegated', 'ManagedIdentity')) {
    throw "AuthMode must be 'AppRegistration', 'Delegated', or 'ManagedIdentity' (got '$AuthMode')."
}
switch ($AuthMode) {
    'AppRegistration' {
        if (-not $AppRegTenantId -or $AppRegTenantId -eq '00000000-0000-0000-0000-000000000000') {
            throw 'Set $AppRegTenantId to your Entra ID tenant GUID.'
        }
        if (-not $AppRegClientId -or $AppRegClientId -eq '00000000-0000-0000-0000-000000000000') {
            throw 'Set $AppRegClientId to your app-registration client GUID.'
        }
        if (-not $AppRegClientSecret -and -not $AppRegCertificateThumbprint) {
            throw 'Set either $AppRegClientSecret or $AppRegCertificateThumbprint.'
        }
    }
    'Delegated' {
        if (-not $DelegatedScopes -or $DelegatedScopes.Count -eq 0) {
            throw '$DelegatedScopes must contain at least one delegated permission scope.'
        }
    }
    'ManagedIdentity' {
        if ([string]::IsNullOrWhiteSpace($StorageAccountName) -xor [string]::IsNullOrWhiteSpace($StorageContainerName)) {
            throw '$StorageAccountName and $StorageContainerName must both be set, or both left blank.'
        }
        if ($ConfirmActions) {
            Write-Warning 'ManagedIdentity mode is non-interactive: forcing $ConfirmActions = $false.'
            $ConfirmActions = $false
        }
    }
}

if (-not $ConfirmActions) { $ConfirmPreference = 'None' }

# Default LogPath if -LogPath was not supplied. MI gets a temp folder (sandbox
# filesystem is ephemeral; outputs are uploaded to blob); others get scriptdir\logs.
if (-not $LogPath) {
    $LogPath = if ($AuthMode -eq 'ManagedIdentity') {
        Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("EntraCleanup-{0}" -f ([guid]::NewGuid().ToString('N')))
    } else {
        Join-Path -Path $PSScriptRoot -ChildPath 'logs'
    }
}

#region Pre-flight

if ($HardDeleteAfterDays -lt $SoftDeleteAfterDays) {
    throw "HardDeleteAfterDays ($HardDeleteAfterDays) must be >= SoftDeleteAfterDays ($SoftDeleteAfterDays)."
}

if ($OnDuplicateMatch -notin @('Skip', 'ProcessAll')) {
    throw "OnDuplicateMatch must be 'Skip' or 'ProcessAll' (got '$OnDuplicateMatch')."
}

if ($DeviceListCsv -and -not (Test-Path -Path $DeviceListCsv)) {
    throw "DeviceListCsv '$DeviceListCsv' does not exist."
}

# Ensure required modules are available.
$requiredModules = @(
    'Microsoft.Graph.Authentication',
    'Microsoft.Graph.Identity.DirectoryManagement',
    'Microsoft.Graph.Identity.SignIns'            # BitLocker recovery keys
)
foreach ($m in $requiredModules) {
    if (-not (Get-Module -ListAvailable -Name $m)) {
        throw "Required module '$m' is not installed. Run: Install-Module $m -Scope CurrentUser"
    }
    Import-Module $m -ErrorAction Stop | Out-Null
}

if (-not (Test-Path -Path $LogPath)) {
    New-Item -ItemType Directory -Path $LogPath -Force | Out-Null
}

$runStamp = (Get-Date).ToString('yyyyMMdd-HHmmss')

# Build output paths: append mode = fixed name, otherwise per-run timestamp.
function New-OutputPath {
    param(
        [Parameter(Mandatory)] [string] $BaseName,
        [Parameter(Mandatory)] [string] $Extension,
        [Parameter(Mandatory)] [bool]   $Append
    )
    $name = if ($Append) { "$BaseName.$Extension" } else { "$BaseName-$runStamp.$Extension" }
    return Join-Path $LogPath $name
}

$transcriptFile = New-OutputPath -BaseName 'EntraCleanup-Log'              -Extension 'log' -Append $AppendLog
$csvFile        = New-OutputPath -BaseName 'EntraCleanup-DevicesCleanedUp' -Extension 'csv' -Append $AppendDevicesCleanedUpCsv

# Run-separator banner only when appending to an existing transcript.
$logFileExisted = Test-Path -Path $transcriptFile
Start-Transcript -Path $transcriptFile -Append:$AppendLog | Out-Null
if ($AppendLog -and $logFileExisted) {
    # Write-Log isn't defined yet -- use Write-Host directly.
    Write-Host ''
    Write-Host ('=' * 78)
    Write-Host "===== NEW RUN: $runStamp ====="
    Write-Host ('=' * 78)
}

function Write-Log {
    param(
        [Parameter(Mandatory)] [string] $Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'ACTION')]
        [string] $Level = 'INFO'
    )
    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format 'u'), $Level, $Message
    switch ($Level) {
        'WARN'   { Write-Warning $Message }
        'ERROR'  { Write-Error   $Message }
        default  { Write-Host $line }
    }
}

#endregion

#region Authenticate to Microsoft Graph

Write-Log "AuthMode = $AuthMode"

try {
    switch ($AuthMode) {

        'AppRegistration' {
            Write-Log "Connecting to Microsoft Graph (tenant $AppRegTenantId, client $AppRegClientId)..."
            if ($AppRegCertificateThumbprint) {
                Connect-MgGraph `
                    -TenantId              $AppRegTenantId `
                    -ClientId              $AppRegClientId `
                    -CertificateThumbprint $AppRegCertificateThumbprint `
                    -NoWelcome `
                    -ErrorAction Stop
            }
            else {
                # SecureString via PSCredential so the SDK never sees cleartext.
                $secureSecret = ConvertTo-SecureString -String $AppRegClientSecret -AsPlainText -Force
                $credential   = [pscredential]::new($AppRegClientId, $secureSecret)
                Connect-MgGraph `
                    -TenantId               $AppRegTenantId `
                    -ClientSecretCredential $credential `
                    -NoWelcome `
                    -ErrorAction Stop
            }
        }

        'Delegated' {
            $connectArgs = @{
                Scopes      = $DelegatedScopes
                NoWelcome   = $true
                ErrorAction = 'Stop'
            }
            if ($DelegatedTenantId) { $connectArgs['TenantId']      = $DelegatedTenantId }
            if ($DelegatedClientId) { $connectArgs['ClientId']      = $DelegatedClientId }
            if ($UseDeviceCode)     { $connectArgs['UseDeviceCode'] = $true               }

            $tenantLabel = if ($DelegatedTenantId) { $DelegatedTenantId } else { '<home tenant>' }
            $clientLabel = if ($DelegatedClientId) { $DelegatedClientId } else { '<built-in Graph PowerShell app>' }
            Write-Log ("Connecting to Microsoft Graph as the signed-in user (tenant {0}, client {1})..." -f $tenantLabel, $clientLabel)
            Write-Log ("Requesting delegated scopes: {0}" -f ($DelegatedScopes -join ', '))

            Connect-MgGraph @connectArgs
        }

        'ManagedIdentity' {
            if ($ManagedIdentityClientId) {
                Write-Log "Connecting to Microsoft Graph as USER-ASSIGNED managed identity (clientId $ManagedIdentityClientId)..."
                Connect-MgGraph -Identity -ClientId $ManagedIdentityClientId -NoWelcome -ErrorAction Stop
            } else {
                Write-Log "Connecting to Microsoft Graph as SYSTEM-ASSIGNED managed identity..."
                Connect-MgGraph -Identity -NoWelcome -ErrorAction Stop
            }
        }
    }

    $ctx = Get-MgContext
    Write-Log "Connected. Context: $($ctx | ConvertTo-Json -Compress)"

    # Delegated-only: warn if any requested scope wasn't granted. Delegated
    # tokens silently drop scopes the user/tenant didn't consent to; calls
    # that need them will 403 later otherwise.
    if ($AuthMode -eq 'Delegated') {
        $granted = @($ctx.Scopes)
        $missing = $DelegatedScopes | Where-Object { $_ -notin $granted }
        if ($missing.Count -gt 0) {
            Write-Log ("WARNING: the following requested scopes were NOT granted: {0}. Calls that need them will 403. Have a tenant admin grant consent or sign in with an account that has them." -f ($missing -join ', ')) -Level WARN
        }
    }
}
catch {
    Write-Log "Failed to connect to Graph: $_" -Level ERROR
    Stop-Transcript | Out-Null
    throw
}

# ---------------------------------------------------------------------------
# ManagedIdentity helpers: IMDS token + blob upload via REST. Defined always
# (cheap; harmless to define unused), only invoked when $AuthMode = MI and
# storage is configured. Avoids Az.Storage / Az.Accounts module dependency
# (notorious for assembly-version conflicts in Automation sandboxes).
# ---------------------------------------------------------------------------

function Get-ManagedIdentityToken {
    param(
        [Parameter(Mandatory)] [string] $Resource,
        [string] $ClientId
    )
    $endpoint   = $env:IDENTITY_ENDPOINT
    $secret     = $env:IDENTITY_HEADER
    $headerName = 'X-IDENTITY-HEADER'
    if (-not $endpoint) {
        # Older hosts: MSI_ENDPOINT / MSI_SECRET.
        $endpoint   = $env:MSI_ENDPOINT
        $secret     = $env:MSI_SECRET
        $headerName = 'Secret'
    }
    if (-not $endpoint) {
        throw 'Managed identity token endpoint not available (no IDENTITY_ENDPOINT / MSI_ENDPOINT).'
    }
    $uri = "$endpoint" + "?api-version=2019-08-01&resource=" + [uri]::EscapeDataString($Resource)
    if ($ClientId) { $uri += "&client_id=" + [uri]::EscapeDataString($ClientId) }
    $headers = @{ $headerName = $secret }
    $resp = Invoke-RestMethod -Method GET -Uri $uri -Headers $headers -ErrorAction Stop
    if (-not $resp.access_token) {
        throw "MI token endpoint returned no access_token. Response: $($resp | ConvertTo-Json -Compress)"
    }
    return $resp.access_token
}

function Send-FileToBlob {
    # Single-PUT block blob (fine for files up to ~256 MB).
    param(
        [Parameter(Mandatory)] [string] $StorageAccountName,
        [Parameter(Mandatory)] [string] $ContainerName,
        [Parameter(Mandatory)] [string] $BlobName,
        [Parameter(Mandatory)] [string] $FilePath,
        [Parameter(Mandatory)] [string] $AccessToken
    )
    $url   = "https://$StorageAccountName.blob.core.windows.net/$ContainerName/$BlobName"
    $bytes = [System.IO.File]::ReadAllBytes($FilePath)
    $headers = @{
        'Authorization'  = "Bearer $AccessToken"
        'x-ms-version'   = '2021-08-06'
        'x-ms-blob-type' = 'BlockBlob'
        'x-ms-date'      = (Get-Date).ToUniversalTime().ToString('R')
    }
    $contentType = switch ([System.IO.Path]::GetExtension($FilePath).ToLowerInvariant()) {
        '.csv'  { 'text/csv' }
        '.log'  { 'text/plain' }
        '.json' { 'application/json' }
        default { 'application/octet-stream' }
    }
    Invoke-RestMethod -Method PUT -Uri $url -Headers $headers -Body $bytes -ContentType $contentType -ErrorAction Stop | Out-Null
}

# Pre-flight the storage token NOW (rather than after the cleanup runs) so a
# misconfigured Storage Blob Data Contributor role or a typo'd account name
# fails fast and we don't lose the run output to a late-bound auth error.
# Failure here is logged but non-fatal -- we still want the cleanup to run.
$storageToken = $null
if ($AuthMode -eq 'ManagedIdentity' -and $StorageAccountName -and $StorageContainerName) {
    try {
        $storageToken = Get-ManagedIdentityToken `
            -Resource 'https://storage.azure.com/' `
            -ClientId $ManagedIdentityClientId
        Write-Log "Acquired storage access token for managed identity. Upload target: https://$StorageAccountName.blob.core.windows.net/$StorageContainerName/"
    }
    catch {
        Write-Log "Failed to acquire storage token via managed identity: $_  -- run output will NOT be uploaded to blob storage." -Level ERROR
    }
}

#endregion

#region Query stale devices

# Cut-off timestamps in UTC (Graph wants ISO 8601 / Zulu).
$nowUtc           = (Get-Date).ToUniversalTime()
$softCutoffUtc    = $nowUtc.AddDays(-1 * $SoftDeleteAfterDays)
$hardCutoffUtc    = $nowUtc.AddDays(-1 * $HardDeleteAfterDays)
$softCutoffIso    = $softCutoffUtc.ToString('yyyy-MM-ddTHH:mm:ssZ')
$hardCutoffIso    = $hardCutoffUtc.ToString('yyyy-MM-ddTHH:mm:ssZ')

Write-Log "Soft-delete cutoff (disable): devices inactive since $softCutoffIso ($SoftDeleteAfterDays days)"
Write-Log "Hard-delete cutoff (delete):  devices inactive since $hardCutoffIso ($HardDeleteAfterDays days)"
Write-Log ("Safety rails: DisableOnly={0}  RequireDisabledBeforeDelete={1}  PreviewSecretsBackup={2}  BackupBLandLAPs={3}  BackupOnlyBeforeHardDelete={4}  DeleteIntuneObjects={5}  DeleteAutopilotObjects={6}  ProceedOnAutopilotLookupFailure={7}  AutopilotLookupPreferEnumeration={8}  HybridAutopilot={9}  ConfirmActions={10}  DryRun={11}" -f `
    $DisableOnly, $RequireDisabledBeforeDelete, $PreviewSecretsBackup, $BackupBLandLAPs, $BackupOnlyBeforeHardDelete, $DeleteIntuneObjects, $DeleteAutopilotObjects, $ProceedOnAutopilotLookupFailure, $AutopilotLookupPreferEnumeration, $HybridAutopilot, $ConfirmActions, $DryRun)
if ($DeviceListCsv) {
    Write-Log ("DeviceListCsv  ='{0}'  OnDuplicateMatch='{1}'  CsvRespectsAgeThresholds={2} -- CSV-OVERRIDE MODE: age-based staleness query SKIPPED." -f $DeviceListCsv, $OnDuplicateMatch, $CsvRespectsAgeThresholds) -Level WARN
}
Write-Log ("Append modes: Log={0}  DevicesCleanedUp={1}  Autopilot={2}  BL/LAPS={3}" -f `
    $AppendLog, $AppendDevicesCleanedUpCsv, $AppendAutopilotCsv, $AppendBLLAPSCsv)
if ($DisableOnly) {
    Write-Log "DisableOnly is ON -- NO hard deletes will be performed on this run; all stage-2 candidates will be disabled instead." -Level WARN
}
if (-not $BackupBLandLAPs -and -not $DryRun -and -not $DisableOnly) {
    Write-Log "BackupBLandLAPs = `$false in a live run with hard deletes enabled: BitLocker + LAPS will NOT be captured before deletion. If you do not have a separate backup mechanism, abort and reconfigure." -Level WARN
}

# Advanced query: requires ConsistencyLevel=eventual.
$filter = "approximateLastSignInDateTime le $softCutoffIso"
$select = 'id,displayName,deviceId,operatingSystem,operatingSystemVersion,accountEnabled,approximateLastSignInDateTime,registrationDateTime,trustType,physicalIds'

# Autopilot devices carry a [ZTDId]:<guid> entry in physicalIds. Disabling /
# deleting their Entra object breaks Autopilot re-enrollment.
function Test-IsAutopilotDevice {
    param([Parameter(Mandatory)] $Device)
    if (-not $Device.PhysicalIds) { return $false }
    return [bool]($Device.PhysicalIds | Where-Object { $_ -match '^\[ZTDId\]:' })
}

function Get-AutopilotZtdId {
    param([Parameter(Mandatory)] $Device)
    if (-not $Device.PhysicalIds) { return $null }
    $match = $Device.PhysicalIds | Where-Object { $_ -match '^\[ZTDId\]:(.+)$' } | Select-Object -First 1
    if ($match -and $match -match '^\[ZTDId\]:(.+)$') { return $Matches[1] }
    return $null
}

# --- Secret-backup helpers: BitLocker recovery keys + Windows LAPS passwords.
# Fetched before any hard delete; a failure aborts the delete for that device.

function Get-DeviceBitlockerKeys {
    # Returns KeyId/VolumeType/CreatedUtc/RecoveryKey records. Throws on error.
    param([Parameter(Mandatory)] [string] $DeviceIdGuid)

    $out = @()

    # List endpoint never returns key material -- need a per-id GET with $select=key.
    $listUri  = "https://graph.microsoft.com/v1.0/informationProtection/bitlocker/recoveryKeys?`$filter=deviceId eq '$DeviceIdGuid'"
    $listResp = Invoke-MgGraphRequest -Method GET -Uri $listUri -OutputType PSObject -ErrorAction Stop
    $items    = @($listResp.value)

    foreach ($m in $items) {
        # Selecting JUST 'key' -- some tenants 400 on multi-field $select here.
        $keyUri = "https://graph.microsoft.com/v1.0/informationProtection/bitlocker/recoveryKeys/$($m.id)?`$select=key"
        $full   = Invoke-MgGraphRequest -Method GET -Uri $keyUri -OutputType PSObject -ErrorAction Stop

        # Case-insensitive fallback in case the SDK ever shifts casing.
        $recoveryKey = $null
        if ($null -ne $full) {
            $recoveryKey = $full.key
            if ([string]::IsNullOrEmpty($recoveryKey) -and $full.PSObject -and $full.PSObject.Properties) {
                $prop = $full.PSObject.Properties | Where-Object { $_.Name -ieq 'key' } | Select-Object -First 1
                if ($prop) { $recoveryKey = $prop.Value }
            }
        }

        if ([string]::IsNullOrEmpty($recoveryKey)) {
            # Common causes: ReadBasic.All instead of Read.All, stale token, or
            # key was stored before AAD escrow was enabled.
            $respDump = try { ($full | ConvertTo-Json -Compress -Depth 4) } catch { '<unavailable>' }
            Write-Log ("BitLocker GET returned no key material for id '{0}'. Check that BitlockerKey.Read.All (NOT .ReadBasic.All) is granted and the app token is fresh. Response shape: {1}" -f $m.id, $respDump) -Level WARN
        }

        $out += [pscustomobject]@{
            KeyId       = $m.id
            VolumeType  = $m.volumeType
            CreatedUtc  = $m.createdDateTime
            RecoveryKey = $recoveryKey
        }
    }
    return ,$out   # unary comma preserves array type even when empty/single
}

function Get-DeviceLapsCredentials {
    # Returns AccountName/AccountSid/BackupDateUtc/Password rows; empty if no LAPS record.
    param([Parameter(Mandatory)] [string] $DeviceIdGuid)

    $out = @()
    $uri = "https://graph.microsoft.com/v1.0/directory/deviceLocalCredentials/$DeviceIdGuid`?`$select=credentials,lastBackupDateTime,deviceName"

    try {
        $laps = Invoke-MgGraphRequest -Method GET -Uri $uri -ErrorAction Stop
    }
    catch {
        # 404 = no LAPS record for this device; benign.
        $msg = "$_"
        if ($msg -match '(?i)\b(404|NotFound|ResourceNotFound|Request_ResourceNotFound)\b') {
            return ,$out
        }
        throw
    }

    if (-not $laps -or -not $laps.credentials) { return ,$out }

    foreach ($cred in $laps.credentials) {
        $plain = $null
        if ($cred.passwordBase64) {
            try {
                $plain = [System.Text.Encoding]::UTF8.GetString(
                            [System.Convert]::FromBase64String($cred.passwordBase64))
            } catch {
                $plain = '<base64 decode failed>'
            }
        }
        $out += [pscustomobject]@{
            AccountName   = $cred.accountName
            AccountSid    = $cred.accountSid
            BackupDateUtc = $cred.backupDateTime
            Password      = $plain
        }
    }
    return ,$out
}

function Backup-DeviceSecrets {
    # Appends one row per BitLocker key / LAPS credential to $Collector.
    # Returns $true if every retrieval succeeded, $false on any error.
    param(
        [Parameter(Mandatory)] $Device,

        # AllowEmptyCollection: a fresh List[object] is empty on first call.
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[object]] $Collector
    )

    # Windows-only gate: BL/LAPS don't exist on iOS/Android/macOS.
    $os = "$($Device.OperatingSystem)"
    if ($os -notmatch '^(?i)windows') {
        Write-Log ("Backup-DeviceSecrets: skipping '{0}' [{1}] -- non-Windows OS '{2}' has no BitLocker/LAPS." -f `
            $Device.DisplayName, $Device.Id, $os)
        return $true
    }

    $allOk = $true
    $stamp = (Get-Date).ToString('u')

    # Inline row builder for stable CSV column order.
    function New-SecretRow {
        param($SecretType, $Identifier, $Detail, $Value, $FetchStatus, $FetchError)
        [pscustomobject][ordered]@{
            Timestamp   = $stamp
            ObjectId    = $Device.Id
            DeviceId    = $Device.DeviceId
            DisplayName = $Device.DisplayName
            SecretType  = $SecretType
            Identifier  = $Identifier
            Detail      = $Detail
            Value       = $Value
            FetchStatus = $FetchStatus
            FetchError  = $FetchError
        }
    }

    # --- BitLocker -----------------------------------------------------------
    try {
        $keys = Get-DeviceBitlockerKeys -DeviceIdGuid $Device.DeviceId
        if (-not $keys -or $keys.Count -eq 0) {
            $Collector.Add((New-SecretRow 'BitLockerRecoveryKey' '' '' '' 'NotFound' '')) | Out-Null
        } else {
            foreach ($k in $keys) {
                $Collector.Add((New-SecretRow `
                    'BitLockerRecoveryKey' `
                    $k.KeyId `
                    "Volume=$($k.VolumeType); Created=$($k.CreatedUtc)" `
                    $k.RecoveryKey `
                    'Success' `
                    '')) | Out-Null
            }
        }
    }
    catch {
        $allOk = $false
        $Collector.Add((New-SecretRow 'BitLockerRecoveryKey' '' '' '' 'Error' $_.Exception.Message)) | Out-Null
        Write-Log "BitLocker backup FAILED for '$($Device.DisplayName)' [$($Device.Id)]: $_" -Level ERROR
    }

    # --- LAPS ----------------------------------------------------------------
    try {
        $creds = Get-DeviceLapsCredentials -DeviceIdGuid $Device.DeviceId
        if (-not $creds -or $creds.Count -eq 0) {
            $Collector.Add((New-SecretRow 'LAPSPassword' '' '' '' 'NotFound' '')) | Out-Null
        } else {
            foreach ($c in $creds) {
                $Collector.Add((New-SecretRow `
                    'LAPSPassword' `
                    $c.AccountName `
                    "Sid=$($c.AccountSid); BackedUp=$($c.BackupDateUtc)" `
                    $c.Password `
                    'Success' `
                    '')) | Out-Null
            }
        }
    }
    catch {
        $allOk = $false
        $Collector.Add((New-SecretRow 'LAPSPassword' '' '' '' 'Error' $_.Exception.Message)) | Out-Null
        Write-Log "LAPS backup FAILED for '$($Device.DisplayName)' [$($Device.Id)]: $_" -Level ERROR
    }

    return $allOk
}

# --- Registered owner lookup. Returns @() on no-owners or lookup failure.
function Get-DeviceRegisteredOwners {
    param([Parameter(Mandatory)] [string] $DeviceObjectId)

    $uri = "https://graph.microsoft.com/v1.0/devices/$DeviceObjectId/registeredOwners?`$select=id,displayName,userPrincipalName"
    try {
        $resp = Invoke-MgGraphRequest -Method GET -Uri $uri -OutputType PSObject -ErrorAction Stop
        return ,@($resp.value)
    }
    catch {
        Write-Log "Failed to fetch registered owners for device '$DeviceObjectId': $_" -Level WARN
        return ,@()
    }
}

# --- Intune + Autopilot deletion helpers (opt-in).
# Both take device.deviceId (the GUID) -- the field both Graph APIs filter on.
# Return $true on success (incl. dry-run and "nothing to delete"), $false on error.

function Remove-IntuneManagedDevice {
    param(
        [Parameter(Mandatory)] [string] $EntraDeviceId,
        [Parameter(Mandatory)] [string] $DisplayName,
        [Parameter(Mandatory)] [bool]   $DryRun
    )

    $listUri = "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices?`$filter=azureADDeviceId eq '$EntraDeviceId'&`$select=id,deviceName,operatingSystem"
    try {
        $resp    = Invoke-MgGraphRequest -Method GET -Uri $listUri -OutputType PSObject -ErrorAction Stop
        $managed = @($resp.value)
    }
    catch {
        Write-Log "Intune lookup failed for '$DisplayName' (deviceId $EntraDeviceId): $_" -Level WARN
        return $false
    }

    if ($managed.Count -eq 0) {
        Write-Log "Intune: no managedDevice record matched '$DisplayName' (deviceId $EntraDeviceId) -- nothing to delete."
        return $true
    }

    $allOk = $true
    foreach ($m in $managed) {
        $label = "Intune managedDevice '$($m.id)' ('$($m.deviceName)', OS '$($m.operatingSystem)')"
        if ($DryRun) {
            Write-Log "DRY-RUN would DELETE $label for Entra deviceId $EntraDeviceId."
            continue
        }
        try {
            Invoke-MgGraphRequest -Method DELETE -Uri "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices/$($m.id)" -ErrorAction Stop | Out-Null
            Write-Log "DELETED $label (Entra deviceId $EntraDeviceId)." -Level ACTION
        }
        catch {
            Write-Log "Failed to delete $label : $_" -Level ERROR
            $allOk = $false
        }
    }
    return $allOk
}

# Cache for client-side AP enumeration fallback. Stays $null until the first
# filtered lookup hits the DeviceEnrollmentFE 500-error pothole and we have
# to enumerate everything; then reused for the rest of the run.
$script:_apEnumerationCache = $null

function Remove-AutopilotDevice {
    param(
        [Parameter(Mandatory)] [string] $EntraDeviceId,
        [Parameter(Mandatory)] [string] $DisplayName,
        [Parameter(Mandatory)] [bool]   $DryRun,
        # ZTDId from the Entra device's physicalIds, if present. Used as a
        # fallback when the AP record's azureActiveDirectoryDeviceId points to
        # a different (older or re-enrolled) Entra object than the one being
        # processed -- a common quirk after wipe + re-enroll.
        [string] $ZtdId
    )

    $v1Base   = 'https://graph.microsoft.com/v1.0/deviceManagement/windowsAutopilotDeviceIdentities'
    $betaBase = 'https://graph.microsoft.com/beta/deviceManagement/windowsAutopilotDeviceIdentities'
    $select   = '$select=id,serialNumber,model,manufacturer,azureActiveDirectoryDeviceId'
    $ap       = $null

    # Build the strategy chain. Each entry: kind ('filter' | 'enumerate'), base URL, label.
    # Filter is faster when it works; enumeration is slower per first-call but
    # robust against the DeviceEnrollmentFE proxy 5xx bug. Order flips when
    # $AutopilotLookupPreferEnumeration = $true.
    $filterV1   = [pscustomobject]@{ Kind = 'filter';    Base = $v1Base;   Version = 'v1.0' }
    $filterBeta = [pscustomobject]@{ Kind = 'filter';    Base = $betaBase; Version = 'beta' }
    $enumV1     = [pscustomobject]@{ Kind = 'enumerate'; Base = $v1Base;   Version = 'v1.0' }
    $enumBeta   = [pscustomobject]@{ Kind = 'enumerate'; Base = $betaBase; Version = 'beta' }
    $strategies = if ($AutopilotLookupPreferEnumeration) {
        @($enumV1, $enumBeta, $filterV1, $filterBeta)
    } else {
        @($filterV1, $filterBeta, $enumV1, $enumBeta)
    }

    foreach ($s in $strategies) {
        if ($null -ne $ap) { break }

        if ($s.Kind -eq 'filter') {
            # v1.0 gets retries on transient errors; beta gets a single shot.
            $maxRetries = if ($s.Version -eq 'v1.0') { 3 } else { 1 }
            $uri        = "$($s.Base)`?`$filter=azureActiveDirectoryDeviceId eq '$EntraDeviceId'&$select"
            for ($attempt = 1; $attempt -le $maxRetries; $attempt++) {
                try {
                    $resp = Invoke-MgGraphRequest -Method GET -Uri $uri -OutputType PSObject -ErrorAction Stop
                    $ap   = @($resp.value)
                    break
                }
                catch {
                    $msg       = "$_"
                    $transient = $msg -match '\b(500|502|503|504|429)\b' -or $msg -match 'InternalServerError|ServiceUnavailable|BadGateway|GatewayTimeout|TooManyRequests'
                    if (-not $transient -or $attempt -eq $maxRetries) {
                        $reason = if ($transient) { 'transient, exhausted retries' } else { 'non-transient' }
                        Write-Log "Autopilot $($s.Version) filtered lookup failed for '$DisplayName' on attempt $attempt -- $reason." -Level WARN
                        break
                    }
                    $delay = [Math]::Pow(2, $attempt)
                    Write-Log "Autopilot $($s.Version) filtered lookup attempt $attempt transient error for '$DisplayName' -- retrying in ${delay}s." -Level WARN
                    Start-Sleep -Seconds $delay
                }
            }
        }
        elseif ($s.Kind -eq 'enumerate') {
            # Cached: only enumerate once per run. Subsequent devices hit the cache.
            if ($null -eq $script:_apEnumerationCache) {
                Write-Log "Enumerating Autopilot via $($s.Version) (cached for this run; slow on large tenants)..." -Level WARN
                try {
                    $all  = @()
                    $next = $s.Base  # bare GET -- no $select keeps the proxy happy
                    while ($next) {
                        $page = Invoke-MgGraphRequest -Method GET -Uri $next -OutputType PSObject -ErrorAction Stop
                        $all += @($page.value)
                        $next = $page.'@odata.nextLink'
                    }
                    $script:_apEnumerationCache = $all
                    Write-Log "AP enumeration via $($s.Version) succeeded: $($all.Count) record(s) cached for the rest of this run."
                }
                catch {
                    Write-Log "AP enumeration via $($s.Version) FAILED for '$DisplayName': $_" -Level WARN
                    continue   # try the next strategy
                }
            }
            $ap = @($script:_apEnumerationCache | Where-Object { $_.azureActiveDirectoryDeviceId -eq $EntraDeviceId })
        }
    }

    if ($null -eq $ap) {
        Write-Log "All Autopilot lookup strategies failed for '$DisplayName' (deviceId $EntraDeviceId). Set `$ProceedOnAutopilotLookupFailure = `$true to override." -Level ERROR
        return $false
    }

    # --- ZTDId fallback: the deviceId match missed, but the Entra object has
    # a [ZTDId] in physicalIds. The AP record's azureActiveDirectoryDeviceId
    # field is "sticky" to the first Entra registration that used the hash and
    # doesn't reliably update on re-enrollment -- so when a device is wiped +
    # re-enrolled, the new Entra object has a [ZTDId] but the AP record still
    # links to the old Entra object. Look it up by AP record id (== ZTDId).
    # Cache lookup first if populated; else direct GET.
    if ($ap.Count -eq 0 -and $ZtdId) {
        Write-Log "deviceId-based AP lookup empty for '$DisplayName' -- trying ZTDId fallback ($ZtdId)..."
        $apRecord = $null
        if ($null -ne $script:_apEnumerationCache) {
            $apRecord = $script:_apEnumerationCache | Where-Object { $_.id -eq $ZtdId } | Select-Object -First 1
            if ($apRecord) {
                Write-Log "Found AP record '$ZtdId' in enumeration cache."
            }
        }
        if (-not $apRecord) {
            foreach ($base in @($v1Base, $betaBase)) {
                $version = if ($base -like '*beta*') { 'beta' } else { 'v1.0' }
                try {
                    $apRecord = Invoke-MgGraphRequest -Method GET -Uri "$base/$ZtdId" -OutputType PSObject -ErrorAction Stop
                    if ($apRecord) {
                        Write-Log "Found AP record '$ZtdId' via direct GET ($version)."
                        break
                    }
                }
                catch {
                    $msg = "$_"
                    if ($msg -match '\b404\b|NotFound|ResourceNotFound') {
                        # AP record genuinely doesn't exist with that id -- stop trying.
                        Write-Log "AP record '$ZtdId' not found via $version (404)." -Level WARN
                        break
                    }
                    Write-Log "ZTDId fallback via $version FAILED for '$DisplayName': $_" -Level WARN
                }
            }
        }

        if ($apRecord) {
            # Detect cross-link: AP record points to a different Entra deviceId.
            $linkedTo = "$($apRecord.azureActiveDirectoryDeviceId)"
            if ($linkedTo -and $linkedTo -ne $EntraDeviceId) {
                Write-Log ("CROSS-LINK: AP record '{0}' (Serial '{1}') is linked to a DIFFERENT Entra deviceId ({2}) than the one being processed ({3})." -f `
                    $ZtdId, $apRecord.serialNumber, $linkedTo, $EntraDeviceId) -Level WARN
                if (-not $HybridAutopilot) {
                    Write-Log "HybridAutopilot = `$false -- SKIPPING AP delete to avoid affecting the cross-linked Entra object. Set `$HybridAutopilot = `$true if this is intentional (hybrid AP cleanups). The Entra delete will still proceed." -Level WARN
                    # Treat as "AP step done, nothing to delete" so the caller
                    # falls through to the Entra delete without touching AP.
                    return $true
                }
                Write-Log "HybridAutopilot = `$true -- proceeding with AP delete despite cross-link."
            }
            $ap = @($apRecord)
        }
    }

    if ($ap.Count -eq 0) {
        # No AP record matched by deviceId or ZTDId -- already clean, Entra delete proceeds.
        Write-Log "Autopilot: no windowsAutopilotDeviceIdentities record matched '$DisplayName' (deviceId $EntraDeviceId, ZTDId $ZtdId) -- treating as already-clean." -Level WARN
        return $true
    }

    $allOk = $true
    foreach ($a in $ap) {
        $label = "Autopilot device '$($a.id)' (Serial '$($a.serialNumber)', Manufacturer '$($a.manufacturer)', Model '$($a.model)')"
        if ($DryRun) {
            Write-Log "DRY-RUN would DELETE $label for Entra deviceId $EntraDeviceId."
            continue
        }
        try {
            Invoke-MgGraphRequest -Method DELETE -Uri "https://graph.microsoft.com/v1.0/deviceManagement/windowsAutopilotDeviceIdentities/$($a.id)" -ErrorAction Stop | Out-Null
            Write-Log "DELETED $label (Entra deviceId $EntraDeviceId)." -Level ACTION
            # Invalidate cache so subsequent lookups don't see a stale match.
            if ($null -ne $script:_apEnumerationCache) {
                $script:_apEnumerationCache = @($script:_apEnumerationCache | Where-Object { $_.id -ne $a.id })
            }
        }
        catch {
            Write-Log "Failed to delete $label : $_" -Level ERROR
            $allOk = $false
        }
    }
    return $allOk
}

# --- CSV writer with optional append + run-separator support.
# Append mode writes a '# ===== NEW RUN' separator line; strip those lines
# before re-importing programmatically.
function Export-CsvWithRunSeparator {
    param(
        [Parameter(Mandatory)] [AllowNull()] $Data,
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [bool]   $Append,
        [Parameter(Mandatory)] [string] $RunStamp
    )

    $exists = Test-Path -Path $Path

    if ($Append -and $exists) {
        $sep = ('# ===== NEW RUN: {0} {1}' -f $RunStamp, ('=' * 50))
        Add-Content -Path $Path -Value '' -Encoding UTF8
        Add-Content -Path $Path -Value $sep -Encoding UTF8

        $rows = @($Data | ConvertTo-Csv -NoTypeInformation)
        if ($rows.Count -gt 1) {
            # Drop the regenerated header -- file already has one.
            $dataRows = $rows[1..($rows.Count - 1)]
            Add-Content -Path $Path -Value $dataRows -Encoding UTF8
        }
        else {
            Add-Content -Path $Path -Value '# (no rows for this run)' -Encoding UTF8
        }
    }
    else {
        $Data | Export-Csv -Path $Path -NoTypeInformation -Encoding UTF8
    }
}

# --- CSV-override resolver: looks up each row by deviceId or displayName
# and returns the matching device objects (with the same $select fields).
function Resolve-DevicesFromCsv {
    param(
        [Parameter(Mandatory)] [string] $CsvPath,
        [Parameter(Mandatory)] [string] $SelectFields,
        [Parameter(Mandatory)] [string] $OnDuplicate    # 'Skip' | 'ProcessAll'
    )

    $rows = @(Import-Csv -Path $CsvPath)
    if ($rows.Count -eq 0) {
        Write-Log "DeviceListCsv '$CsvPath' is empty -- nothing to do." -Level WARN
        return ,@()
    }

    $cols = $rows[0].PSObject.Properties.Name
    $hasName = $cols -contains 'DisplayName'
    $hasId   = $cols -contains 'DeviceId'
    if (-not $hasName -and -not $hasId) {
        throw "DeviceListCsv '$CsvPath' must have a 'DisplayName' or 'DeviceId' column (found: $($cols -join ', '))."
    }

    $matched = New-Object System.Collections.Generic.List[object]
    $seen    = New-Object System.Collections.Generic.HashSet[string]
    $rowIdx  = 0
    foreach ($r in $rows) {
        $rowIdx++
        $deviceId    = if ($hasId)   { "$($r.DeviceId)".Trim()    } else { '' }
        $displayName = if ($hasName) { "$($r.DisplayName)".Trim() } else { '' }

        if (-not $deviceId -and -not $displayName) {
            Write-Log "DeviceListCsv row $rowIdx skipped -- both DisplayName and DeviceId are blank." -Level WARN
            continue
        }

        $hits  = @()
        $label = ''
        try {
            if ($deviceId) {
                # DeviceId wins -- it's a GUID, can't collide.
                $label = "DeviceId '$deviceId'"
                $hits  = @(Get-MgDevice -Filter "deviceId eq '$deviceId'" `
                                        -Property ($SelectFields -split ',') `
                                        -ConsistencyLevel eventual `
                                        -All -ErrorAction Stop)
            }
            else {
                $label   = "DisplayName '$displayName'"
                $escaped = $displayName -replace "'", "''"
                $hits    = @(Get-MgDevice -Filter "displayName eq '$escaped'" `
                                          -Property ($SelectFields -split ',') `
                                          -ConsistencyLevel eventual `
                                          -All -ErrorAction Stop)
            }
        }
        catch {
            Write-Log "DeviceListCsv row $rowIdx ($label) lookup FAILED: $_" -Level WARN
            continue
        }

        if ($hits.Count -eq 0) {
            Write-Log "DeviceListCsv row $rowIdx ($label) matched 0 Entra devices -- skipping." -Level WARN
            continue
        }

        if ($hits.Count -gt 1 -and $OnDuplicate -eq 'Skip') {
            $ids = ($hits | ForEach-Object { $_.Id }) -join ', '
            Write-Log ("DeviceListCsv row {0} ({1}) matched {2} Entra devices [{3}]. OnDuplicateMatch='Skip' -- ALL skipped. Disambiguate by DeviceId or set `$OnDuplicateMatch='ProcessAll'." -f `
                $rowIdx, $label, $hits.Count, $ids) -Level WARN
            continue
        }

        foreach ($h in $hits) {
            if ($seen.Add($h.Id)) {
                $matched.Add($h) | Out-Null
            }
        }
    }
    return ,$matched.ToArray()
}

if ($DeviceListCsv) {
    Write-Log "Loading target devices from CSV '$DeviceListCsv' (age-based staleness query bypassed)..."
    try {
        $staleDevices = Resolve-DevicesFromCsv -CsvPath $DeviceListCsv -SelectFields $select -OnDuplicate $OnDuplicateMatch
        $totalStale   = @($staleDevices).Count
        Write-Log "DeviceListCsv resolved $totalStale Entra device(s) for processing."
    }
    catch {
        Write-Log "Failed to resolve DeviceListCsv: $_" -Level ERROR
        Disconnect-MgGraph | Out-Null
        Stop-Transcript | Out-Null
        throw
    }
}
else {
    try {
        Write-Log "Querying Graph for candidate stale devices..."
        $staleDevices = Get-MgDevice `
            -Filter           $filter `
            -Property         ($select -split ',') `
            -ConsistencyLevel eventual `
            -CountVariable    totalStale `
            -All `
            -ErrorAction Stop
        Write-Log "Graph returned $totalStale candidate device(s)."
    }
    catch {
        Write-Log "Failed to query devices: $_" -Level ERROR
        Disconnect-MgGraph | Out-Null
        Stop-Transcript | Out-Null
        throw
    }
}

# Set of CSV-sourced object IDs -- classify loop force-HardDeletes these.
$csvDeviceIdSet = $null
if ($DeviceListCsv) {
    $csvDeviceIdSet = New-Object System.Collections.Generic.HashSet[string]
    foreach ($d in $staleDevices) { [void]$csvDeviceIdSet.Add($d.Id) }
}

#endregion

#region Classify and act

$results         = New-Object System.Collections.Generic.List[object]
$autopilotStale  = New-Object System.Collections.Generic.List[object]
$secretsBackup   = New-Object System.Collections.Generic.List[object]
$counters = [ordered]@{
    Total                   = 0
    AutopilotProtected      = 0
    AutopilotDeleted        = 0
    AutopilotDeleteSkipped  = 0
    AutopilotLookupBypassed = 0
    ToDisable               = 0
    Disabled                = 0
    DisableSkipped          = 0
    ToDelete                = 0
    Deleted                 = 0
    DeleteSkipped           = 0
    IntuneDeleted           = 0
    IntuneDeleteSkipped     = 0
    BackupFailed            = 0
    Errors                  = 0
}

foreach ($device in $staleDevices) {
    $counters.Total++

    $isFromCsv = ($csvDeviceIdSet -and $csvDeviceIdSet.Contains($device.Id))

    # Fall back to registrationDateTime when last-sign-in is missing.
    $effectiveDate = if ($device.ApproximateLastSignInDateTime) {
        $device.ApproximateLastSignInDateTime
    } elseif ($device.RegistrationDateTime) {
        $device.RegistrationDateTime
    } else {
        $null
    }

    if (-not $effectiveDate) {
        if ($isFromCsv) {
            # CSV-override: honor curated list even for never-used objects.
            Write-Log "DeviceListCsv override: processing '$($device.DisplayName)' [$($device.Id)] despite no timestamp."
            $ageDays = 0
        }
        else {
            Write-Log "Skipping device '$($device.DisplayName)' [$($device.Id)] -- no last-sign-in or registration timestamp." -Level WARN
            continue
        }
    }
    else {
        $ageDays = [int]([datetime]::UtcNow - $effectiveDate.ToUniversalTime()).TotalDays
    }

    # Stage by age (CSV-sourced devices are force-HardDelete below).
    $targetStage     = if ($ageDays -ge $HardDeleteAfterDays) { 'HardDelete' }
                       elseif ($ageDays -ge $SoftDeleteAfterDays) { 'SoftDelete' }
                       else { 'None' }
    $downgradeReason = $null

    if ($isFromCsv) {
        if ($CsvRespectsAgeThresholds) {
            # Honor age. Fresher-than-soft-cutoff devices are skipped with a WARN.
            if ($targetStage -eq 'None') {
                Write-Log "DeviceListCsv: skipping '$($device.DisplayName)' [$($device.Id)] -- $ageDays days < $SoftDeleteAfterDays day soft cutoff (CsvRespectsAgeThresholds = `$true)." -Level WARN
                continue
            }
        }
        else {
            $targetStage = 'HardDelete'
        }
    }

    # Safety-rail downgrades: HardDelete -> SoftDelete.
    if ($targetStage -eq 'HardDelete') {
        if ($DisableOnly) {
            $targetStage     = 'SoftDelete'
            $downgradeReason = 'DisableOnly flag is $true'
        }
        elseif ($RequireDisabledBeforeDelete -and $device.AccountEnabled) {
            $targetStage     = 'SoftDelete'
            $downgradeReason = 'RequireDisabledBeforeDelete: device still enabled, disable first and delete on a future run'
        }
    }

    $isAutopilot = Test-IsAutopilotDevice -Device $device
    $ztdId       = if ($isAutopilot) { Get-AutopilotZtdId -Device $device } else { $null }

    # Registered owners (joined with '; ' to keep one row per device).
    $owners     = Get-DeviceRegisteredOwners -DeviceObjectId $device.Id
    $ownerNames = if ($owners) { (@($owners | ForEach-Object { $_.displayName })       | Where-Object { $_ }) -join '; ' } else { '' }
    $ownerUpns  = if ($owners) { (@($owners | ForEach-Object { $_.userPrincipalName }) | Where-Object { $_ }) -join '; ' } else { '' }

    $row = [pscustomobject]@{
        DeviceId        = $device.DeviceId
        ObjectId        = $device.Id
        DisplayName     = $device.DisplayName
        OS              = "$($device.OperatingSystem) $($device.OperatingSystemVersion)".Trim()
        TrustType       = $device.TrustType
        LastSignInUtc   = $device.ApproximateLastSignInDateTime
        RegisteredUtc   = $device.RegistrationDateTime
        AgeDays         = $ageDays
        WasEnabled      = [bool]$device.AccountEnabled
        IsAutopilot     = $isAutopilot
        ZtdId           = $ztdId
        OwnerName      = $ownerNames
        OwnerUPN       = $ownerUpns
        Stage           = $targetStage
        DowngradeReason = $downgradeReason
        Action          = 'None'
        Status          = 'Planned'
        Error           = $null
    }

    if ($downgradeReason) {
        Write-Log ("Downgrading '{0}' [{1}] from HardDelete to SoftDelete -- {2} (age {3} days)." -f `
            $device.DisplayName, $device.Id, $downgradeReason, $ageDays)
    }

    # --- Autopilot guard.
    # Default: protect (record to Autopilot CSV only, skip Entra changes).
    # $DeleteAutopilotObjects + HardDelete stage: delete AP record, then
    # fall through to the normal HardDelete path (BL/LAPS backup still runs).
    if ($isAutopilot) {
        $apFallThrough = $false
        if ($DeleteAutopilotObjects -and $targetStage -eq 'HardDelete') {
            Write-Log ("DeleteAutopilotObjects ON -- removing Autopilot record for '{0}' [{1}] (ZTDId {2}) before Entra hard delete..." -f `
                $device.DisplayName, $device.Id, $ztdId)
            $apDeleteOk = Remove-AutopilotDevice -EntraDeviceId $device.DeviceId -DisplayName $device.DisplayName -DryRun ([bool]$DryRun) -ZtdId $ztdId
            if ($apDeleteOk) {
                $counters.AutopilotDeleted++
                $apFallThrough = $true
            }
            elseif ($ProceedOnAutopilotLookupFailure) {
                $counters.AutopilotLookupBypassed++
                Write-Log "ProceedOnAutopilotLookupFailure ON -- AP lookup unreachable, proceeding with Entra delete for '$($device.DisplayName)' [$($device.Id)] anyway. Manually verify the AP record is gone in Intune." -Level ERROR
                $apFallThrough = $true
            }
            else {
                $counters.AutopilotDeleteSkipped++
                Write-Log "Autopilot record delete FAILED for '$($device.DisplayName)' [$($device.Id)] -- reverting to protect-and-skip so Entra object is NOT deleted." -Level ERROR
            }
        }

        if (-not $apFallThrough) {
            $counters.AutopilotProtected++
            $row.Action = 'None (Autopilot-protected)'
            $row.Status = 'SkippedAutopilot'
            # AP devices land in EntraCleanup-StaleAutopilotDevices.csv only.
            $autopilotStale.Add($row) | Out-Null
            Write-Log ("PROTECTED Autopilot device '{0}' [{1}] (ZTDId {2}) -- would have been {3}, age {4} days." -f `
                $device.DisplayName, $device.Id, $ztdId, $targetStage, $ageDays) -Level WARN
            continue
        }
        # AP record gone -- treat as a normal HardDelete candidate.
    }

    try {
        switch ($targetStage) {

            'HardDelete' {
                $counters.ToDelete++
                $row.Action = 'Backup secrets -> Remove-MgDevice'

                # --- BL/LAPS backup before delete (Windows-only).
                # Always runs even in dry-run; a real-run failure aborts the delete.
                $isWindowsDevice = $device.OperatingSystem -match '^(?i)windows'
                if (-not $BackupBLandLAPs) {
                    # Operator has opted out -- assume external backup pipeline.
                    Write-Log "Skipping BitLocker/LAPS backup for '$($device.DisplayName)' [$($device.Id)] -- BackupBLandLAPs = `$false." -Level WARN
                    $backupOk = $true
                }
                elseif ($isWindowsDevice) {
                    Write-Log "Backing up BitLocker + LAPS for '$($device.DisplayName)' [$($device.Id)] before hard delete..."
                    $backupOk = Backup-DeviceSecrets -Device $device -Collector $secretsBackup
                }
                else {
                    Write-Log ("Skipping BitLocker/LAPS backup for non-Windows device '{0}' [{1}] (OS: {2})." -f `
                        $device.DisplayName, $device.Id, $device.OperatingSystem)
                    $backupOk = $true
                }

                if (-not $backupOk) {
                    $counters.BackupFailed++
                    if (-not $DryRun) {
                        $row.Status = 'SkippedBackupFailed'
                        $row.Error  = 'Secret backup failed -- device NOT deleted. Will retry next run.'
                        $counters.DeleteSkipped++
                        Write-Log "ABORTING delete of '$($device.DisplayName)' [$($device.Id)] -- secret backup failed." -Level ERROR
                        break
                    }
                    # Dry-run: log and continue so the admin sees full output.
                    Write-Log "Dry-run: secret backup for '$($device.DisplayName)' [$($device.Id)] failed. In a real run the delete would be aborted." -Level WARN
                }

                # --- Intune managedDevice cleanup (opt-in).
                # Runs before the Entra delete while the deviceId is still resolvable.
                # Failures are logged but non-fatal -- the Entra delete still proceeds.
                if ($DeleteIntuneObjects) {
                    $intuneOk = Remove-IntuneManagedDevice -EntraDeviceId $device.DeviceId -DisplayName $device.DisplayName -DryRun ([bool]$DryRun)
                    if ($intuneOk) {
                        $counters.IntuneDeleted++
                    }
                    else {
                        $counters.IntuneDeleteSkipped++
                        Write-Log "Intune managedDevice cleanup FAILED for '$($device.DisplayName)' [$($device.Id)] -- Entra delete will still proceed." -Level WARN
                    }
                }

                if (-not $DryRun -and $PSCmdlet.ShouldProcess("$($device.DisplayName) [$($device.Id)]", 'Remove device')) {
                    Remove-MgDevice -DeviceId $device.Id -ErrorAction Stop
                    $row.Status = 'Deleted'
                    $counters.Deleted++
                    Write-Log "DELETED device '$($device.DisplayName)' [$($device.Id)] -- inactive $ageDays days." -Level ACTION
                }
                else {
                    $row.Status = if ($DryRun) { 'DryRun' } else { 'Skipped (ShouldProcess)' }
                    $counters.DeleteSkipped++
                    Write-Log "DRY-RUN would DELETE '$($device.DisplayName)' [$($device.Id)] -- inactive $ageDays days."
                }
            }

            'SoftDelete' {
                # Preview backup: capture BL/LAPS for Windows devices downgraded
                # from HardDelete, so the backup flow gets validated early.
                # Errors here are logged but non-fatal.
                if ($BackupBLandLAPs -and $PreviewSecretsBackup -and -not $BackupOnlyBeforeHardDelete -and $downgradeReason -and ($device.OperatingSystem -match '^(?i)windows')) {
                    Write-Log "Preview backup: capturing BitLocker + LAPS for '$($device.DisplayName)' [$($device.Id)] (downgraded from HardDelete, age $ageDays days)..."
                    try {
                        Backup-DeviceSecrets -Device $device -Collector $secretsBackup | Out-Null
                    } catch {
                        Write-Log "Preview backup failed for '$($device.DisplayName)' [$($device.Id)]: $_" -Level WARN
                    }
                }

                if (-not $device.AccountEnabled) {
                    # Already disabled -- stage 2 picks it up at $HardDeleteAfterDays.
                    $row.Action = 'None (already disabled)'
                    $row.Status = 'NoOp'
                    Write-Log "No-op: '$($device.DisplayName)' [$($device.Id)] already disabled, age $ageDays days."
                    break
                }

                $counters.ToDisable++
                $row.Action = 'Update-MgDevice (accountEnabled=false)'
                if (-not $DryRun -and $PSCmdlet.ShouldProcess("$($device.DisplayName) [$($device.Id)]", 'Disable device')) {
                    Update-MgDevice -DeviceId $device.Id -BodyParameter @{ accountEnabled = $false } -ErrorAction Stop
                    $row.Status = 'Disabled'
                    $counters.Disabled++
                    Write-Log "DISABLED device '$($device.DisplayName)' [$($device.Id)] -- inactive $ageDays days." -Level ACTION
                }
                else {
                    $row.Status = if ($DryRun) { 'DryRun' } else { 'Skipped (ShouldProcess)' }
                    $counters.DisableSkipped++
                    Write-Log "DRY-RUN would DISABLE '$($device.DisplayName)' [$($device.Id)] -- inactive $ageDays days."
                }
            }

            default {
                # Below soft-delete cutoff after fallback date logic -- leave alone.
                $row.Status = 'NoOp'
            }
        }
    }
    catch {
        $counters.Errors++
        $row.Status = 'Error'
        $row.Error  = $_.Exception.Message
        Write-Log "ERROR processing '$($device.DisplayName)' [$($device.Id)]: $_" -Level ERROR
    }

    $results.Add($row) | Out-Null
}

#endregion

#region Summary + cleanup

try {
    Export-CsvWithRunSeparator -Data $results -Path $csvFile -Append $AppendDevicesCleanedUpCsv -RunStamp $runStamp
    Write-Log "Per-device results written to $csvFile (append mode = $AppendDevicesCleanedUpCsv)"
}
catch {
    Write-Log "Failed to write CSV summary: $_" -Level WARN
}

# Dedicated CSV for Autopilot devices that need Intune-side cleanup.
$autopilotCsv = New-OutputPath -BaseName 'EntraCleanup-StaleAutopilotDevices' -Extension 'csv' -Append $AppendAutopilotCsv
if ($autopilotStale.Count -gt 0) {
    try {
        Export-CsvWithRunSeparator -Data $autopilotStale -Path $autopilotCsv -Append $AppendAutopilotCsv -RunStamp $runStamp
        Write-Log "Stale Autopilot devices (protected -- NOT modified) written to $autopilotCsv (append mode = $AppendAutopilotCsv)"
    }
    catch {
        Write-Log "Failed to write Autopilot CSV: $_" -Level WARN
    }
}

# SECRETS CSV -- plaintext BitLocker keys + LAPS passwords. Treat like a
# password vault export: move to a secure vault, tighten ACLs, purge when done.
$secretsCsv = New-OutputPath -BaseName 'EntraCleanup-BL-LAPSBackup' -Extension 'csv' -Append $AppendBLLAPSCsv
if (-not $BackupBLandLAPs) {
    Write-Log "Skipping secrets CSV write -- BackupBLandLAPs = `$false." -Level WARN
}
elseif ($secretsBackup.Count -gt 0) {
    try {
        Export-CsvWithRunSeparator -Data $secretsBackup -Path $secretsCsv -Append $AppendBLLAPSCsv -RunStamp $runStamp
        # Best-effort ACL: owner + SYSTEM + Administrators only.
        if ($IsWindows -or $PSVersionTable.PSEdition -eq 'Desktop') {
            try {
                $acl = New-Object System.Security.AccessControl.FileSecurity
                $acl.SetAccessRuleProtection($true, $false)  # drop inheritance
                $currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
                foreach ($id in @('NT AUTHORITY\SYSTEM', 'BUILTIN\Administrators', $currentUser)) {
                    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
                        $id, 'FullControl', 'Allow')
                    $acl.AddAccessRule($rule)
                }
                Set-Acl -Path $secretsCsv -AclObject $acl
            } catch {
                Write-Log "Wrote secrets CSV but could not tighten ACL: $_" -Level WARN
            }
        }
        Write-Log "SECRETS backup written to $secretsCsv -- treat this file as sensitive." -Level WARN
    }
    catch {
        Write-Log "Failed to write secrets CSV: $_" -Level ERROR
    }
}

Write-Log "----- Summary -----"
$counters.GetEnumerator() | ForEach-Object {
    Write-Log ("{0,-20} : {1}" -f $_.Key, $_.Value)
}

if ($autopilotStale.Count -gt 0) {
    Write-Log "----- Stale Autopilot devices (skipped, require Intune-side cleanup) -----" -Level WARN
    foreach ($ap in $autopilotStale) {
        Write-Log ("  [{0}] {1}  ZTDId={2}  Stage={3}  Age={4}d" -f `
            $ap.ObjectId, $ap.DisplayName, $ap.ZtdId, $ap.Stage, $ap.AgeDays) -Level WARN
    }
    Write-Log ("Total Autopilot devices needing attention in Intune: {0}" -f $autopilotStale.Count) -Level WARN
    Write-Log "Remove them from Windows Autopilot deployment profiles / devices first; the Entra object will then be eligible on a subsequent run." -Level WARN
}
if ($DryRun) {
    Write-Log "DRY-RUN complete. Set `$DryRun = `$false at the top of the script (or re-run with -Apply) to actually disable/delete." -Level WARN
}

Disconnect-MgGraph | Out-Null
Stop-Transcript    | Out-Null

# ManagedIdentity: upload transcript + CSVs to blob storage after the run.
# Runs AFTER Stop-Transcript so the .log file is flushed before upload.
if ($AuthMode -eq 'ManagedIdentity' -and $storageToken) {
    $blobPrefix = "$runStamp/"
    $uploadCandidates = @($transcriptFile, $csvFile, $autopilotCsv, $secretsCsv) |
        Where-Object { $_ -and (Test-Path -Path $_) }
    foreach ($f in $uploadCandidates) {
        $blobName = $blobPrefix + (Split-Path -Leaf $f)
        try {
            Send-FileToBlob `
                -StorageAccountName $StorageAccountName `
                -ContainerName      $StorageContainerName `
                -BlobName           $blobName `
                -FilePath           $f `
                -AccessToken        $storageToken
            Write-Host "Uploaded $f -> https://$StorageAccountName.blob.core.windows.net/$StorageContainerName/$blobName"
        }
        catch {
            Write-Host ("Failed to upload {0}: {1}" -f $f, $_)
        }
    }
}
