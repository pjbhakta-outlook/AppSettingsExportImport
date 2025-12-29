# Export-AppServiceApps.ps1
# Exports all App Service apps with their settings to a CSV file for migration planning.
# The CSV includes columns for target configuration that users can edit before importing.

[CmdletBinding(PositionalBinding=$false)]
param(
    [string]$TenantId,
    [string]$SubscriptionId,
    [string]$OutputFile,
    [Parameter(ValueFromRemainingArguments=$true)]
    [string[]]$RemainingArgs
)

# Parse CLI-style arguments
$cliArgs = $RemainingArgs
if (-not $cliArgs -and $args) { $cliArgs = $args }

if ($cliArgs) {
    for ($i = 0; $i -lt $cliArgs.Count; $i++) {
        switch ($cliArgs[$i]) {
            '--tenant' { if ($i + 1 -lt $cliArgs.Count) { $TenantId = $cliArgs[$i + 1] } }
            '--subscription' { if ($i + 1 -lt $cliArgs.Count) { $SubscriptionId = $cliArgs[$i + 1] } }
            '--output' { if ($i + 1 -lt $cliArgs.Count) { $OutputFile = $cliArgs[$i + 1] } }
        }
    }
}

function Show-Usage {
    Write-Host ""
    Write-Host "Export-AppServiceApps.ps1" -ForegroundColor Cyan
    Write-Host "=========================" -ForegroundColor Cyan
    Write-Host "Exports App Service apps to a CSV file for migration planning."
    Write-Host ""
    Write-Host "Usage:" -ForegroundColor Yellow
    Write-Host "  .\Export-AppServiceApps.ps1 --tenant <tenantId> [--subscription <subscriptionId>] [--output <file>]"
    Write-Host ""
    Write-Host "Parameters:" -ForegroundColor Yellow
    Write-Host "  --tenant        : (Required) Azure Tenant ID" -ForegroundColor Gray
    Write-Host "  --subscription  : (Optional) Specific subscription ID. If omitted, scans all subscriptions." -ForegroundColor Gray
    Write-Host "  --output        : (Optional) Output CSV file path. Default: scans/AppMigration-<timestamp>.csv" -ForegroundColor Gray
    Write-Host ""
    Write-Host "Output CSV Columns:" -ForegroundColor Yellow
    Write-Host "  SOURCE (Reference - Do Not Edit):" -ForegroundColor Gray
    Write-Host "    - SourceSubscriptionId, SourceSubscriptionName, SourceAppName" -ForegroundColor Gray
    Write-Host "    - SourceResourceGroup, SourceAppServicePlan, SourceLocation, SourceSku" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  TARGET (Edit These for Migration):" -ForegroundColor Gray
    Write-Host "    - TargetSubscriptionId  : Subscription for new app" -ForegroundColor Gray
    Write-Host "    - TargetResourceGroup   : Resource group for new app" -ForegroundColor Gray
    Write-Host "    - TargetAppServicePlan  : App Service Plan for new app" -ForegroundColor Gray
    Write-Host "    - TargetLocation        : Azure region for new app" -ForegroundColor Gray
    Write-Host "    - TargetSku             : SKU for new plan (if creating)" -ForegroundColor Gray
    Write-Host "    - NewAppName            : Name for the new app" -ForegroundColor Gray
    Write-Host "    - Skip                  : Set to 'Yes' to skip this app" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  STATUS (Updated by Import Script):" -ForegroundColor Gray
    Write-Host "    - ImportStatus          : Pending/Success/Failed/Skipped" -ForegroundColor Gray
    Write-Host "    - ImportMessage         : Details or error message" -ForegroundColor Gray
    Write-Host "    - ImportTimestamp       : When the import was attempted" -ForegroundColor Gray
    Write-Host ""
    Write-Host "Example:" -ForegroundColor Yellow
    Write-Host "  .\Export-AppServiceApps.ps1 --tenant 12345-abcde --subscription 67890-fghij"
    Write-Host ""
}

if (-not $TenantId) {
    Show-Usage
    exit 1
}

$ErrorActionPreference = 'Stop'

Write-Host ""
Write-Host "Export-AppServiceApps" -ForegroundColor Cyan
Write-Host "=====================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Tenant: $TenantId" -ForegroundColor Gray
if ($SubscriptionId) {
    Write-Host "Subscription: $SubscriptionId" -ForegroundColor Gray
} else {
    Write-Host "Subscription: All subscriptions" -ForegroundColor Gray
}
Write-Host ""

