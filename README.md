# App Service Migration Guide

This guide explains how to perform a **complete migration** of App Service apps from one subscription/resource group to another. The migration includes creating new apps, copying settings, deploying code, and handling all dependencies.

## Overview

### What This Guide Covers

| Phase | Description |
|-------|-------------|
| **Phase 1: Export & Plan** | Scan source apps and create migration plan |
| **Phase 2: Create Apps** | Create new apps with settings using scripts |
| **Phase 3: Deploy Code** | Deploy application code to new apps |
| **Phase 4: Configure** | Set up custom domains, SSL, identities, etc. |
| **Phase 5: Test** | Validate apps work correctly |
| **Phase 6: Cutover** | Switch traffic to new apps |

### Scripts Provided

| Script | Purpose |
|--------|---------|
| `Export-AppServiceApps.ps1` | Scans subscriptions and exports a list of all App Service apps to a CSV file |
| `Import-AppServiceApps.ps1` | Reads the CSV file, creates new apps, and copies all settings from source apps |
| `Get-AppServiceConfiguration.ps1` | Exports Phase 4 configuration (domains, SSL, identities, VNet, etc.) for verification |
| `Compare-AppServiceApps.ps1` | Compares source and target apps to verify migration completeness |
| `Copy-AppSettings.ps1` | Helper script to copy settings to existing apps |

## Prerequisites

- **Azure CLI** installed and configured
- **PowerShell** 5.1 or later
- Appropriate permissions to:
  - Read App Service apps in source subscriptions
  - Create resources in target subscriptions
  - Access app settings and connection strings

## Migration Workflow

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           MIGRATION WORKFLOW                                 │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  Step 1: EXPORT                                                             │
│  ┌─────────────────┐                                                        │
│  │ Azure           │  ──────►  Export-AppServiceApps.ps1                    │
│  │ Subscriptions   │                      │                                 │
│  └─────────────────┘                      ▼                                 │
│                                   ┌───────────────┐                         │
│                                   │  CSV File     │                         │
│                                   │  (Migration   │                         │
│                                   │   Plan)       │                         │
│                                   └───────────────┘                         │
│                                           │                                 │
│  Step 2: EDIT CSV                         ▼                                 │
│                                   ┌───────────────┐                         │
│                                   │ User edits    │                         │
│                                   │ target columns│                         │
│                                   └───────────────┘                         │
│                                           │                                 │
│  Step 3: IMPORT                           ▼                                 │
│                                   Import-AppServiceApps.ps1                 │
│                                           │                                 │
│                                           ▼                                 │
│  ┌─────────────────┐              ┌───────────────┐                         │
│  │ New Apps        │  ◄──────────│ Creates apps  │                         │
│  │ Created with    │              │ Copies settings│                        │
│  │ Settings        │              │ Updates CSV   │                         │
│  └─────────────────┘              └───────────────┘                         │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Step 1: Export Apps

### Command

```powershell
.\Export-AppServiceApps.ps1 --tenant <tenantId> [--subscription <subscriptionId>] [--output <path>]
```

### Parameters

| Parameter | Required | Description |
|-----------|----------|-------------|
| `--tenant` | Yes | Azure Tenant ID |
| `--subscription` | No | Specific subscription to scan (scans all if omitted) |
| `--output` | No | Output CSV file path (default: `.\scans\AppMigration-<timestamp>.csv`) |

### Example

```powershell
# Export all apps from all subscriptions in the tenant
.\Export-AppServiceApps.ps1 --tenant 93f24d9d-38da-4545-be46-e9f4c02b62ee

# Export from a specific subscription
.\Export-AppServiceApps.ps1 --tenant 93f24d9d-38da-4545-be46-e9f4c02b62ee --subscription 4af85dff-7368-4ef3-bab1-b9ceab3ed766

# Export to a specific file
.\Export-AppServiceApps.ps1 --tenant 93f24d9d-38da-4545-be46-e9f4c02b62ee --output .\my-migration-plan.csv
```

### Output CSV Columns

The export creates a CSV with the following columns:

#### Source Columns (Read-Only Reference)
| Column | Description |
|--------|-------------|
| `SourceSubscriptionId` | Source subscription GUID |
| `SourceSubscriptionName` | Source subscription name |
| `SourceAppName` | Original app name |
| `SourceResourceGroup` | Original resource group |
| `SourceAppServicePlan` | Original App Service Plan |
| `SourceLocation` | Azure region |
| `SourceSku` | SKU/pricing tier |
| `SourceKind` | App type (e.g., `app,linux`, `app,linux,container`) |
| `AppSettingsCount` | Number of app settings |
| `ConnectionStringsCount` | Number of connection strings |

