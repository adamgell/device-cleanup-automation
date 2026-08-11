<#
.SYNOPSIS
    Cleans up stale Entra ID (Azure AD) device records using a two-stage lifecycle.
    MANAGED-IDENTITY variant: designed to run as an Azure Automation runbook
    using the Automation account's system-assigned (or user-assigned) managed
    identity. No client secret, no certificate, no interactive sign-in.

      Stage 1 (soft delete): disable devices whose ApproximateLastSignInDateTime is
                             older than $SoftDeleteAfterDays.
      Stage 2 (hard delete): delete devices whose ApproximateLastSignInDateTime is
                             older than $HardDeleteAfterDays.

.DESCRIPTION
    Uses the Microsoft Graph PowerShell SDK with managed-identity auth
    (Connect-MgGraph -Identity). The Automation account's identity is treated
    by Entra ID as a service principal; Graph APP-ONLY permissions are assigned
    directly to that service principal.

    Required Microsoft Graph APPLICATION permissions, granted to the managed
    identity's service principal (these have to be assigned via PowerShell --
    the Azure portal does not expose a UI for assigning Graph app permissions
    to a managed identity; see the setup guide that ships with this script):
      - Device.ReadWrite.All
      - Directory.Read.All
      - BitlockerKey.Read.All          (to back up BitLocker recovery keys)
      - DeviceLocalCredential.Read.All (to back up Windows LAPS passwords)

    Defaults to dry-run so the first runbook execution just logs what WOULD
    happen. Pass -Apply (a runbook input parameter) to actually disable/delete.

    OUTPUT FILES IN AUTOMATION:
    Azure Automation runbooks execute in a sandbox where the local filesystem
    is ephemeral -- anything written to disk is gone when the job finishes.
    The default $LogPath uses $env:TEMP for the duration of the job; the
    OUTPUT BLOCK at the bottom of the script uploads the resulting CSVs to
    an Azure Storage container so you can retrieve them after the run. Set
    $StorageAccountName + $StorageContainerName near the top of the script,
    or leave them blank to skip the upload (useful for ad-hoc local testing).

.PARAMETER Apply
    Command-line override that forces a real run by setting $DryRun = $false.
    The primary dry-run toggle is the $DryRun variable at the top of the script
    (defaults to $true). Pass -Apply via the runbook's input parameters when
    you're ready to go live.

.PARAMETER LogPath
    Path to write the transcript + CSVs during the job. Defaults to a temp
    subfolder under $env:TEMP, which is fine because the OUTPUT BLOCK uploads
    them to blob storage at the end of the run.
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory = $false)]
    [switch] $Apply,

    [Parameter(Mandatory = $false)]
    [string] $LogPath = (Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("EntraCleanup-{0}" -f ([guid]::NewGuid().ToString('N'))))
)

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

# --- Managed-identity settings ------------------------------------------
# Leave $ManagedIdentityClientId BLANK to use the Automation account's
# SYSTEM-ASSIGNED managed identity. Set it to the *client ID* (not object ID)
# of a USER-ASSIGNED managed identity if you've attached one and want to use
# that instead. The user-assigned approach is preferred when you want the
# same identity (and the same Graph permission grants) shared across multiple
# Automation accounts or other Azure resources.
$ManagedIdentityClientId = ''

# --- Output: Azure Storage upload --------------------------------------
# The Automation runbook sandbox is ephemeral, so the script uploads the
# transcript + CSVs to a blob container at the end of each run. Set both
# values to use blob upload; leave both blank to skip upload (useful for
# local testing of this script outside Automation).
#
# The managed identity needs the "Storage Blob Data Contributor" role on
# the storage account (or just on the container, scoped tighter).
$StorageAccountName   = ''   # e.g. 'contosocleanuplogs'
$StorageContainerName = ''   # e.g. 'entra-device-cleanup'
# --- Lifecycle thresholds -----------------------------------------------
# Stage 1: soft-delete (disable) a device once it has been inactive this long.
$SoftDeleteAfterDays = 90