# Check Azure CLI
Write-Host "Checking Azure CLI..." -ForegroundColor Yellow
try {
    $null = az version 2>$null
    Write-Host "  Azure CLI is installed." -ForegroundColor Green
}
catch {
    Write-Host "  Azure CLI is not installed." -ForegroundColor Red
    exit 1
}

# Authenticate
Write-Host "Checking authentication..." -ForegroundColor Yellow
try {
    $accountInfo = az account show 2>$null | ConvertFrom-Json -ErrorAction SilentlyContinue
}
catch {
    $accountInfo = $null
}

if (-not $accountInfo -or $accountInfo.tenantId -ne $TenantId) {
    Write-Host "  Signing in to tenant $TenantId..." -ForegroundColor Yellow
    az login --tenant $TenantId --only-show-errors | Out-Null
}

try {
    $currentAccount = az account show 2>$null | ConvertFrom-Json -ErrorAction SilentlyContinue
}
catch {
    $currentAccount = $null
}

if (-not $currentAccount -or $currentAccount.tenantId -ne $TenantId) {
    Write-Host "  Failed to authenticate." -ForegroundColor Red
    exit 1
}

Write-Host "  Authenticated as: $($currentAccount.user.name)" -ForegroundColor Green

# Get subscriptions
Write-Host ""
Write-Host "Getting subscriptions..." -ForegroundColor Yellow

if ($SubscriptionId) {
    $subscriptionsJson = az account show --subscription $SubscriptionId --only-show-errors 2>$null
    $sub = $subscriptionsJson | ConvertFrom-Json
    if (-not $sub) {
        Write-Host "  Subscription not found: $SubscriptionId" -ForegroundColor Red
        exit 1
    }
    $subscriptions = @($sub)
    Write-Host "  Using subscription: $($sub.name)" -ForegroundColor Green
} else {
    $subscriptionsJson = az account list --query "[?tenantId=='$TenantId' && state=='Enabled']" --only-show-errors 2>$null
    $subscriptions = $subscriptionsJson | ConvertFrom-Json | Sort-Object -Property name
    if (-not $subscriptions -or $subscriptions.Count -eq 0) {
        Write-Host "  No enabled subscriptions found." -ForegroundColor Red
        exit 1
    }
    Write-Host "  Found $($subscriptions.Count) subscription(s)" -ForegroundColor Green
}

# Collect app data
Write-Host ""
Write-Host "Scanning for App Service apps..." -ForegroundColor Yellow
Write-Host ""

$allApps = @()
$subCount = 0

foreach ($sub in $subscriptions) {
    $subCount++
    Write-Progress -Activity "Scanning Subscriptions" -Status "$($sub.name)" -PercentComplete (($subCount / $subscriptions.Count) * 100) -Id 1
    
    Write-Host "[$subCount/$($subscriptions.Count)] $($sub.name)" -ForegroundColor Cyan
    
    az account set --subscription $sub.id --only-show-errors 2>$null
    
    # Get App Service Plans
    $plansJson = az appservice plan list --only-show-errors 2>$null
    if (-not $plansJson) {
        Write-Host "  No App Service Plans found." -ForegroundColor Gray
        continue
    }
    
    $plans = $plansJson | ConvertFrom-Json
    if (-not $plans -or $plans.Count -eq 0) {
        Write-Host "  No App Service Plans found." -ForegroundColor Gray
        continue
    }
    
    Write-Host "  Found $($plans.Count) App Service Plan(s)" -ForegroundColor Gray
    
    foreach ($plan in $plans) {
        Write-Progress -Activity "Scanning Plans" -Status "$($plan.name)" -Id 2 -ParentId 1
        
        # Get apps in this plan's resource group
        $appsJson = az webapp list --resource-group $plan.resourceGroup --only-show-errors 2>$null
        if (-not $appsJson) { continue }
        
        $apps = $appsJson | ConvertFrom-Json
        $planApps = $apps | Where-Object { $_.appServicePlanId -eq $plan.id -or $_.serverFarmId -eq $plan.id }
        
        if (-not $planApps) { continue }
        
        foreach ($app in $planApps) {
            Write-Host "    Found: $($app.name)" -ForegroundColor Gray
            
            # Get app settings count
            $settingsJson = az webapp config appsettings list --name $app.name --resource-group $app.resourceGroup --only-show-errors 2>$null
            $settingsCount = 0
            if ($settingsJson) {
                $settings = $settingsJson | ConvertFrom-Json
                $settingsCount = $settings.Count
            }
            
            # Get connection strings count
            $connStrJson = az webapp config connection-string list --name $app.name --resource-group $app.resourceGroup --only-show-errors 2>$null
            $connStrCount = 0
            if ($connStrJson) {
                $connStr = $connStrJson | ConvertFrom-Json
                $connStrCount = $connStr.PSObject.Properties.Count
            }
            
            $allApps += [PSCustomObject]@{
                # Source Information (Reference)
                SourceSubscriptionId   = $sub.id
                SourceSubscriptionName = $sub.name
                SourceAppName          = $app.name
                SourceResourceGroup    = $app.resourceGroup
                SourceAppServicePlan   = $plan.name
                SourceLocation         = $app.location
                SourceSku              = $plan.sku.name
                SourceKind             = $app.kind
                AppSettingsCount       = $settingsCount
                ConnectionStringsCount = $connStrCount
                # Target Configuration (Edit These)
                TargetSubscriptionId   = $sub.id
                TargetResourceGroup    = ""
                TargetAppServicePlan   = ""
                TargetLocation         = $app.location
                TargetSku              = $plan.sku.name
                NewAppName             = ""
                Skip                   = "No"
                # Import Status (Updated by Import Script)
                ImportStatus           = "Pending"
                ImportMessage          = ""
                ImportTimestamp        = ""
            }
        }
        
        Write-Progress -Activity "Scanning Plans" -Completed -Id 2
    }
}