#### Target Columns (User Editable)
| Column | Description |
|--------|-------------|
| `TargetSubscriptionId` | Destination subscription GUID |
| `TargetResourceGroup` | Destination resource group name |
| `TargetAppServicePlan` | Destination App Service Plan name |
| `TargetLocation` | Destination Azure region |
| `TargetSku` | Destination SKU (e.g., `S1`, `P1v3`, `P3V3`) |
| `NewAppName` | New app name (must be globally unique) |
| `Skip` | Set to `Yes` to skip this app |

#### Status Columns (Updated by Import)
| Column | Description |
|--------|-------------|
| `ImportStatus` | `Pending`, `Success`, `Failed`, `Skipped`, `WhatIf` |
| `ImportMessage` | Status message or error details |
| `ImportTimestamp` | When the import was attempted |

---

## Step 2: Edit the CSV

After exporting, open the CSV file and fill in the **Target columns** for each app you want to migrate:

1. **TargetSubscriptionId** - The destination subscription GUID
2. **TargetResourceGroup** - The destination resource group (can be new or existing)
3. **TargetAppServicePlan** - The destination App Service Plan (can be new or existing)
4. **TargetLocation** - The Azure region (e.g., `Central US`, `East US 2`)
5. **TargetSku** - The pricing tier (e.g., `S1`, `P1v3`, `P3V3`)
6. **NewAppName** - The new app name (**must be globally unique**)
7. **Skip** - Set to `Yes` to skip migrating this app

### Important Notes

- **App names must be globally unique** across all of Azure
- If you use the same name as the source app, it will fail
- Consider adding a suffix like `-migrated` or `-new` to app names

### Example CSV After Editing

```csv
SourceAppName,NewAppName,TargetSubscriptionId,TargetResourceGroup,TargetAppServicePlan,TargetLocation,TargetSku,Skip
MyWebApp,MyWebApp-migrated,0530ec14-...,rg-NewEnv,asp-NewEnv,Central US,P3V3,No
OldApp,,,,,,,Yes
```

---

## Step 3: Import Apps

### Command

```powershell
.\Import-AppServiceApps.ps1 --tenant <tenantId> --file <csvPath> [options]
```

### Parameters

| Parameter | Required | Description |
|-----------|----------|-------------|
| `--tenant` | Yes | Azure Tenant ID |
| `--file` | Yes | Path to the migration CSV file |
| `--createMissingPlans` | No | Create App Service Plans if they don't exist |
| `--createMissingResourceGroups` | No | Create Resource Groups if they don't exist |
| `--whatif` | No | Preview changes without creating anything |

### Example

```powershell
# Preview what will be created (no changes made)
.\Import-AppServiceApps.ps1 --tenant 93f24d9d-38da-4545-be46-e9f4c02b62ee --file .\scans\AppMigration.csv --whatif

# Create apps (resource groups and plans must exist)
.\Import-AppServiceApps.ps1 --tenant 93f24d9d-38da-4545-be46-e9f4c02b62ee --file .\scans\AppMigration.csv

# Create apps and auto-create missing resource groups and plans
.\Import-AppServiceApps.ps1 --tenant 93f24d9d-38da-4545-be46-e9f4c02b62ee --file .\scans\AppMigration.csv --createMissingPlans --createMissingResourceGroups
```

### What Gets Copied

The import script copies the following from source to target apps:

| Item | Description |
|------|-------------|
| **App Settings** | All application settings (environment variables) |
| **Connection Strings** | Database and service connection strings |
| **General Configuration** | AlwaysOn, HTTP/2, TLS version, FTPS state, WebSockets |
| **Runtime** | Linux runtime stack (e.g., `DOTNETCORE|8.0`, `NODE|18-lts`) |
| **Container Image** | For container apps, the Docker image reference |

### What Does NOT Get Copied (Manual Steps Required)

The following items require **manual migration** after creating the apps:

| Item | Manual Steps Required |
|------|----------------------|
| **Deployment source/code** | Re-deploy code from source control or backup |
| **Custom domains** | Add domains and update DNS |
| **SSL certificates** | Upload/bind certificates or use managed certificates |
| **Managed identities** | Enable and configure RBAC permissions |
| **VNet integration** | Configure VNet and subnet |
| **Private endpoints** | Set up private endpoints |
| **Deployment slots** | Create slots and configure |
| **WebJobs** | Re-deploy WebJobs |
| **Backups** | Configure new backup schedule |
| **Authentication** | Reconfigure Easy Auth providers |
| **CORS settings** | Configure allowed origins |

---

## Full Migration Checklist

Use this checklist to ensure a complete migration:

