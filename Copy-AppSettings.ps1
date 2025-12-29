# Copy-AppSettings.ps1
# Copies app settings and connection strings from a source App Service app to an existing target app.
# Use this when apps are already created but settings need to be synchronized.

[CmdletBinding(PositionalBinding=$false)]
param(
    [string]$TenantId,
    [string]$SourceSubscriptionId,
    [string]$SourceResourceGroup,
    [string]$SourceAppName,
    [string]$TargetSubscriptionId,
    [string]$TargetResourceGroup,
    [string]$TargetAppName,
    [switch]$IncludeConnectionStrings,
    [switch]$IncludeGeneralConfig,
    [switch]$WhatIf,
    [switch]$Force,
    [string[]]$ExcludeSettings,
    [string[]]$OnlySettings,
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
            '--source-subscription' { if ($i + 1 -lt $cliArgs.Count) { $SourceSubscriptionId = $cliArgs[$i + 1] } }
            '--source-resource-group' { if ($i + 1 -lt $cliArgs.Count) { $SourceResourceGroup = $cliArgs[$i + 1] } }
            '--source-app' { if ($i + 1 -lt $cliArgs.Count) { $SourceAppName = $cliArgs[$i + 1] } }
            '--target-subscription' { if ($i + 1 -lt $cliArgs.Count) { $TargetSubscriptionId = $cliArgs[$i + 1] } }
            '--target-resource-group' { if ($i + 1 -lt $cliArgs.Count) { $TargetResourceGroup = $cliArgs[$i + 1] } }
            '--target-app' { if ($i + 1 -lt $cliArgs.Count) { $TargetAppName = $cliArgs[$i + 1] } }
            '--include-connection-strings' { $IncludeConnectionStrings = $true }
            '--include-general-config' { $IncludeGeneralConfig = $true }
            '--whatif' { $WhatIf = $true }
            '--force' { $Force = $true }
            '--exclude' { 
                if ($i + 1 -lt $cliArgs.Count) { 
                    $ExcludeSettings = $cliArgs[$i + 1] -split ',' 
                } 
            }
            '--only' { 
                if ($i + 1 -lt $cliArgs.Count) { 
                    $OnlySettings = $cliArgs[$i + 1] -split ',' 
                } 
            }
        }
    }
}