# Stage 2: hard-delete a device once it has been inactive this long.
# Measured from last sign-in, NOT from the disable action. Must be >= SoftDeleteAfterDays.
$HardDeleteAfterDays = 120

# --- Safety rails for the first / early runs ----------------------------
# FIRST-RUN EMERGENCY BRAKE.
# When $true, the script NEVER hard-deletes on this run: any device that
# would have been hard-deleted is downgraded to a disable instead. Set this
# to $true for the first few runs while you audit the output, then flip to
# $false once you're comfortable.
$DisableOnly = $true

# PERMANENT GUARDRAIL.
# When $true, the script will only hard-delete a device that is ALREADY
# disabled. A stale-but-still-enabled device is downgraded to a disable on
# the current run, and becomes eligible for hard delete on a future run.
# Leave this on ($true) in production -- it prevents a misconfigured
# age threshold from wiping actively-used objects.
$RequireDisabledBeforeDelete = $true

# PREVIEW SECRETS BACKUP.
# When $true, Windows devices that *would* have been hard-deleted this run
# (but were downgraded to a disable by the safety rails above) still get
# their BitLocker + LAPS captured to the backup CSV. Useful during the
# $DisableOnly phase to validate that secret retrieval works end-to-end
# before any destructive action. Set to $false once you're comfortable.
$PreviewSecretsBackup = $true

# WRITE BL + LAPS CSV.
# When $true (default), BitLocker recovery keys and Windows LAPS passwords
# are retrieved from Graph and written to EntraCleanup-BL-LAPSBackup-<ts>.csv
# before any hard delete. When $false, retrieval is skipped entirely and
# no secrets CSV is produced.
#
# IMPORTANT: this script's safety contract is that we never hard-delete a
# device without first capturing its recovery secrets. Setting this to
# $false disables that safety net. Only set to $false if EITHER:
#   (a) you're staying in $DisableOnly mode and nothing is actually being
#       deleted, so there is nothing to back up, OR
#   (b) you have a separate backup mechanism for BitLocker + LAPS (e.g.
#       MDE / Intune reporting feeding a vault) and don't need this script
#       to capture them too.
$BackupBLandLAPs = $true

# --- Dry-run toggle -----------------------------------------------------
# When $true, the script only logs what it WOULD do and makes no changes.
# Flip to $false to actually disable/delete devices.
# The -Apply command-line switch overrides this to $false for one-off runs.
$DryRun = $true
# ---------------------------------------------------------------------------

# Command-line override: -Apply forces a real run regardless of $DryRun above.
if ($Apply) { $DryRun = $false }

# No credential variables to validate -- the managed identity is supplied
# automatically by the Azure Automation runtime. If $ManagedIdentityClientId
# is blank, the system-assigned identity is used. If set, the named
# user-assigned identity is used.
#
# If $StorageAccountName is set, $StorageContainerName must be too (and vice
# versa) -- partial config is almost always a mistake.
if ([string]::IsNullOrWhiteSpace($StorageAccountName) -xor [string]::IsNullOrWhiteSpace($StorageContainerName)) {
    throw '$StorageAccountName and $StorageContainerName must both be set, or both left blank.'
}

#region Pre-flight

if ($HardDeleteAfterDays -lt $SoftDeleteAfterDays) {
    throw "HardDeleteAfterDays ($HardDeleteAfterDays) must be >= SoftDeleteAfterDays ($SoftDeleteAfterDays)."
}

# Ensure required modules are available.
$requiredModules = @(
    'Microsoft.Graph.Authentication',
    'Microsoft.Graph.Identity.DirectoryManagement',
    'Microsoft.Graph.Identity.SignIns'            # BitLocker recovery keys
)
# Note: blob upload is done via direct REST calls (Invoke-RestMethod) using
# a managed-identity-issued bearer token. No Az.Storage / Az.Accounts module
# dependency -- we sidestep the Az version-pin / assembly-load failures that
# plague Automation accounts.
foreach ($m in $requiredModules) {
    if (-not (Get-Module -ListAvailable -Name $m)) {
        throw "Required module '$m' is not installed. Run: Install-Module $m -Scope CurrentUser"
    }
    Import-Module $m -ErrorAction Stop | Out-Null
}