### Pre-Migration
- [ ] Document all source apps and their dependencies
- [ ] Identify custom domains and SSL certificates
- [ ] Note VNet integrations and private endpoints
- [ ] List managed identities and their RBAC roles
- [ ] Identify connected resources (databases, storage, Key Vault)
- [ ] Plan maintenance window for cutover
- [ ] Communicate with stakeholders

### Phase 1: Export & Plan
- [ ] Run `Export-AppServiceApps.ps1` to generate CSV
- [ ] Review all apps in the CSV
- [ ] Fill in target columns (subscription, resource group, plan, app name)
- [ ] Mark apps to skip with `Skip=Yes`
- [ ] Verify app names are globally unique

### Phase 2: Create Apps with Settings
- [ ] Run `Import-AppServiceApps.ps1` with `--whatif` first
- [ ] Review what will be created
- [ ] Run import to create apps
- [ ] Verify apps created successfully
- [ ] Confirm app settings and connection strings copied

### Phase 3: Deploy Application Code
- [ ] Choose deployment method (see section below)
- [ ] Deploy code to each new app
- [ ] Verify deployment succeeded

### Phase 4: Configure Additional Settings
- [ ] Run `Get-AppServiceConfiguration.ps1` to document source configuration
- [ ] Review the configuration report for each app
- [ ] Configure managed identities
- [ ] Set up VNet integration (if needed)
- [ ] Configure private endpoints (if needed)
- [ ] Add custom domains
- [ ] Configure SSL certificates
- [ ] Set up authentication providers
- [ ] Configure CORS settings
- [ ] Create deployment slots (if needed)
- [ ] Deploy and configure WebJobs
- [ ] Configure backup schedules
- [ ] Set up IP restrictions (if needed)
- [ ] Configure hybrid connections (if needed)

### Phase 5: Testing
- [ ] Run `Compare-AppServiceApps.ps1` to verify target matches source
- [ ] Review comparison report and fix any blockers
- [ ] Test each app using the `.azurewebsites.net` URL
- [ ] Verify all functionality works
- [ ] Test authentication flows
- [ ] Test database connections
- [ ] Test external API integrations
- [ ] Load test if applicable
- [ ] Test deployment slots (if used)

### Phase 6: Cutover
- [ ] Update DNS records to point to new apps
- [ ] Monitor for errors
- [ ] Verify traffic flowing to new apps
- [ ] Keep old apps running temporarily (rollback option)
- [ ] Decommission old apps after validation period

---

## Phase 3: Deploy Application Code

After creating apps with settings, you need to deploy your application code. Choose the method that matches your current deployment setup.

### Option A: Re-deploy from Source Control (Recommended)

If you use CI/CD pipelines (Azure DevOps, GitHub Actions):

1. **Update your pipeline** to deploy to the new app:
   ```yaml
   # Azure DevOps example
   - task: AzureWebApp@1
     inputs:
       azureSubscription: 'your-subscription'
       appName: 'your-new-app-name'    # Update this
       resourceGroupName: 'rg-NewEnv'  # Update this
   ```

2. **Run the pipeline** to deploy to the new app

### Option B: Deploy from Deployment Center

If your source app uses Deployment Center:

```powershell
# Get the deployment source from the old app
az webapp deployment source show --name "OldApp" --resource-group "OldRG"

# Configure the same source on the new app
az webapp deployment source config --name "NewApp" --resource-group "NewRG" \
    --repo-url "https://github.com/your/repo" \
    --branch "main" \
    --manual-integration
```

### Option C: Download and Re-deploy (ZIP Deploy)

Download the code from the old app and deploy to the new one:

```powershell
# Download the deployed code from old app
$oldApp = "OldApp"
$oldRg = "OldRG"

# Get the publish profile (contains deployment credentials)
az webapp deployment list-publishing-profiles --name $oldApp --resource-group $oldRg --xml > publish-profile.xml

# Download the site content using Kudu ZIP API
$kuduUrl = "https://$oldApp.scm.azurewebsites.net/api/zip/site/wwwroot/"
# Use credentials from publish profile to download

# Deploy to new app using ZIP deploy
az webapp deployment source config-zip --name "NewApp" --resource-group "NewRG" --src "app.zip"
```

### Option D: Use Deployment Slots for Zero-Downtime

```powershell
# Create a staging slot on the new app
az webapp deployment slot create --name "NewApp" --resource-group "NewRG" --slot "staging"

# Deploy to staging slot
az webapp deployment source config-zip --name "NewApp" --resource-group "NewRG" --slot "staging" --src "app.zip"

# Test the staging slot
# https://newapp-staging.azurewebsites.net

# Swap staging to production
az webapp deployment slot swap --name "NewApp" --resource-group "NewRG" --slot "staging" --target-slot "production"
```

