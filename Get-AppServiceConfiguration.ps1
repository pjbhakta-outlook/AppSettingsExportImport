# Get-AppServiceConfiguration.ps1
# Exports detailed configuration information from App Service apps for Phase 4 verification.
# This includes custom domains, SSL certificates, managed identities, VNet integration, 
# private endpoints, authentication, CORS, deployment slots, and WebJobs.

[CmdletBinding(PositionalBinding=$false)]
param(
    [string]$TenantId,
    [string]$SubscriptionId,
    [string]$ResourceGroup,
    [string]$AppName,
    [string]$OutputFile,
    [switch]$Json,
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
            '--resource-group' { if ($i + 1 -lt $cliArgs.Count) { $ResourceGroup = $cliArgs[$i + 1] } }
            '--app' { if ($i + 1 -lt $cliArgs.Count) { $AppName = $cliArgs[$i + 1] } }
            '--output' { if ($i + 1 -lt $cliArgs.Count) { $OutputFile = $cliArgs[$i + 1] } }
            '--json' { $Json = $true }
        }
    }
}

function Show-Usage {
    Write-Host ""
    Write-Host "Get-AppServiceConfiguration.ps1" -ForegroundColor Cyan
    Write-Host "================================" -ForegroundColor Cyan
    Write-Host "Exports detailed configuration information for App Service apps."
    Write-Host "Use this to document Phase 4 items that require manual migration."
    Write-Host ""
    Write-Host "Usage:" -ForegroundColor Yellow
    Write-Host "  .\Get-AppServiceConfiguration.ps1 --tenant <tenantId> [options]"
    Write-Host ""
    Write-Host "Parameters:" -ForegroundColor Yellow
    Write-Host "  --tenant         : (Required) Azure Tenant ID" -ForegroundColor Gray
    Write-Host "  --subscription   : (Optional) Specific subscription ID. If omitted, scans all." -ForegroundColor Gray
    Write-Host "  --resource-group : (Optional) Specific resource group. Requires --subscription." -ForegroundColor Gray
    Write-Host "  --app            : (Optional) Specific app name. Requires --resource-group." -ForegroundColor Gray
    Write-Host "  --output         : (Optional) Output file path. Default: scans/AppConfig-<timestamp>.txt" -ForegroundColor Gray
    Write-Host "  --json           : (Optional) Also export as JSON file for programmatic use." -ForegroundColor Gray
    Write-Host ""
    Write-Host "Configuration Items Exported:" -ForegroundColor Yellow
    Write-Host "  - Custom Domains and Hostnames" -ForegroundColor Gray
    Write-Host "  - SSL/TLS Certificates" -ForegroundColor Gray
    Write-Host "  - Managed Identities (System & User Assigned)" -ForegroundColor Gray
    Write-Host "  - VNet Integration" -ForegroundColor Gray
    Write-Host "  - Private Endpoints" -ForegroundColor Gray
    Write-Host "  - Hybrid Connections" -ForegroundColor Gray
    Write-Host "  - Authentication (Easy Auth)" -ForegroundColor Gray
    Write-Host "  - CORS Settings" -ForegroundColor Gray
    Write-Host "  - Deployment Slots" -ForegroundColor Gray
    Write-Host "  - WebJobs" -ForegroundColor Gray
    Write-Host "  - Backup Configuration" -ForegroundColor Gray
    Write-Host "  - IP Restrictions" -ForegroundColor Gray
    Write-Host "  - Virtual Applications" -ForegroundColor Gray
    Write-Host ""
    Write-Host "Examples:" -ForegroundColor Yellow
    Write-Host "  # Scan all apps in all subscriptions"
    Write-Host "  .\Get-AppServiceConfiguration.ps1 --tenant <tenantId>"
    Write-Host ""
    Write-Host "  # Scan a specific subscription"
    Write-Host "  .\Get-AppServiceConfiguration.ps1 --tenant <tenantId> --subscription <subId>"
    Write-Host ""
    Write-Host "  # Scan a specific app"
    Write-Host "  .\Get-AppServiceConfiguration.ps1 --tenant <tenantId> --subscription <subId> --resource-group <rg> --app <appName>"
    Write-Host ""
}

if (-not $TenantId) {
    Show-Usage
    exit 1
}

$ErrorActionPreference = 'Stop'

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

function Write-Section {
    param([string]$Title)
    $line = "=" * 60
    Write-Host ""
    Write-Host $line -ForegroundColor Cyan
    Write-Host " $Title" -ForegroundColor Cyan
    Write-Host $line -ForegroundColor Cyan
}

function Write-SubSection {
    param([string]$Title)
    Write-Host ""
    Write-Host "  $Title" -ForegroundColor Yellow
    Write-Host "  $("-" * ($Title.Length))" -ForegroundColor Yellow
}