function Show-Usage {
    Write-Host ""
    Write-Host "Copy-AppSettings.ps1" -ForegroundColor Cyan
    Write-Host "====================" -ForegroundColor Cyan
    Write-Host "Copies app settings and connection strings from a source app to a target app."
    Write-Host ""
    Write-Host "Usage:" -ForegroundColor Yellow
    Write-Host "  .\Copy-AppSettings.ps1 --tenant <tenantId> \"
    Write-Host "    --source-subscription <subId> --source-resource-group <rg> --source-app <app> \"
    Write-Host "    --target-subscription <subId> --target-resource-group <rg> --target-app <app> [options]"
    Write-Host ""
    Write-Host "Parameters:" -ForegroundColor Yellow
    Write-Host "  --tenant              : (Required) Azure Tenant ID" -ForegroundColor Gray
    Write-Host "  --source-subscription : (Required) Source subscription ID" -ForegroundColor Gray
    Write-Host "  --source-resource-group: (Required) Source resource group" -ForegroundColor Gray
    Write-Host "  --source-app          : (Required) Source app name" -ForegroundColor Gray
    Write-Host "  --target-subscription : (Optional) Target subscription ID (defaults to source)" -ForegroundColor Gray
    Write-Host "  --target-resource-group: (Required) Target resource group" -ForegroundColor Gray
    Write-Host "  --target-app          : (Required) Target app name" -ForegroundColor Gray
    Write-Host ""
    Write-Host "Options:" -ForegroundColor Yellow
    Write-Host "  --include-connection-strings : Also copy connection strings" -ForegroundColor Gray
    Write-Host "  --include-general-config     : Also copy general config (AlwaysOn, TLS, etc.)" -ForegroundColor Gray
    Write-Host "  --whatif                     : Preview changes without applying" -ForegroundColor Gray
    Write-Host "  --force                      : Overwrite existing settings without prompting" -ForegroundColor Gray
    Write-Host "  --exclude <settings>         : Comma-separated list of settings to exclude" -ForegroundColor Gray
    Write-Host "  --only <settings>            : Comma-separated list of settings to copy (ignores others)" -ForegroundColor Gray
    Write-Host ""
    Write-Host "What Gets Copied:" -ForegroundColor Yellow
    Write-Host "  Default:" -ForegroundColor Gray
    Write-Host "    - All app settings (environment variables)" -ForegroundColor Gray
    Write-Host "  With --include-connection-strings:" -ForegroundColor Gray
    Write-Host "    - Connection strings (database connections, etc.)" -ForegroundColor Gray
    Write-Host "  With --include-general-config:" -ForegroundColor Gray
    Write-Host "    - AlwaysOn, HTTP/2, Min TLS Version, FTPS State" -ForegroundColor Gray
    Write-Host "    - WebSockets, Linux Runtime Stack" -ForegroundColor Gray
    Write-Host ""
    Write-Host "Examples:" -ForegroundColor Yellow
    Write-Host "  # Copy all app settings"
    Write-Host "  .\Copy-AppSettings.ps1 --tenant <tenantId> \"
    Write-Host "    --source-subscription <subId> --source-resource-group rg-old --source-app MyApp \"
    Write-Host "    --target-resource-group rg-new --target-app MyApp-new"
    Write-Host ""
    Write-Host "  # Copy everything including connection strings and general config"
    Write-Host "  .\Copy-AppSettings.ps1 --tenant <tenantId> \"
    Write-Host "    --source-subscription <subId> --source-resource-group rg-old --source-app MyApp \"
    Write-Host "    --target-resource-group rg-new --target-app MyApp-new \"
    Write-Host "    --include-connection-strings --include-general-config"
    Write-Host ""
    Write-Host "  # Preview what would be copied"
    Write-Host "  .\Copy-AppSettings.ps1 --tenant <tenantId> \"
    Write-Host "    --source-subscription <subId> --source-resource-group rg-old --source-app MyApp \"
    Write-Host "    --target-resource-group rg-new --target-app MyApp-new --whatif"
    Write-Host ""
    Write-Host "  # Copy only specific settings"
    Write-Host "  .\Copy-AppSettings.ps1 --tenant <tenantId> \"
    Write-Host "    --source-subscription <subId> --source-resource-group rg-old --source-app MyApp \"
    Write-Host "    --target-resource-group rg-new --target-app MyApp-new \"
    Write-Host "    --only ""ApiKey,DatabaseConnection,StorageAccount"""
    Write-Host ""
    Write-Host "  # Copy all except certain settings"
    Write-Host "  .\Copy-AppSettings.ps1 --tenant <tenantId> \"
    Write-Host "    --source-subscription <subId> --source-resource-group rg-old --source-app MyApp \"
    Write-Host "    --target-resource-group rg-new --target-app MyApp-new \"
    Write-Host "    --exclude ""WEBSITE_NODE_DEFAULT_VERSION,SCM_DO_BUILD_DURING_DEPLOYMENT"""
    Write-Host ""
}

# Validate required parameters
if (-not $TenantId -or -not $SourceResourceGroup -or -not $SourceAppName -or -not $TargetResourceGroup -or -not $TargetAppName) {
    Show-Usage
    exit 1
}

# Default target subscription to source subscription
if (-not $TargetSubscriptionId -and $SourceSubscriptionId) {
    $TargetSubscriptionId = $SourceSubscriptionId
}

$ErrorActionPreference = 'Stop'

# ============================================================================
# MAIN SCRIPT
# ============================================================================

Write-Host ""
Write-Host "Copy-AppSettings" -ForegroundColor Cyan
Write-Host "================" -ForegroundColor Cyan
Write-Host ""

if ($WhatIf) {
    Write-Host "*** WHATIF MODE - No changes will be made ***" -ForegroundColor Yellow
    Write-Host ""
}

Write-Host "Source:" -ForegroundColor White
Write-Host "  Subscription: $SourceSubscriptionId" -ForegroundColor Gray
Write-Host "  Resource Group: $SourceResourceGroup" -ForegroundColor Gray
Write-Host "  App: $SourceAppName" -ForegroundColor Gray
Write-Host ""
Write-Host "Target:" -ForegroundColor White
Write-Host "  Subscription: $TargetSubscriptionId" -ForegroundColor Gray
Write-Host "  Resource Group: $TargetResourceGroup" -ForegroundColor Gray
Write-Host "  App: $TargetAppName" -ForegroundColor Gray
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