### Option E: Container Apps

For container-based apps, update the container image:

```powershell
# Set the container image on the new app
az webapp config container set --name "NewApp" --resource-group "NewRG" \
    --container-image-name "myregistry.azurecr.io/myapp:latest" \
    --container-registry-url "https://myregistry.azurecr.io" \
    --container-registry-user "username" \
    --container-registry-password "password"
```

---

## Scan Source Configuration (Pre-Phase 4)

Before starting Phase 4, use the configuration scanner to document all settings that require manual migration.

### Command

```powershell
.\Get-AppServiceConfiguration.ps1 --tenant <tenantId> [options]
```

### Parameters

| Parameter | Required | Description |
|-----------|----------|-------------|
| `--tenant` | Yes | Azure Tenant ID |
| `--subscription` | No | Specific subscription ID (scans all if omitted) |
| `--resource-group` | No | Specific resource group (requires `--subscription`) |
| `--app` | No | Specific app name (requires `--resource-group`) |
| `--output` | No | Output file path (default: `.\scans\AppConfig-<timestamp>.txt`) |
| `--json` | No | Also export as JSON file for programmatic use |

### Examples

```powershell
# Scan all apps in all subscriptions
.\Get-AppServiceConfiguration.ps1 --tenant 93f24d9d-38da-4545-be46-e9f4c02b62ee

# Scan a specific subscription
.\Get-AppServiceConfiguration.ps1 --tenant 93f24d9d-38da-4545-be46-e9f4c02b62ee --subscription 4af85dff-7368-4ef3-bab1-b9ceab3ed766

# Scan a specific app
.\Get-AppServiceConfiguration.ps1 --tenant 93f24d9d-38da-4545-be46-e9f4c02b62ee --subscription 4af85dff-7368-4ef3-bab1-b9ceab3ed766 --resource-group rg-MyApp --app MyWebApp

# Export with JSON for automation
.\Get-AppServiceConfiguration.ps1 --tenant 93f24d9d-38da-4545-be46-e9f4c02b62ee --json
```

### Configuration Items Scanned

| Item | What's Captured |
|------|-----------------|
| **Custom Domains** | Hostname, SSL state, certificate thumbprint |
| **SSL Certificates** | Name, subject, issuer, expiration date, thumbprint |
| **Managed Identity** | Type (system/user), principal ID, user-assigned IDs |
| **VNet Integration** | VNet resource ID, subnet name |
| **Private Endpoints** | Endpoint name, subnet, IP address |
| **Hybrid Connections** | Name, hostname, port, relay namespace |
| **Authentication** | Enabled status, providers (Azure AD, Facebook, etc.) |
| **CORS** | List of allowed origins |
| **Deployment Slots** | Slot names and states |
| **WebJobs** | Name, type (triggered/continuous), status |
| **Backup Config** | Schedule frequency, retention period |
| **IP Restrictions** | Rule name, action, IP/subnet, priority |
| **Virtual Applications** | Virtual path, physical path |

### Output Report Structure

The report contains three sections:

**1. Summary** - Overview of all configuration items found:
```
PHASE 4 CONFIGURATION SUMMARY
=============================
Total Apps Scanned: 15
Apps with Configuration: 8

CONFIGURATION ITEMS TO VERIFY ON TARGET APPS:
 [ ] Custom Domains: 12
 [ ] SSL Certificates: 10
 [ ] Managed Identities: 6
 [ ] VNet Integrations: 4
 ...
```

**2. Per-App Details** - Configuration for each app:
```
======================================================================
 APP: MyWebApp
 Subscription: Production
 Resource Group: rg-prod-apps
======================================================================

  CUSTOM DOMAINS
  --------------
    [!] www.mydomain.com [SSL: SniEnabled]
    [!] api.mydomain.com [SSL: SniEnabled]

  MANAGED IDENTITY
  -----------------
    [!] Type: SystemAssigned
    Principal ID: 12345678-1234-1234-1234-123456789abc
    ** NOTE: Check RBAC role assignments for this identity **
```

**3. Verification Checklist** - Step-by-step guide for target apps:
```
PHASE 4 VERIFICATION CHECKLIST
==============================
 [ ] 1. MANAGED IDENTITIES
     - Enable system-assigned managed identity (if used)
     - Assign user-assigned managed identities (if used)
     - Configure RBAC role assignments for each identity

 [ ] 2. VNET INTEGRATION
     - Configure VNet integration with appropriate subnet
     ...
```

---

## Phase 4: Configure Additional Settings

### 4.1 Managed Identity