function Write-ConfigItem {
    param(
        [string]$Label,
        [string]$Value,
        [switch]$Important
    )
    if ($Important) {
        Write-Host "    [!] $Label : " -ForegroundColor Magenta -NoNewline
        Write-Host $Value -ForegroundColor White
    } else {
        Write-Host "    $Label : " -ForegroundColor Gray -NoNewline
        Write-Host $Value -ForegroundColor White
    }
}

function Write-ListItem {
    param(
        [string]$Item,
        [switch]$Warning
    )
    if ($Warning) {
        Write-Host "    [!] $Item" -ForegroundColor Yellow
    } else {
        Write-Host "    - $Item" -ForegroundColor Gray
    }
}

function Get-AppConfiguration {
    param(
        [string]$SubscriptionId,
        [string]$SubscriptionName,
        [string]$ResourceGroup,
        [string]$AppName
    )
    
    $config = [PSCustomObject]@{
        SubscriptionId      = $SubscriptionId
        SubscriptionName    = $SubscriptionName
        ResourceGroup       = $ResourceGroup
        AppName             = $AppName
        CustomDomains       = @()
        SSLCertificates     = @()
        ManagedIdentity     = $null
        VNetIntegration     = $null
        PrivateEndpoints    = @()
        HybridConnections   = @()
        Authentication      = $null
        CORS                = @()
        DeploymentSlots     = @()
        WebJobs             = @()
        BackupConfig        = $null
        IPRestrictions      = @()
        VirtualApplications = @()
        HasConfiguration    = $false
        Warnings            = @()
    }
    
    try {
        # Get custom domains (hostnames)
        Write-Host "      Checking custom domains..." -ForegroundColor Gray
        $hostnamesJson = az webapp config hostname list --webapp-name $AppName --resource-group $ResourceGroup --only-show-errors 2>$null
        if ($hostnamesJson) {
            $hostnames = $hostnamesJson | ConvertFrom-Json
            $customDomains = $hostnames | Where-Object { $_.hostNameType -eq "Verified" -and $_.name -notlike "*.azurewebsites.net" }
            if ($customDomains) {
                $config.CustomDomains = @($customDomains | ForEach-Object {
                    [PSCustomObject]@{
                        Hostname    = $_.name
                        SSLState    = $_.sslState
                        Thumbprint  = $_.thumbprint
                    }
                })
                $config.HasConfiguration = $true
            }
        }
    } catch {
        $config.Warnings += "Failed to get custom domains: $($_.Exception.Message)"
    }
    
    try {
        # Get SSL certificates
        Write-Host "      Checking SSL certificates..." -ForegroundColor Gray
        $certsJson = az webapp config ssl list --resource-group $ResourceGroup --only-show-errors 2>$null
        if ($certsJson) {
            $allCerts = $certsJson | ConvertFrom-Json
            # Filter to certs used by this app
            $appCerts = $allCerts | Where-Object { 
                $config.CustomDomains | ForEach-Object { $_.Thumbprint } | Where-Object { $_ -eq $_.thumbprint }
            }
            if (-not $appCerts -and $config.CustomDomains.Count -gt 0) {
                # Try to get all certs in the resource group that might be relevant
                $appCerts = $allCerts
            }
            if ($appCerts) {
                $config.SSLCertificates = @($appCerts | ForEach-Object {
                    [PSCustomObject]@{
                        Name            = $_.name
                        Thumbprint      = $_.thumbprint
                        SubjectName     = $_.subjectName
                        ExpirationDate  = $_.expirationDate
                        Issuer          = $_.issuer
                        HostNames       = $_.hostNames -join ", "
                    }
                })
                $config.HasConfiguration = $true
            }
        }
    } catch {
        $config.Warnings += "Failed to get SSL certificates: $($_.Exception.Message)"
    }
    
    try {
        # Get managed identity
        Write-Host "      Checking managed identity..." -ForegroundColor Gray
        $identityJson = az webapp identity show --name $AppName --resource-group $ResourceGroup --only-show-errors 2>$null
        if ($identityJson) {
            $identity = $identityJson | ConvertFrom-Json
            if ($identity.principalId -or $identity.userAssignedIdentities) {
                $config.ManagedIdentity = [PSCustomObject]@{
                    Type                   = $identity.type
                    PrincipalId            = $identity.principalId
                    TenantId               = $identity.tenantId
                    UserAssignedIdentities = if ($identity.userAssignedIdentities) { 
                        ($identity.userAssignedIdentities.PSObject.Properties | ForEach-Object { $_.Name }) -join ", "
                    } else { $null }
                }
                $config.HasConfiguration = $true
            }
        }
    } catch {
        # No identity is not an error
    }
    
    try {
        # Get VNet integration
        Write-Host "      Checking VNet integration..." -ForegroundColor Gray
        $vnetJson = az webapp vnet-integration list --name $AppName --resource-group $ResourceGroup --only-show-errors 2>$null
        if ($vnetJson) {
            $vnets = $vnetJson | ConvertFrom-Json
            if ($vnets -and $vnets.Count -gt 0) {
                $config.VNetIntegration = @($vnets | ForEach-Object {
                    [PSCustomObject]@{
                        VNetResourceId = $_.vnetResourceId
                        SubnetName     = if ($_.vnetResourceId) { ($_.vnetResourceId -split '/')[-1] } else { $null }
                    }
                })
                $config.HasConfiguration = $true
            }
        }
    } catch {
        $config.Warnings += "Failed to get VNet integration: $($_.Exception.Message)"
    }
    
    try {
        # Get private endpoints
        Write-Host "      Checking private endpoints..." -ForegroundColor Gray
        $peJson = az network private-endpoint list --resource-group $ResourceGroup --only-show-errors 2>$null
        if ($peJson) {
            $allPEs = $peJson | ConvertFrom-Json
            $appPEs = $allPEs | Where-Object { 
                $_.privateLinkServiceConnections | Where-Object { $_.privateLinkServiceId -like "*sites/$AppName" }
            }
            if ($appPEs) {
                $config.PrivateEndpoints = @($appPEs | ForEach-Object {
                    [PSCustomObject]@{
                        Name      = $_.name
                        Subnet    = if ($_.subnet) { $_.subnet.id } else { $null }
                        IPAddress = if ($_.customDnsConfigs) { ($_.customDnsConfigs | ForEach-Object { $_.ipAddresses }) -join ", " } else { $null }
                    }
                })
                $config.HasConfiguration = $true
            }
        }
    } catch {
        $config.Warnings += "Failed to get private endpoints: $($_.Exception.Message)"
    }
    
    try {
        # Get hybrid connections
        Write-Host "      Checking hybrid connections..." -ForegroundColor Gray
        $hcJson = az webapp hybrid-connection list --name $AppName --resource-group $ResourceGroup --only-show-errors 2>$null
        if ($hcJson) {
            $hybridConnections = $hcJson | ConvertFrom-Json
            if ($hybridConnections -and $hybridConnections.Count -gt 0) {
                $config.HybridConnections = @($hybridConnections | ForEach-Object {
                    [PSCustomObject]@{
                        Name         = $_.name
                        Hostname     = $_.hostname
                        Port         = $_.port
                        RelayName    = $_.relayName
                        Namespace    = $_.serviceBusNamespace
                    }
                })
                $config.HasConfiguration = $true
            }
        }
    } catch {
        # Hybrid connections might not be available
    }
    
    try {
        # Get authentication settings
        Write-Host "      Checking authentication..." -ForegroundColor Gray
        $authJson = az webapp auth show --name $AppName --resource-group $ResourceGroup --only-show-errors 2>$null
        if ($authJson) {
            $auth = $authJson | ConvertFrom-Json
            if ($auth.enabled -eq $true -or $auth.platform.enabled -eq $true) {
                $providers = @()
                if ($auth.identityProviders) {
                    if ($auth.identityProviders.azureActiveDirectory) { $providers += "Azure AD" }
                    if ($auth.identityProviders.facebook) { $providers += "Facebook" }
                    if ($auth.identityProviders.gitHub) { $providers += "GitHub" }
                    if ($auth.identityProviders.google) { $providers += "Google" }
                    if ($auth.identityProviders.twitter) { $providers += "Twitter" }
                    if ($auth.identityProviders.apple) { $providers += "Apple" }
                    if ($auth.identityProviders.customOpenIdConnectProviders) { $providers += "Custom OIDC" }
                }
                $config.Authentication = [PSCustomObject]@{
                    Enabled                 = $true
                    Providers               = $providers -join ", "
                    UnauthenticatedAction   = $auth.globalValidation.unauthenticatedClientAction
                    TokenStoreEnabled       = $auth.login.tokenStore.enabled
                }
                $config.HasConfiguration = $true
            }
        }
    } catch {
        # Auth might use legacy format
        try {
            $authJson = az webapp auth show --name $AppName --resource-group $ResourceGroup --only-show-errors 2>$null
            if ($authJson) {
                $auth = $authJson | ConvertFrom-Json
                if ($auth.enabled) {
                    $config.Authentication = [PSCustomObject]@{
                        Enabled   = $true
                        Providers = "Check Azure Portal for details"
                    }
                    $config.HasConfiguration = $true
                }
            }
        } catch {
            $config.Warnings += "Failed to get authentication: $($_.Exception.Message)"
        }
    }
    
    try {
        # Get CORS settings
        Write-Host "      Checking CORS..." -ForegroundColor Gray
        $corsJson = az webapp cors show --name $AppName --resource-group $ResourceGroup --only-show-errors 2>$null
        if ($corsJson) {
            $cors = $corsJson | ConvertFrom-Json
            if ($cors.allowedOrigins -and $cors.allowedOrigins.Count -gt 0) {
                $config.CORS = $cors.allowedOrigins
                $config.HasConfiguration = $true
            }
        }
    } catch {
        $config.Warnings += "Failed to get CORS: $($_.Exception.Message)"
    }
    
    try {
        # Get deployment slots
        Write-Host "      Checking deployment slots..." -ForegroundColor Gray
        $slotsJson = az webapp deployment slot list --name $AppName --resource-group $ResourceGroup --only-show-errors 2>$null
        if ($slotsJson) {
            $slots = $slotsJson | ConvertFrom-Json
            if ($slots -and $slots.Count -gt 0) {
                $config.DeploymentSlots = @($slots | ForEach-Object {
                    [PSCustomObject]@{
                        Name    = $_.name
                        State   = $_.state
                        Enabled = $_.enabled
                    }
                })
                $config.HasConfiguration = $true
            }
        }
    } catch {
        # Slots might not be available on certain SKUs
    }
    
    try {
        # Get WebJobs
        Write-Host "      Checking WebJobs..." -ForegroundColor Gray
        # Get triggered WebJobs
        $triggeredJson = az webapp webjob triggered list --name $AppName --resource-group $ResourceGroup --only-show-errors 2>$null
        if ($triggeredJson) {
            $triggered = $triggeredJson | ConvertFrom-Json
            if ($triggered -and $triggered.Count -gt 0) {
                foreach ($job in $triggered) {
                    $config.WebJobs += [PSCustomObject]@{
                        Name    = $job.name
                        Type    = "Triggered"
                        Status  = $job.status
                    }
                }
                $config.HasConfiguration = $true
            }
        }
        # Get continuous WebJobs
        $continuousJson = az webapp webjob continuous list --name $AppName --resource-group $ResourceGroup --only-show-errors 2>$null
        if ($continuousJson) {
            $continuous = $continuousJson | ConvertFrom-Json
            if ($continuous -and $continuous.Count -gt 0) {
                foreach ($job in $continuous) {
                    $config.WebJobs += [PSCustomObject]@{
                        Name    = $job.name
                        Type    = "Continuous"
                        Status  = $job.status
                    }
                }
                $config.HasConfiguration = $true
            }
        }
    } catch {
        # WebJobs might not be accessible
    }
    
    try {
        # Get backup configuration
        Write-Host "      Checking backup configuration..." -ForegroundColor Gray
        $backupJson = az webapp config backup show --webapp-name $AppName --resource-group $ResourceGroup --only-show-errors 2>$null
        if ($backupJson) {
            $backup = $backupJson | ConvertFrom-Json
            if ($backup -and $backup.backupSchedule) {
                $config.BackupConfig = [PSCustomObject]@{
                    Enabled            = $backup.enabled
                    FrequencyInterval  = $backup.backupSchedule.frequencyInterval
                    FrequencyUnit      = $backup.backupSchedule.frequencyUnit
                    RetentionDays      = $backup.backupSchedule.retentionPeriodInDays
                    StorageAccountUrl  = if ($backup.storageAccountUrl) { "Configured (URL hidden)" } else { $null }
                }
                $config.HasConfiguration = $true
            }
        }
    } catch {
        # Backup might not be configured
    }
    
    try {
        # Get IP restrictions
        Write-Host "      Checking IP restrictions..." -ForegroundColor Gray
        $accessJson = az webapp config access-restriction show --name $AppName --resource-group $ResourceGroup --only-show-errors 2>$null
        if ($accessJson) {
            $access = $accessJson | ConvertFrom-Json
            if ($access.ipSecurityRestrictions -and $access.ipSecurityRestrictions.Count -gt 0) {
                $restrictions = $access.ipSecurityRestrictions | Where-Object { $_.name -ne "Allow all" -and $_.ipAddress -ne "Any" }
                if ($restrictions) {
                    $config.IPRestrictions = @($restrictions | ForEach-Object {
                        [PSCustomObject]@{
                            Name        = $_.name
                            Priority    = $_.priority
                            Action      = $_.action
                            IPAddress   = $_.ipAddress
                            SubnetMask  = $_.subnetMask
                            VNetSubnet  = $_.vnetSubnetResourceId
                        }
                    })
                    $config.HasConfiguration = $true
                }
            }
            # Also check SCM restrictions
            if ($access.scmIpSecurityRestrictionsUseMain -eq $false -and $access.scmIpSecurityRestrictions) {
                $config.Warnings += "SCM site has separate IP restrictions configured"
            }
        }
    } catch {
        $config.Warnings += "Failed to get IP restrictions: $($_.Exception.Message)"
    }
    
    try {
        # Get virtual applications
        Write-Host "      Checking virtual applications..." -ForegroundColor Gray
        $webConfigJson = az webapp config show --name $AppName --resource-group $ResourceGroup --only-show-errors 2>$null
        if ($webConfigJson) {
            $webConfig = $webConfigJson | ConvertFrom-Json
            if ($webConfig.virtualApplications -and $webConfig.virtualApplications.Count -gt 1) {
                $config.VirtualApplications = @($webConfig.virtualApplications | ForEach-Object {
                    [PSCustomObject]@{
                        VirtualPath     = $_.virtualPath
                        PhysicalPath    = $_.physicalPath
                        PreloadEnabled  = $_.preloadEnabled
                    }
                })
                $config.HasConfiguration = $true
            }
        }
    } catch {
        $config.Warnings += "Failed to get virtual applications: $($_.Exception.Message)"
    }
    
    return $config
}