if (-not (Test-Path -Path $LogPath)) {
    New-Item -ItemType Directory -Path $LogPath -Force | Out-Null
}

$runStamp       = (Get-Date).ToString('yyyyMMdd-HHmmss')
$transcriptFile = Join-Path $LogPath "EntraCleanup-Log-$runStamp.log"
$csvFile        = Join-Path $LogPath "EntraCleanup-DevicesCleanedUp-$runStamp.csv"
Start-Transcript -Path $transcriptFile -Append | Out-Null

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

try {
    if ($ManagedIdentityClientId) {
        Write-Log "Connecting to Microsoft Graph as USER-ASSIGNED managed identity (clientId $ManagedIdentityClientId)..."
        Connect-MgGraph -Identity -ClientId $ManagedIdentityClientId -NoWelcome -ErrorAction Stop
    } else {
        Write-Log "Connecting to Microsoft Graph as SYSTEM-ASSIGNED managed identity..."
        Connect-MgGraph -Identity -NoWelcome -ErrorAction Stop
    }
    Write-Log "Connected. Context: $((Get-MgContext | ConvertTo-Json -Compress))"
}
catch {
    Write-Log "Failed to connect to Graph: $_" -Level ERROR
    Stop-Transcript | Out-Null
    throw
}

# ---------------------------------------------------------------------------
# Managed-identity token + blob upload helpers (REST API).
# ---------------------------------------------------------------------------
# These avoid the Az.Storage / Az.Accounts module dependency entirely. Az
# modules in Azure Automation are notorious for assembly-version conflicts
# (Azure.Core.dll mismatches between Az.Accounts and Az.Storage), so we go
# straight to the platform's IMDS token endpoint and the storage REST API.

function Get-ManagedIdentityToken {
    <#
        Acquire an OAuth access token for $Resource using the managed identity
        attached to the current Azure host (Automation, App Service, VM, etc.).
        $Resource examples:
          - 'https://graph.microsoft.com/'
          - 'https://storage.azure.com/'
        $ClientId is required only for user-assigned managed identities.
    #>
    param(
        [Parameter(Mandatory)] [string] $Resource,
        [string] $ClientId
    )

    # The modern (App Service / Automation / Functions) MI endpoint is
    # advertised via $env:IDENTITY_ENDPOINT + the secret in $env:IDENTITY_HEADER.
    # The older endpoint ($env:MSI_ENDPOINT / $env:MSI_SECRET) is kept as a
    # fallback for the ever-shrinking set of hosts that still expose it.
    $endpoint = $env:IDENTITY_ENDPOINT
    $secret   = $env:IDENTITY_HEADER
    $headerName = 'X-IDENTITY-HEADER'

    if (-not $endpoint) {
        $endpoint   = $env:MSI_ENDPOINT
        $secret     = $env:MSI_SECRET
        $headerName = 'Secret'
    }

    if (-not $endpoint) {
        throw "Managed identity token endpoint not available. Are you running under Azure Automation / App Service / a managed-identity-enabled VM?"
    }

    $uri = "$endpoint" + "?api-version=2019-08-01&resource=" + [uri]::EscapeDataString($Resource)
    if ($ClientId) {
        $uri += "&client_id=" + [uri]::EscapeDataString($ClientId)
    }

    $headers = @{ $headerName = $secret }
    $resp = Invoke-RestMethod -Method GET -Uri $uri -Headers $headers -ErrorAction Stop
    if (-not $resp.access_token) {
        throw "MI token endpoint returned no access_token. Response: $($resp | ConvertTo-Json -Compress)"
    }
    return $resp.access_token
}