```powershell
# Enable system-assigned managed identity
az webapp identity assign --name "NewApp" --resource-group "NewRG"

# Get the principal ID
$principalId = az webapp identity show --name "NewApp" --resource-group "NewRG" --query principalId -o tsv

# Assign RBAC roles (example: Key Vault access)
az role assignment create --assignee $principalId --role "Key Vault Secrets User" --scope "/subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.KeyVault/vaults/{vault}"
```

### 4.2 VNet Integration

```powershell
# Integrate with a VNet subnet
az webapp vnet-integration add --name "NewApp" --resource-group "NewRG" \
    --vnet "MyVNet" --subnet "AppSubnet"
```

### 4.3 Private Endpoints

```powershell
# Create a private endpoint for the app
az network private-endpoint create --name "NewApp-pe" --resource-group "NewRG" \
    --vnet-name "MyVNet" --subnet "PrivateEndpointSubnet" \
    --private-connection-resource-id "/subscriptions/{sub}/resourceGroups/NewRG/providers/Microsoft.Web/sites/NewApp" \
    --group-id "sites" \
    --connection-name "NewApp-connection"
```

### 4.4 Custom Domains

```powershell
# Add a custom domain
az webapp config hostname add --webapp-name "NewApp" --resource-group "NewRG" \
    --hostname "www.mydomain.com"

# Create a managed certificate (free)
az webapp config ssl create --name "NewApp" --resource-group "NewRG" \
    --hostname "www.mydomain.com"

# Bind the certificate
az webapp config ssl bind --name "NewApp" --resource-group "NewRG" \
    --certificate-thumbprint "{thumbprint}" --ssl-type SNI
```

### 4.5 Authentication (Easy Auth)

```powershell
# Configure Azure AD authentication
az webapp auth microsoft update --name "NewApp" --resource-group "NewRG" \
    --client-id "{app-registration-client-id}" \
    --client-secret "{client-secret}" \
    --issuer "https://login.microsoftonline.com/{tenant-id}/v2.0"

az webapp auth update --name "NewApp" --resource-group "NewRG" --enabled true
```

### 4.6 CORS Settings

```powershell
# Configure CORS
az webapp cors add --name "NewApp" --resource-group "NewRG" \
    --allowed-origins "https://www.mydomain.com" "https://app.mydomain.com"
```

### 4.7 WebJobs

WebJobs must be re-deployed manually:

1. Download WebJobs from old app via Kudu (`https://oldapp.scm.azurewebsites.net/api/zip/data/jobs/`)
2. Upload to new app via Kudu or Azure Portal

### 4.8 Backup Configuration

```powershell
# Configure backup (requires storage account)
az webapp config backup create --webapp-name "NewApp" --resource-group "NewRG" \
    --container-url "https://mystorageaccount.blob.core.windows.net/backups?{sas-token}" \
    --frequency "1d" --retain-one true
```

---

## Compare Source and Target Apps (Pre-Production Verification)

Before going to production, use the comparison script to verify that your target apps have all the necessary configuration from the source apps.

### Command

```powershell
# Compare a single app pair
.\Compare-AppServiceApps.ps1 --tenant <tenantId> \
    --source-subscription <subId> --source-resource-group <rg> --source-app <app> \
    --target-subscription <subId> --target-resource-group <rg> --target-app <app>

# Compare all apps from a migration CSV
.\Compare-AppServiceApps.ps1 --tenant <tenantId> --csv <migrationFile.csv>
```

### Parameters

| Parameter | Required | Description |
|-----------|----------|-------------|
| `--tenant` | Yes | Azure Tenant ID |
| `--source-subscription` | No* | Source subscription ID |
| `--source-resource-group` | No* | Source resource group |
| `--source-app` | No* | Source app name |
| `--target-subscription` | No* | Target subscription ID |
| `--target-resource-group` | No* | Target resource group |
| `--target-app` | No* | Target app name |
| `--csv` | No* | Migration CSV file (compares all successful migrations) |
| `--output` | No | Output file path (default: `.\scans\AppComparison-<timestamp>.txt`) |
| `--json` | No | Also export as JSON file |
| `--ignore-values` | No | Only check if settings exist, not their values |

*Either provide source/target parameters OR a CSV file.

### Examples

```powershell
# Compare a single app pair
.\Compare-AppServiceApps.ps1 --tenant 93f24d9d-38da-4545-be46-e9f4c02b62ee \
    --source-subscription 4af85dff-7368-4ef3-bab1-b9ceab3ed766 \
    --source-resource-group rg-prod \
    --source-app MyWebApp \
    --target-subscription 0530ec14-1234-5678-9abc-def012345678 \
    --target-resource-group rg-prod-new \
    --target-app MyWebApp-new

# Compare all migrated apps from CSV
.\Compare-AppServiceApps.ps1 --tenant 93f24d9d-38da-4545-be46-e9f4c02b62ee --csv .\scans\AppMigration.csv

# Compare with JSON output for automation
.\Compare-AppServiceApps.ps1 --tenant 93f24d9d-38da-4545-be46-e9f4c02b62ee --csv .\scans\AppMigration.csv --json
```