function Format-AppConfiguration {
    param([PSCustomObject]$Config)
    
    $output = @()
    
    $output += ""
    $output += "=" * 70
    $output += " APP: $($Config.AppName)"
    $output += " Subscription: $($Config.SubscriptionName)"
    $output += " Resource Group: $($Config.ResourceGroup)"
    $output += "=" * 70
    
    if (-not $Config.HasConfiguration) {
        $output += ""
        $output += "  No Phase 4 configuration items found."
        $output += "  This app uses only basic settings (app settings, connection strings)."
        return $output
    }
    
    # Custom Domains
    if ($Config.CustomDomains.Count -gt 0) {
        $output += ""
        $output += "  CUSTOM DOMAINS"
        $output += "  --------------"
        foreach ($domain in $Config.CustomDomains) {
            $sslInfo = if ($domain.SSLState -and $domain.SSLState -ne "Disabled") { " [SSL: $($domain.SSLState)]" } else { " [No SSL]" }
            $output += "    [!] $($domain.Hostname)$sslInfo"
        }
    }
    
    # SSL Certificates
    if ($Config.SSLCertificates.Count -gt 0) {
        $output += ""
        $output += "  SSL CERTIFICATES"
        $output += "  -----------------"
        foreach ($cert in $Config.SSLCertificates) {
            $output += "    Certificate: $($cert.Name)"
            $output += "      Subject: $($cert.SubjectName)"
            $output += "      Expires: $($cert.ExpirationDate)"
            $output += "      Thumbprint: $($cert.Thumbprint)"
        }
    }
    
    # Managed Identity
    if ($Config.ManagedIdentity) {
        $output += ""
        $output += "  MANAGED IDENTITY"
        $output += "  -----------------"
        $output += "    [!] Type: $($Config.ManagedIdentity.Type)"
        if ($Config.ManagedIdentity.PrincipalId) {
            $output += "    Principal ID: $($Config.ManagedIdentity.PrincipalId)"
        }
        if ($Config.ManagedIdentity.UserAssignedIdentities) {
            $output += "    User Assigned: $($Config.ManagedIdentity.UserAssignedIdentities)"
        }
        $output += "    ** NOTE: Check RBAC role assignments for this identity **"
    }
    
    # VNet Integration
    if ($Config.VNetIntegration -and $Config.VNetIntegration.Count -gt 0) {
        $output += ""
        $output += "  VNET INTEGRATION"
        $output += "  -----------------"
        foreach ($vnet in $Config.VNetIntegration) {
            $output += "    [!] Subnet: $($vnet.SubnetName)"
            $output += "    Resource ID: $($vnet.VNetResourceId)"
        }
    }
    
    # Private Endpoints
    if ($Config.PrivateEndpoints.Count -gt 0) {
        $output += ""
        $output += "  PRIVATE ENDPOINTS"
        $output += "  ------------------"
        foreach ($pe in $Config.PrivateEndpoints) {
            $output += "    [!] $($pe.Name)"
            if ($pe.IPAddress) { $output += "      IP: $($pe.IPAddress)" }
        }
    }
    
    # Hybrid Connections
    if ($Config.HybridConnections.Count -gt 0) {
        $output += ""
        $output += "  HYBRID CONNECTIONS"
        $output += "  -------------------"
        foreach ($hc in $Config.HybridConnections) {
            $output += "    [!] $($hc.Name)"
            $output += "      Endpoint: $($hc.Hostname):$($hc.Port)"
            $output += "      Namespace: $($hc.Namespace)"
        }
    }
    
    # Authentication
    if ($Config.Authentication) {
        $output += ""
        $output += "  AUTHENTICATION (Easy Auth)"
        $output += "  ---------------------------"
        $output += "    [!] Enabled: $($Config.Authentication.Enabled)"
        if ($Config.Authentication.Providers) {
            $output += "    Providers: $($Config.Authentication.Providers)"
        }
        if ($Config.Authentication.UnauthenticatedAction) {
            $output += "    Unauthenticated Action: $($Config.Authentication.UnauthenticatedAction)"
        }
    }
    
    # CORS
    if ($Config.CORS.Count -gt 0) {
        $output += ""
        $output += "  CORS ALLOWED ORIGINS"
        $output += "  ---------------------"
        foreach ($origin in $Config.CORS) {
            $output += "    - $origin"
        }
    }
    
    # Deployment Slots
    if ($Config.DeploymentSlots.Count -gt 0) {
        $output += ""
        $output += "  DEPLOYMENT SLOTS"
        $output += "  -----------------"
        foreach ($slot in $Config.DeploymentSlots) {
            $output += "    [!] $($slot.Name) (State: $($slot.State))"
        }
    }
    
    # WebJobs
    if ($Config.WebJobs.Count -gt 0) {
        $output += ""
        $output += "  WEBJOBS"
        $output += "  --------"
        foreach ($job in $Config.WebJobs) {
            $output += "    [!] $($job.Name) - $($job.Type)"
        }
    }
    
    # Backup Configuration
    if ($Config.BackupConfig) {
        $output += ""
        $output += "  BACKUP CONFIGURATION"
        $output += "  ---------------------"
        $output += "    [!] Enabled: $($Config.BackupConfig.Enabled)"
        $output += "    Frequency: Every $($Config.BackupConfig.FrequencyInterval) $($Config.BackupConfig.FrequencyUnit)"
        $output += "    Retention: $($Config.BackupConfig.RetentionDays) days"
    }
    
    # IP Restrictions
    if ($Config.IPRestrictions.Count -gt 0) {
        $output += ""
        $output += "  IP RESTRICTIONS"
        $output += "  ----------------"
        foreach ($rule in $Config.IPRestrictions) {
            $target = if ($rule.VNetSubnet) { "VNet: $($rule.VNetSubnet)" } else { "IP: $($rule.IPAddress)" }
            $output += "    $($rule.Action) - $($rule.Name): $target (Priority: $($rule.Priority))"
        }
    }
    
    # Virtual Applications
    if ($Config.VirtualApplications.Count -gt 1) {
        $output += ""
        $output += "  VIRTUAL APPLICATIONS"
        $output += "  ---------------------"
        foreach ($vapp in $Config.VirtualApplications) {
            $output += "    $($vapp.VirtualPath) -> $($vapp.PhysicalPath)"
        }
    }
    
    # Warnings
    if ($Config.Warnings.Count -gt 0) {
        $output += ""
        $output += "  WARNINGS"
        $output += "  ---------"
        foreach ($warning in $Config.Warnings) {
            $output += "    [!] $warning"
        }
    }
    
    return $output
}

