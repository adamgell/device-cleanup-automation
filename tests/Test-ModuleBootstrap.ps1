$ErrorActionPreference = 'Stop'
$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $PSScriptRoot '../runbook/Invoke-StaleDeviceCleanup.ps1'), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors -join "`n") }
$node = $ast.Find({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Initialize-CleanupModules'}, $false)
. ([scriptblock]::Create($node.Extent.Text))
function Assert($value, $message) { if (-not $value) { throw $message } }
function Write-Log { param($Message) }
$script:Calls = [System.Collections.Generic.List[string]]::new()
function Get-Module { param($Name, [switch]$ListAvailable); if ($Name -eq 'Installed') { return @{ Name = $Name } } }
function Install-Module {
    param($Name, $Repository, $Scope, [switch]$Force, [switch]$AllowClobber, $ErrorAction)
    Assert ($Repository -eq 'PSGallery' -and $Scope -eq 'CurrentUser') 'Installation must use PSGallery and CurrentUser'
    Assert ($Force -and $AllowClobber -and $ErrorAction -eq 'Stop') 'Installation flags missing'
    $script:Calls.Add("install:$Name")
    if ($Name -eq 'Unavailable') { throw 'Simulated download failure' }
}
function Import-Module { param($Name, $ErrorAction); $script:Calls.Add("import:$Name"); if ($Name -eq 'Broken') { throw 'Simulated import failure' } }
Initialize-CleanupModules -Names @('Installed', 'Missing')
Assert (($script:Calls -join ',') -eq 'import:Installed,install:Missing,import:Missing') 'Reuse existing modules and install missing modules before importing'
$script:Calls.Clear()
$failure = $null
try { Initialize-CleanupModules -Names @('Unavailable', 'Later') } catch { $failure = $_ }
Assert ($failure -and $failure.Exception.Message -like '*Unavailable*Simulated download failure*') 'Install failure must name module and preserve cause'
Assert (($script:Calls -join ',') -eq 'install:Unavailable') 'Failed installation must stop before import or later modules'
$script:Calls.Clear()
$failure = $null
try { Initialize-CleanupModules -Names @('Broken', 'Later') } catch { $failure = $_ }
Assert ([bool]$failure) 'Import errors must stop initialization'
Assert (($script:Calls -join ',') -eq 'install:Broken,import:Broken') 'Failed import must stop before later modules'
Write-Output 'PASS: module reuse, installation scope, install-before-import ordering, and failure handling (offline mocks).'
# Graph submodules must use the Authentication module's selected release.
$script:Calls.Clear()
function Get-Module {
    param($Name, [switch]$ListAvailable)
    if ($ListAvailable -and $Name -eq 'Microsoft.Graph.Authentication') { return [pscustomobject]@{Name=$Name;Version=[version]'2.41.0'} }
    if ($ListAvailable -and $Name -eq 'Microsoft.Graph.Identity.DirectoryManagement') { return [pscustomobject]@{Name=$Name;Version=[version]'2.40.0'} }
}
function Install-Module {
    param($Name, $RequiredVersion, $Repository, $Scope, [switch]$Force, [switch]$AllowClobber, $ErrorAction)
    Assert ($RequiredVersion -eq '2.41.0') 'Missing Graph submodule must install the selected Authentication version'
    $script:Calls.Add("install:$Name")
}
function Import-Module {
    param($Name, $RequiredVersion, $ErrorAction, $ErrorVariable)
    Assert ($RequiredVersion -eq '2.41.0') 'Graph imports must pin a consistent release'
    $script:Calls.Add("import:$Name")
}
Initialize-CleanupModules -Names @('Microsoft.Graph.Authentication', 'Microsoft.Graph.Identity.DirectoryManagement')
Assert (($script:Calls -join ',') -eq 'import:Microsoft.Graph.Authentication,install:Microsoft.Graph.Identity.DirectoryManagement,import:Microsoft.Graph.Identity.DirectoryManagement') 'Mismatched installed Graph version must be repaired'
Write-Output 'PASS: consistent Graph version selection.'
$script:Calls.Clear()
function Get-Module {
    param($Name, [switch]$ListAvailable)
    if (-not $ListAvailable) {
        return @([pscustomobject]@{Version=[version]'2.40.0'}, [pscustomobject]@{Version=[version]'2.41.0'})
    }
}
$failure = $null
try { Initialize-CleanupModules -Names @('Microsoft.Graph.Authentication') } catch { $failure = $_ }
Assert ($failure -and $failure.Exception.Message -like '*fresh pwsh*') 'Loaded version conflicts must require a fresh process'
Assert ($script:Calls.Count -eq 0) 'Conflicting session must stop before install/import'
function Get-Module { param($Name, [switch]$ListAvailable); return @{Name=$Name} }
function Import-Module {
    param($Name, $ErrorAction, $ErrorVariable)
    Set-Variable -Name importErrors -Scope 1 -Value @('Simulated startup error despite successful return')
}
$failure = $null
try { Initialize-CleanupModules -Names @('StartupFailure') } catch { $failure = $_ }
Assert ($failure -and $failure.Exception.Message -like '*Simulated startup error*') 'Startup errors must fail even when import returns normally'
Write-Output 'PASS: loaded-version conflicts and startup errors stop initialization.'