# If no source subscription specified, use current
if (-not $SourceSubscriptionId) {
    $SourceSubscriptionId = $currentAccount.id
    Write-Host "  Using current subscription for source: $SourceSubscriptionId" -ForegroundColor Gray
}

if (-not $TargetSubscriptionId) {
    $TargetSubscriptionId = $SourceSubscriptionId
}

# ============================================================================
# VERIFY APPS EXIST
# ============================================================================

Write-Host ""
Write-Host "Verifying apps exist..." -ForegroundColor Yellow

# Check source app
az account set --subscription $SourceSubscriptionId --only-show-errors 2>$null
$sourceAppJson = az webapp show --name $SourceAppName --resource-group $SourceResourceGroup --only-show-errors 2>$null
if (-not $sourceAppJson) {
    Write-Host "  ERROR: Source app '$SourceAppName' not found in resource group '$SourceResourceGroup'" -ForegroundColor Red
    exit 1
}
$sourceApp = $sourceAppJson | ConvertFrom-Json
Write-Host "  Source app found: $($sourceApp.defaultHostName)" -ForegroundColor Green

# Check target app
az account set --subscription $TargetSubscriptionId --only-show-errors 2>$null
$targetAppJson = az webapp show --name $TargetAppName --resource-group $TargetResourceGroup --only-show-errors 2>$null
if (-not $targetAppJson) {
    Write-Host "  ERROR: Target app '$TargetAppName' not found in resource group '$TargetResourceGroup'" -ForegroundColor Red
    exit 1
}
$targetApp = $targetAppJson | ConvertFrom-Json
Write-Host "  Target app found: $($targetApp.defaultHostName)" -ForegroundColor Green

# ============================================================================
# GET SOURCE SETTINGS
# ============================================================================

Write-Host ""
Write-Host "Reading source app settings..." -ForegroundColor Yellow

az account set --subscription $SourceSubscriptionId --only-show-errors 2>$null

# Get app settings
$sourceSettingsJson = az webapp config appsettings list --name $SourceAppName --resource-group $SourceResourceGroup --only-show-errors 2>$null
$sourceSettings = @()
if ($sourceSettingsJson) {
    $sourceSettings = $sourceSettingsJson | ConvertFrom-Json
}
Write-Host "  Found $($sourceSettings.Count) app setting(s)" -ForegroundColor Gray

# Get connection strings if requested
$sourceConnStrings = @()
if ($IncludeConnectionStrings) {
    $sourceConnStrJson = az webapp config connection-string list --name $SourceAppName --resource-group $SourceResourceGroup --only-show-errors 2>$null
    if ($sourceConnStrJson) {
        $connStrObj = $sourceConnStrJson | ConvertFrom-Json
        foreach ($prop in $connStrObj.PSObject.Properties) {
            $sourceConnStrings += [PSCustomObject]@{
                Name = $prop.Name
                Type = $prop.Value.type
                Value = $prop.Value.value
            }
        }
    }
    Write-Host "  Found $($sourceConnStrings.Count) connection string(s)" -ForegroundColor Gray
}

# Get general config if requested
$sourceConfig = $null
if ($IncludeGeneralConfig) {
    $sourceConfigJson = az webapp config show --name $SourceAppName --resource-group $SourceResourceGroup --only-show-errors 2>$null
    if ($sourceConfigJson) {
        $sourceConfig = $sourceConfigJson | ConvertFrom-Json
    }
    Write-Host "  General configuration loaded" -ForegroundColor Gray
}

# ============================================================================
# GET TARGET SETTINGS (for comparison)
# ============================================================================

Write-Host ""
Write-Host "Reading target app settings..." -ForegroundColor Yellow

az account set --subscription $TargetSubscriptionId --only-show-errors 2>$null

$targetSettingsJson = az webapp config appsettings list --name $TargetAppName --resource-group $TargetResourceGroup --only-show-errors 2>$null
$targetSettings = @()
if ($targetSettingsJson) {
    $targetSettings = $targetSettingsJson | ConvertFrom-Json
}
Write-Host "  Found $($targetSettings.Count) existing app setting(s)" -ForegroundColor Gray

$targetSettingsHash = @{}
foreach ($setting in $targetSettings) {
    $targetSettingsHash[$setting.name] = $setting.value
}

# ============================================================================
# FILTER SETTINGS
# ============================================================================