# ============================================================================
# MAIN SCRIPT
# ============================================================================

Write-Host ""
Write-Host "Get-AppServiceConfiguration" -ForegroundColor Cyan
Write-Host "=============================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Tenant: $TenantId" -ForegroundColor Gray
if ($SubscriptionId) { Write-Host "Subscription: $SubscriptionId" -ForegroundColor Gray }
if ($ResourceGroup) { Write-Host "Resource Group: $ResourceGroup" -ForegroundColor Gray }
if ($AppName) { Write-Host "App: $AppName" -ForegroundColor Gray }
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

# Collect configuration data
Write-Host ""
Write-Host "Scanning for App Service configuration..." -ForegroundColor Yellow
Write-Host ""

$allConfigs = @()
$allOutputLines = @()
$appsWithConfig = 0
$totalApps = 0

foreach ($sub in $subscriptions) {
    Write-Host "Subscription: $($sub.name)" -ForegroundColor Cyan
    
    az account set --subscription $sub.id --only-show-errors 2>$null
    
    # Get apps
    if ($AppName -and $ResourceGroup) {
        # Specific app
        $appsJson = az webapp show --name $AppName --resource-group $ResourceGroup --only-show-errors 2>$null
        if ($appsJson) {
            $apps = @($appsJson | ConvertFrom-Json)
        } else {
            Write-Host "  App not found: $AppName" -ForegroundColor Red
            continue
        }
    } elseif ($ResourceGroup) {
        # Apps in resource group
        $appsJson = az webapp list --resource-group $ResourceGroup --only-show-errors 2>$null
        if ($appsJson) {
            $apps = $appsJson | ConvertFrom-Json
        } else {
            Write-Host "  No apps found in resource group: $ResourceGroup" -ForegroundColor Yellow
            continue
        }
    } else {
        # All apps in subscription
        $appsJson = az webapp list --only-show-errors 2>$null
        if ($appsJson) {
            $apps = $appsJson | ConvertFrom-Json
        } else {
            Write-Host "  No apps found" -ForegroundColor Yellow
            continue
        }
    }
    
    if (-not $apps -or $apps.Count -eq 0) {
        Write-Host "  No apps found" -ForegroundColor Yellow
        continue
    }
    
    Write-Host "  Found $($apps.Count) app(s)" -ForegroundColor Gray
    
    foreach ($app in $apps) {
        $totalApps++
        Write-Host ""
        Write-Host "  [$totalApps] $($app.name)" -ForegroundColor White
        
        $config = Get-AppConfiguration -SubscriptionId $sub.id -SubscriptionName $sub.name -ResourceGroup $app.resourceGroup -AppName $app.name
        $allConfigs += $config
        
        if ($config.HasConfiguration) {
            $appsWithConfig++
            Write-Host "      Configuration items found!" -ForegroundColor Green
        } else {
            Write-Host "      No Phase 4 configuration items" -ForegroundColor Gray
        }
        
        $outputLines = Format-AppConfiguration -Config $config
        $allOutputLines += $outputLines
    }
}

