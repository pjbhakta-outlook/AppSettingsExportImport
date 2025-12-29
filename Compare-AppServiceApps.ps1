# Compare-AppServiceApps.ps1
# Compares source and target App Service apps to verify migration completeness.
# Generates a detailed report showing matches, differences, and missing items.

[CmdletBinding(PositionalBinding=$false)]
param(
    [string]$TenantId,
    [string]$SourceSubscriptionId,
    [string]$SourceResourceGroup,
    [string]$SourceAppName,
    [string]$TargetSubscriptionId,
    [string]$TargetResourceGroup,
    [string]$TargetAppName,
    [string]$CsvFile,
    [string]$OutputFile,
    [switch]$Json,
    [switch]$IgnoreValues,
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
            '--csv' { if ($i + 1 -lt $cliArgs.Count) { $CsvFile = $cliArgs[$i + 1] } }
            '--output' { if ($i + 1 -lt $cliArgs.Count) { $OutputFile = $cliArgs[$i + 1] } }
            '--json' { $Json = $true }
            '--ignore-values' { $IgnoreValues = $true }
        }
    }
}

function Show-Usage {
    Write-Host ""
    Write-Host "Compare-AppServiceApps.ps1" -ForegroundColor Cyan
    Write-Host "===========================" -ForegroundColor Cyan
    Write-Host "Compares source and target App Service apps to verify migration completeness."
    Write-Host ""
    Write-Host "Usage (Single App):" -ForegroundColor Yellow
    Write-Host "  .\Compare-AppServiceApps.ps1 --tenant <tenantId> \"
    Write-Host "    --source-subscription <subId> --source-resource-group <rg> --source-app <app> \"
    Write-Host "    --target-subscription <subId> --target-resource-group <rg> --target-app <app>"
    Write-Host ""
    Write-Host "Usage (From CSV):" -ForegroundColor Yellow
    Write-Host "  .\Compare-AppServiceApps.ps1 --tenant <tenantId> --csv <migrationFile.csv>"
    Write-Host ""
    Write-Host "Parameters:" -ForegroundColor Yellow
    Write-Host "  --tenant              : (Required) Azure Tenant ID" -ForegroundColor Gray
    Write-Host "  --source-subscription : Source subscription ID" -ForegroundColor Gray
    Write-Host "  --source-resource-group: Source resource group" -ForegroundColor Gray
    Write-Host "  --source-app          : Source app name" -ForegroundColor Gray
    Write-Host "  --target-subscription : Target subscription ID" -ForegroundColor Gray
    Write-Host "  --target-resource-group: Target resource group" -ForegroundColor Gray
    Write-Host "  --target-app          : Target app name" -ForegroundColor Gray
    Write-Host "  --csv                 : Migration CSV file (compares all successful migrations)" -ForegroundColor Gray
    Write-Host "  --output              : Output file path (default: scans/AppComparison-<timestamp>.txt)" -ForegroundColor Gray
    Write-Host "  --json                : Also export as JSON file" -ForegroundColor Gray
    Write-Host "  --ignore-values       : Only check if settings exist, not their values" -ForegroundColor Gray
    Write-Host ""
    Write-Host "What Gets Compared:" -ForegroundColor Yellow
    Write-Host "  - App Settings (names and values)" -ForegroundColor Gray
    Write-Host "  - Connection Strings (names and types)" -ForegroundColor Gray
    Write-Host "  - General Configuration (AlwaysOn, TLS, HTTP/2, etc.)" -ForegroundColor Gray
    Write-Host "  - Custom Domains" -ForegroundColor Gray
    Write-Host "  - SSL Certificates" -ForegroundColor Gray
    Write-Host "  - Managed Identities" -ForegroundColor Gray
    Write-Host "  - VNet Integration" -ForegroundColor Gray
    Write-Host "  - Authentication Settings" -ForegroundColor Gray
    Write-Host "  - CORS Allowed Origins" -ForegroundColor Gray
    Write-Host "  - Deployment Slots" -ForegroundColor Gray
    Write-Host "  - IP Restrictions" -ForegroundColor Gray
    Write-Host ""
    Write-Host "Examples:" -ForegroundColor Yellow
    Write-Host "  # Compare a single app pair"
    Write-Host "  .\Compare-AppServiceApps.ps1 --tenant <tenantId> \"
    Write-Host "    --source-subscription <subId> --source-resource-group rg-old --source-app MyApp \"
    Write-Host "    --target-subscription <subId> --target-resource-group rg-new --target-app MyApp-new"
    Write-Host ""
    Write-Host "  # Compare all apps from a migration CSV"
    Write-Host "  .\Compare-AppServiceApps.ps1 --tenant <tenantId> --csv .\scans\AppMigration.csv"
    Write-Host ""
}

if (-not $TenantId) {
    Show-Usage
    exit 1
}

# Validate parameters
$singleAppMode = $SourceAppName -and $SourceResourceGroup -and $TargetAppName -and $TargetResourceGroup
$csvMode = -not [string]::IsNullOrEmpty($CsvFile)

if (-not $singleAppMode -and -not $csvMode) {
    Write-Host "ERROR: Either specify source/target app parameters or provide a CSV file." -ForegroundColor Red
    Show-Usage
    exit 1
}

$ErrorActionPreference = 'Stop'

# ============================================================================
# COMPARISON RESULT CLASSES
# ============================================================================

class ComparisonItem {
    [string]$Category
    [string]$Item
    [string]$Status  # Match, Missing, Different, Extra
    [string]$SourceValue
    [string]$TargetValue
    [string]$Notes
}