### What Gets Compared

| Category | Items Compared |
|----------|----------------|
| **App Settings** | Names and values (identifies missing, different, or extra settings) |
| **Connection Strings** | Names and types |
| **General Configuration** | AlwaysOn, HTTP/2, Min TLS Version, FTPS State, WebSockets, Runtime Stack |
| **Custom Domains** | Hostnames and SSL state |
| **Managed Identities** | System-assigned and user-assigned identities |
| **VNet Integration** | Subnet configuration |
| **Authentication** | Easy Auth enabled/disabled status |
| **CORS** | Allowed origins |
| **Deployment Slots** | Slot names |
| **IP Restrictions** | Access restriction rules |

### Comparison Report

The report categorizes each item as:

| Status | Icon | Meaning |
|--------|------|---------|
| **Match** | `[=]` | Source and target are identical |
| **Missing** | `[-]` | Exists on source but not on target |
| **Different** | `[!]` | Exists on both but values differ |
| **Extra** | `[+]` | Exists on target but not on source |

### Production Readiness

The script determines if an app is **Ready for Production** based on:

- **Blockers** (must fix): Missing app settings, connection strings, managed identities, VNet integration
- **Warnings** (should review): Different values, missing CORS, missing deployment slots

### Sample Output

```
================================================================================
 OVERALL COMPARISON SUMMARY
================================================================================

 Total Apps Compared: 5
 Ready for Production: 3
 Not Ready: 2

 Apps NOT Ready:
   - MyWebApp-new: 2 blocker(s)
   - ApiService-new: 1 blocker(s)

================================================================================
 APP COMPARISON REPORT
================================================================================

 SOURCE: MyWebApp
 TARGET: MyWebApp-new

--------------------------------------------------------------------------------
 SUMMARY
--------------------------------------------------------------------------------

   [=] Matching Items:    25
   [!] Different Items:   2
   [-] Missing on Target: 3
   [+] Extra on Target:   1

   *** PRODUCTION READY: NO - See blockers below ***

--------------------------------------------------------------------------------
 BLOCKERS (Must Fix Before Production)
--------------------------------------------------------------------------------
   [X] App setting 'ConnectionString__Primary' is missing on target
   [X] System-assigned managed identity not enabled on target

--------------------------------------------------------------------------------
 ACTION ITEMS
--------------------------------------------------------------------------------

   1. ADD App Settings: ConnectionString__Primary
   2. ADD App Settings: ApiKey
   3. ADD Managed Identity: System-Assigned
   4. UPDATE Configuration: AlwaysOn to match source
```

---

## Phase 5: Testing

### Test URLs

| Test | URL |
|------|-----|
| Direct app URL | `https://newapp.azurewebsites.net` |
| Staging slot | `https://newapp-staging.azurewebsites.net` |
| Kudu/SCM | `https://newapp.scm.azurewebsites.net` |

### Testing Checklist

```powershell
# Check app is running
curl https://newapp.azurewebsites.net/health

# Check app settings are applied
az webapp config appsettings list --name "NewApp" --resource-group "NewRG" -o table

# Check connection strings
az webapp config connection-string list --name "NewApp" --resource-group "NewRG" -o table

# View app logs
az webapp log tail --name "NewApp" --resource-group "NewRG"
```

---

## Phase 6: DNS Cutover

### Update DNS Records

1. **Lower TTL** before migration (e.g., 60 seconds)
2. **Update DNS** to point to new app:
   - For `azurewebsites.net`: Update CNAME to `newapp.azurewebsites.net`
   - For Traffic Manager: Update endpoint
   - For Front Door: Update backend pool

### Cutover Commands

```powershell
# If using Azure DNS
az network dns record-set cname set-record --zone-name "mydomain.com" --resource-group "DNS-RG" \
    --record-set-name "www" --cname "newapp.azurewebsites.net"
```

### Rollback Plan

Keep the old apps running for 24-48 hours after cutover:

```powershell
# If rollback needed, update DNS back to old app
az network dns record-set cname set-record --zone-name "mydomain.com" --resource-group "DNS-RG" \
    --record-set-name "www" --cname "oldapp.azurewebsites.net"
```

---

## Complete Example

### 1. Export all apps

```powershell
.\Export-AppServiceApps.ps1 --tenant 93f24d9d-38da-4545-be46-e9f4c02b62ee
```