# Generate summary
$summaryLines = @()
$summaryLines += ""
$summaryLines += "=" * 70
$summaryLines += " PHASE 4 CONFIGURATION SUMMARY"
$summaryLines += " Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
$summaryLines += "=" * 70
$summaryLines += ""
$summaryLines += " Total Apps Scanned: $totalApps"
$summaryLines += " Apps with Configuration: $appsWithConfig"
$summaryLines += ""
$summaryLines += " CONFIGURATION ITEMS TO VERIFY ON TARGET APPS:"
$summaryLines += " ---------------------------------------------"
$summaryLines += ""

# Count items
$domainsCount = ($allConfigs | ForEach-Object { $_.CustomDomains.Count } | Measure-Object -Sum).Sum
$certsCount = ($allConfigs | ForEach-Object { $_.SSLCertificates.Count } | Measure-Object -Sum).Sum
$identitiesCount = ($allConfigs | Where-Object { $_.ManagedIdentity } | Measure-Object).Count
$vnetsCount = ($allConfigs | Where-Object { $_.VNetIntegration -and $_.VNetIntegration.Count -gt 0 } | Measure-Object).Count
$pesCount = ($allConfigs | ForEach-Object { $_.PrivateEndpoints.Count } | Measure-Object -Sum).Sum
$hcCount = ($allConfigs | ForEach-Object { $_.HybridConnections.Count } | Measure-Object -Sum).Sum
$authCount = ($allConfigs | Where-Object { $_.Authentication } | Measure-Object).Count
$corsCount = ($allConfigs | Where-Object { $_.CORS.Count -gt 0 } | Measure-Object).Count
$slotsCount = ($allConfigs | ForEach-Object { $_.DeploymentSlots.Count } | Measure-Object -Sum).Sum
$jobsCount = ($allConfigs | ForEach-Object { $_.WebJobs.Count } | Measure-Object -Sum).Sum
$backupCount = ($allConfigs | Where-Object { $_.BackupConfig } | Measure-Object).Count
$ipCount = ($allConfigs | Where-Object { $_.IPRestrictions.Count -gt 0 } | Measure-Object).Count

