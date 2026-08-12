<#
.SYNOPSIS
    Two-stage stale-device cleanup for Entra ID -- Azure Automation runbook,
    system-assigned managed identity auth.

.DESCRIPTION
    Faithful port of Matt Kohut's Div-CleanupEntra-Intune-AP-Devices.ps1
    (delegated/interactive variant) for Azure Automation. All original
    configuration options are preserved as runbook parameters with the same
    defaults. Environment-forced changes only:
      - Connect-MgGraph -Identity (managed identity) replaces interactive auth.
      - Transcript/CSV file outputs are replaced by job output streams.
      - BitLocker/LAPS backup writes to Azure Key Vault (one secret per device)
        instead of a local CSV, with automatic retention cleanup. Secret
        material is NEVER written to the job output stream.
      - -DeviceListCsv is replaced by -DeviceListBlobUrl (same columns and
        semantics, read from blob storage with the managed identity).

    The managed identity needs these Graph application permissions:
      Device.ReadWrite.All, Directory.Read.All, BitlockerKey.Read.All,
      DeviceLocalCredential.Read.All, DeviceManagementManagedDevices.ReadWrite.All,
      DeviceManagementServiceConfig.ReadWrite.All
    plus 'Key Vault Secrets Officer' on the vault named in -KeyVaultName.

.NOTES
    Original: Matt Kohut (source/Div-CleanupEntra-Intune-AP-Devices.ps1).
    Port:     2026-07-30. The source copy is truncated at the "secrets CSV"
              comment; the summary/disconnect tail here is rebuilt.
#>

param(
    # --- Run mode -------------------------------------------------------------
    [Parameter()] [bool]   $DryRun = $true,

    # --- Lifecycle thresholds (days) ------------------------------------------
    [Parameter()] [int]    $SoftDeleteAfterDays = 90,
    [Parameter()] [int]    $HardDeleteAfterDays = 120,

    # --- Safety rails ---------------------------------------------------------
    [Parameter()] [bool]   $DisableOnly                 = $false,
    [Parameter()] [bool]   $RequireDisabledBeforeDelete = $false,

    # --- BitLocker / LAPS backup ----------------------------------------------
    [Parameter()] [bool]   $BackupBLandLAPs            = $true,
    [Parameter()] [bool]   $PreviewSecretsBackup       = $true,
    [Parameter()] [bool]   $BackupOnlyBeforeHardDelete = $true,
    [Parameter()] [string] $KeyVaultName               = '',
    [Parameter()] [int]    $SecretRetentionDays        = 4,
    [Parameter()] [string] $SecretNamePrefix           = 'devclean',

    # --- Intune / Autopilot deletion ------------------------------------------
    [Parameter()] [bool]   $DeleteIntuneObjects              = $true,
    [Parameter()] [bool]   $DeleteAutopilotObjects           = $true,
    [Parameter()] [bool]   $ProceedOnAutopilotLookupFailure  = $false,
    [Parameter()] [bool]   $AutopilotLookupPreferEnumeration = $true,
    # Serial-aware AP guard (added 2026-07-31): a stale pre-enrollment Entra
    # object can share hardware with a LIVE enrollment under a different Entra
    # object. Matching AP records by the stale object's deviceId would then
    # delete the Autopilot registration of an in-service machine. When enabled,
    # AP records whose serial matches a managed device that synced within
    # ActiveHardwareWindowDays are protected: the AP record is kept while the
    # stale Entra object still proceeds through its normal deletion path.
    [Parameter()] [bool]   $ProtectAutopilotForActiveHardware = $true,
    [Parameter()] [int]    $ActiveHardwareWindowDays          = 30,

    # --- Device-list override (blob replaces local CSV) ------------------------
    [Parameter()] [string] $DeviceListBlobUrl        = '',
    [Parameter()] [string] $OnDuplicateMatch         = 'Skip',   # 'Skip' | 'ProcessAll'
    [Parameter()] [bool]   $CsvRespectsAgeThresholds = $false,

    # --- Operating-system filter ----------------------------------------------
    # Empty = include every operating-system value (backward-compatible default).
    # Use -OperatingSystemFilter Windows for a Windows-only run.
    [Parameter()]
    [ValidateSet('Windows', 'Android', 'AndroidForWork', 'AndroidAOSP', 'iOS', 'IPhone', 'IPad', 'macOS', 'Linux', 'Unknown', 'Other')]
    [string] $OperatingSystemFilter = ''
)

$OperatingSystemFilterValues = @(
    $OperatingSystemFilter -split ',' |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ }
)

$ErrorActionPreference = 'Stop'

# ============================================================================
# Logging -- single output stream with level prefixes so ordering survives in
# the Automation job output. (Replaces Start-Transcript in the original.)
# ============================================================================
function Write-Log {
    param(
        [Parameter(Mandatory)] [string] $Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'ACTION')]
        [string] $Level = 'INFO'
    )
    Write-Output ("[{0}] [{1}] {2}" -f (Get-Date -Format 'u'), $Level, $Message)
}

$runStamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
Write-Log "===== NEW RUN: $runStamp ====="

#region Pre-flight

if ($HardDeleteAfterDays -lt $SoftDeleteAfterDays) {
    throw "HardDeleteAfterDays ($HardDeleteAfterDays) must be >= SoftDeleteAfterDays ($SoftDeleteAfterDays)."
}
if ($OnDuplicateMatch -notin @('Skip', 'ProcessAll')) {
    throw "OnDuplicateMatch must be 'Skip' or 'ProcessAll' (got '$OnDuplicateMatch')."
}
# Portal job-input fields sometimes arrive with literal surrounding quotes
# (a pasted "value"); a quoted name silently builds an invalid vault URL that
# only fails at the first live backup. Strip them, then validate the result.
$KeyVaultName = $KeyVaultName.Trim().Trim('"').Trim("'")
if ($BackupBLandLAPs -and [string]::IsNullOrWhiteSpace($KeyVaultName)) {
    throw 'BackupBLandLAPs is $true but -KeyVaultName is empty. Provide the vault name or disable the backup.'
}
if ($KeyVaultName -and $KeyVaultName -notmatch '^[A-Za-z][A-Za-z0-9-]{1,22}[A-Za-z0-9]$') {
    throw "KeyVaultName '$KeyVaultName' is not a valid Key Vault name (3-24 chars, alphanumeric/hyphens). Do not wrap the value in quotes."
}
if ($SecretRetentionDays -lt 1 -or $SecretRetentionDays -gt 30) {
    throw "SecretRetentionDays=$SecretRetentionDays is outside the sane range (1-30). Long retention keeps plaintext BitLocker/LAPS material in the vault -- the design intent is a short rollback window (default 4 days)."
}

$requiredModules = @(
    'Microsoft.Graph.Authentication',
    'Microsoft.Graph.Identity.DirectoryManagement',
    'Microsoft.Graph.Identity.SignIns'            # BitLocker recovery keys
)
foreach ($m in $requiredModules) {
    if (-not (Get-Module -ListAvailable -Name $m)) {
        throw "Required module '$m' is not available in this Automation account. Import it (see Terraform module_version variable)."
    }
    Import-Module $m -ErrorAction Stop | Out-Null
}

#endregion

#region Managed-identity token helper (Key Vault / Storage data planes)

function Get-ManagedIdentityToken {
    # Returns a bearer token for the given resource audience using the
    # Automation sandbox's managed-identity endpoint.
    param([Parameter(Mandatory)] [string] $Resource)

    if (-not $env:IDENTITY_ENDPOINT -or -not $env:IDENTITY_HEADER) {
        throw 'Managed identity endpoint not available -- is this running in Azure Automation with a system-assigned identity?'
    }
    $uri  = "$($env:IDENTITY_ENDPOINT)?resource=$([uri]::EscapeDataString($Resource))&api-version=2019-08-01"
    $resp = Invoke-RestMethod -Method GET -Uri $uri -Headers @{ 'X-IDENTITY-HEADER' = $env:IDENTITY_HEADER } -ErrorAction Stop
    return $resp.access_token
}

#endregion

#region Authenticate to Microsoft Graph

try {
    Write-Log 'Connecting to Microsoft Graph with the system-assigned managed identity...'
    Connect-MgGraph -Identity -NoWelcome -ErrorAction Stop
    $ctx = Get-MgContext
    Write-Log "Connected. Account: $($ctx.Account)  ClientId: $($ctx.ClientId)  AuthType: $($ctx.AuthType)"
    # Delegated-scope sanity check from the original does not apply: app-role
    # grants are fixed at deploy time. A missing role surfaces as a 403 on the
    # affected call; the Terraform module is the source of truth for grants.
}
catch {
    Write-Log "Failed to connect to Graph: $_" -Level ERROR
    throw
}

#endregion

#region Query stale devices

$nowUtc        = (Get-Date).ToUniversalTime()
$softCutoffUtc = $nowUtc.AddDays(-1 * $SoftDeleteAfterDays)
$hardCutoffUtc = $nowUtc.AddDays(-1 * $HardDeleteAfterDays)
$softCutoffIso = $softCutoffUtc.ToString('yyyy-MM-ddTHH:mm:ssZ')
$hardCutoffIso = $hardCutoffUtc.ToString('yyyy-MM-ddTHH:mm:ssZ')