Output:
```
Export completed!
CSV saved to: .\scans\AppMigration-20251229_140000.csv
```

### 2. Edit the CSV file

Open `.\scans\AppMigration-20251229_140000.csv` in Excel or VS Code and fill in target columns.

### 3. Run import with --whatif first

```powershell
.\Import-AppServiceApps.ps1 --tenant 93f24d9d-38da-4545-be46-e9f4c02b62ee --file ".\scans\AppMigration-20251229_140000.csv" --createMissingPlans --createMissingResourceGroups --whatif
```

### 4. Run the actual import

```powershell
.\Import-AppServiceApps.ps1 --tenant 93f24d9d-38da-4545-be46-e9f4c02b62ee --file ".\scans\AppMigration-20251229_140000.csv" --createMissingPlans --createMissingResourceGroups
```

### 5. Check results in CSV

Open the CSV file to see the `ImportStatus`, `ImportMessage`, and `ImportTimestamp` columns updated with results.

---

## Troubleshooting

### Error: App name not unique

```
ERROR: Unable to retrieve details of the existing app 'MyApp'. 
App names must be globally unique.
```

**Solution**: Use a different name in the `NewAppName` column (e.g., `MyApp-migrated`).

### Error: Resource group doesn't exist

```
Resource group 'rg-NewEnv' does not exist. Use --createMissingResourceGroups to create it.
```

**Solution**: Add `--createMissingResourceGroups` flag or create the resource group manually first.

### Error: App Service Plan doesn't exist

```
App Service Plan 'asp-NewEnv' does not exist. Use --createMissingPlans to create it.
```

**Solution**: Add `--createMissingPlans` flag or create the plan manually first.

### Apps created but settings not copied

If apps are created but settings weren't copied (due to an interrupted import), use the `Copy-AppSettings.ps1` helper script to manually copy settings.

---

## Helper Scripts

### Copy-AppSettings.ps1

Copies app settings and connection strings from a source App Service app to an existing target app. Use this when apps are already created but settings need to be synchronized.

#### Command

```powershell
.\Copy-AppSettings.ps1 --tenant <tenantId> \
    --source-subscription <subId> --source-resource-group <rg> --source-app <app> \
    --target-subscription <subId> --target-resource-group <rg> --target-app <app> [options]
```

#### Parameters

| Parameter | Required | Description |
|-----------|----------|-------------|
| `--tenant` | Yes | Azure Tenant ID |
| `--source-subscription` | Yes | Source subscription ID |
| `--source-resource-group` | Yes | Source resource group |
| `--source-app` | Yes | Source app name |
| `--target-subscription` | No | Target subscription ID (defaults to source) |
| `--target-resource-group` | Yes | Target resource group |
| `--target-app` | Yes | Target app name |
| `--include-connection-strings` | No | Also copy connection strings |
| `--include-general-config` | No | Also copy general config (AlwaysOn, TLS, etc.) |
| `--whatif` | No | Preview changes without applying |
| `--force` | No | Overwrite existing settings without prompting |
| `--exclude <settings>` | No | Comma-separated list of settings to exclude |
| `--only <settings>` | No | Comma-separated list of settings to copy (ignores others) |

#### Examples

```powershell
# Copy all app settings only
.\Copy-AppSettings.ps1 --tenant 93f24d9d-38da-4545-be46-e9f4c02b62ee \
    --source-subscription 4af85dff-7368-4ef3-bab1-b9ceab3ed766 \
    --source-resource-group rg-prod \
    --source-app MyWebApp \
    --target-resource-group rg-prod-new \
    --target-app MyWebApp-new

# Copy everything including connection strings and general config
.\Copy-AppSettings.ps1 --tenant 93f24d9d-38da-4545-be46-e9f4c02b62ee \
    --source-subscription 4af85dff-7368-4ef3-bab1-b9ceab3ed766 \
    --source-resource-group rg-prod \
    --source-app MyWebApp \
    --target-resource-group rg-prod-new \
    --target-app MyWebApp-new \
    --include-connection-strings --include-general-config

# Preview what would be copied (no changes made)
.\Copy-AppSettings.ps1 --tenant 93f24d9d-38da-4545-be46-e9f4c02b62ee \
    --source-subscription 4af85dff-7368-4ef3-bab1-b9ceab3ed766 \
    --source-resource-group rg-prod \
    --source-app MyWebApp \
    --target-resource-group rg-prod-new \
    --target-app MyWebApp-new --whatif

# Copy only specific settings
.\Copy-AppSettings.ps1 --tenant 93f24d9d-38da-4545-be46-e9f4c02b62ee \
    --source-subscription 4af85dff-7368-4ef3-bab1-b9ceab3ed766 \
    --source-resource-group rg-prod \
    --source-app MyWebApp \
    --target-resource-group rg-prod-new \
    --target-app MyWebApp-new \
    --only "ApiKey,DatabaseConnection,StorageAccount"

# Copy all except certain settings
.\Copy-AppSettings.ps1 --tenant 93f24d9d-38da-4545-be46-e9f4c02b62ee \
    --source-subscription 4af85dff-7368-4ef3-bab1-b9ceab3ed766 \
    --source-resource-group rg-prod \
    --source-app MyWebApp \
    --target-resource-group rg-prod-new \
    --target-app MyWebApp-new \
    --exclude "WEBSITE_NODE_DEFAULT_VERSION,SCM_DO_BUILD_DURING_DEPLOYMENT"
```