$summaryLines += " [ ] Custom Domains: $domainsCount"
$summaryLines += " [ ] SSL Certificates: $certsCount"
$summaryLines += " [ ] Managed Identities: $identitiesCount"
$summaryLines += " [ ] VNet Integrations: $vnetsCount"
$summaryLines += " [ ] Private Endpoints: $pesCount"
$summaryLines += " [ ] Hybrid Connections: $hcCount"
$summaryLines += " [ ] Authentication (Easy Auth): $authCount"
$summaryLines += " [ ] CORS Configurations: $corsCount"
$summaryLines += " [ ] Deployment Slots: $slotsCount"
$summaryLines += " [ ] WebJobs: $jobsCount"
$summaryLines += " [ ] Backup Configurations: $backupCount"
$summaryLines += " [ ] IP Restrictions: $ipCount"
$summaryLines += ""
$summaryLines += " Items marked with [!] require manual configuration on target apps."
$summaryLines += ""

$allOutputLines = $summaryLines + $allOutputLines

# Add verification checklist
$checklistLines = @()
$checklistLines += ""
$checklistLines += "=" * 70
$checklistLines += " PHASE 4 VERIFICATION CHECKLIST"
$checklistLines += "=" * 70
$checklistLines += ""
$checklistLines += " After creating target apps, verify the following:"
$checklistLines += ""
$checklistLines += " [ ] 1. MANAGED IDENTITIES"
$checklistLines += "     - Enable system-assigned managed identity (if used)"
$checklistLines += "     - Assign user-assigned managed identities (if used)"
$checklistLines += "     - Configure RBAC role assignments for each identity"
$checklistLines += ""
$checklistLines += " [ ] 2. VNET INTEGRATION"
$checklistLines += "     - Configure VNet integration with appropriate subnet"
$checklistLines += "     - Verify subnet delegation is set correctly"
$checklistLines += "     - Test connectivity to private resources"
$checklistLines += ""
$checklistLines += " [ ] 3. PRIVATE ENDPOINTS"
$checklistLines += "     - Create private endpoints in target VNet"
$checklistLines += "     - Configure private DNS zones"
$checklistLines += "     - Update DNS records"
$checklistLines += ""
$checklistLines += " [ ] 4. CUSTOM DOMAINS"
$checklistLines += "     - Add custom domains to target app"
$checklistLines += "     - Verify domain ownership (TXT/CNAME records)"
$checklistLines += "     - Wait for domain validation"
$checklistLines += ""
$checklistLines += " [ ] 5. SSL CERTIFICATES"
$checklistLines += "     - Upload or create managed certificates"
$checklistLines += "     - Bind certificates to custom domains"
$checklistLines += "     - Verify certificate chain is complete"
$checklistLines += ""
$checklistLines += " [ ] 6. AUTHENTICATION"
$checklistLines += "     - Configure identity providers"
$checklistLines += "     - Update app registration redirect URIs"
$checklistLines += "     - Test authentication flow"
$checklistLines += ""
$checklistLines += " [ ] 7. CORS SETTINGS"
$checklistLines += "     - Add allowed origins"
$checklistLines += "     - Test cross-origin requests"
$checklistLines += ""
$checklistLines += " [ ] 8. DEPLOYMENT SLOTS"
$checklistLines += "     - Create staging/preview slots"
$checklistLines += "     - Configure slot-specific settings"
$checklistLines += "     - Test slot swap functionality"
$checklistLines += ""
$checklistLines += " [ ] 9. WEBJOBS"
$checklistLines += "     - Download WebJobs from source app"
$checklistLines += "     - Deploy WebJobs to target app"
$checklistLines += "     - Verify WebJob schedules and triggers"
$checklistLines += ""
$checklistLines += " [ ] 10. IP RESTRICTIONS"
$checklistLines += "     - Configure access restrictions"
$checklistLines += "     - Add VNet/subnet rules (if used)"
$checklistLines += "     - Test access from allowed sources"
$checklistLines += ""
$checklistLines += " [ ] 11. BACKUP CONFIGURATION"
$checklistLines += "     - Configure backup schedule"
$checklistLines += "     - Set up storage account connection"
$checklistLines += "     - Test backup/restore"
$checklistLines += ""
$checklistLines += " [ ] 12. HYBRID CONNECTIONS"
$checklistLines += "     - Configure Hybrid Connection Manager"
$checklistLines += "     - Add hybrid connections"
$checklistLines += "     - Test connectivity to on-premises resources"
$checklistLines += ""

