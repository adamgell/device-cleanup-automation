<#
.SYNOPSIS
    Pre-flight check (and optional fix) for a device-cleanup Terraform deployment.

.DESCRIPTION
    Reads a deployment tfvars file and verifies everything the apply will need:

      1. az CLI present, logged in, and able to see the target subscription.
      2. Required resource providers registered on the subscription — the set
         adapts to which features the tfvars enables:
           always:                Microsoft.Automation, Microsoft.KeyVault
           alerting_enabled:      Microsoft.Insights, Microsoft.OperationalInsights
           pretty_email_enabled:  Microsoft.Communication, Microsoft.Logic
         -Register registers any that are missing (and waits for completion).
      3. Target resource group exists (the module reads it, it does not create it).
      4. Deployer RBAC on the RG: Owner, or Contributor + User Access Administrator
         (or Role Based Access Control Administrator) — the apply creates role
         assignments (Key Vault Secrets Officer; plus Log Analytics Reader and
         ACS Contributor when the optional features are on).
      5. Deployer directory role: Global Administrator or Privileged Role
         Administrator — required for the six Graph app-role grants to the
         managed identity.
      6. terraform binary present (>= 1.5).

    Read-only except when -Register is passed (which only registers providers).

.PARAMETER TfvarsPath
    Path to the deployment tfvars (e.g. terraform/deployments/contoso-dev.tfvars).

.PARAMETER Register
    Register any missing resource providers and wait for them to finish.

.EXAMPLE
    ./scripts/Test-DeploymentPrereqs.ps1 -TfvarsPath terraform/deployments/contoso-dev.tfvars

.EXAMPLE
    ./scripts/Test-DeploymentPrereqs.ps1 -TfvarsPath terraform/deployments/contoso-dev.tfvars -Register
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $TfvarsPath,
    [switch] $Register
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$script:Results = [System.Collections.Generic.List[object]]::new()
function Add-Check {
    param(
        [Parameter(Mandatory)] [string] $Check,
        [Parameter(Mandatory)] [ValidateSet('Pass', 'Fail', 'Warn', 'Fixed')] [string] $Status,
        [string] $Detail = ''
    )
    $script:Results.Add([pscustomobject]@{ Check = $Check; Status = $Status; Detail = $Detail })
    $color = @{ Pass = 'Green'; Fixed = 'Green'; Warn = 'Yellow'; Fail = 'Red' }[$Status]
    Write-Host ("[{0,-5}] {1}{2}" -f $Status.ToUpper(), $Check, ($Detail ? " -- $Detail" : '')) -ForegroundColor $color
}

# --- 0. Parse tfvars ---------------------------------------------------------
if (-not (Test-Path -Path $TfvarsPath)) { throw "tfvars not found: $TfvarsPath" }
$tf = Get-Content -Path $TfvarsPath -Raw