class AppComparison {
    [string]$SourceApp
    [string]$SourceResourceGroup
    [string]$SourceSubscription
    [string]$TargetApp
    [string]$TargetResourceGroup
    [string]$TargetSubscription
    [datetime]$ComparedAt
    [System.Collections.Generic.List[ComparisonItem]]$Items
    [int]$MatchCount
    [int]$MissingCount
    [int]$DifferentCount
    [int]$ExtraCount
    [bool]$ReadyForProduction
    [System.Collections.Generic.List[string]]$Warnings
    [System.Collections.Generic.List[string]]$Blockers
    
    AppComparison() {
        $this.Items = [System.Collections.Generic.List[ComparisonItem]]::new()
        $this.Warnings = [System.Collections.Generic.List[string]]::new()
        $this.Blockers = [System.Collections.Generic.List[string]]::new()
        $this.ComparedAt = Get-Date
    }
    
    [void]AddItem([string]$Category, [string]$Item, [string]$Status, [string]$SourceValue, [string]$TargetValue, [string]$Notes) {
        $compItem = [ComparisonItem]::new()
        $compItem.Category = $Category
        $compItem.Item = $Item
        $compItem.Status = $Status
        $compItem.SourceValue = $SourceValue
        $compItem.TargetValue = $TargetValue
        $compItem.Notes = $Notes
        $this.Items.Add($compItem)
        
        switch ($Status) {
            'Match' { $this.MatchCount++ }
            'Missing' { $this.MissingCount++ }
            'Different' { $this.DifferentCount++ }
            'Extra' { $this.ExtraCount++ }
        }
    }
}

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

function Get-AppSettings {
    param([string]$AppName, [string]$ResourceGroup)
    
    $settingsJson = az webapp config appsettings list --name $AppName --resource-group $ResourceGroup --only-show-errors 2>$null
    if ($settingsJson) {
        return $settingsJson | ConvertFrom-Json
    }
    return @()
}

function Get-ConnectionStrings {
    param([string]$AppName, [string]$ResourceGroup)
    
    $connJson = az webapp config connection-string list --name $AppName --resource-group $ResourceGroup --only-show-errors 2>$null
    if ($connJson) {
        $conn = $connJson | ConvertFrom-Json
        $result = @()
        foreach ($prop in $conn.PSObject.Properties) {
            $result += [PSCustomObject]@{
                Name = $prop.Name
                Type = $prop.Value.type
                Value = $prop.Value.value
            }
        }
        return $result
    }
    return @()
}

function Get-GeneralConfig {
    param([string]$AppName, [string]$ResourceGroup)
    
    $configJson = az webapp config show --name $AppName --resource-group $ResourceGroup --only-show-errors 2>$null
    if ($configJson) {
        return $configJson | ConvertFrom-Json
    }
    return $null
}

function Get-CustomDomains {
    param([string]$AppName, [string]$ResourceGroup)
    
    $hostnamesJson = az webapp config hostname list --webapp-name $AppName --resource-group $ResourceGroup --only-show-errors 2>$null
    if ($hostnamesJson) {
        $hostnames = $hostnamesJson | ConvertFrom-Json
        return $hostnames | Where-Object { $_.name -notlike "*.azurewebsites.net" }
    }
    return @()
}

function Get-ManagedIdentity {
    param([string]$AppName, [string]$ResourceGroup)
    
    $identityJson = az webapp identity show --name $AppName --resource-group $ResourceGroup --only-show-errors 2>$null
    if ($identityJson) {
        return $identityJson | ConvertFrom-Json
    }
    return $null
}

function Get-VNetIntegration {
    param([string]$AppName, [string]$ResourceGroup)
    
    $vnetJson = az webapp vnet-integration list --name $AppName --resource-group $ResourceGroup --only-show-errors 2>$null
    if ($vnetJson) {
        return $vnetJson | ConvertFrom-Json
    }
    return @()
}

function Get-AuthSettings {
    param([string]$AppName, [string]$ResourceGroup)
    
    $authJson = az webapp auth show --name $AppName --resource-group $ResourceGroup --only-show-errors 2>$null
    if ($authJson) {
        return $authJson | ConvertFrom-Json
    }
    return $null
}

function Get-CorsSettings {
    param([string]$AppName, [string]$ResourceGroup)
    
    $corsJson = az webapp cors show --name $AppName --resource-group $ResourceGroup --only-show-errors 2>$null
    if ($corsJson) {
        $cors = $corsJson | ConvertFrom-Json
        return $cors.allowedOrigins
    }
    return @()
}

function Get-DeploymentSlots {
    param([string]$AppName, [string]$ResourceGroup)
    
    $slotsJson = az webapp deployment slot list --name $AppName --resource-group $ResourceGroup --only-show-errors 2>$null
    if ($slotsJson) {
        return $slotsJson | ConvertFrom-Json
    }
    return @()
}

function Get-IPRestrictions {
    param([string]$AppName, [string]$ResourceGroup)
    
    $accessJson = az webapp config access-restriction show --name $AppName --resource-group $ResourceGroup --only-show-errors 2>$null
    if ($accessJson) {
        $access = $accessJson | ConvertFrom-Json
        return $access.ipSecurityRestrictions | Where-Object { $_.name -ne "Allow all" -and $_.ipAddress -ne "Any" }
    }
    return @()
}