# Apply --only filter
if ($OnlySettings -and $OnlySettings.Count -gt 0) {
    $sourceSettings = $sourceSettings | Where-Object { $OnlySettings -contains $_.name }
    Write-Host ""
    Write-Host "Filtered to $($sourceSettings.Count) setting(s) (--only filter applied)" -ForegroundColor Yellow
}

# Apply --exclude filter
if ($ExcludeSettings -and $ExcludeSettings.Count -gt 0) {
    $beforeCount = $sourceSettings.Count
    $sourceSettings = $sourceSettings | Where-Object { $ExcludeSettings -notcontains $_.name }
    Write-Host ""
    Write-Host "Excluded $($beforeCount - $sourceSettings.Count) setting(s) (--exclude filter applied)" -ForegroundColor Yellow
}

# ============================================================================
# ANALYZE CHANGES
# ============================================================================

Write-Host ""
Write-Host "Analyzing changes..." -ForegroundColor Yellow
Write-Host ""

$settingsToAdd = @()
$settingsToUpdate = @()
$settingsUnchanged = @()

foreach ($setting in $sourceSettings) {
    if ($targetSettingsHash.ContainsKey($setting.name)) {
        if ($targetSettingsHash[$setting.name] -eq $setting.value) {
            $settingsUnchanged += $setting
        } else {
            $settingsToUpdate += $setting
        }
    } else {
        $settingsToAdd += $setting
    }
}

Write-Host "App Settings Summary:" -ForegroundColor White
Write-Host "  New settings to add: $($settingsToAdd.Count)" -ForegroundColor Green
Write-Host "  Existing settings to update: $($settingsToUpdate.Count)" -ForegroundColor Yellow
Write-Host "  Unchanged settings: $($settingsUnchanged.Count)" -ForegroundColor Gray
Write-Host ""

# Display what will be changed
if ($settingsToAdd.Count -gt 0) {
    Write-Host "Settings to ADD:" -ForegroundColor Green
    foreach ($setting in $settingsToAdd) {
        Write-Host "  [+] $($setting.name)" -ForegroundColor Green
    }
    Write-Host ""
}

if ($settingsToUpdate.Count -gt 0) {
    Write-Host "Settings to UPDATE:" -ForegroundColor Yellow
    foreach ($setting in $settingsToUpdate) {
        Write-Host "  [~] $($setting.name)" -ForegroundColor Yellow
    }
    Write-Host ""
}

# Connection strings analysis
$connStrToAdd = @()
$connStrToUpdate = @()

if ($IncludeConnectionStrings -and $sourceConnStrings.Count -gt 0) {
    # Get target connection strings
    $targetConnStrJson = az webapp config connection-string list --name $TargetAppName --resource-group $TargetResourceGroup --only-show-errors 2>$null
    $targetConnStrHash = @{}
    if ($targetConnStrJson) {
        $targetConnStrObj = $targetConnStrJson | ConvertFrom-Json
        foreach ($prop in $targetConnStrObj.PSObject.Properties) {
            $targetConnStrHash[$prop.Name] = $prop.Value
        }
    }
    
    foreach ($connStr in $sourceConnStrings) {
        if ($targetConnStrHash.ContainsKey($connStr.Name)) {
            $connStrToUpdate += $connStr
        } else {
            $connStrToAdd += $connStr
        }
    }
    
    Write-Host "Connection Strings Summary:" -ForegroundColor White
    Write-Host "  New to add: $($connStrToAdd.Count)" -ForegroundColor Green
    Write-Host "  Existing to update: $($connStrToUpdate.Count)" -ForegroundColor Yellow
    Write-Host ""
    
    if ($connStrToAdd.Count -gt 0) {
        Write-Host "Connection Strings to ADD:" -ForegroundColor Green
        foreach ($connStr in $connStrToAdd) {
            Write-Host "  [+] $($connStr.Name) ($($connStr.Type))" -ForegroundColor Green
        }
        Write-Host ""
    }
    
    if ($connStrToUpdate.Count -gt 0) {
        Write-Host "Connection Strings to UPDATE:" -ForegroundColor Yellow
        foreach ($connStr in $connStrToUpdate) {
            Write-Host "  [~] $($connStr.Name) ($($connStr.Type))" -ForegroundColor Yellow
        }
        Write-Host ""
    }
}