$allOutputLines += $checklistLines

# Output to console
foreach ($line in $allOutputLines) {
    if ($line -like "*[!]*") {
        Write-Host $line -ForegroundColor Magenta
    } elseif ($line -like "  ---*" -or $line -like "  ===*" -or $line -like "===*") {
        Write-Host $line -ForegroundColor Cyan
    } elseif ($line -like " [ ]*") {
        Write-Host $line -ForegroundColor Yellow
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
    $OutputFile = Join-Path -Path $scansFolder -ChildPath "AppConfig-$timestamp.txt"
}

$allOutputLines | Out-File -FilePath $OutputFile -Encoding UTF8

Write-Host ""
Write-Host "======================================" -ForegroundColor Green
Write-Host "EXPORT COMPLETED" -ForegroundColor Green
Write-Host "======================================" -ForegroundColor Green
Write-Host ""
Write-Host "Report saved to: $OutputFile" -ForegroundColor Cyan

# Export JSON if requested
if ($Json) {
    $jsonFile = [System.IO.Path]::ChangeExtension($OutputFile, '.json')
    $allConfigs | ConvertTo-Json -Depth 10 | Out-File -FilePath $jsonFile -Encoding UTF8
    Write-Host "JSON saved to: $jsonFile" -ForegroundColor Cyan
}

Write-Host ""
Write-Host "Use this report to verify Phase 4 configuration on target apps." -ForegroundColor Yellow
Write-Host ""
