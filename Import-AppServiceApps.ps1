# Import-AppServiceApps.ps1
# Reads a migration CSV file, creates new apps with settings from source apps,
# and updates the CSV with import status.

[CmdletBinding(PositionalBinding=$false)]
param(
    [string]$TenantId,
    [string]$CsvFile,
    [switch]$CreateMissingPlans,
    [switch]$CreateMissingResourceGroups,
    [switch]$WhatIf,
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
            '--file' { if ($i + 1 -lt $cliArgs.Count) { $CsvFile = $cliArgs[$i + 1] } }
            '--createMissingPlans' { $CreateMissingPlans = $true }
            '--createMissingResourceGroups' { $CreateMissingResourceGroups = $true }
            '--whatif' { $WhatIf = $true }
        }
    }
}

function Show-Usage {
    Write-Host ""
    Write-Host "Import-AppServiceApps.ps1" -ForegroundColor Cyan
    Write-Host "=========================" -ForegroundColor Cyan
    Write-Host "Creates new App Service apps based on a migration CSV file."
    Write-Host "Copies all settings from source apps to new apps."
    Write-Host ""
    Write-Host "Usage:" -ForegroundColor Yellow
    Write-Host "  .\Import-AppServiceApps.ps1 --tenant <tenantId> --file <csvFile> [options]"
    Write-Host ""
    Write-Host "Parameters:" -ForegroundColor Yellow
    Write-Host "  --tenant                    : (Required) Azure Tenant ID" -ForegroundColor Gray
    Write-Host "  --file                      : (Required) Path to the migration CSV file" -ForegroundColor Gray
    Write-Host "  --createMissingPlans        : (Optional) Create App Service Plans if they don't exist" -ForegroundColor Gray
    Write-Host "  --createMissingResourceGroups : (Optional) Create Resource Groups if they don't exist" -ForegroundColor Gray
    Write-Host "  --whatif                    : (Optional) Show what would be done without making changes" -ForegroundColor Gray
    Write-Host ""
    Write-Host "Required CSV Columns (from Export script):" -ForegroundColor Yellow
    Write-Host "  Source: SourceSubscriptionId, SourceAppName, SourceResourceGroup" -ForegroundColor Gray
    Write-Host "  Target: TargetSubscriptionId, TargetResourceGroup, TargetAppServicePlan," -ForegroundColor Gray
    Write-Host "          TargetLocation, TargetSku, NewAppName, Skip" -ForegroundColor Gray
    Write-Host ""
    Write-Host "Example:" -ForegroundColor Yellow
    Write-Host "  .\Import-AppServiceApps.ps1 --tenant 12345-abcde --file .\scans\AppMigration.csv --createMissingPlans"
    Write-Host ""
}

if (-not $TenantId -or -not $CsvFile) {
    Show-Usage
    exit 1
}

if (-not (Test-Path -LiteralPath $CsvFile)) {
    Write-Host "Error: CSV file not found: $CsvFile" -ForegroundColor Red
    exit 1
}

$ErrorActionPreference = 'Stop'

