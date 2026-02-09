<#
.SYNOPSIS
    Setup script for SRE Agent Demo - deploys infrastructure and both app versions
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $true)]
    [string]$AppServiceName,

    [string]$Location = 'westus2',
    [string]$SubscriptionId
)

$ErrorActionPreference = 'Stop'

# ------------------------------------------------------------
# Paths
# ------------------------------------------------------------
$ScriptDir     = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot   = Split-Path -Parent $ScriptDir
$AppPath       = Join-Path $ProjectRoot 'SREPerfDemo'
$InfraPath     = Join-Path $ProjectRoot 'infrastructure'
$ControllerPath = Join-Path $AppPath 'Controllers\ProductsController.cs'

# ------------------------------------------------------------
# Helper functions
# ------------------------------------------------------------
function Write-Step    { Write-Host "`n[STEP] $($args -join ' ')" -ForegroundColor Cyan }
function Write-Success { Write-Host "[OK] $($args -join ' ')" -ForegroundColor Green }
function Write-Info    { Write-Host "[INFO] $($args -join ' ')" -ForegroundColor Gray }
function Write-Warn    { Write-Host "[WARN] $($args -join ' ')" -ForegroundColor Yellow }

# ------------------------------------------------------------
# STEP 0: Select Azure Subscription
# ------------------------------------------------------------
Write-Step 'Checking Azure subscription'

$subscriptions = az account list `
    --query '[].{Name:name, Id:id, IsDefault:isDefault}' `
    --output json | ConvertFrom-Json

if (-not $subscriptions) {
    throw "No Azure subscriptions found. Run 'az login' first."
}

if ($SubscriptionId) {
    $selectedSub = $subscriptions | Where-Object { $_.Id -eq $SubscriptionId }
    if (-not $selectedSub) { throw "Subscription not found" }
} else {
    Write-Host ''
    Write-Host 'Available Azure Subscriptions:' -ForegroundColor White

    for ($i = 0; $i -lt $subscriptions.Count; $i++) {
        $sub = $subscriptions[$i]
        $current = if ($sub.IsDefault) { ' (current)' } else { '' }
        Write-Host " [$($i + 1)] $($sub.Name)$current"
        Write-Host "     $($sub.Id)" -ForegroundColor DarkGray
    }

    $selection = Read-Host "Select subscription (1-$($subscriptions.Count)) or press Enter"
    if ($selection) {
        $selectedSub = $subscriptions[[int]$selection - 1]
    } else {
        $selectedSub = $subscriptions | Where-Object IsDefault | Select-Object -First 1
    }
}

az account set --subscription $selectedSub.Id
Write-Success "Using subscription $($selectedSub.Name)"

# ------------------------------------------------------------
# STEP 1: Resource Group
# ------------------------------------------------------------
Write-Step "Creating resource group $ResourceGroupName"

az group create `
    --name $ResourceGroupName `
    --location $Location `
    --output none

Write-Success 'Resource group ready'

# ------------------------------------------------------------
# STEP 2: Infrastructure
# ------------------------------------------------------------
Write-Step 'Deploying infrastructure'

$bicepFile = Join-Path $InfraPath 'main.bicep'

$deploymentOutput = az deployment group create `
    --resource-group $ResourceGroupName `
    --template-file $bicepFile `
    --parameters appServiceName=$AppServiceName `
    --query 'properties.outputs' `
    --output json | ConvertFrom-Json

$prodUrl     = $deploymentOutput.appServiceUrl.value
$stagingUrl  = $deploymentOutput.stagingUrl.value
$appInsights = $deploymentOutput.applicationInsightsName.value

Write-Success 'Infrastructure deployed'
Write-Info "Production URL: $prodUrl"
Write-Info "Staging URL:    $stagingUrl"

# ------------------------------------------------------------
# STEP 3: GOOD → Production
# ------------------------------------------------------------
Write-Step 'Deploying GOOD version to production'

Push-Location $AppPath
try {
    (Get-Content $ControllerPath -Raw) `
        -replace 'EnableSlowEndpoints = true', 'EnableSlowEndpoints = false' |
        Set-Content $ControllerPath

    dotnet publish -c Release -o publish-good --nologo
    Compress-Archive publish-good/* good.zip -Force

    az webapp deploy `
        --resource-group $ResourceGroupName `
        --name $AppServiceName `
        --src-path good.zip `
        --type zip `
        --output none

    Write-Success 'GOOD version deployed'
}
finally { Pop-Location }

# ------------------------------------------------------------
# STEP 4: BAD → Staging
# ------------------------------------------------------------
Write-Step 'Deploying BAD version to staging'

Push-Location $AppPath
try {
    (Get-Content $ControllerPath -Raw) `
        -replace 'EnableSlowEndpoints = false', 'EnableSlowEndpoints = true' |
        Set-Content $ControllerPath

    dotnet publish -c Release -o publish-bad --nologo
    Compress-Archive publish-bad/* bad.zip -Force

    az webapp deploy `
        --resource-group $ResourceGroupName `
        --name $AppServiceName `
        --slot staging `
        --src-path bad.zip `
        --type zip `
        --output none

    Write-Success 'BAD version deployed'
}
finally {
    (Get-Content $ControllerPath -Raw) `
        -replace 'EnableSlowEndpoints = true', 'EnableSlowEndpoints = false' |
        Set-Content $ControllerPath
    Pop-Location
}

# ------------------------------------------------------------
# STEP 5: Verify
# ------------------------------------------------------------
Write-Step 'Waiting for apps to start (30 seconds)'
Start-Sleep 30

Write-Step 'Health checks'

try {
    Invoke-RestMethod "$prodUrl/health" -TimeoutSec 20 | Out-Null
    Write-Success 'Production healthy'
} catch { Write-Warn 'Production health check failed' }

try {
    Invoke-RestMethod "$stagingUrl/health" -TimeoutSec 20 | Out-Null
    Write-Success 'Staging healthy'
} catch { Write-Warn 'Staging health check failed' }

# ------------------------------------------------------------
# STEP 6: Save config
# ------------------------------------------------------------
$config = @{
    ResourceGroup = $ResourceGroupName
    AppService    = $AppServiceName
    ProductionUrl = $prodUrl
    StagingUrl    = $stagingUrl
    AppInsights   = $appInsights
    SetupTime     = (Get-Date)
}

$config | ConvertTo-Json | Set-Content (Join-Path $ProjectRoot 'demo-config.json')

# ------------------------------------------------------------
# DONE
# ------------------------------------------------------------
Write-Host ''
Write-Host '==================================================' -ForegroundColor Green
Write-Host ' SETUP COMPLETE ' -ForegroundColor Green
Write-Host '==================================================' -ForegroundColor Green
Write-Host " Production (GOOD): $prodUrl"
Write-Host " Staging (BAD):     $stagingUrl"
Write-Host ''
Write-Host 'Next: Run .\2-run-demo.ps1' -ForegroundColor Yellow
Write-Host ''
