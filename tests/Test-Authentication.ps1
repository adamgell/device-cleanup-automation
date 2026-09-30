$ErrorActionPreference = 'Stop'
$path = Join-Path $PSScriptRoot '../runbook/Invoke-StaleDeviceCleanup.ps1'
$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors -join "`n") }
foreach ($node in $ast.FindAll({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst]}, $false)) {
    . ([scriptblock]::Create($node.Extent.Text))
}
function Assert($value, $message) { if (-not $value) { throw $message } }
function Connect-MgGraph { $script:GraphArgs = $args }
function Connect-AzAccount { $script:AzureArgs = $args; return @{ Context = @{ Account = @{ Id = 'user@example.test' } } } }
function Get-MgContext { return @{ Account = 'user@example.test' } }
function Disable-AzContextAutosave {}
function Get-AzAccessToken { return @{ Token = (ConvertTo-SecureString 'test-token' -AsPlainText -Force) } }
function Get-ManagedIdentityToken { return 'identity-token' }
$TenantId = ''; $ClientId = ''; $CertificateThumbprint = ''; $ClientSecret = $null; $UseDeviceAuthentication = $false
$AuthMode = 'ManagedIdentity'; $script:UseAzureDataPlane = $true; $script:AzureArgs = $null
Connect-CleanupServices
Assert ($script:GraphArgs -contains '-Identity:') 'Managed identity Graph route missing'
Assert ($null -eq $script:AzureArgs) 'Managed identity must not connect through Az.Accounts'
Assert ((Get-CleanupResourceToken 'https://vault.azure.net') -eq 'identity-token') 'Managed identity token routing failed'
$AuthMode = 'Delegated'; $TenantId = 'test-tenant'; $UseDeviceAuthentication = $true
Connect-CleanupServices
Assert ($script:GraphArgs -contains '-Scopes:') 'Delegated scopes missing'
Assert ($script:GraphArgs -contains '-UseDeviceAuthentication:') 'Graph device code missing'
Assert ($script:AzureArgs -contains '-UseDeviceAuthentication:') 'Azure device code missing'
Assert ((Get-CleanupResourceToken 'https://vault.azure.net') -eq 'test-token') 'SecureString token conversion failed'
$AuthMode = 'AppRegistration'; $ClientId = 'test-client'; $UseDeviceAuthentication = $false; $CertificateThumbprint = 'test-thumbprint'
Connect-CleanupServices
Assert ($script:GraphArgs -contains '-CertificateThumbprint:') 'Graph certificate missing'
Assert ($script:AzureArgs -contains '-ServicePrincipal:') 'Azure service principal missing'
$CertificateThumbprint = ''; $ClientSecret = ConvertTo-SecureString 'test-secret' -AsPlainText -Force
Connect-CleanupServices
Assert ($script:GraphArgs -contains '-ClientSecretCredential:') 'Graph credential missing'
Assert ($script:AzureArgs -contains '-Credential:') 'Azure credential missing'
$CertificateThumbprint = 'conflict'
$failed = $false; try { Connect-CleanupServices } catch { $failed = $true }
Assert $failed 'Conflicting credentials must fail'
$CertificateThumbprint = ''; $ClientSecret = $null
$failed = $false; try { Connect-CleanupServices } catch { $failed = $true }
Assert $failed 'Missing app credential must fail'
$AuthMode = 'Delegated'; $TenantId = ''
$failed = $false; try { Connect-CleanupServices } catch { $failed = $true }
Assert $failed 'Missing tenant must fail'
$TenantId = 'test-tenant'; $script:UseAzureDataPlane = $false; $script:AzureArgs = $null
Connect-CleanupServices
Assert ($null -eq $script:AzureArgs) 'Graph-only preview must not require Azure sign-in'
$script:UseAzureDataPlane = $true
function Get-MgContext { return @{ Account = 'different@example.test' } }
$failed = $false; try { Connect-CleanupServices } catch { $failed = $true }
Assert $failed 'Different Graph and Azure users must fail before cleanup'
function Get-AzAccessToken { return @{ Token = 'legacy-token' } }
Assert ((Get-CleanupResourceToken 'https://storage.azure.com/') -eq 'legacy-token') 'Legacy string token support failed'
Write-Output 'Authentication tests passed (offline mocks).'