function Compare-Apps {
    param(
        [string]$SourceSubscriptionId,
        [string]$SourceResourceGroup,
        [string]$SourceAppName,
        [string]$TargetSubscriptionId,
        [string]$TargetResourceGroup,
        [string]$TargetAppName,
        [bool]$IgnoreValues
    )
    
    $comparison = [AppComparison]::new()
    $comparison.SourceApp = $SourceAppName
    $comparison.SourceResourceGroup = $SourceResourceGroup
    $comparison.SourceSubscription = $SourceSubscriptionId
    $comparison.TargetApp = $TargetAppName
    $comparison.TargetResourceGroup = $TargetResourceGroup
    $comparison.TargetSubscription = $TargetSubscriptionId
    
    Write-Host ""
    Write-Host "Comparing: $SourceAppName -> $TargetAppName" -ForegroundColor Cyan
    
    # ========== APP SETTINGS ==========
    Write-Host "  Comparing app settings..." -ForegroundColor Gray
    
    az account set --subscription $SourceSubscriptionId --only-show-errors 2>$null
    $sourceSettings = Get-AppSettings -AppName $SourceAppName -ResourceGroup $SourceResourceGroup
    
    az account set --subscription $TargetSubscriptionId --only-show-errors 2>$null
    $targetSettings = Get-AppSettings -AppName $TargetAppName -ResourceGroup $TargetResourceGroup
    
    $sourceSettingsHash = @{}
    $targetSettingsHash = @{}
    
    foreach ($setting in $sourceSettings) {
        $sourceSettingsHash[$setting.name] = $setting.value
    }
    foreach ($setting in $targetSettings) {
        $targetSettingsHash[$setting.name] = $setting.value
    }
    
    # Check source settings exist in target
    foreach ($name in $sourceSettingsHash.Keys) {
        if ($targetSettingsHash.ContainsKey($name)) {
            if ($IgnoreValues -or $sourceSettingsHash[$name] -eq $targetSettingsHash[$name]) {
                $comparison.AddItem("App Settings", $name, "Match", "(value hidden)", "(value hidden)", "")
            } else {
                $comparison.AddItem("App Settings", $name, "Different", "(source value)", "(target value)", "Values differ")
                $comparison.Warnings.Add("App setting '$name' has different value on target")
            }
        } else {
            $comparison.AddItem("App Settings", $name, "Missing", "(exists)", "(not found)", "Setting not on target")
            $comparison.Blockers.Add("App setting '$name' is missing on target")
        }
    }
    
    # Check for extra settings on target
    foreach ($name in $targetSettingsHash.Keys) {
        if (-not $sourceSettingsHash.ContainsKey($name)) {
            $comparison.AddItem("App Settings", $name, "Extra", "(not on source)", "(exists)", "Additional setting on target")
        }
    }
    
    # ========== CONNECTION STRINGS ==========
    Write-Host "  Comparing connection strings..." -ForegroundColor Gray
    
    az account set --subscription $SourceSubscriptionId --only-show-errors 2>$null
    $sourceConnStr = Get-ConnectionStrings -AppName $SourceAppName -ResourceGroup $SourceResourceGroup
    
    az account set --subscription $TargetSubscriptionId --only-show-errors 2>$null
    $targetConnStr = Get-ConnectionStrings -AppName $TargetAppName -ResourceGroup $TargetResourceGroup
    
    $sourceConnHash = @{}
    $targetConnHash = @{}
    
    foreach ($conn in $sourceConnStr) {
        $sourceConnHash[$conn.Name] = $conn
    }
    foreach ($conn in $targetConnStr) {
        $targetConnHash[$conn.Name] = $conn
    }
    
    foreach ($name in $sourceConnHash.Keys) {
        if ($targetConnHash.ContainsKey($name)) {
            $sourceConn = $sourceConnHash[$name]
            $targetConn = $targetConnHash[$name]
            if ($sourceConn.Type -eq $targetConn.Type) {
                $comparison.AddItem("Connection Strings", $name, "Match", $sourceConn.Type, $targetConn.Type, "")
            } else {
                $comparison.AddItem("Connection Strings", $name, "Different", $sourceConn.Type, $targetConn.Type, "Type mismatch")
                $comparison.Warnings.Add("Connection string '$name' has different type")
            }
        } else {
            $comparison.AddItem("Connection Strings", $name, "Missing", "(exists)", "(not found)", "")
            $comparison.Blockers.Add("Connection string '$name' is missing on target")
        }
    }
    
    foreach ($name in $targetConnHash.Keys) {
        if (-not $sourceConnHash.ContainsKey($name)) {
            $comparison.AddItem("Connection Strings", $name, "Extra", "(not on source)", "(exists)", "Additional on target")
        }
    }
    
    # ========== GENERAL CONFIGURATION ==========
    Write-Host "  Comparing general configuration..." -ForegroundColor Gray
    
    az account set --subscription $SourceSubscriptionId --only-show-errors 2>$null
    $sourceConfig = Get-GeneralConfig -AppName $SourceAppName -ResourceGroup $SourceResourceGroup
    
    az account set --subscription $TargetSubscriptionId --only-show-errors 2>$null
    $targetConfig = Get-GeneralConfig -AppName $TargetAppName -ResourceGroup $TargetResourceGroup
    
    if ($sourceConfig -and $targetConfig) {
        # AlwaysOn
        $sourceAlwaysOn = if ($sourceConfig.alwaysOn) { "Enabled" } else { "Disabled" }
        $targetAlwaysOn = if ($targetConfig.alwaysOn) { "Enabled" } else { "Disabled" }
        if ($sourceAlwaysOn -eq $targetAlwaysOn) {
            $comparison.AddItem("Configuration", "AlwaysOn", "Match", $sourceAlwaysOn, $targetAlwaysOn, "")
        } else {
            $comparison.AddItem("Configuration", "AlwaysOn", "Different", $sourceAlwaysOn, $targetAlwaysOn, "")
            $comparison.Warnings.Add("AlwaysOn setting differs")
        }
        
        # HTTP/2
        $sourceHttp2 = if ($sourceConfig.http20Enabled) { "Enabled" } else { "Disabled" }
        $targetHttp2 = if ($targetConfig.http20Enabled) { "Enabled" } else { "Disabled" }
        if ($sourceHttp2 -eq $targetHttp2) {
            $comparison.AddItem("Configuration", "HTTP/2", "Match", $sourceHttp2, $targetHttp2, "")
        } else {
            $comparison.AddItem("Configuration", "HTTP/2", "Different", $sourceHttp2, $targetHttp2, "")
        }
        
        # Min TLS Version
        $sourceTls = $sourceConfig.minTlsVersion
        $targetTls = $targetConfig.minTlsVersion
        if ($sourceTls -eq $targetTls) {
            $comparison.AddItem("Configuration", "Min TLS Version", "Match", $sourceTls, $targetTls, "")
        } else {
            $comparison.AddItem("Configuration", "Min TLS Version", "Different", $sourceTls, $targetTls, "")
            $comparison.Warnings.Add("TLS version differs")
        }
        
        # FTPS State
        $sourceFtps = $sourceConfig.ftpsState
        $targetFtps = $targetConfig.ftpsState
        if ($sourceFtps -eq $targetFtps) {
            $comparison.AddItem("Configuration", "FTPS State", "Match", $sourceFtps, $targetFtps, "")
        } else {
            $comparison.AddItem("Configuration", "FTPS State", "Different", $sourceFtps, $targetFtps, "")
        }
        
        # WebSockets
        $sourceWs = if ($sourceConfig.webSocketsEnabled) { "Enabled" } else { "Disabled" }
        $targetWs = if ($targetConfig.webSocketsEnabled) { "Enabled" } else { "Disabled" }
        if ($sourceWs -eq $targetWs) {
            $comparison.AddItem("Configuration", "WebSockets", "Match", $sourceWs, $targetWs, "")
        } else {
            $comparison.AddItem("Configuration", "WebSockets", "Different", $sourceWs, $targetWs, "")
        }
        
        # Linux Fx Version (runtime)
        if ($sourceConfig.linuxFxVersion -or $targetConfig.linuxFxVersion) {
            $sourceRuntime = if ($sourceConfig.linuxFxVersion) { $sourceConfig.linuxFxVersion } else { "(not set)" }
            $targetRuntime = if ($targetConfig.linuxFxVersion) { $targetConfig.linuxFxVersion } else { "(not set)" }
            if ($sourceRuntime -eq $targetRuntime) {
                $comparison.AddItem("Configuration", "Runtime Stack", "Match", $sourceRuntime, $targetRuntime, "")
            } else {
                $comparison.AddItem("Configuration", "Runtime Stack", "Different", $sourceRuntime, $targetRuntime, "")
                $comparison.Warnings.Add("Runtime stack differs: $sourceRuntime vs $targetRuntime")
            }
        }
    }
    
    # ========== CUSTOM DOMAINS ==========
    Write-Host "  Comparing custom domains..." -ForegroundColor Gray
    
    az account set --subscription $SourceSubscriptionId --only-show-errors 2>$null
    $sourceDomains = Get-CustomDomains -AppName $SourceAppName -ResourceGroup $SourceResourceGroup
    
    az account set --subscription $TargetSubscriptionId --only-show-errors 2>$null
    $targetDomains = Get-CustomDomains -AppName $TargetAppName -ResourceGroup $TargetResourceGroup
    
    $sourceDomainsHash = @{}
    $targetDomainsHash = @{}
    
    foreach ($domain in $sourceDomains) {
        $sourceDomainsHash[$domain.name] = $domain
    }
    foreach ($domain in $targetDomains) {
        $targetDomainsHash[$domain.name] = $domain
    }
    
    foreach ($name in $sourceDomainsHash.Keys) {
        if ($targetDomainsHash.ContainsKey($name)) {
            $sourceSsl = $sourceDomainsHash[$name].sslState
            $targetSsl = $targetDomainsHash[$name].sslState
            if ($sourceSsl -eq $targetSsl) {
                $comparison.AddItem("Custom Domains", $name, "Match", "SSL: $sourceSsl", "SSL: $targetSsl", "")
            } else {
                $comparison.AddItem("Custom Domains", $name, "Different", "SSL: $sourceSsl", "SSL: $targetSsl", "SSL state differs")
                $comparison.Warnings.Add("Domain '$name' has different SSL state")
            }
        } else {
            $comparison.AddItem("Custom Domains", $name, "Missing", "(exists)", "(not configured)", "Domain not on target")
            $comparison.Warnings.Add("Custom domain '$name' not configured on target (may be intentional for cutover)")
        }
    }
    
    foreach ($name in $targetDomainsHash.Keys) {
        if (-not $sourceDomainsHash.ContainsKey($name)) {
            $comparison.AddItem("Custom Domains", $name, "Extra", "(not on source)", "(exists)", "Additional domain on target")
        }
    }
    
    # ========== MANAGED IDENTITY ==========
    Write-Host "  Comparing managed identity..." -ForegroundColor Gray
    
    az account set --subscription $SourceSubscriptionId --only-show-errors 2>$null
    $sourceIdentity = Get-ManagedIdentity -AppName $SourceAppName -ResourceGroup $SourceResourceGroup
    
    az account set --subscription $TargetSubscriptionId --only-show-errors 2>$null
    $targetIdentity = Get-ManagedIdentity -AppName $TargetAppName -ResourceGroup $TargetResourceGroup
    
    $sourceHasSystemIdentity = $sourceIdentity -and $sourceIdentity.principalId
    $targetHasSystemIdentity = $targetIdentity -and $targetIdentity.principalId
    
    if ($sourceHasSystemIdentity -and $targetHasSystemIdentity) {
        $comparison.AddItem("Managed Identity", "System-Assigned", "Match", "Enabled", "Enabled", "Check RBAC assignments")
        $comparison.Warnings.Add("Verify RBAC role assignments for target managed identity")
    } elseif ($sourceHasSystemIdentity -and -not $targetHasSystemIdentity) {
        $comparison.AddItem("Managed Identity", "System-Assigned", "Missing", "Enabled", "Disabled", "Identity not enabled")
        $comparison.Blockers.Add("System-assigned managed identity not enabled on target")
    } elseif (-not $sourceHasSystemIdentity -and $targetHasSystemIdentity) {
        $comparison.AddItem("Managed Identity", "System-Assigned", "Extra", "Disabled", "Enabled", "")
    } else {
        $comparison.AddItem("Managed Identity", "System-Assigned", "Match", "Disabled", "Disabled", "")
    }
    
    # User-assigned identities
    $sourceUserIds = if ($sourceIdentity -and $sourceIdentity.userAssignedIdentities) { 
        $sourceIdentity.userAssignedIdentities.PSObject.Properties.Name 
    } else { @() }
    $targetUserIds = if ($targetIdentity -and $targetIdentity.userAssignedIdentities) { 
        $targetIdentity.userAssignedIdentities.PSObject.Properties.Name 
    } else { @() }
    
    foreach ($id in $sourceUserIds) {
        $idName = ($id -split '/')[-1]
        if ($targetUserIds -contains $id) {
            $comparison.AddItem("Managed Identity", "User-Assigned: $idName", "Match", "(assigned)", "(assigned)", "")
        } else {
            $comparison.AddItem("Managed Identity", "User-Assigned: $idName", "Missing", "(assigned)", "(not assigned)", "")
            $comparison.Blockers.Add("User-assigned identity '$idName' not assigned to target")
        }
    }
    
    # ========== VNET INTEGRATION ==========
    Write-Host "  Comparing VNet integration..." -ForegroundColor Gray
    
    az account set --subscription $SourceSubscriptionId --only-show-errors 2>$null
    $sourceVNet = Get-VNetIntegration -AppName $SourceAppName -ResourceGroup $SourceResourceGroup
    
    az account set --subscription $TargetSubscriptionId --only-show-errors 2>$null
    $targetVNet = Get-VNetIntegration -AppName $TargetAppName -ResourceGroup $TargetResourceGroup
    
    $sourceHasVNet = $sourceVNet -and $sourceVNet.Count -gt 0
    $targetHasVNet = $targetVNet -and $targetVNet.Count -gt 0
    
    if ($sourceHasVNet -and $targetHasVNet) {
        $sourceSubnet = ($sourceVNet[0].vnetResourceId -split '/')[-1]
        $targetSubnet = ($targetVNet[0].vnetResourceId -split '/')[-1]
        $comparison.AddItem("VNet Integration", "Subnet", "Match", $sourceSubnet, $targetSubnet, "Verify subnet configuration")
    } elseif ($sourceHasVNet -and -not $targetHasVNet) {
        $sourceSubnet = ($sourceVNet[0].vnetResourceId -split '/')[-1]
        $comparison.AddItem("VNet Integration", "Subnet", "Missing", $sourceSubnet, "(not configured)", "")
        $comparison.Blockers.Add("VNet integration not configured on target")
    } elseif (-not $sourceHasVNet -and $targetHasVNet) {
        $targetSubnet = ($targetVNet[0].vnetResourceId -split '/')[-1]
        $comparison.AddItem("VNet Integration", "Subnet", "Extra", "(not configured)", $targetSubnet, "")
    } else {
        $comparison.AddItem("VNet Integration", "Status", "Match", "Not configured", "Not configured", "")
    }
    
    # ========== AUTHENTICATION ==========
    Write-Host "  Comparing authentication..." -ForegroundColor Gray
    
    az account set --subscription $SourceSubscriptionId --only-show-errors 2>$null
    $sourceAuth = Get-AuthSettings -AppName $SourceAppName -ResourceGroup $SourceResourceGroup
    
    az account set --subscription $TargetSubscriptionId --only-show-errors 2>$null
    $targetAuth = Get-AuthSettings -AppName $TargetAppName -ResourceGroup $TargetResourceGroup
    
    $sourceAuthEnabled = $sourceAuth -and ($sourceAuth.enabled -eq $true -or ($sourceAuth.platform -and $sourceAuth.platform.enabled -eq $true))
    $targetAuthEnabled = $targetAuth -and ($targetAuth.enabled -eq $true -or ($targetAuth.platform -and $targetAuth.platform.enabled -eq $true))
    
    if ($sourceAuthEnabled -and $targetAuthEnabled) {
        $comparison.AddItem("Authentication", "Easy Auth", "Match", "Enabled", "Enabled", "Verify provider configuration")
        $comparison.Warnings.Add("Verify authentication provider settings and redirect URIs")
    } elseif ($sourceAuthEnabled -and -not $targetAuthEnabled) {
        $comparison.AddItem("Authentication", "Easy Auth", "Missing", "Enabled", "Disabled", "")
        $comparison.Blockers.Add("Authentication not configured on target")
    } elseif (-not $sourceAuthEnabled -and $targetAuthEnabled) {
        $comparison.AddItem("Authentication", "Easy Auth", "Extra", "Disabled", "Enabled", "")
    } else {
        $comparison.AddItem("Authentication", "Easy Auth", "Match", "Disabled", "Disabled", "")
    }
    
    # ========== CORS ==========
    Write-Host "  Comparing CORS settings..." -ForegroundColor Gray
    
    az account set --subscription $SourceSubscriptionId --only-show-errors 2>$null
    $sourceCors = Get-CorsSettings -AppName $SourceAppName -ResourceGroup $SourceResourceGroup
    
    az account set --subscription $TargetSubscriptionId --only-show-errors 2>$null
    $targetCors = Get-CorsSettings -AppName $TargetAppName -ResourceGroup $TargetResourceGroup
    
    if (-not $sourceCors) { $sourceCors = @() }
    if (-not $targetCors) { $targetCors = @() }
    
    foreach ($origin in $sourceCors) {
        if ($targetCors -contains $origin) {
            $comparison.AddItem("CORS", $origin, "Match", "(allowed)", "(allowed)", "")
        } else {
            $comparison.AddItem("CORS", $origin, "Missing", "(allowed)", "(not allowed)", "")
            $comparison.Warnings.Add("CORS origin '$origin' not configured on target")
        }
    }
    
    foreach ($origin in $targetCors) {
        if ($sourceCors -notcontains $origin) {
            $comparison.AddItem("CORS", $origin, "Extra", "(not on source)", "(allowed)", "")
        }
    }
    
    # ========== DEPLOYMENT SLOTS ==========
    Write-Host "  Comparing deployment slots..." -ForegroundColor Gray
    
    az account set --subscription $SourceSubscriptionId --only-show-errors 2>$null
    $sourceSlots = Get-DeploymentSlots -AppName $SourceAppName -ResourceGroup $SourceResourceGroup
    
    az account set --subscription $TargetSubscriptionId --only-show-errors 2>$null
    $targetSlots = Get-DeploymentSlots -AppName $TargetAppName -ResourceGroup $TargetResourceGroup
    
    $sourceSlotNames = @($sourceSlots | ForEach-Object { ($_.name -split '/')[-1] })
    $targetSlotNames = @($targetSlots | ForEach-Object { ($_.name -split '/')[-1] })
    
    foreach ($slot in $sourceSlotNames) {
        if ($targetSlotNames -contains $slot) {
            $comparison.AddItem("Deployment Slots", $slot, "Match", "(exists)", "(exists)", "")
        } else {
            $comparison.AddItem("Deployment Slots", $slot, "Missing", "(exists)", "(not created)", "")
            $comparison.Warnings.Add("Deployment slot '$slot' not created on target")
        }
    }
    
    foreach ($slot in $targetSlotNames) {
        if ($sourceSlotNames -notcontains $slot) {
            $comparison.AddItem("Deployment Slots", $slot, "Extra", "(not on source)", "(exists)", "")
        }
    }
    
    # ========== IP RESTRICTIONS ==========
    Write-Host "  Comparing IP restrictions..." -ForegroundColor Gray
    
    az account set --subscription $SourceSubscriptionId --only-show-errors 2>$null
    $sourceIpRules = Get-IPRestrictions -AppName $SourceAppName -ResourceGroup $SourceResourceGroup
    
    az account set --subscription $TargetSubscriptionId --only-show-errors 2>$null
    $targetIpRules = Get-IPRestrictions -AppName $TargetAppName -ResourceGroup $TargetResourceGroup
    
    if (-not $sourceIpRules) { $sourceIpRules = @() }
    if (-not $targetIpRules) { $targetIpRules = @() }
    
    $sourceRuleNames = @($sourceIpRules | ForEach-Object { $_.name })
    $targetRuleNames = @($targetIpRules | ForEach-Object { $_.name })
    
    foreach ($rule in $sourceIpRules) {
        $matchingRule = $targetIpRules | Where-Object { $_.name -eq $rule.name }
        if ($matchingRule) {
            if ($rule.ipAddress -eq $matchingRule.ipAddress -and $rule.action -eq $matchingRule.action) {
                $comparison.AddItem("IP Restrictions", $rule.name, "Match", "$($rule.action): $($rule.ipAddress)", "$($matchingRule.action): $($matchingRule.ipAddress)", "")
            } else {
                $comparison.AddItem("IP Restrictions", $rule.name, "Different", "$($rule.action): $($rule.ipAddress)", "$($matchingRule.action): $($matchingRule.ipAddress)", "Rule differs")
                $comparison.Warnings.Add("IP restriction '$($rule.name)' differs on target")
            }
        } else {
            $comparison.AddItem("IP Restrictions", $rule.name, "Missing", "$($rule.action): $($rule.ipAddress)", "(not configured)", "")
            $comparison.Warnings.Add("IP restriction '$($rule.name)' not configured on target")
        }
    }
    
    foreach ($rule in $targetIpRules) {
        if ($sourceRuleNames -notcontains $rule.name) {
            $comparison.AddItem("IP Restrictions", $rule.name, "Extra", "(not on source)", "$($rule.action): $($rule.ipAddress)", "")
        }
    }
    
    # ========== DETERMINE PRODUCTION READINESS ==========
    $comparison.ReadyForProduction = $comparison.Blockers.Count -eq 0
    
    return $comparison
}