Write-Log "Soft-delete cutoff (disable): devices inactive since $softCutoffIso ($SoftDeleteAfterDays days)"
Write-Log "Hard-delete cutoff (delete):  devices inactive since $hardCutoffIso ($HardDeleteAfterDays days)"
Write-Log ("Safety rails: DisableOnly={0}  RequireDisabledBeforeDelete={1}  PreviewSecretsBackup={2}  BackupBLandLAPs={3}  BackupOnlyBeforeHardDelete={4}  DeleteIntuneObjects={5}  DeleteAutopilotObjects={6}  ProceedOnAutopilotLookupFailure={7}  AutopilotLookupPreferEnumeration={8}  DryRun={9}" -f `
    $DisableOnly, $RequireDisabledBeforeDelete, $PreviewSecretsBackup, $BackupBLandLAPs, $BackupOnlyBeforeHardDelete, $DeleteIntuneObjects, $DeleteAutopilotObjects, $ProceedOnAutopilotLookupFailure, $AutopilotLookupPreferEnumeration, $DryRun)
if ($DeviceListBlobUrl) {
    Write-Log ("DeviceListBlobUrl='{0}'  OnDuplicateMatch='{1}'  CsvRespectsAgeThresholds={2} -- CSV-OVERRIDE MODE: age-based staleness query SKIPPED." -f $DeviceListBlobUrl, $OnDuplicateMatch, $CsvRespectsAgeThresholds) -Level WARN
}
if ($OperatingSystemFilterValues.Count -gt 0) {
    Write-Log ("OperatingSystemFilter='{0}' -- only matching operating-system values will be processed." -f ($OperatingSystemFilterValues -join ', ')) -Level WARN
}
if ($DisableOnly) {
    Write-Log 'DisableOnly is ON -- NO hard deletes will be performed on this run; all stage-2 candidates will be disabled instead.' -Level WARN
}
if (-not $BackupBLandLAPs -and -not $DryRun -and -not $DisableOnly) {
    Write-Log 'BackupBLandLAPs = $false in a live run with hard deletes enabled: BitLocker + LAPS will NOT be captured before deletion. If you do not have a separate backup mechanism, abort and reconfigure.' -Level WARN
}

$filter = "approximateLastSignInDateTime le $softCutoffIso"
$select = 'id,displayName,deviceId,operatingSystem,operatingSystemVersion,accountEnabled,approximateLastSignInDateTime,registrationDateTime,trustType,physicalIds'

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

function Test-OperatingSystemMatch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $OperatingSystem,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]] $AllowedOperatingSystems
    )

    if ($AllowedOperatingSystems.Count -eq 0) { return $true }

    $value = $OperatingSystem.Trim()
    foreach ($allowed in $AllowedOperatingSystems) {
        switch ($allowed) {
            'Windows'        { if ($value -match '(?i)^Windows') { return $true } }
            'Android'        { if ($value -ieq 'Android') { return $true } }
            'AndroidForWork' { if ($value -ieq 'AndroidForWork') { return $true } }
            'AndroidAOSP'    { if ($value -ieq 'AndroidAOSP') { return $true } }
            'iOS'            { if ($value -match '(?i)^(iOS|IPhone|IPad)$') { return $true } }
            'IPhone'         { if ($value -ieq 'IPhone') { return $true } }
            'IPad'           { if ($value -ieq 'IPad') { return $true } }
            'macOS'          { if ($value -match '(?i)^(macOS|MacMDM|Mac)$') { return $true } }
            'Linux'          { if ($value -ieq 'Linux') { return $true } }
            'Unknown'        { if ([string]::IsNullOrWhiteSpace($value) -or $value -ieq 'Unknown') { return $true } }
            'Other'          { if ($value -notmatch '(?i)^(Windows|Android|AndroidForWork|AndroidAOSP|iOS|IPhone|IPad|macOS|MacMDM|Mac|Linux|Unknown)$') { return $true } }
        }
    }
    return $false
}

# --- Secret-backup helpers: BitLocker recovery keys + Windows LAPS passwords.

function Get-DeviceBitlockerKeys {
    param([Parameter(Mandatory)] [string] $DeviceIdGuid)

    $out = @()
    $listUri  = "https://graph.microsoft.com/v1.0/informationProtection/bitlocker/recoveryKeys?`$filter=deviceId eq '$DeviceIdGuid'"
    $listResp = Invoke-MgGraphRequest -Method GET -Uri $listUri -OutputType PSObject -ErrorAction Stop
    $items    = @($listResp.value)

    foreach ($m in $items) {
        $keyUri = "https://graph.microsoft.com/v1.0/informationProtection/bitlocker/recoveryKeys/$($m.id)?`$select=key"
        $full   = Invoke-MgGraphRequest -Method GET -Uri $keyUri -OutputType PSObject -ErrorAction Stop

        $recoveryKey = $null
        if ($null -ne $full) {
            $recoveryKey = $full.key
            if ([string]::IsNullOrEmpty($recoveryKey) -and $full.PSObject -and $full.PSObject.Properties) {
                $prop = $full.PSObject.Properties | Where-Object { $_.Name -ieq 'key' } | Select-Object -First 1
                if ($prop) { $recoveryKey = $prop.Value }
            }
        }

        if ([string]::IsNullOrEmpty($recoveryKey)) {
            Write-Log ("BitLocker GET returned no key material for id '{0}'. Check that BitlockerKey.Read.All (NOT .ReadBasic.All) is granted to the managed identity." -f $m.id) -Level WARN
        }

        $out += [pscustomobject]@{
            KeyId       = $m.id
            VolumeType  = $m.volumeType
            CreatedUtc  = $m.createdDateTime
            RecoveryKey = $recoveryKey
        }
    }
    return ,$out
}