# General config analysis
if ($IncludeGeneralConfig -and $sourceConfig) {
    Write-Host "General Configuration to apply:" -ForegroundColor White
    Write-Host "  AlwaysOn: $($sourceConfig.alwaysOn)" -ForegroundColor Gray
    Write-Host "  HTTP/2: $($sourceConfig.http20Enabled)" -ForegroundColor Gray
    Write-Host "  Min TLS Version: $($sourceConfig.minTlsVersion)" -ForegroundColor Gray
    Write-Host "  FTPS State: $($sourceConfig.ftpsState)" -ForegroundColor Gray
    Write-Host "  WebSockets: $($sourceConfig.webSocketsEnabled)" -ForegroundColor Gray
    if ($sourceConfig.linuxFxVersion) {
        Write-Host "  Linux Runtime: $($sourceConfig.linuxFxVersion)" -ForegroundColor Gray
    }
    Write-Host ""
}

# ============================================================================
# CONFIRM AND APPLY CHANGES
# ============================================================================

$totalChanges = $settingsToAdd.Count + $settingsToUpdate.Count + $connStrToAdd.Count + $connStrToUpdate.Count
if ($IncludeGeneralConfig) { $totalChanges++ }

if ($totalChanges -eq 0) {
    Write-Host "No changes to apply. Target app settings are already in sync." -ForegroundColor Green
    exit 0
}

if ($WhatIf) {
    Write-Host "=" * 60 -ForegroundColor Yellow
    Write-Host "WHATIF: The above changes would be applied." -ForegroundColor Yellow
    Write-Host "Run without --whatif to apply changes." -ForegroundColor Yellow
    Write-Host "=" * 60 -ForegroundColor Yellow
    exit 0
}

# Confirm if not --force
if (-not $Force -and ($settingsToUpdate.Count -gt 0 -or $connStrToUpdate.Count -gt 0)) {
    Write-Host "=" * 60 -ForegroundColor Yellow
    Write-Host "WARNING: This will overwrite $($settingsToUpdate.Count + $connStrToUpdate.Count) existing setting(s)." -ForegroundColor Yellow
    Write-Host "=" * 60 -ForegroundColor Yellow
    Write-Host ""
    $confirm = Read-Host "Do you want to continue? (y/N)"
    if ($confirm -ne 'y' -and $confirm -ne 'Y') {
        Write-Host "Operation cancelled." -ForegroundColor Yellow
        exit 0
    }
    Write-Host ""
}

Write-Host "Applying changes..." -ForegroundColor Yellow
Write-Host ""

az account set --subscription $TargetSubscriptionId --only-show-errors 2>$null

# ============================================================================
# APPLY APP SETTINGS
# ============================================================================

$allSettingsToApply = $settingsToAdd + $settingsToUpdate

if ($allSettingsToApply.Count -gt 0) {
    Write-Host "Copying $($allSettingsToApply.Count) app setting(s)..." -ForegroundColor Yellow
    
    # Build settings string for az cli
    $settingsArgs = @()
    foreach ($setting in $allSettingsToApply) {
        # Escape special characters in values
        $value = $setting.value
        if ($value -eq $null) { $value = "" }
        $settingsArgs += "$($setting.name)=$value"
    }
    
    try {
        # Apply in batches if there are many settings
        $batchSize = 20
        for ($i = 0; $i -lt $settingsArgs.Count; $i += $batchSize) {
            $batch = $settingsArgs[$i..[Math]::Min($i + $batchSize - 1, $settingsArgs.Count - 1)]
            $batchNum = [Math]::Floor($i / $batchSize) + 1
            $totalBatches = [Math]::Ceiling($settingsArgs.Count / $batchSize)
            
            Write-Host "  Applying batch $batchNum of $totalBatches..." -ForegroundColor Gray
            
            $result = az webapp config appsettings set --name $TargetAppName --resource-group $TargetResourceGroup --settings $batch --only-show-errors 2>&1
            if ($LASTEXITCODE -ne 0) {
                Write-Host "  ERROR: Failed to apply app settings batch $batchNum" -ForegroundColor Red
                Write-Host "  $result" -ForegroundColor Red
            }
        }
        Write-Host "  App settings applied successfully." -ForegroundColor Green
    }
    catch {
        Write-Host "  ERROR: Failed to apply app settings: $($_.Exception.Message)" -ForegroundColor Red
    }
}