function Format-ComparisonReport {
    param([AppComparison]$Comparison)
    
    $output = @()
    
    $output += ""
    $output += "=" * 80
    $output += " APP COMPARISON REPORT"
    $output += " Generated: $($Comparison.ComparedAt.ToString('yyyy-MM-dd HH:mm:ss'))"
    $output += "=" * 80
    $output += ""
    $output += " SOURCE: $($Comparison.SourceApp)"
    $output += "   Subscription: $($Comparison.SourceSubscription)"
    $output += "   Resource Group: $($Comparison.SourceResourceGroup)"
    $output += ""
    $output += " TARGET: $($Comparison.TargetApp)"
    $output += "   Subscription: $($Comparison.TargetSubscription)"
    $output += "   Resource Group: $($Comparison.TargetResourceGroup)"
    $output += ""
    $output += "-" * 80
    $output += " SUMMARY"
    $output += "-" * 80
    $output += ""
    $output += "   [=] Matching Items:    $($Comparison.MatchCount)"
    $output += "   [!] Different Items:   $($Comparison.DifferentCount)"
    $output += "   [-] Missing on Target: $($Comparison.MissingCount)"
    $output += "   [+] Extra on Target:   $($Comparison.ExtraCount)"
    $output += ""
    
    if ($Comparison.ReadyForProduction) {
        $output += "   *** PRODUCTION READY: YES ***"
    } else {
        $output += "   *** PRODUCTION READY: NO - See blockers below ***"
    }
    
    # Blockers
    if ($Comparison.Blockers.Count -gt 0) {
        $output += ""
        $output += "-" * 80
        $output += " BLOCKERS (Must Fix Before Production)"
        $output += "-" * 80
        foreach ($blocker in $Comparison.Blockers) {
            $output += "   [X] $blocker"
        }
    }
    
    # Warnings
    if ($Comparison.Warnings.Count -gt 0) {
        $output += ""
        $output += "-" * 80
        $output += " WARNINGS (Review Before Production)"
        $output += "-" * 80
        foreach ($warning in $Comparison.Warnings) {
            $output += "   [!] $warning"
        }
    }
    
    # Detailed comparison by category
    $categories = $Comparison.Items | Group-Object Category
    
    foreach ($category in $categories) {
        $output += ""
        $output += "-" * 80
        $output += " $($category.Name.ToUpper())"
        $output += "-" * 80
        
        foreach ($item in $category.Group) {
            $statusIcon = switch ($item.Status) {
                'Match' { '[=]' }
                'Missing' { '[-]' }
                'Different' { '[!]' }
                'Extra' { '[+]' }
            }
            
            $line = "   $statusIcon $($item.Item)"
            if ($item.Status -ne 'Match' -or $item.SourceValue -ne "(value hidden)") {
                if ($item.SourceValue -and $item.TargetValue) {
                    $line += ": $($item.SourceValue) -> $($item.TargetValue)"
                }
            }
            if ($item.Notes) {
                $line += " ($($item.Notes))"
            }
            $output += $line
        }
    }
    
    # Action items
    $output += ""
    $output += "=" * 80
    $output += " ACTION ITEMS"
    $output += "=" * 80
    $output += ""
    
    $missingItems = $Comparison.Items | Where-Object { $_.Status -eq 'Missing' }
    $differentItems = $Comparison.Items | Where-Object { $_.Status -eq 'Different' }
    
    if ($missingItems.Count -eq 0 -and $differentItems.Count -eq 0) {
        $output += "   No action items - target app matches source configuration!"
    } else {
        $actionNum = 1
        
        foreach ($item in $missingItems) {
            $output += "   $actionNum. ADD $($item.Category): $($item.Item)"
            $actionNum++
        }
        
        foreach ($item in $differentItems) {
            $output += "   $actionNum. UPDATE $($item.Category): $($item.Item) to match source"
            $actionNum++
        }
    }
    
    $output += ""
    
    return $output
}

