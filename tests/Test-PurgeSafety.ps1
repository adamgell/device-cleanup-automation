$ErrorActionPreference='Stop'
$AuthMode='ManagedIdentity';$TenantId='';$ClientId='';$CertificateThumbprint='';$ClientSecret=$null;$UseDeviceAuthentication=$false
$path=Join-Path $PSScriptRoot '../runbook/Invoke-StaleDeviceCleanup.ps1'
$source=Get-Content $path -Raw
$t=$null;$e=$null;$ast=[System.Management.Automation.Language.Parser]::ParseInput($source,[ref]$t,[ref]$e)
if($e.Count){throw 'Syntax errors'}
foreach($node in $ast.FindAll({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst]},$false)){. ([scriptblock]::Create($node.Extent.Text))}
$script:CleanupLog=[System.Collections.Generic.List[string]]::new()
function Assert($condition,$message){if(-not $condition){throw $message}}
function Invoke-MgGraphRequest {throw 'Injected Graph failure'}
$script:_activeSerialCache=$null;$ActiveHardwareWindowDays=30
$threw=$false;try{Get-ActiveHardwareSerials | Out-Null}catch{$threw=$true}
Assert $threw 'Incomplete serial enumeration must throw'
Assert ($null -eq $script:_activeSerialCache) 'Failed enumeration must not cache partial data'
$device=[pscustomobject]@{Id='00000000-0000-0000-0000-000000000001';DeviceId='00000000-0000-0000-0000-000000000002';DisplayName='TEST-RETIRED';OperatingSystem='Windows';OperatingSystemVersion='11';ApproximateLastSignInDateTime=[datetime]::UtcNow.AddDays(-200);RegistrationDateTime=[datetime]::UtcNow.AddDays(-300);AccountEnabled=$false;TrustType='AzureAd';PhysicalIds=@('[ZTDId]:test')}
function Get-DeviceBitlockerKeys {return @()}
function Get-DeviceLapsCredentials {return @()}
$DryRun=$true
$ok=Backup-DeviceSecrets -Device $device
Assert ($ok -is [bool] -and -not $ok) 'No recovery material must be a scalar false'
function Get-DeviceBitlockerKeys {Write-Log 'Metadata only';return [pscustomobject]@{RecoveryKey='';KeyId='test'}}
$ok=Backup-DeviceSecrets -Device $device
Assert ($ok -is [bool] -and -not $ok) 'Empty recovery key must fail despite logs'
function Get-DeviceBitlockerKeys {return [pscustomobject]@{RecoveryKey='test-only-value';KeyId='test';VolumeType='operatingSystem';CreatedUtc='2026-01-01'}}
$script:VaultWrites=0
function Set-DeviceSecretInVault {$script:VaultWrites++;return $false}
$ok=Backup-DeviceSecrets -Device $device
Assert ($ok -is [bool] -and $ok -and $script:VaultWrites -eq 0) 'DryRun must not write vault'
$DryRun=$false
$ok=Backup-DeviceSecrets -Device $device
Assert ($ok -is [bool] -and -not $ok) 'Vault verification failure must return scalar false'
$script:CleanupManagedDevices=@([pscustomobject]@{azureADDeviceId=$device.DeviceId;operatingSystem='Windows';lastSyncDateTime=[datetime]::UtcNow;serialNumber='TEST-SERIAL'})
$script:CleanupManagedDevices += [pscustomobject]@{azureADDeviceId='unrelated';operatingSystem='Windows';lastSyncDateTime=[datetime]::UtcNow.AddDays(-200);serialNumber='OTHER'}
Assert (@(Get-CleanupManagedDevices | Where-Object { $_.azureADDeviceId -eq $device.DeviceId }).Count -eq 1) 'Inventory must stream individual records'
$script:_apEnumerationCache=@();$HardDeleteAfterDays=120
Assert ([bool](Get-DeviceSafetyHold -Device $device)) 'Recent Intune activity must hold'
$script:CleanupManagedDevices=@([pscustomobject]@{azureADDeviceId='different';operatingSystem='Windows';lastSyncDateTime=[datetime]::UtcNow;serialNumber='TEST-SERIAL'})
$script:_apEnumerationCache=@([pscustomobject]@{azureActiveDirectoryDeviceId=$device.DeviceId;serialNumber='TEST-SERIAL'})
Assert ([bool](Get-DeviceSafetyHold -Device $device)) 'Active same serial must hold'
$script:_apEnumerationCache=@([pscustomobject]@{azureActiveDirectoryDeviceId=$device.DeviceId;serialNumber=''})
Assert ([bool](Get-DeviceSafetyHold -Device $device)) 'Missing AP serial must hold'
$ExcludedDeviceNamePattern='^HELD-';$device.DisplayName='HELD-TEST'
Assert ((Get-DeviceSafetyHold -Device $device) -eq 'Configured asset hold') 'Configured asset hold must survive'
$device.DisplayName='TEST-RETIRED'
function Get-DeviceSafetyHold {return ''}
function Get-DeviceRegisteredOwners {return @()}
function Backup-DeviceSecrets {Write-Log 'Backup';$script:Calls.Add('backup');return $script:BackupPass}
function Remove-IntuneManagedDevice {Write-Log 'Intune';$script:Calls.Add('intune');return $script:IntunePass}
function Remove-AutopilotDevice {Write-Log 'Autopilot';$script:Calls.Add('autopilot');return $script:ApPass}
function Remove-MgDevice {$script:Calls.Add('entra')}
$start=$source.IndexOf('$results        =')
$end=$source.IndexOf('#endregion',$start)
$classify=[scriptblock]::Create($source.Substring($start,$end-$start))
$HybridDeviceHandling='Process';$ExcludedDeviceNamePattern='';$SoftDeleteAfterDays=90;$HardDeleteAfterDays=120;$DisableOnly=$false;$RequireDisabledBeforeDelete=$false
$BackupBLandLAPs=$true;$DeleteIntuneObjects=$true;$DeleteAutopilotObjects=$true;$PurgeOnly=$true;$MaxLiveActions=5;$csvDeviceIdSet=$null
foreach($case in 'backup-fail','intune-fail','ap-fail','success','limit'){
 $script:Calls=[System.Collections.Generic.List[string]]::new()
 $script:BackupPass=$case -ne 'backup-fail';$script:IntunePass=$case -ne 'intune-fail';$script:ApPass=$case -ne 'ap-fail'
 $script:LiveActions=if($case -eq 'limit'){5}else{0};$staleDevices=@($device)
 . $classify
 $expected=switch($case){'backup-fail'{'backup'}'intune-fail'{'backup,intune'}'ap-fail'{'backup,intune,autopilot'}'success'{'backup,intune,autopilot,entra'}'limit'{''}}
 Assert (($script:Calls -join ',') -eq $expected) "Incorrect mutation ordering in $case"
 Assert ($results.Count -eq 1) 'One result required'
}
$HybridDeviceHandling='ReportOnly';$device.TrustType='ServerAd';$script:Calls.Clear();$staleDevices=@($device);$script:LiveActions=0
. $classify
Assert ($results[0].Status -eq 'OnPremRemediationRequired' -and $script:Calls.Count -eq 0) 'Hybrid ReportOnly must suppress all device actions'
$device.TrustType='AzureAd'
# Exercise live preflight without module imports, authentication or network calls.
$preStart=$source.IndexOf('if ($HardDeleteAfterDays -lt')
$preEnd=$source.IndexOf('$requiredModules =',$preStart)
$preflight=[scriptblock]::Create($source.Substring($preStart,$preEnd-$preStart))
function Test-LivePreflight($os,$ids,$backup,$bypass) {
 $DryRun=$false;$OperatingSystemFilter=$os;$ApprovedDeviceObjectIds=$ids
 $BackupBLandLAPs=$backup;$ProtectAutopilotForActiveHardware=$true;$ProceedOnAutopilotLookupFailure=$bypass
 $SoftDeleteAfterDays=90;$HardDeleteAfterDays=120;$OnDuplicateMatch='Skip';$KeyVaultName='test-vault';$SecretRetentionDays=4;$MaxLiveActions=5;$ExcludedDeviceNamePattern=''
 try { . $preflight; return $true } catch { return $false }
}
Assert (-not (Test-LivePreflight 'Windows' '' $true $false)) 'Live mode must require explicit cohort'
Assert (-not (Test-LivePreflight 'Android' $device.Id $true $false)) 'Live mode must require Windows'
Assert (-not (Test-LivePreflight 'Windows' $device.Id $false $false)) 'Live mode must require backup'
Assert (-not (Test-LivePreflight 'Windows' $device.Id $true $true)) 'Live lookup bypass must be rejected'
Assert (Test-LivePreflight 'Windows' $device.Id $true $false) 'Valid scoped live preflight must pass'
# Verify versioned Key Vault read-back rejects a mismatch using the actual helper.
$node=$ast.FindAll({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Set-DeviceSecretInVault'},$false)[0]
. ([scriptblock]::Create($node.Extent.Text))
function Get-KeyVaultAuthHeader {return @{}}
function Invoke-RestMethod {param($Method,$Uri,$Headers,$Body,$ContentType,$ErrorAction);if($Method -eq 'PUT'){return @{id='https://test.vault.azure.net/secrets/test/version'}};return @{value='mismatch'}}
$KeyVaultName='test';$SecretNamePrefix='test';$SecretRetentionDays=4;$runStamp='test'
$threw=$false;try{Set-DeviceSecretInVault -Device $device -BitlockerKeys @() -LapsCredentials @() | Out-Null}catch{$threw=$true}
Assert $threw 'Read-back mismatch must fail'
'PASS: failure output, serial enumeration, empty secrets, DryRun vault isolation, active hardware, held assets, batch limits, deletion order, and vault read-back.'