function Get-DeviceLapsCredentials {
    param([Parameter(Mandatory)] [string] $DeviceIdGuid)

    $out = @()
    $uri = "https://graph.microsoft.com/v1.0/directory/deviceLocalCredentials/$DeviceIdGuid`?`$select=credentials,lastBackupDateTime,deviceName"

    try {
        $laps = Invoke-MgGraphRequest -Method GET -Uri $uri -ErrorAction Stop
    }
    catch {
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
                $plain = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($cred.passwordBase64))
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

# --- Key Vault secret store (replaces the plaintext secrets CSV).
# One secret per device holding a JSON document with every BitLocker key and
# LAPS credential. NEVER emitted to the output stream.

$script:_kvToken = $null
function Get-KeyVaultAuthHeader {
    if (-not $script:_kvToken) {
        $script:_kvToken = Get-ManagedIdentityToken -Resource 'https://vault.azure.net'
    }
    return @{ Authorization = "Bearer $($script:_kvToken)" }
}

function Set-DeviceSecretInVault {
    # Returns $true on success. Secret name: <prefix>-<entra deviceId guid>.
    param(
        [Parameter(Mandatory)] $Device,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $BitlockerKeys,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $LapsCredentials
    )

    $payload = [ordered]@{
        collectedUtc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        runStamp     = $runStamp
        objectId     = $Device.Id
        deviceId     = $Device.DeviceId
        displayName  = $Device.DisplayName
        os           = "$($Device.OperatingSystem) $($Device.OperatingSystemVersion)".Trim()
        bitlocker    = @($BitlockerKeys | ForEach-Object { [ordered]@{ keyId = $_.KeyId; volumeType = $_.VolumeType; createdUtc = $_.CreatedUtc; recoveryKey = $_.RecoveryKey } })
        laps         = @($LapsCredentials | ForEach-Object { [ordered]@{ accountName = $_.AccountName; accountSid = $_.AccountSid; backupDateUtc = $_.BackupDateUtc; password = $_.Password } })
    }

    $secretName = ('{0}-{1}' -f $SecretNamePrefix, $Device.DeviceId) -replace '[^0-9a-zA-Z-]', '-'
    $retainUntil = (Get-Date).ToUniversalTime().AddDays($SecretRetentionDays).ToString('yyyy-MM-ddTHH:mm:ssZ')
    $body = @{
        value = ($payload | ConvertTo-Json -Depth 6)
        tags  = @{ source = 'device-cleanup'; retainUntil = $retainUntil; displayName = "$($Device.DisplayName)" }
    } | ConvertTo-Json -Depth 8

    $uri = "https://$KeyVaultName.vault.azure.net/secrets/$secretName`?api-version=7.4"
    Invoke-RestMethod -Method PUT -Uri $uri -Headers (Get-KeyVaultAuthHeader) -Body $body -ContentType 'application/json' -ErrorAction Stop | Out-Null
    Write-Log "Key Vault: stored secret '$secretName' (retainUntil $retainUntil) for '$($Device.DisplayName)'."
    return $true
}

function Invoke-VaultRetentionCleanup {
    # Two-phase cleanup to avoid delete/purge 409 races:
    #   1. purge previously-DELETED secrets with our prefix (deleted on an earlier run)
    #   2. delete ACTIVE secrets whose retainUntil tag is in the past
    param([Parameter(Mandatory)] [bool] $IsDryRun)

    $headers  = Get-KeyVaultAuthHeader
    $vaultUri = "https://$KeyVaultName.vault.azure.net"
    $nowIso   = (Get-Date).ToUniversalTime()

    # Phase 1: purge previously deleted.
    try {
        $next = "$vaultUri/deletedsecrets?api-version=7.4"
        while ($next) {
            $page = Invoke-RestMethod -Method GET -Uri $next -Headers $headers -ErrorAction Stop
            foreach ($item in @($page.value)) {
                $name = ($item.id -split '/')[-1]
                if ($name -notlike "$SecretNamePrefix-*") { continue }
                if ($IsDryRun) {
                    Write-Log "DRY-RUN would PURGE deleted Key Vault secret '$name'."
                    continue
                }
                try {
                    Invoke-RestMethod -Method DELETE -Uri "$vaultUri/deletedsecrets/$name`?api-version=7.4" -Headers $headers -ErrorAction Stop | Out-Null
                    Write-Log "Key Vault: PURGED deleted secret '$name'." -Level ACTION
                }
                catch {
                    Write-Log "Key Vault purge failed for '$name': $_" -Level WARN
                }
            }
            $next = $page.nextLink
        }
    }
    catch {
        Write-Log "Key Vault deleted-secret enumeration failed: $_" -Level WARN
    }

    # Phase 2: delete active secrets past retention.
    try {
        $next = "$vaultUri/secrets?api-version=7.4"
        while ($next) {
            $page = Invoke-RestMethod -Method GET -Uri $next -Headers $headers -ErrorAction Stop
            foreach ($item in @($page.value)) {
                $name = ($item.id -split '/')[-1]
                if ($name -notlike "$SecretNamePrefix-*") { continue }
                $retainUntilTag = $null
                if ($item.tags -and $item.tags.retainUntil) { $retainUntilTag = $item.tags.retainUntil }
                $expired = $false
                if ($retainUntilTag) {
                    try { $expired = ([datetime]::Parse($retainUntilTag).ToUniversalTime() -lt $nowIso) } catch { $expired = $false }
                }
                if (-not $expired) { continue }
                if ($IsDryRun) {
                    Write-Log "DRY-RUN would DELETE expired Key Vault secret '$name' (retainUntil $retainUntilTag)."
                    continue
                }
                try {
                    Invoke-RestMethod -Method DELETE -Uri "$vaultUri/secrets/$name`?api-version=7.4" -Headers $headers -ErrorAction Stop | Out-Null
                    Write-Log "Key Vault: DELETED expired secret '$name' (retainUntil $retainUntilTag) -- will be purged next run." -Level ACTION
                }
                catch {
                    Write-Log "Key Vault delete failed for '$name': $_" -Level WARN
                }
            }
            $next = $page.nextLink
        }
    }
    catch {
        Write-Log "Key Vault secret enumeration failed: $_" -Level WARN
    }
}

function Backup-DeviceSecrets {
    # Fetches BL + LAPS and stores one Key Vault secret per device.
    # Returns $true if every retrieval + the store succeeded.
    param([Parameter(Mandatory)] $Device)

    $os = "$($Device.OperatingSystem)"
    if ($os -notmatch '^(?i)windows') {
        Write-Log ("Backup-DeviceSecrets: skipping '{0}' [{1}] -- non-Windows OS '{2}' has no BitLocker/LAPS." -f `
            $Device.DisplayName, $Device.Id, $os)
        return $true
    }

    $keys  = @()
    $creds = @()
    $allOk = $true

    try {
        $keys = @(Get-DeviceBitlockerKeys -DeviceIdGuid $Device.DeviceId)
        Write-Log ("BitLocker: {0} key(s) found for '{1}'." -f $keys.Count, $Device.DisplayName)
    }
    catch {
        $allOk = $false
        Write-Log "BitLocker backup FAILED for '$($Device.DisplayName)' [$($Device.Id)]: $_" -Level ERROR
    }

    try {
        $creds = @(Get-DeviceLapsCredentials -DeviceIdGuid $Device.DeviceId)
        Write-Log ("LAPS: {0} credential(s) found for '{1}'." -f $creds.Count, $Device.DisplayName)
    }
    catch {
        $allOk = $false
        Write-Log "LAPS backup FAILED for '$($Device.DisplayName)' [$($Device.Id)]: $_" -Level ERROR
    }

    if ($allOk -and (($keys.Count -gt 0) -or ($creds.Count -gt 0))) {
        try {
            Set-DeviceSecretInVault -Device $Device -BitlockerKeys $keys -LapsCredentials $creds | Out-Null
        }
        catch {
            $allOk = $false
            Write-Log "Key Vault store FAILED for '$($Device.DisplayName)' [$($Device.Id)]: $_" -Level ERROR
        }
    }
    elseif ($allOk) {
        Write-Log "No BitLocker keys or LAPS credentials found for '$($Device.DisplayName)' -- nothing to store."
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

# --- Intune + Autopilot deletion helpers (unchanged from original).

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

$script:_apEnumerationCache = $null
$script:_activeSerialCache  = $null
$script:_apProtectedCount   = 0

function Get-ActiveHardwareSerials {
    # Serials of managed devices that synced with Intune within the window.
    # Cached for the run. Used by the serial-aware Autopilot guard.
    if ($null -ne $script:_activeSerialCache) { return $script:_activeSerialCache }

    $serials = New-Object System.Collections.Generic.HashSet[string]
    $cutoff  = (Get-Date).ToUniversalTime().AddDays(-1 * $ActiveHardwareWindowDays)
    try {
        $next = "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices?`$select=serialNumber,lastSyncDateTime&`$top=999"
        while ($next) {
            $page = Invoke-MgGraphRequest -Method GET -Uri $next -OutputType PSObject -ErrorAction Stop
            foreach ($m in @($page.value)) {
                $serial = "$($m.serialNumber)".Trim().ToUpperInvariant()
                if (-not $serial) { continue }
                try {
                    if ([datetime]$m.lastSyncDateTime -ge $cutoff) { [void]$serials.Add($serial) }
                } catch { }
            }
            $next = if ($page.PSObject.Properties['@odata.nextLink']) { $page.'@odata.nextLink' } else { $null }
        }
        Write-Log "Active-hardware serial cache: $($serials.Count) managed devices synced within $ActiveHardwareWindowDays days."
    }
    catch {
        Write-Log "Active-hardware serial lookup FAILED: $_ -- AP guard will treat all serials as unknown (protect none by serial)." -Level WARN
    }
    $script:_activeSerialCache = $serials
    return $serials
}

function Remove-AutopilotDevice {
    param(
        [Parameter(Mandatory)] [string] $EntraDeviceId,
        [Parameter(Mandatory)] [string] $DisplayName,
        [Parameter(Mandatory)] [bool]   $DryRun
    )

    $v1Base   = 'https://graph.microsoft.com/v1.0/deviceManagement/windowsAutopilotDeviceIdentities'
    $betaBase = 'https://graph.microsoft.com/beta/deviceManagement/windowsAutopilotDeviceIdentities'
    $select   = '$select=id,serialNumber,model,manufacturer,azureActiveDirectoryDeviceId'
    $ap       = $null

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
            if ($null -eq $script:_apEnumerationCache) {
                Write-Log "Enumerating Autopilot via $($s.Version) (cached for this run; slow on large tenants)..." -Level WARN
                try {
                    $all  = @()
                    $next = $s.Base
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
                    continue
                }
            }
            $ap = @($script:_apEnumerationCache | Where-Object { $_.azureActiveDirectoryDeviceId -eq $EntraDeviceId })
        }
    }

    if ($null -eq $ap) {
        Write-Log "All Autopilot lookup strategies failed for '$DisplayName' (deviceId $EntraDeviceId). Set ProceedOnAutopilotLookupFailure = `$true to override." -Level ERROR
        return $false
    }

    if ($ap.Count -eq 0) {
        Write-Log "Autopilot: no windowsAutopilotDeviceIdentities record matched '$DisplayName' (deviceId $EntraDeviceId) -- treating as already-clean." -Level WARN
        return $true
    }

    $allOk = $true
    foreach ($a in $ap) {
        $label = "Autopilot device '$($a.id)' (Serial '$($a.serialNumber)', Manufacturer '$($a.manufacturer)', Model '$($a.model)')"

        # Serial-aware guard: never delete the AP registration of hardware that
        # is actively syncing under another (live) enrollment. The stale Entra
        # object still gets cleaned up by the caller.
        if ($ProtectAutopilotForActiveHardware) {
            $serial = "$($a.serialNumber)".Trim().ToUpperInvariant()
            if ($serial -and (Get-ActiveHardwareSerials).Contains($serial)) {
                $script:_apProtectedCount++
                Write-Log "PROTECTED $label -- serial matches a managed device that synced within $ActiveHardwareWindowDays days. AP record KEPT; stale Entra object deletion proceeds." -Level WARN
                continue
            }
        }

        if ($DryRun) {
            Write-Log "DRY-RUN would DELETE $label for Entra deviceId $EntraDeviceId."
            continue
        }
        try {
            Invoke-MgGraphRequest -Method DELETE -Uri "https://graph.microsoft.com/v1.0/deviceManagement/windowsAutopilotDeviceIdentities/$($a.id)" -ErrorAction Stop | Out-Null
            Write-Log "DELETED $label (Entra deviceId $EntraDeviceId)." -Level ACTION
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

# --- Blob-based device-list override (replaces local -DeviceListCsv).

function Get-DeviceListFromBlob {
    param([Parameter(Mandatory)] [string] $BlobUrl)

    $token = Get-ManagedIdentityToken -Resource 'https://storage.azure.com/'
    $headers = @{
        Authorization  = "Bearer $token"
        'x-ms-version' = '2021-08-06'
    }
    $content = Invoke-RestMethod -Method GET -Uri $BlobUrl -Headers $headers -ErrorAction Stop
    return ,@($content | ConvertFrom-Csv)
}

function Resolve-DevicesFromCsvRows {
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Rows,
        [Parameter(Mandatory)] [string] $SelectFields,
        [Parameter(Mandatory)] [string] $OnDuplicate    # 'Skip' | 'ProcessAll'
    )

    if ($Rows.Count -eq 0) {
        Write-Log 'Device list blob is empty -- nothing to do.' -Level WARN
        return ,@()
    }

    $cols    = $Rows[0].PSObject.Properties.Name
    $hasName = $cols -contains 'DisplayName'
    $hasId   = $cols -contains 'DeviceId'
    if (-not $hasName -and -not $hasId) {
        throw "Device list must have a 'DisplayName' or 'DeviceId' column (found: $($cols -join ', '))."
    }

    $matched = New-Object System.Collections.Generic.List[object]
    $seen    = New-Object System.Collections.Generic.HashSet[string]
    $rowIdx  = 0
    foreach ($r in $Rows) {
        $rowIdx++
        $deviceId    = if ($hasId)   { "$($r.DeviceId)".Trim()    } else { '' }
        $displayName = if ($hasName) { "$($r.DisplayName)".Trim() } else { '' }

        if (-not $deviceId -and -not $displayName) {
            Write-Log "Device list row $rowIdx skipped -- both DisplayName and DeviceId are blank." -Level WARN
            continue
        }

        $hits  = @()
        $label = ''
        try {
            if ($deviceId) {
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
            Write-Log "Device list row $rowIdx ($label) lookup FAILED: $_" -Level WARN
            continue
        }

        if ($hits.Count -eq 0) {
            Write-Log "Device list row $rowIdx ($label) matched 0 Entra devices -- skipping." -Level WARN
            continue
        }

        if ($hits.Count -gt 1 -and $OnDuplicate -eq 'Skip') {
            $ids = ($hits | ForEach-Object { $_.Id }) -join ', '
            Write-Log ("Device list row {0} ({1}) matched {2} Entra devices [{3}]. OnDuplicateMatch='Skip' -- ALL skipped. Disambiguate by DeviceId or set OnDuplicateMatch='ProcessAll'." -f `
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

if ($DeviceListBlobUrl) {
    Write-Log "Loading target devices from blob (age-based staleness query bypassed)..."
    try {
        $csvRows      = Get-DeviceListFromBlob -BlobUrl $DeviceListBlobUrl
        $staleDevices = Resolve-DevicesFromCsvRows -Rows $csvRows -SelectFields $select -OnDuplicate $OnDuplicateMatch
        $totalStale   = @($staleDevices).Count
        Write-Log "Device list resolved $totalStale Entra device(s) for processing."
    }
    catch {
        Write-Log "Failed to resolve device list blob: $_" -Level ERROR
        Disconnect-MgGraph | Out-Null
        throw
    }
}
else {
    try {
        Write-Log 'Querying Graph for candidate stale devices...'
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
        throw
    }
}

if ($OperatingSystemFilterValues.Count -gt 0) {
    $beforeOsFilter = @($staleDevices).Count
    $staleDevices = @($staleDevices | Where-Object {
        Test-OperatingSystemMatch -OperatingSystem "$($_.OperatingSystem)" -AllowedOperatingSystems $OperatingSystemFilterValues
    })
    Write-Log ("Operating-system filter reduced candidates from {0} to {1}." -f $beforeOsFilter, @($staleDevices).Count) -Level WARN
}

$csvDeviceIdSet = $null
if ($DeviceListBlobUrl) {
    $csvDeviceIdSet = New-Object System.Collections.Generic.HashSet[string]
    foreach ($d in $staleDevices) { [void]$csvDeviceIdSet.Add($d.Id) }
}

#endregion

#region Classify and act

$results        = New-Object System.Collections.Generic.List[object]
$autopilotStale = New-Object System.Collections.Generic.List[object]
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

    $effectiveDate = if ($device.ApproximateLastSignInDateTime) {
        $device.ApproximateLastSignInDateTime
    } elseif ($device.RegistrationDateTime) {
        $device.RegistrationDateTime
    } else {
        $null
    }

    if (-not $effectiveDate) {
        if ($isFromCsv) {
            Write-Log "Device list override: processing '$($device.DisplayName)' [$($device.Id)] despite no timestamp."
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

    $targetStage     = if ($ageDays -ge $HardDeleteAfterDays) { 'HardDelete' }
                       elseif ($ageDays -ge $SoftDeleteAfterDays) { 'SoftDelete' }
                       else { 'None' }
    $downgradeReason = $null

    if ($isFromCsv) {
        if ($CsvRespectsAgeThresholds) {
            if ($targetStage -eq 'None') {
                Write-Log "Device list: skipping '$($device.DisplayName)' [$($device.Id)] -- $ageDays days < $SoftDeleteAfterDays day soft cutoff (CsvRespectsAgeThresholds = `$true)." -Level WARN
                continue
            }
        }
        else {
            $targetStage = 'HardDelete'
        }
    }

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
        OwnerName       = $ownerNames
        OwnerUPN        = $ownerUpns
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

    if ($isAutopilot) {
        $apFallThrough = $false
        if ($DeleteAutopilotObjects -and $targetStage -eq 'HardDelete') {
            Write-Log ("DeleteAutopilotObjects ON -- removing Autopilot record for '{0}' [{1}] (ZTDId {2}) before Entra hard delete..." -f `
                $device.DisplayName, $device.Id, $ztdId)
            $apDeleteOk = Remove-AutopilotDevice -EntraDeviceId $device.DeviceId -DisplayName $device.DisplayName -DryRun $DryRun
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
            $autopilotStale.Add($row) | Out-Null
            Write-Log ("PROTECTED Autopilot device '{0}' [{1}] (ZTDId {2}) -- would have been {3}, age {4} days." -f `
                $device.DisplayName, $device.Id, $ztdId, $targetStage, $ageDays) -Level WARN
            continue
        }
    }

    try {
        switch ($targetStage) {

            'HardDelete' {
                $counters.ToDelete++
                $row.Action = 'Backup secrets -> Remove-MgDevice'

                $isWindowsDevice = $device.OperatingSystem -match '^(?i)windows'
                if (-not $BackupBLandLAPs) {
                    Write-Log "Skipping BitLocker/LAPS backup for '$($device.DisplayName)' [$($device.Id)] -- BackupBLandLAPs = `$false." -Level WARN
                    $backupOk = $true
                }
                elseif ($isWindowsDevice) {
                    Write-Log "Backing up BitLocker + LAPS for '$($device.DisplayName)' [$($device.Id)] before hard delete..."
                    $backupOk = Backup-DeviceSecrets -Device $device
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
                    Write-Log "Dry-run: secret backup for '$($device.DisplayName)' [$($device.Id)] failed. In a real run the delete would be aborted." -Level WARN
                }

                if ($DeleteIntuneObjects) {
                    $intuneOk = Remove-IntuneManagedDevice -EntraDeviceId $device.DeviceId -DisplayName $device.DisplayName -DryRun $DryRun
                    if ($intuneOk) {
                        $counters.IntuneDeleted++
                    }
                    else {
                        $counters.IntuneDeleteSkipped++
                        Write-Log "Intune managedDevice cleanup FAILED for '$($device.DisplayName)' [$($device.Id)] -- Entra delete will still proceed." -Level WARN
                    }
                }

                if (-not $DryRun) {
                    Remove-MgDevice -DeviceId $device.Id -ErrorAction Stop
                    $row.Status = 'Deleted'
                    $counters.Deleted++
                    Write-Log "DELETED device '$($device.DisplayName)' [$($device.Id)] -- inactive $ageDays days." -Level ACTION
                }
                else {
                    $row.Status = 'DryRun'
                    $counters.DeleteSkipped++
                    Write-Log "DRY-RUN would DELETE '$($device.DisplayName)' [$($device.Id)] -- inactive $ageDays days."
                }
            }

            'SoftDelete' {
                if ($BackupBLandLAPs -and $PreviewSecretsBackup -and -not $BackupOnlyBeforeHardDelete -and $downgradeReason -and ($device.OperatingSystem -match '^(?i)windows')) {
                    Write-Log "Preview backup: capturing BitLocker + LAPS for '$($device.DisplayName)' [$($device.Id)] (downgraded from HardDelete, age $ageDays days)..."
                    try {
                        Backup-DeviceSecrets -Device $device | Out-Null
                    } catch {
                        Write-Log "Preview backup failed for '$($device.DisplayName)' [$($device.Id)]: $_" -Level WARN
                    }
                }

                if (-not $device.AccountEnabled) {
                    $row.Action = 'None (already disabled)'
                    $row.Status = 'NoOp'
                    Write-Log "No-op: '$($device.DisplayName)' [$($device.Id)] already disabled, age $ageDays days."
                    break
                }

                $counters.ToDisable++
                $row.Action = 'Update-MgDevice (accountEnabled=false)'
                if (-not $DryRun) {
                    Update-MgDevice -DeviceId $device.Id -BodyParameter @{ accountEnabled = $false } -ErrorAction Stop
                    $row.Status = 'Disabled'
                    $counters.Disabled++
                    Write-Log "DISABLED device '$($device.DisplayName)' [$($device.Id)] -- inactive $ageDays days." -Level ACTION
                }
                else {
                    $row.Status = 'DryRun'
                    $counters.DisableSkipped++
                    Write-Log "DRY-RUN would DISABLE '$($device.DisplayName)' [$($device.Id)] -- inactive $ageDays days."
                }
            }

            default {
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

#region Key Vault retention cleanup + summary (rebuilt tail)

if ($BackupBLandLAPs -and $KeyVaultName) {
    Write-Log "Running Key Vault retention cleanup (SecretRetentionDays=$SecretRetentionDays)..."
    Invoke-VaultRetentionCleanup -IsDryRun $DryRun
}

# Per-device results as JSON blocks in the output stream (no secret material).
Write-Log '===== PER-DEVICE RESULTS (JSON) ====='
Write-Output ($results | ConvertTo-Json -Depth 4)

# One [CSVROW] line per device: Log Analytics truncates large stream entries,
# so the JSON block above is unusable for downstream consumers. Small
# per-device lines survive intact; the pretty-email Logic App reassembles
# them into the devices.csv attachment.
$csvQuote = { param($v) '"' + ([string]$v -replace '"', '""') + '"' }
Write-Output ('[CSVROW] ' + (@('DisplayName','DeviceId','OS','TrustType','LastSignInUtc','AgeDays','OwnerUPN','Stage','Action','Status') -join ','))
foreach ($r in $results) {
    $fields = foreach ($p in 'DisplayName','DeviceId','OS','TrustType','LastSignInUtc','AgeDays','OwnerUPN','Stage','Action','Status') { & $csvQuote $r.$p }
    Write-Output ('[CSVROW] ' + ($fields -join ','))
}

if ($autopilotStale.Count -gt 0) {
    Write-Log '===== AUTOPILOT-PROTECTED DEVICES (JSON) -- NOT modified ====='
    Write-Output ($autopilotStale | ConvertTo-Json -Depth 4)
}

Write-Log '===== RUN SUMMARY ====='
foreach ($key in $counters.Keys) {
    Write-Log ("  {0,-24} {1}" -f $key, $counters[$key])
}
Write-Log ("  {0,-24} {1}" -f 'ApRecordsProtectedBySerial', $script:_apProtectedCount)
if ($DryRun) {
    Write-Log 'DryRun was ON -- no changes were made. Re-run with -DryRun:$false (Terraform: enable_apply=true) to act.' -Level WARN
}

Disconnect-MgGraph | Out-Null
Write-Log "Run $runStamp complete."

#endregion