# ============================================================================
# APPLY CONNECTION STRINGS
# ============================================================================

$allConnStrToApply = $connStrToAdd + $connStrToUpdate

if ($allConnStrToApply.Count -gt 0) {
    Write-Host ""
    Write-Host "Copying $($allConnStrToApply.Count) connection string(s)..." -ForegroundColor Yellow
    
    foreach ($connStr in $allConnStrToApply) {
        Write-Host "  Applying: $($connStr.Name)..." -ForegroundColor Gray
        
        try {
            $connStrSetting = "$($connStr.Name)=$($connStr.Value)"
            $result = az webapp config connection-string set --name $TargetAppName --resource-group $TargetResourceGroup `
                --connection-string-type $connStr.Type --settings $connStrSetting --only-show-errors 2>&1
            
            if ($LASTEXITCODE -ne 0) {
                Write-Host "    ERROR: Failed to apply connection string '$($connStr.Name)'" -ForegroundColor Red
            }
        }
        catch {
            Write-Host "    ERROR: $($_.Exception.Message)" -ForegroundColor Red
        }
    }
    Write-Host "  Connection strings applied." -ForegroundColor Green
}

# ============================================================================
# APPLY GENERAL CONFIG
# ============================================================================

if ($IncludeGeneralConfig -and $sourceConfig) {
    Write-Host ""
    Write-Host "Applying general configuration..." -ForegroundColor Yellow
    
    try {
        $configArgs = @(
            "--always-on", $(if ($sourceConfig.alwaysOn) { "true" } else { "false" }),
            "--http20-enabled", $(if ($sourceConfig.http20Enabled) { "true" } else { "false" }),
            "--min-tls-version", $sourceConfig.minTlsVersion,
            "--ftps-state", $sourceConfig.ftpsState,
            "--web-sockets-enabled", $(if ($sourceConfig.webSocketsEnabled) { "true" } else { "false" })
        )
        
        $result = az webapp config set --name $TargetAppName --resource-group $TargetResourceGroup @configArgs --only-show-errors 2>&1
        
        if ($LASTEXITCODE -ne 0) {
            Write-Host "  WARNING: Some general config settings may not have been applied." -ForegroundColor Yellow
            Write-Host "  $result" -ForegroundColor Gray
        } else {
            Write-Host "  General configuration applied." -ForegroundColor Green
        }
        
        # Apply Linux runtime stack separately if present
        if ($sourceConfig.linuxFxVersion) {
            Write-Host "  Setting Linux runtime: $($sourceConfig.linuxFxVersion)..." -ForegroundColor Gray
            $result = az webapp config set --name $TargetAppName --resource-group $TargetResourceGroup `
                --linux-fx-version $sourceConfig.linuxFxVersion --only-show-errors 2>&1
            
            if ($LASTEXITCODE -ne 0) {
                Write-Host "  WARNING: Could not set Linux runtime stack." -ForegroundColor Yellow
            }
        }
    }
    catch {
        Write-Host "  ERROR: Failed to apply general configuration: $($_.Exception.Message)" -ForegroundColor Red
    }
}

# ============================================================================
# SUMMARY
# ============================================================================

Write-Host ""
Write-Host "=" * 60 -ForegroundColor Green
Write-Host "COPY COMPLETED" -ForegroundColor Green
Write-Host "=" * 60 -ForegroundColor Green
Write-Host ""
Write-Host "Summary:" -ForegroundColor White
Write-Host "  App settings copied: $($allSettingsToApply.Count)" -ForegroundColor Gray
if ($IncludeConnectionStrings) {
    Write-Host "  Connection strings copied: $($allConnStrToApply.Count)" -ForegroundColor Gray
}
if ($IncludeGeneralConfig) {
    Write-Host "  General configuration: Applied" -ForegroundColor Gray
}
Write-Host ""
Write-Host "Target app: https://$($targetApp.defaultHostName)" -ForegroundColor Cyan
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Yellow
Write-Host "  1. Verify the settings in Azure Portal or using:" -ForegroundColor Gray
Write-Host "     az webapp config appsettings list --name $TargetAppName --resource-group $TargetResourceGroup" -ForegroundColor Gray
Write-Host "  2. Test the target application" -ForegroundColor Gray
Write-Host "  3. Run Compare-AppServiceApps.ps1 to verify completeness" -ForegroundColor Gray
Write-Host ""