Write-Progress -Activity "Scanning Subscriptions" -Completed -Id 1

if ($allApps.Count -eq 0) {
    Write-Host ""
    Write-Host "No apps found to export." -ForegroundColor Yellow
    exit 0
}

# Export to CSV
$scansFolder = Join-Path -Path $PWD.Path -ChildPath 'scans'
if (-not (Test-Path -LiteralPath $scansFolder)) {
    $null = New-Item -ItemType Directory -Path $scansFolder -Force
}

if (-not $OutputFile) {
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $OutputFile = Join-Path -Path $scansFolder -ChildPath "AppMigration-$timestamp.csv"
}

$allApps | Export-Csv -Path $OutputFile -NoTypeInformation -Encoding UTF8

Write-Host ""
Write-Host "======================================" -ForegroundColor Green
Write-Host "EXPORT COMPLETED" -ForegroundColor Green
Write-Host "======================================" -ForegroundColor Green
Write-Host ""
Write-Host "Total Apps Exported: $($allApps.Count)" -ForegroundColor Cyan
Write-Host "Output File: $OutputFile" -ForegroundColor Cyan
Write-Host ""
Write-Host "NEXT STEPS:" -ForegroundColor Yellow
Write-Host "1. Open the CSV file in Excel or a text editor" -ForegroundColor Gray
Write-Host "2. Fill in the TARGET columns for each app you want to migrate:" -ForegroundColor Gray
Write-Host "   - TargetSubscriptionId  : Where to create the new app" -ForegroundColor Gray
Write-Host "   - TargetResourceGroup   : Resource group name" -ForegroundColor Gray
Write-Host "   - TargetAppServicePlan  : App Service Plan name" -ForegroundColor Gray
Write-Host "   - TargetLocation        : Azure region (e.g., eastus)" -ForegroundColor Gray
Write-Host "   - TargetSku             : SKU if creating new plan (e.g., P1V3)" -ForegroundColor Gray
Write-Host "   - NewAppName            : Globally unique name for new app" -ForegroundColor Gray
Write-Host "3. Set Skip=Yes for any apps you do not want to migrate" -ForegroundColor Gray
Write-Host "4. Save the CSV file" -ForegroundColor Gray
Write-Host "5. Run the import script:" -ForegroundColor Gray
Write-Host ""
Write-Host "   .\Import-AppServiceApps.ps1 --tenant $TenantId --file `"$OutputFile`"" -ForegroundColor Cyan
Write-Host ""

# Display summary
Write-Host "Apps by Subscription:" -ForegroundColor Yellow
$allApps | Group-Object SourceSubscriptionName | ForEach-Object {
    Write-Host "  $($_.Name): $($_.Count) app(s)" -ForegroundColor Gray
}
Write-Host ""

$allApps | Format-Table -Property SourceSubscriptionName, SourceAppName, SourceResourceGroup, SourceAppServicePlan, SourceLocation, AppSettingsCount -AutoSize

Write-Host ""
Write-Host "Press Enter to close..." -ForegroundColor Gray
$null = Read-Host