# ============================================================================
# MAIN SCRIPT
# ============================================================================

Write-Host ""
Write-Host "Compare-AppServiceApps" -ForegroundColor Cyan
Write-Host "=======================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Tenant: $TenantId" -ForegroundColor Gray
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

# Build list of app pairs to compare
$appPairs = @()

if ($csvMode) {
    Write-Host ""
    Write-Host "Loading migration CSV: $CsvFile" -ForegroundColor Yellow
    
    if (-not (Test-Path $CsvFile)) {
        Write-Host "  CSV file not found: $CsvFile" -ForegroundColor Red
        exit 1
    }
    
    $csvData = Import-Csv -Path $CsvFile
    
    # Filter to successful migrations
    $successfulMigrations = $csvData | Where-Object { 
        $_.ImportStatus -eq 'Success' -and 
        $_.NewAppName -and 
        $_.TargetResourceGroup -and
        $_.Skip -ne 'Yes'
    }
    
    if ($successfulMigrations.Count -eq 0) {
        Write-Host "  No successful migrations found in CSV." -ForegroundColor Yellow
        Write-Host "  Looking for apps with target configuration..." -ForegroundColor Yellow
        
        # Fall back to any rows with target info filled in
        $successfulMigrations = $csvData | Where-Object { 
            $_.NewAppName -and 
            $_.TargetResourceGroup -and
            $_.Skip -ne 'Yes'
        }
    }
    
    Write-Host "  Found $($successfulMigrations.Count) app pair(s) to compare" -ForegroundColor Green
    
    foreach ($row in $successfulMigrations) {
        $appPairs += [PSCustomObject]@{
            SourceSubscriptionId = $row.SourceSubscriptionId
            SourceResourceGroup = $row.SourceResourceGroup
            SourceAppName = $row.SourceAppName
            TargetSubscriptionId = if ($row.TargetSubscriptionId) { $row.TargetSubscriptionId } else { $row.SourceSubscriptionId }
            TargetResourceGroup = $row.TargetResourceGroup
            TargetAppName = $row.NewAppName
        }
    }
} else {
    # Single app mode
    $appPairs += [PSCustomObject]@{
        SourceSubscriptionId = if ($SourceSubscriptionId) { $SourceSubscriptionId } else { $currentAccount.id }
        SourceResourceGroup = $SourceResourceGroup
        SourceAppName = $SourceAppName
        TargetSubscriptionId = if ($TargetSubscriptionId) { $TargetSubscriptionId } else { $SourceSubscriptionId }
        TargetResourceGroup = $TargetResourceGroup
        TargetAppName = $TargetAppName
    }
}