function Get-TfString { param($Name) if ($tf -match "(?m)^\s*$Name\s*=\s*`"([^`"]*)`"") { $Matches[1] } else { $null } }
function Get-TfBool   { param($Name) if ($tf -match "(?m)^\s*$Name\s*=\s*(true|false)") { $Matches[1] -eq 'true' } else { $false } }

$subscriptionId    = Get-TfString 'subscription_id'
$resourceGroupName = Get-TfString 'resource_group_name'
$alertingEnabled   = Get-TfBool   'alerting_enabled'
$prettyEnabled     = Get-TfBool   'pretty_email_enabled'

if (-not $subscriptionId -or -not $resourceGroupName) {
    throw "Could not parse subscription_id / resource_group_name from $TfvarsPath."
}
Write-Host "Deployment: sub=$subscriptionId  rg=$resourceGroupName  alerting=$alertingEnabled  prettyEmail=$prettyEnabled`n"

# --- 1. az CLI + login + subscription ---------------------------------------
if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    Add-Check 'az CLI installed' Fail 'az not found on PATH'
    $script:Results | Format-Table -AutoSize; exit 1
}
Add-Check 'az CLI installed' Pass

$account = az account show --only-show-errors 2>$null | ConvertFrom-Json
if (-not $account) {
    Add-Check 'az login session' Fail "not logged in -- run: az login --tenant <customer-tenant>"
    $script:Results | Format-Table -AutoSize; exit 1
}

$subs = az account list --only-show-errors --query "[].id" -o tsv 2>$null
if ($subs -notcontains $subscriptionId) {
    Add-Check 'target subscription visible' Fail "signed-in account ($($account.user.name)) cannot see $subscriptionId -- wrong tenant? run: az login --tenant <customer-tenant>"
    $script:Results | Format-Table -AutoSize; exit 1
}
if ($account.id -ne $subscriptionId) {
    az account set --subscription $subscriptionId --only-show-errors
    $account = az account show --only-show-errors | ConvertFrom-Json
}
Add-Check 'az login session' Pass "$($account.user.name) on subscription '$($account.name)' (tenant $($account.tenantId))"

# --- 2. Resource providers ---------------------------------------------------
$providers = @('Microsoft.Automation', 'Microsoft.KeyVault')
if ($alertingEnabled) { $providers += @('Microsoft.Insights', 'Microsoft.OperationalInsights') }
if ($prettyEnabled)   { $providers += @('Microsoft.Communication', 'Microsoft.Logic') }

foreach ($p in $providers) {
    $state = az provider show --namespace $p --query registrationState -o tsv --only-show-errors 2>$null
    if ($state -eq 'Registered') {
        Add-Check "provider $p" Pass
        continue
    }
    if (-not $Register) {
        Add-Check "provider $p" Fail "state=$($state ?? 'Unknown') -- fix: az provider register --namespace $p (or rerun with -Register)"
        continue
    }
    az provider register --namespace $p --only-show-errors | Out-Null
    $deadline = (Get-Date).AddMinutes(10)
    do {
        Start-Sleep -Seconds 15
        $state = az provider show --namespace $p --query registrationState -o tsv --only-show-errors
    } while ($state -ne 'Registered' -and (Get-Date) -lt $deadline)
    if ($state -eq 'Registered') { Add-Check "provider $p" Fixed 'registered' }
    else { Add-Check "provider $p" Fail "still $state after 10 min" }
}

# --- 3. Resource group -------------------------------------------------------
$rg = az group show --name $resourceGroupName --only-show-errors 2>$null | ConvertFrom-Json
if ($rg) {
    Add-Check "resource group $resourceGroupName" Pass "location=$($rg.location)"
} else {
    Add-Check "resource group $resourceGroupName" Fail "does not exist -- the module reads it, it does not create it. fix: az group create --name $resourceGroupName --location <region>"
}

# --- 4. RBAC on the RG -------------------------------------------------------
if ($rg) {
    $upn = $account.user.name
    $roles = @(az role assignment list --assignee $upn --scope $rg.id --include-inherited --include-groups --query "[].roleDefinitionName" -o tsv --only-show-errors 2>$null)
    $isOwner   = $roles -contains 'Owner'
    $canDeploy = $isOwner -or (($roles -contains 'Contributor') -and (($roles -contains 'User Access Administrator') -or ($roles -contains 'Role Based Access Control Administrator')))
    if ($canDeploy) {
        Add-Check 'RBAC: can deploy + assign roles' Pass ($roles -join ', ')
    } else {
        Add-Check 'RBAC: can deploy + assign roles' Fail "have [$($roles -join ', ')] -- need Owner, or Contributor + User Access Administrator, on $($rg.id)"
    }
}

# --- 5. Directory role for Graph app-role grants -----------------------------
# Global Administrator: 62e90394-69f5-4237-9190-012177145e10
# Privileged Role Administrator: e8611ab8-c189-46e8-94e1-60213ab1f814
try {
    $dirRoles = az rest --method GET --url 'https://graph.microsoft.com/v1.0/me/transitiveMemberOf/microsoft.graph.directoryRole?$select=displayName,roleTemplateId' --only-show-errors 2>$null | ConvertFrom-Json
    $templates = @($dirRoles.value | ForEach-Object { $_.roleTemplateId })
    if ($templates -contains '62e90394-69f5-4237-9190-012177145e10' -or $templates -contains 'e8611ab8-c189-46e8-94e1-60213ab1f814') {
        Add-Check 'directory role for Graph app-role grants' Pass (($dirRoles.value | ForEach-Object { $_.displayName }) -join ', ')
    } else {
        Add-Check 'directory role for Graph app-role grants' Fail "active roles [$(($dirRoles.value | ForEach-Object { $_.displayName }) -join ', ')] -- need Global Administrator or Privileged Role Administrator (activate via PIM if eligible)"
    }
}
catch {
    Add-Check 'directory role for Graph app-role grants' Warn "could not query Graph ($_). If the apply fails on azuread_app_role_assignment, activate GA/PRA and retry."
}

# --- 6. terraform ------------------------------------------------------------
$tfCmd = Get-Command terraform -ErrorAction SilentlyContinue
if ($tfCmd) {
    $ver = (terraform version -json | ConvertFrom-Json).terraform_version
    if ([version]$ver -ge [version]'1.5.0') { Add-Check 'terraform >= 1.5' Pass "v$ver" }
    else { Add-Check 'terraform >= 1.5' Fail "v$ver" }
} else {
    Add-Check 'terraform >= 1.5' Fail 'terraform not found on PATH'
}

# --- Summary ------------------------------------------------------------------
Write-Host ''
$script:Results | Format-Table -AutoSize
$failed = @($script:Results | Where-Object Status -eq 'Fail')
if ($failed.Count -gt 0) {
    Write-Host "$($failed.Count) check(s) failed -- fix the above before terraform apply." -ForegroundColor Red
    exit 1
}
Write-Host 'All prerequisites satisfied. Remember: one terraform workspace per tfvars file.' -ForegroundColor Green
exit 0