function Send-FileToBlob {
    <#
        PUT a single file as a block blob via the storage REST API.
        Single-PUT is fine for files up to ~256 MB. Our outputs are small
        (a transcript and a few CSVs), so we never need block-staged uploads.
    #>
    param(
        [Parameter(Mandatory)] [string] $StorageAccountName,
        [Parameter(Mandatory)] [string] $ContainerName,
        [Parameter(Mandatory)] [string] $BlobName,
        [Parameter(Mandatory)] [string] $FilePath,
        [Parameter(Mandatory)] [string] $AccessToken
    )

    $url   = "https://$StorageAccountName.blob.core.windows.net/$ContainerName/$BlobName"
    $bytes = [System.IO.File]::ReadAllBytes($FilePath)

    # Storage REST requires a current x-ms-date and an x-ms-version. Pin to
    # a known-good API version rather than 'latest' so behavior is stable.
    $headers = @{
        'Authorization'  = "Bearer $AccessToken"
        'x-ms-version'   = '2021-08-06'
        'x-ms-blob-type' = 'BlockBlob'
        'x-ms-date'      = (Get-Date).ToUniversalTime().ToString('R')
    }

    # Pick a content type so blobs render reasonably if previewed in the portal.
    $contentType = switch ([System.IO.Path]::GetExtension($FilePath).ToLowerInvariant()) {
        '.csv'  { 'text/csv' }
        '.log'  { 'text/plain' }
        '.json' { 'application/json' }
        default { 'application/octet-stream' }
    }

    Invoke-RestMethod `
        -Method      PUT `
        -Uri         $url `
        -Headers     $headers `
        -Body        $bytes `
        -ContentType $contentType `
        -ErrorAction Stop | Out-Null
}

# Pre-flight the storage token NOW (rather than after the cleanup runs) so a
# misconfigured Storage Blob Data Contributor role or a typo'd account name
# fails fast and we don't lose the run output to a late-bound auth error.
$storageToken = $null
if ($StorageAccountName -and $StorageContainerName) {
    try {
        $storageToken = Get-ManagedIdentityToken `
            -Resource 'https://storage.azure.com/' `
            -ClientId $ManagedIdentityClientId
        Write-Log "Acquired storage access token for managed identity. Upload target: https://$StorageAccountName.blob.core.windows.net/$StorageContainerName/"
    }
    catch {
        Write-Log "Failed to acquire storage token via managed identity: $_  -- run output will not be uploaded to blob storage." -Level ERROR
        # Don't throw -- we still want the cleanup work to proceed and log
        # locally even if upload is broken. Throwing here would skip the
        # actual cleanup over a logging-pipeline issue.
    }
}

#endregion

#region Query stale devices

# Compute cut-off timestamps in UTC (Graph expects ISO 8601 / Zulu).
$nowUtc           = (Get-Date).ToUniversalTime()
$softCutoffUtc    = $nowUtc.AddDays(-1 * $SoftDeleteAfterDays)
$hardCutoffUtc    = $nowUtc.AddDays(-1 * $HardDeleteAfterDays)
$softCutoffIso    = $softCutoffUtc.ToString('yyyy-MM-ddTHH:mm:ssZ')
$hardCutoffIso    = $hardCutoffUtc.ToString('yyyy-MM-ddTHH:mm:ssZ')

Write-Log "Soft-delete cutoff (disable): devices inactive since $softCutoffIso ($SoftDeleteAfterDays days)"
Write-Log "Hard-delete cutoff (delete):  devices inactive since $hardCutoffIso ($HardDeleteAfterDays days)"
Write-Log ("Safety rails: DisableOnly={0}  RequireDisabledBeforeDelete={1}  PreviewSecretsBackup={2}  BackupBLandLAPs={3}  DryRun={4}" -f `
    $DisableOnly, $RequireDisabledBeforeDelete, $PreviewSecretsBackup, $BackupBLandLAPs, $DryRun)
if ($DisableOnly) {
    Write-Log "DisableOnly is ON -- NO hard deletes will be performed on this run; all stage-2 candidates will be disabled instead." -Level WARN
}
if (-not $BackupBLandLAPs -and -not $DryRun -and -not $DisableOnly) {
    Write-Log "BackupBLandLAPs = `$false in a live run with hard deletes enabled: BitLocker + LAPS will NOT be captured before deletion. If you do not have a separate backup mechanism, abort and reconfigure." -Level WARN
}