# Compare all app pairs
$allComparisons = @()
$allOutputLines = @()

foreach ($pair in $appPairs) {
    $comparison = Compare-Apps `
        -SourceSubscriptionId $pair.SourceSubscriptionId `
        -SourceResourceGroup $pair.SourceResourceGroup `
        -SourceAppName $pair.SourceAppName `
        -TargetSubscriptionId $pair.TargetSubscriptionId `
        -TargetResourceGroup $pair.TargetResourceGroup `
        -TargetAppName $pair.TargetAppName `
        -IgnoreValues $IgnoreValues
    
    $allComparisons += $comparison
    
    $reportLines = Format-ComparisonReport -Comparison $comparison
    $allOutputLines += $reportLines
    
    # Display summary for this app
    Write-Host ""
    if ($comparison.ReadyForProduction) {
        Write-Host "  Result: READY FOR PRODUCTION" -ForegroundColor Green
    } else {
        Write-Host "  Result: NOT READY - $($comparison.Blockers.Count) blocker(s)" -ForegroundColor Red
    }
    Write-Host "    Matches: $($comparison.MatchCount) | Different: $($comparison.DifferentCount) | Missing: $($comparison.MissingCount) | Extra: $($comparison.ExtraCount)" -ForegroundColor Gray
}

# Overall summary
$totalReady = ($allComparisons | Where-Object { $_.ReadyForProduction }).Count
$totalNotReady = ($allComparisons | Where-Object { -not $_.ReadyForProduction }).Count

$summaryLines = @()
$summaryLines += ""
$summaryLines += "=" * 80
$summaryLines += " OVERALL COMPARISON SUMMARY"
$summaryLines += " Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
$summaryLines += "=" * 80
$summaryLines += ""
$summaryLines += " Total Apps Compared: $($allComparisons.Count)"
$summaryLines += " Ready for Production: $totalReady"
$summaryLines += " Not Ready: $totalNotReady"
$summaryLines += ""

if ($totalNotReady -gt 0) {
    $summaryLines += " Apps NOT Ready:"
    foreach ($comp in ($allComparisons | Where-Object { -not $_.ReadyForProduction })) {
        $summaryLines += "   - $($comp.TargetApp): $($comp.Blockers.Count) blocker(s)"
    }
    $summaryLines += ""
}

$allOutputLines = $summaryLines + $allOutputLines

# Output to console
foreach ($line in $allOutputLines) {
    if ($line -like "*BLOCKER*" -or $line -like "*[X]*" -or $line -like "*NOT READY*") {
        Write-Host $line -ForegroundColor Red
    } elseif ($line -like "*WARNING*" -or $line -like "*[!]*") {
        Write-Host $line -ForegroundColor Yellow
    } elseif ($line -like "*READY*" -or $line -like "*[=]*") {
        Write-Host $line -ForegroundColor Green
    } elseif ($line -like "*[-]*") {
        Write-Host $line -ForegroundColor Magenta
    } elseif ($line -like "*[+]*") {
        Write-Host $line -ForegroundColor Cyan
    } else {
        Write-Host $line
    }
}

# Save to file
$scansFolder = Join-Path -Path $PWD.Path -ChildPath 'scans'
if (-not (Test-Path -LiteralPath $scansFolder)) {
    $null = New-Item -ItemType Directory -Path $scansFolder -Force
}

if (-not $OutputFile) {
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $OutputFile = Join-Path -Path $scansFolder -ChildPath "AppComparison-$timestamp.txt"
}

$allOutputLines | Out-File -FilePath $OutputFile -Encoding UTF8

Write-Host ""
Write-Host "======================================" -ForegroundColor Green
Write-Host "COMPARISON COMPLETED" -ForegroundColor Green
Write-Host "======================================" -ForegroundColor Green
Write-Host ""
Write-Host "Report saved to: $OutputFile" -ForegroundColor Cyan

# Export JSON if requested
if ($Json) {
    $jsonFile = [System.IO.Path]::ChangeExtension($OutputFile, '.json')
    $allComparisons | ConvertTo-Json -Depth 10 | Out-File -FilePath $jsonFile -Encoding UTF8
    Write-Host "JSON saved to: $jsonFile" -ForegroundColor Cyan
}

Write-Host ""
Write-Host "Summary:" -ForegroundColor Yellow
Write-Host "  Apps Compared: $($allComparisons.Count)" -ForegroundColor Gray
Write-Host "  Ready for Production: $totalReady" -ForegroundColor $(if ($totalReady -eq $allComparisons.Count) { "Green" } else { "Yellow" })
Write-Host "  Not Ready: $totalNotReady" -ForegroundColor $(if ($totalNotReady -gt 0) { "Red" } else { "Green" })
Write-Host ""

if ($totalNotReady -gt 0) {
    Write-Host "Review the report for action items before going to production." -ForegroundColor Yellow
} else {
    Write-Host "All apps are ready for production cutover!" -ForegroundColor Green
}

Write-Host ""