Write-Host ""
Write-Host "Import-AppServiceApps" -ForegroundColor Cyan
Write-Host "=====================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Tenant: $TenantId" -ForegroundColor Gray
Write-Host "CSV File: $CsvFile" -ForegroundColor Gray
Write-Host "Create Missing Plans: $CreateMissingPlans" -ForegroundColor Gray
Write-Host "Create Missing RGs: $CreateMissingResourceGroups" -ForegroundColor Gray
if ($WhatIf) {
    Write-Host "Mode: WHAT-IF (No changes will be made)" -ForegroundColor Yellow
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

# Load CSV
Write-Host ""
Write-Host "Loading migration plan..." -ForegroundColor Yellow
$migrationPlan = Import-Csv -Path $CsvFile -Encoding UTF8

# Validate required columns
$requiredColumns = @('SourceSubscriptionId', 'SourceAppName', 'SourceResourceGroup', 
                     'TargetSubscriptionId', 'TargetResourceGroup', 'TargetAppServicePlan',
                     'TargetLocation', 'NewAppName', 'Skip')
$csvColumns = $migrationPlan[0].PSObject.Properties.Name
$missingColumns = $requiredColumns | Where-Object { $_ -notin $csvColumns }

if ($missingColumns.Count -gt 0) {
    Write-Host "  Error: Missing required columns: $($missingColumns -join ', ')" -ForegroundColor Red
    exit 1
}

Write-Host "  Loaded $($migrationPlan.Count) app(s) from CSV" -ForegroundColor Green

# Filter apps to process
$appsToProcess = $migrationPlan | Where-Object { 
    $_.Skip -ne 'Yes' -and $_.Skip -ne 'yes' -and $_.Skip -ne 'TRUE' -and 
    $_.NewAppName -and $_.TargetResourceGroup -and $_.TargetAppServicePlan -and
    $_.ImportStatus -ne 'Success'
}

$appsToSkip = $migrationPlan | Where-Object { 
    $_.Skip -eq 'Yes' -or $_.Skip -eq 'yes' -or $_.Skip -eq 'TRUE' 
}

$appsIncomplete = $migrationPlan | Where-Object {
    $_.Skip -ne 'Yes' -and $_.Skip -ne 'yes' -and $_.Skip -ne 'TRUE' -and
    (-not $_.NewAppName -or -not $_.TargetResourceGroup -or -not $_.TargetAppServicePlan) -and
    $_.ImportStatus -ne 'Success'
}

$appsAlreadyDone = $migrationPlan | Where-Object { $_.ImportStatus -eq 'Success' }

Write-Host ""
Write-Host "Migration Summary:" -ForegroundColor Yellow
Write-Host "  Apps to create: $($appsToProcess.Count)" -ForegroundColor Green
Write-Host "  Apps to skip (Skip=Yes): $($appsToSkip.Count)" -ForegroundColor Gray
Write-Host "  Apps incomplete (missing target info): $($appsIncomplete.Count)" -ForegroundColor $(if ($appsIncomplete.Count -gt 0) { "Yellow" } else { "Gray" })
Write-Host "  Apps already imported: $($appsAlreadyDone.Count)" -ForegroundColor Gray
Write-Host ""

if ($appsIncomplete.Count -gt 0) {
    Write-Host "Apps with incomplete target configuration:" -ForegroundColor Yellow
    $appsIncomplete | ForEach-Object {
        $missing = @()
        if (-not $_.NewAppName) { $missing += "NewAppName" }
        if (-not $_.TargetResourceGroup) { $missing += "TargetResourceGroup" }
        if (-not $_.TargetAppServicePlan) { $missing += "TargetAppServicePlan" }
        Write-Host "  - $($_.SourceAppName): Missing $($missing -join ', ')" -ForegroundColor Yellow
    }
    Write-Host ""
}

if ($appsToProcess.Count -eq 0) {
    Write-Host "No apps to process. Please fill in the target columns in the CSV." -ForegroundColor Yellow
    exit 0
}

# Confirm
if (-not $WhatIf) {
    Write-Host "Apps to be created:" -ForegroundColor Yellow
    $appsToProcess | ForEach-Object {
        Write-Host "  $($_.SourceAppName) -> $($_.NewAppName) in $($_.TargetResourceGroup)/$($_.TargetAppServicePlan)" -ForegroundColor Gray
    }
    Write-Host ""
    
    $confirm = Read-Host "Proceed with creating $($appsToProcess.Count) app(s)? (Y/N)"
    if ($confirm -ne 'Y' -and $confirm -ne 'y') {
        Write-Host "Cancelled." -ForegroundColor Yellow
        exit 0
    }
}

# Track created resources to avoid duplicate creation attempts
$createdResourceGroups = @{}
$createdPlans = @{}
$currentSubscription = ""

# Process each app
Write-Host ""
Write-Host "Processing apps..." -ForegroundColor Cyan
Write-Host ""

$appIndex = 0
$successCount = 0
$failCount = 0

foreach ($app in $migrationPlan) {
    $appIndex++
    
    # Update skipped apps
    if ($app.Skip -eq 'Yes' -or $app.Skip -eq 'yes' -or $app.Skip -eq 'TRUE') {
        $app.ImportStatus = "Skipped"
        $app.ImportMessage = "Skipped by user"
        $app.ImportTimestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        continue
    }
    
    # Skip already successful imports
    if ($app.ImportStatus -eq 'Success') {
        continue
    }
    
    # Skip incomplete entries
    if (-not $app.NewAppName -or -not $app.TargetResourceGroup -or -not $app.TargetAppServicePlan) {
        $app.ImportStatus = "Skipped"
        $app.ImportMessage = "Missing target configuration"
        $app.ImportTimestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        continue
    }
    
    $percentComplete = [math]::Round(($appIndex / $migrationPlan.Count) * 100)
    Write-Progress -Activity "Creating Apps" -Status "$($app.NewAppName)" -PercentComplete $percentComplete
    
    Write-Host "[$appIndex/$($migrationPlan.Count)] $($app.SourceAppName) -> $($app.NewAppName)" -ForegroundColor Cyan
    
    if ($WhatIf) {
        Write-Host "  [WHAT-IF] Would create app in $($app.TargetResourceGroup)/$($app.TargetAppServicePlan)" -ForegroundColor Yellow
        $app.ImportStatus = "WhatIf"
        $app.ImportMessage = "Would create app"
        $app.ImportTimestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        continue
    }
    
    try {
        # Switch subscription if needed
        if ($currentSubscription -ne $app.TargetSubscriptionId) {
            Write-Host "  Switching to subscription: $($app.TargetSubscriptionId)" -ForegroundColor Gray
            az account set --subscription $app.TargetSubscriptionId --only-show-errors 2>$null
            $currentSubscription = $app.TargetSubscriptionId
        }
        
        # Create Resource Group if needed
        $rgKey = "$($app.TargetSubscriptionId)_$($app.TargetResourceGroup)"
        if (-not $createdResourceGroups.ContainsKey($rgKey)) {
            $rgExists = az group exists --name $app.TargetResourceGroup --only-show-errors 2>$null
            if ($rgExists -eq 'false') {
                if ($CreateMissingResourceGroups) {
                    Write-Host "  Creating resource group: $($app.TargetResourceGroup)" -ForegroundColor Yellow
                    az group create --name $app.TargetResourceGroup --location $app.TargetLocation --only-show-errors 2>$null | Out-Null
                } else {
                    throw "Resource group '$($app.TargetResourceGroup)' does not exist. Use --createMissingResourceGroups to create it."
                }
            }
            $createdResourceGroups[$rgKey] = $true
        }
        
        # Get source app details first (to determine if it's Linux/container)
        Write-Host "  Getting source app details..." -ForegroundColor Gray
        az account set --subscription $app.SourceSubscriptionId --only-show-errors 2>$null
        
        $sourceAppJson = az webapp show --name $app.SourceAppName --resource-group $app.SourceResourceGroup --only-show-errors 2>$null
        $sourceApp = $null
        if ($sourceAppJson) {
            $sourceApp = $sourceAppJson | ConvertFrom-Json
        }
        
        $isLinux = $false
        $isContainer = $false
        $containerImage = $null
        $runtime = $null
        
        if ($sourceApp) {
            # Check if Linux app
            $isLinux = $app.SourceKind -match 'linux'
            $isContainer = $app.SourceKind -match 'container'
            
            # Get runtime stack for Linux apps
            if ($isLinux -and -not $isContainer) {
                $sourceConfigJson = az webapp config show --name $app.SourceAppName --resource-group $app.SourceResourceGroup --only-show-errors 2>$null
                if ($sourceConfigJson) {
                    $srcConfig = $sourceConfigJson | ConvertFrom-Json
                    if ($srcConfig.linuxFxVersion) {
                        $runtime = $srcConfig.linuxFxVersion
                    }
                }
            }
            
            # Get container image for container apps
            if ($isContainer) {
                $containerConfigJson = az webapp config container show --name $app.SourceAppName --resource-group $app.SourceResourceGroup --only-show-errors 2>$null
                if ($containerConfigJson) {
                    $containerConfig = $containerConfigJson | ConvertFrom-Json
                    foreach ($setting in $containerConfig) {
                        if ($setting.name -eq 'DOCKER_CUSTOM_IMAGE_NAME') {
                            $containerImage = $setting.value
                        }
                    }
                }
            }
        }
        
        # Switch back to target subscription
        az account set --subscription $app.TargetSubscriptionId --only-show-errors 2>$null
        $currentSubscription = $app.TargetSubscriptionId
        
        # Create App Service Plan if needed
        $planKey = "$($app.TargetSubscriptionId)_$($app.TargetResourceGroup)_$($app.TargetAppServicePlan)"
        if (-not $createdPlans.ContainsKey($planKey)) {
            $existingPlan = az appservice plan show --name $app.TargetAppServicePlan --resource-group $app.TargetResourceGroup --only-show-errors 2>$null
            if (-not $existingPlan) {
                if ($CreateMissingPlans) {
                    $sku = if ($app.TargetSku) { $app.TargetSku } else { "S1" }
                    Write-Host "  Creating App Service Plan: $($app.TargetAppServicePlan) (SKU: $sku, Linux: $isLinux)" -ForegroundColor Yellow
                    
                    $planArgs = @("appservice", "plan", "create", "--name", $app.TargetAppServicePlan, "--resource-group", $app.TargetResourceGroup, "--location", $app.TargetLocation, "--sku", $sku)
                    if ($isLinux) {
                        $planArgs += "--is-linux"
                    }
                    $planArgs += "--only-show-errors"
                    & az @planArgs 2>$null | Out-Null
                } else {
                    throw "App Service Plan '$($app.TargetAppServicePlan)' does not exist. Use --createMissingPlans to create it."
                }
            }
            $createdPlans[$planKey] = $true
        }
        
        # Create the web app
        Write-Host "  Creating web app: $($app.NewAppName) (Linux: $isLinux, Container: $isContainer)" -ForegroundColor Gray
        
        $createResult = $null
        
        if ($isContainer -and $containerImage) {
            # Container app - use container image
            Write-Host "  Using container image: $containerImage" -ForegroundColor Gray
            $createResult = cmd /c "az webapp create --name `"$($app.NewAppName)`" --resource-group `"$($app.TargetResourceGroup)`" --plan `"$($app.TargetAppServicePlan)`" --container-image-name `"$containerImage`" --only-show-errors 2>&1"
        }
        elseif ($isLinux -and $runtime) {
            # Linux code app - use runtime (cmd /c handles pipe character correctly)
            Write-Host "  Using runtime: $runtime" -ForegroundColor Gray
            $createResult = cmd /c "az webapp create --name `"$($app.NewAppName)`" --resource-group `"$($app.TargetResourceGroup)`" --plan `"$($app.TargetAppServicePlan)`" --runtime `"$runtime`" --only-show-errors 2>&1"
        }
        else {
            # Windows app or Linux without specific runtime
            $createResult = az webapp create --name $app.NewAppName --resource-group $app.TargetResourceGroup --plan $app.TargetAppServicePlan --only-show-errors 2>&1
        }
        
        # Check if creation failed (look for ERROR: at start of line, not just anywhere)
        $createResultStr = $createResult | Out-String
        if ($createResultStr -match '(?m)^ERROR:') {
            throw $createResultStr.Trim()
        }
        
        Write-Host "  Web app created successfully" -ForegroundColor Green
        
        # Get settings from source app
        Write-Host "  Copying settings from source app..." -ForegroundColor Gray
        
        # Switch to source subscription to get settings
        az account set --subscription $app.SourceSubscriptionId --only-show-errors 2>$null
        
        # Get app settings
        $sourceSettingsJson = az webapp config appsettings list --name $app.SourceAppName --resource-group $app.SourceResourceGroup --only-show-errors 2>$null
        
        # Get connection strings
        $sourceConnStrJson = az webapp config connection-string list --name $app.SourceAppName --resource-group $app.SourceResourceGroup --only-show-errors 2>$null
        
        # Get general config (reuse if already fetched, otherwise get it)
        if (-not $sourceConfigJson) {
            $sourceConfigJson = az webapp config show --name $app.SourceAppName --resource-group $app.SourceResourceGroup --only-show-errors 2>$null
        }
        
        # Switch back to target subscription
        az account set --subscription $app.TargetSubscriptionId --only-show-errors 2>$null
        $currentSubscription = $app.TargetSubscriptionId
        
        # Apply app settings
        if ($sourceSettingsJson) {
            $sourceSettings = $sourceSettingsJson | ConvertFrom-Json
            if ($sourceSettings -and $sourceSettings.Count -gt 0) {
                Write-Host "  Applying $($sourceSettings.Count) app settings..." -ForegroundColor Gray
                
                $settingsArray = @()
                foreach ($setting in $sourceSettings) {
                    if ($setting.name -and $null -ne $setting.value) {
                        $settingsArray += "$($setting.name)=$($setting.value)"
                    }
                }
                
                if ($settingsArray.Count -gt 0) {
                    # Apply in batches
                    $batchSize = 20
                    for ($i = 0; $i -lt $settingsArray.Count; $i += $batchSize) {
                        $batch = $settingsArray[$i..[math]::Min($i + $batchSize - 1, $settingsArray.Count - 1)]
                        az webapp config appsettings set --name $app.NewAppName --resource-group $app.TargetResourceGroup --settings @batch --only-show-errors 2>$null | Out-Null
                    }
                }
                Write-Host "  App settings applied" -ForegroundColor Green
            }
        }
        
        # Apply connection strings
        if ($sourceConnStrJson) {
            $sourceConnStr = $sourceConnStrJson | ConvertFrom-Json
            if ($sourceConnStr -and $sourceConnStr.PSObject.Properties.Count -gt 0) {
                Write-Host "  Applying connection strings..." -ForegroundColor Gray
                
                foreach ($prop in $sourceConnStr.PSObject.Properties) {
                    $connName = $prop.Name
                    $connValue = $prop.Value.value
                    $connType = $prop.Value.type
                    
                    if ($connName -and $connValue -and $connType) {
                        az webapp config connection-string set --name $app.NewAppName --resource-group $app.TargetResourceGroup --connection-string-type $connType --settings "$connName=$connValue" --only-show-errors 2>$null | Out-Null
                    }
                }
                Write-Host "  Connection strings applied" -ForegroundColor Green
            }
        }
        
        # Apply general configuration
        if ($sourceConfigJson) {
            $sourceConfig = $sourceConfigJson | ConvertFrom-Json
            Write-Host "  Applying general configuration..." -ForegroundColor Gray
            
            $configArgs = @("webapp", "config", "set", "--name", $app.NewAppName, "--resource-group", $app.TargetResourceGroup)
            
            if ($null -ne $sourceConfig.alwaysOn) {
                $val = if ($sourceConfig.alwaysOn) { "true" } else { "false" }
                $configArgs += @("--always-on", $val)
            }
            if ($null -ne $sourceConfig.http20Enabled) {
                $val = if ($sourceConfig.http20Enabled) { "true" } else { "false" }
                $configArgs += @("--http20-enabled", $val)
            }
            if ($sourceConfig.minTlsVersion) {
                $configArgs += @("--min-tls-version", $sourceConfig.minTlsVersion)
            }
            if ($sourceConfig.ftpsState) {
                $configArgs += @("--ftps-state", $sourceConfig.ftpsState)
            }
            if ($null -ne $sourceConfig.webSocketsEnabled) {
                $val = if ($sourceConfig.webSocketsEnabled) { "true" } else { "false" }
                $configArgs += @("--web-sockets-enabled", $val)
            }
            
            $configArgs += "--only-show-errors"
            & az @configArgs 2>$null | Out-Null
            
            Write-Host "  Configuration applied" -ForegroundColor Green
        }
        
        # Update status
        $app.ImportStatus = "Success"
        $app.ImportMessage = "App created and settings applied"
        $app.ImportTimestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        $successCount++
        
        Write-Host "  COMPLETED: $($app.NewAppName)" -ForegroundColor Green
    }
    catch {
        $app.ImportStatus = "Failed"
        $app.ImportMessage = $_.Exception.Message
        $app.ImportTimestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        $failCount++
        
        Write-Host "  FAILED: $($_.Exception.Message)" -ForegroundColor Red
    }
    
    # Save CSV after each app (to preserve progress)
    $migrationPlan | Export-Csv -Path $CsvFile -NoTypeInformation -Encoding UTF8
}

Write-Progress -Activity "Creating Apps" -Completed

# Final save
$migrationPlan | Export-Csv -Path $CsvFile -NoTypeInformation -Encoding UTF8

# Summary
Write-Host ""
Write-Host "======================================" -ForegroundColor Green
Write-Host "IMPORT COMPLETED" -ForegroundColor Green
Write-Host "======================================" -ForegroundColor Green
Write-Host ""
Write-Host "Results:" -ForegroundColor Yellow
Write-Host "  Successful: $successCount" -ForegroundColor Green
Write-Host "  Failed: $failCount" -ForegroundColor $(if ($failCount -gt 0) { "Red" } else { "Green" })
Write-Host "  Skipped: $($appsToSkip.Count + $appsIncomplete.Count)" -ForegroundColor Gray
Write-Host ""
Write-Host "CSV file updated with status: $CsvFile" -ForegroundColor Cyan
Write-Host ""

# Show failed apps
$failedApps = $migrationPlan | Where-Object { $_.ImportStatus -eq 'Failed' }
if ($failedApps.Count -gt 0) {
    Write-Host "Failed Apps:" -ForegroundColor Red
    $failedApps | Format-Table -Property SourceAppName, NewAppName, ImportMessage -AutoSize
}

# Show successful apps
$successApps = $migrationPlan | Where-Object { $_.ImportStatus -eq 'Success' }
if ($successApps.Count -gt 0) {
    Write-Host "Successfully Created Apps:" -ForegroundColor Green
    $successApps | Format-Table -Property SourceAppName, NewAppName, TargetResourceGroup, TargetAppServicePlan -AutoSize
}

Write-Host ""
Write-Host "Press Enter to close..." -ForegroundColor Gray
$null = Read-Host