# Filtering on approximateLastSignInDateTime is an advanced query -- requires
# ConsistencyLevel=eventual and $count=true.
$filter = "approximateLastSignInDateTime le $softCutoffIso"
$select = 'id,displayName,deviceId,operatingSystem,operatingSystemVersion,accountEnabled,approximateLastSignInDateTime,registrationDateTime,trustType,physicalIds'

# Autopilot devices carry a [ZTDId]:<guid> entry in their physicalIds array.
# We must NOT disable or delete these Entra objects -- doing so breaks the
# device's ability to re-enroll via Autopilot. Cleanup of Autopilot records
# should be done on the Intune / Autopilot side first, which then cascades.
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

# ---------------------------------------------------------------------------
# Secret-backup helpers -- BitLocker recovery keys and Windows LAPS passwords
# ---------------------------------------------------------------------------
# These are fetched BEFORE any hard delete. If a backup fails for a device
# that is slated for real deletion, the script refuses to delete that device
# so the recovery material is never lost to a transient API hiccup.

function Get-DeviceBitlockerKeys {
    # Returns an array of PSCustomObject with KeyId/VolumeType/CreatedUtc/RecoveryKey.
    # Throws on retrieval errors so the caller can abort the delete.
    #
    # Uses Invoke-MgGraphRequest with -OutputType PSObject so the 'key'
    # property is returned as a proper member (the default HashTable output
    # can silently resolve missing keys to $null on some PS versions).
    param([Parameter(Mandatory)] [string] $DeviceIdGuid)

    $out = @()

    # Step 1: list all recovery key records for this device. The list endpoint
    # returns id, createdDateTime, volumeType, deviceId by default -- the key
    # material itself is NEVER returned from the list call.
    $listUri  = "https://graph.microsoft.com/v1.0/informationProtection/bitlocker/recoveryKeys?`$filter=deviceId eq '$DeviceIdGuid'"
    $listResp = Invoke-MgGraphRequest -Method GET -Uri $listUri -OutputType PSObject -ErrorAction Stop
    $items    = @($listResp.value)

    foreach ($m in $items) {
        # Step 2: re-fetch each key with $select=key to force the key
        # material into the response body. Narrow the select to JUST 'key' --
        # some tenants return errors when selecting multiple fields on this
        # endpoint, and we already have volumeType + createdDateTime from
        # the list response above.
        $keyUri = "https://graph.microsoft.com/v1.0/informationProtection/bitlocker/recoveryKeys/$($m.id)?`$select=key"
        $full   = Invoke-MgGraphRequest -Method GET -Uri $keyUri -OutputType PSObject -ErrorAction Stop

        # Defensive accessor: try direct property, then a case-insensitive
        # lookup via the PSObject adapter in case the SDK ever shifts casing.
        $recoveryKey = $null
        if ($null -ne $full) {
            $recoveryKey = $full.key
            if ([string]::IsNullOrEmpty($recoveryKey) -and $full.PSObject -and $full.PSObject.Properties) {
                $prop = $full.PSObject.Properties | Where-Object { $_.Name -ieq 'key' } | Select-Object -First 1
                if ($prop) { $recoveryKey = $prop.Value }
            }
        }

        if ([string]::IsNullOrEmpty($recoveryKey)) {
            # Surface a diagnostic so you can tell backup-empty apart from
            # backup-successful-but-CSV-misread. Common causes:
            #   - App registration has BitlockerKey.ReadBasic.All, not .Read.All
            #   - Cached access token predates the permission consent
            #   - Key was stored before BitLocker-to-AAD escrow was enabled
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
    # Returns an array of PSCustomObject with AccountName/AccountSid/BackupDateUtc/Password.
    # Returns empty array (not throw) if the device simply has no LAPS record.
    #
    # Uses Invoke-MgGraphRequest for the same reason as Get-DeviceBitlockerKeys:
    # the $select=credentials query param is required to get the password
    # field populated, and the typed cmdlet's -Property has been flaky.
    param([Parameter(Mandatory)] [string] $DeviceIdGuid)

    $out = @()
    $uri = "https://graph.microsoft.com/v1.0/directory/deviceLocalCredentials/$DeviceIdGuid`?`$select=credentials,lastBackupDateTime,deviceName"

    try {
        $laps = Invoke-MgGraphRequest -Method GET -Uri $uri -ErrorAction Stop
    }
    catch {
        # 404 = no LAPS record for this device; treat as benign.
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
    <#
        Collects BitLocker keys and LAPS credentials for a device, appending
        one row per secret (or a NotFound marker) to $Collector. Returns
        $true if every retrieval succeeded, $false if anything errored.
    #>
    param(
        [Parameter(Mandatory)] $Device,

        # AllowEmptyCollection is required: a freshly-created List[object] has
        # zero elements on the first call, and PowerShell's default Mandatory
        # binding rejects empty collections ("Cannot bind argument ... because
        # it is an empty collection").
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[object]] $Collector
    )

    # Belt-and-suspenders Windows gate: BitLocker and Windows LAPS only exist
    # for Windows devices. If a caller ever forgets to filter on OS, this
    # short-circuits so the CSV never gets polluted with blank iOS / Android /
    # macOS rows. We return $true so the caller's delete path still proceeds.
    $os = "$($Device.OperatingSystem)"
    if ($os -notmatch '^(?i)windows') {
        Write-Log ("Backup-DeviceSecrets: skipping '{0}' [{1}] -- non-Windows OS '{2}' has no BitLocker/LAPS." -f `
            $Device.DisplayName, $Device.Id, $os)
        return $true
    }

    $allOk = $true
    $stamp = (Get-Date).ToString('u')

    # Inline row builder keeps CSV column order stable across records.
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

#endregion

#region Classify and act

$results         = New-Object System.Collections.Generic.List[object]
$autopilotStale  = New-Object System.Collections.Generic.List[object]
$secretsBackup   = New-Object System.Collections.Generic.List[object]
$counters = [ordered]@{
    Total              = 0
    AutopilotProtected = 0
    ToDisable          = 0
    Disabled           = 0
    DisableSkipped     = 0
    ToDelete           = 0
    Deleted            = 0
    DeleteSkipped      = 0
    BackupFailed       = 0
    Errors             = 0
}

foreach ($device in $staleDevices) {
    $counters.Total++

    # Guard: some devices genuinely have no last-sign-in stamp. Fall back to
    # registrationDateTime so brand-new, never-used devices still age out.
    $effectiveDate = if ($device.ApproximateLastSignInDateTime) {
        $device.ApproximateLastSignInDateTime
    } elseif ($device.RegistrationDateTime) {
        $device.RegistrationDateTime
    } else {
        $null
    }

    if (-not $effectiveDate) {
        Write-Log "Skipping device '$($device.DisplayName)' [$($device.Id)] -- no last-sign-in or registration timestamp." -Level WARN
        continue
    }

    $ageDays = [int]([datetime]::UtcNow - $effectiveDate.ToUniversalTime()).TotalDays

    # Initial classification based purely on age.
    $targetStage     = if ($ageDays -ge $HardDeleteAfterDays) { 'HardDelete' }
                       elseif ($ageDays -ge $SoftDeleteAfterDays) { 'SoftDelete' }
                       else { 'None' }
    $downgradeReason = $null

    # Safety-rail downgrades: HardDelete -> SoftDelete in certain conditions.
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

    # --- Autopilot guard ---------------------------------------------------
    # Never disable or delete Autopilot devices from Entra -- it breaks the
    # re-enrollment path. Record them in a separate list and move on so the
    # admin can clean them up in Intune / Autopilot first.
    if ($isAutopilot) {
        $counters.AutopilotProtected++
        $row.Action = 'None (Autopilot-protected)'
        $row.Status = 'SkippedAutopilot'
        $autopilotStale.Add($row) | Out-Null
        $results.Add($row)        | Out-Null
        Write-Log ("PROTECTED Autopilot device '{0}' [{1}] (ZTDId {2}) -- would have been {3}, age {4} days." -f `
            $device.DisplayName, $device.Id, $ztdId, $targetStage, $ageDays) -Level WARN
        continue
    }
    # -----------------------------------------------------------------------

    try {
        switch ($targetStage) {

            'HardDelete' {
                $counters.ToDelete++
                $row.Action = 'Backup secrets -> Remove-MgDevice'

                # --- Back up BitLocker + LAPS BEFORE deleting --------------
                # Only applicable to Windows devices. Android / iOS / iPadOS /
                # macOS don't have BitLocker or Windows LAPS records, so skip
                # the backup call entirely for those and let the delete proceed.
                # We always run the backup (even in dry-run) so the admin can
                # verify what would be captured. If backup fails in a real run
                # we refuse to delete -- the recovery material is irreplaceable.
                $isWindowsDevice = $device.OperatingSystem -match '^(?i)windows'
                if (-not $BackupBLandLAPs) {
                    # Operator has opted out of capturing secrets entirely
                    # (e.g. they have a separate BL/LAPS backup pipeline).
                    # Treat backup as "not required" so the delete can proceed.
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
                    # Dry-run: record the failure but continue so the admin sees full output.
                    Write-Log "Dry-run: secret backup for '$($device.DisplayName)' [$($device.Id)] failed. In a real run the delete would be aborted." -Level WARN
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
                # Preview backup: for Windows devices that were downgraded from
                # HardDelete by the safety rails, opportunistically capture
                # BitLocker + LAPS now so the admin can validate the backup
                # flow before anything destructive ever runs. Opt-in via
                # $PreviewSecretsBackup. Retrieval errors here are logged but
                # non-fatal -- the disable still proceeds.
                if ($BackupBLandLAPs -and $PreviewSecretsBackup -and $downgradeReason -and ($device.OperatingSystem -match '^(?i)windows')) {
                    Write-Log "Preview backup: capturing BitLocker + LAPS for '$($device.DisplayName)' [$($device.Id)] (downgraded from HardDelete, age $ageDays days)..."
                    try {
                        Backup-DeviceSecrets -Device $device -Collector $secretsBackup | Out-Null
                    } catch {
                        Write-Log "Preview backup failed for '$($device.DisplayName)' [$($device.Id)]: $_" -Level WARN
                    }
                }

                if (-not $device.AccountEnabled) {
                    # Already disabled -- nothing to do in stage 1; it'll be picked
                    # up by stage 2 once it crosses $HardDeleteAfterDays.
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
                # Device was returned by the filter but falls below the soft-delete
                # cutoff after fallback date logic -- leave it alone.
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
    $results | Export-Csv -Path $csvFile -NoTypeInformation -Encoding UTF8
    Write-Log "Per-device results written to $csvFile"
}
catch {
    Write-Log "Failed to write CSV summary: $_" -Level WARN
}

# Separate CSV for Autopilot devices the admin needs to clean up in Intune.
$autopilotCsv = Join-Path $LogPath "EntraCleanup-StaleAutopilotDevices-$runStamp.csv"
if ($autopilotStale.Count -gt 0) {
    try {
        $autopilotStale | Export-Csv -Path $autopilotCsv -NoTypeInformation -Encoding UTF8
        Write-Log "Stale Autopilot devices (protected -- NOT modified) written to $autopilotCsv"
    }
    catch {
        Write-Log "Failed to write Autopilot CSV: $_" -Level WARN
    }
}

# --------------------------------------------------------------------------
# SECRETS CSV -- BitLocker recovery keys and LAPS passwords backed up prior
# to hard delete. This file contains plaintext recovery material: treat it
# like a password vault export. Recommended handling:
#   - Move it into a secure vault (e.g. Azure Key Vault, secure share) asap.
#   - Tighten NTFS ACLs on the logs folder (SYSTEM + the automation identity only).
#   - Purge once you've confirmed no restore is needed.
# --------------------------------------------------------------------------
$secretsCsv = Join-Path $LogPath "EntraCleanup-BL-LAPSBackup-$runStamp.csv"
if (-not $BackupBLandLAPs) {
    Write-Log "Skipping secrets CSV write -- BackupBLandLAPs = `$false." -Level WARN
}
elseif ($secretsBackup.Count -gt 0) {
    try {
        $secretsBackup | Export-Csv -Path $secretsCsv -NoTypeInformation -Encoding UTF8
        # Best-effort ACL tightening on Windows: owner + SYSTEM + Administrators only.
        if ($IsWindows -or $PSVersionTable.PSEdition -eq 'Desktop') {
            try {
                $acl = New-Object System.Security.AccessControl.FileSecurity
                $acl.SetAccessRuleProtection($true, $false)  # disable inheritance, drop inherited
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

# --------------------------------------------------------------------------
# OUTPUT BLOCK -- upload run artifacts to Azure Blob Storage via REST.
# Required because the Automation runbook sandbox is ephemeral. We upload
# everything in $LogPath (transcript + all CSVs from this run) into a
# date-stamped "folder" (blob prefix) so successive runs don't collide.
#
# Implementation note: this block uses a managed-identity-issued bearer
# token + Invoke-RestMethod against the storage REST API. No Az.Storage
# module is imported or required -- that module's notorious dependency
# conflict with Az.Accounts in Automation accounts is the very reason we
# do this by hand.
#
# Skip the block entirely if the storage vars weren't set or the token
# couldn't be acquired during pre-flight.
# --------------------------------------------------------------------------
if ($StorageAccountName -and $StorageContainerName -and $storageToken) {
    Write-Log "Uploading run artifacts to https://$StorageAccountName.blob.core.windows.net/$StorageContainerName/..."

    $blobPrefix = "runs/$runStamp"
    $files      = Get-ChildItem -Path $LogPath -File -ErrorAction SilentlyContinue
    $okCount    = 0
    $failCount  = 0

    foreach ($f in $files) {
        $blobName = "$blobPrefix/$($f.Name)"
        try {
            Send-FileToBlob `
                -StorageAccountName $StorageAccountName `
                -ContainerName      $StorageContainerName `
                -BlobName           $blobName `
                -FilePath           $f.FullName `
                -AccessToken        $storageToken
            Write-Log "  uploaded $($f.Name) -> $blobName"
            $okCount++
        }
        catch {
            # Log per-file failure but keep going so a transient 500 on the
            # transcript doesn't lose the secrets CSV (or vice versa).
            Write-Log "  FAILED to upload $($f.Name): $_" -Level ERROR
            $failCount++
        }
    }

    if ($failCount -eq 0) {
        Write-Log "Upload complete: $okCount file(s) uploaded under prefix '$blobPrefix'."
    } else {
        Write-Log "Upload finished with errors: $okCount succeeded, $failCount failed (prefix '$blobPrefix'). Failed artifacts will be lost when this job ends." -Level ERROR
    }
}
elseif ($StorageAccountName -and $StorageContainerName -and -not $storageToken) {
    Write-Log "Storage upload skipped because the managed-identity token could not be acquired earlier in this run. See the ERROR above for the cause." -Level WARN
}
else {
    Write-Log "Storage upload not configured -- artifacts left at '$LogPath'. In Azure Automation this folder is ephemeral and will be discarded when the job ends." -Level WARN
}

Disconnect-MgGraph | Out-Null
Stop-Transcript    | Out-Null