#### What Gets Copied

| Option | Items Copied |
|--------|--------------|
| **Default** | All app settings (environment variables) |
| `--include-connection-strings` | Connection strings (database connections, etc.) |
| `--include-general-config` | AlwaysOn, HTTP/2, Min TLS Version, FTPS State, WebSockets, Linux Runtime |

#### Use Cases

- **Interrupted import**: If the import script was interrupted after creating apps but before copying settings
- **Manual app creation**: When apps were created manually and need settings from another app
- **Selective sync**: When you need to copy only specific settings between apps
- **Settings refresh**: To re-sync settings after changes were made to the source app

---

## Files

| File | Description |
|------|-------------|
| `Export-AppServiceApps.ps1` | Main export script |
| `Import-AppServiceApps.ps1` | Main import script |
| `Get-AppServiceConfiguration.ps1` | Phase 4 configuration scanner |
| `Compare-AppServiceApps.ps1` | Source/target comparison script |
| `Copy-AppSettings.ps1` | Helper to copy settings to existing apps |
| `scans/` | Default folder for CSV and report output files |

---

## Best Practices

1. **Always run `--whatif` first** to preview changes before creating resources
2. **Use unique app names** - add a suffix like `-migrated`, `-v2`, or `-new`
3. **Back up your CSV** before running import (it gets updated with status)
4. **Test with one app first** before migrating many apps
5. **Check the CSV after import** to see which apps succeeded/failed
6. **Re-run import for failed apps** - successful apps are skipped automatically
7. **Plan a maintenance window** for production migrations
8. **Keep old apps running** until new apps are validated
9. **Lower DNS TTL** before cutover for faster rollback if needed
10. **Document everything** - keep a record of changes made

---

## Migration Timeline Example

| Day | Phase | Activities |
|-----|-------|------------|
| D-7 | Planning | Export apps, run configuration scan, review CSV, plan target environment |
| D-5 | Preparation | Lower DNS TTL, notify stakeholders, review Phase 4 config report |
| D-3 | Create | Run import script to create apps with settings |
| D-2 | Deploy | Deploy code to new apps |
| D-1 | Configure | Set up domains, SSL, identities, VNet (use config report as checklist) |
| D-0 (AM) | Test | Full testing of all apps |
| D-0 (PM) | Cutover | Update DNS, monitor |
| D+1 | Validate | Monitor for issues, fix any problems |
| D+7 | Cleanup | Decommission old apps after validation |

---

## Connected Resources Checklist

Don't forget to update these resources to allow access from new apps:

| Resource | Action Required |
|----------|-----------------|
| **Azure SQL** | Add new app's outbound IPs to firewall, or use VNet integration |
| **Cosmos DB** | Update firewall rules or use private endpoint |
| **Storage Account** | Update firewall or use managed identity |
| **Key Vault** | Add new app's managed identity to access policies |
| **Redis Cache** | Update firewall rules |
| **Service Bus** | Update network rules |
| **Event Hub** | Update network rules |
| **API Management** | Update backend URLs |
| **Application Gateway** | Update backend pool |
| **Front Door** | Update origin group |

---

## Summary

A complete App Service migration involves:

1. **Export** - Use `Export-AppServiceApps.ps1` to create migration plan
2. **Scan Configuration** - Use `Get-AppServiceConfiguration.ps1` to document Phase 4 items
3. **Create** - Use `Import-AppServiceApps.ps1` to create apps with settings
4. **Deploy** - Deploy application code using your preferred method
5. **Configure** - Set up identities, domains, SSL, VNet, etc. (use scan report as checklist)
6. **Compare** - Use `Compare-AppServiceApps.ps1` to verify target matches source
7. **Test** - Thoroughly test all functionality
8. **Cutover** - Update DNS and switch traffic
9. **Validate** - Monitor and keep old apps as rollback option

The scripts automate steps 1-3 and 6. Steps 4-5 and 7-9 require manual intervention based on your specific application requirements.
