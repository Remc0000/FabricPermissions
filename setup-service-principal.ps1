# setup-service-principal.ps1
# Creates an Entra app registration with the permissions needed by WorkspaceAccessReport.ipynb
# Prerequisites: az CLI installed and logged in as Global Administrator or Privileged Role Administrator

#Requires -Version 7

$ErrorActionPreference = "Stop"

$APP_NAME = "FabricWorkspaceAccessReport"

Write-Host "`n🔐 Creating service principal for Fabric Workspace Access Report...`n"

# 1 — Check az login
$account = az account show -o json 2>$null | ConvertFrom-Json
if (-not $account) {
    Write-Error "Not logged in. Run 'az login' first."
}
Write-Host "✓ Logged in as: $($account.user.name) (tenant: $($account.tenantId))"

# 2 — Create app registration
Write-Host "`n📝 Creating app registration '$APP_NAME'..."
$existing = az ad app list --display-name $APP_NAME --query "[0]" -o json | ConvertFrom-Json
if ($existing) {
    Write-Host "  ℹ️  App '$APP_NAME' already exists (appId: $($existing.appId)) — reusing."
    $appId       = $existing.appId
    $appObjectId = $existing.id
} else {
    $app         = az ad app create --display-name $APP_NAME -o json | ConvertFrom-Json
    $appId       = $app.appId
    $appObjectId = $app.id
    Write-Host "  ✓ App created (appId: $appId)"
}

# 3 — Create service principal
Write-Host "`n👤 Creating service principal..."
$spExists = az ad sp show --id $appId -o json 2>$null | ConvertFrom-Json
if ($spExists) {
    Write-Host "  ℹ️  Service principal already exists — reusing."
    $spId = $spExists.id
} else {
    $sp   = az ad sp create --id $appId -o json | ConvertFrom-Json
    $spId = $sp.id
    Write-Host "  ✓ Service principal created"
}

# 4 — Create client secret
Write-Host "`n🔑 Creating client secret (valid 1 year)..."
$cred   = az ad app credential reset --id $appId --years 1 -o json | ConvertFrom-Json
$secret = $cred.password
Write-Host "  ✓ Client secret created"

# 5 — Add GroupMember.Read.All to app manifest
Write-Host "`n📋 Adding GroupMember.Read.All to app manifest..."
$manifest = '{"requiredResourceAccess":[{"resourceAppId":"00000003-0000-0000-c000-000000000000","resourceAccess":[{"id":"98830695-27a2-44f7-8c18-0c3ebc9698f6","type":"Role"},{"id":"df021288-bdef-4463-88db-98f22de89214","type":"Role"}]}]}'
$manifest | Out-File "$env:TEMP\appmft.json" -Encoding utf8 -NoNewline
az rest --method patch --resource "https://graph.microsoft.com" `
    --url "https://graph.microsoft.com/v1.0/applications/$appObjectId" `
    --body "@$env:TEMP\appmft.json" -o none
Write-Host "  ✓ Manifest updated — waiting 15s for propagation..."
Start-Sleep -Seconds 15

# 6 — Grant admin consent via appRoleAssignments
Write-Host "`n✅ Granting admin consent for GroupMember.Read.All and User.Read.All..."
$graphSpId = (az ad sp show --id "00000003-0000-0000-c000-000000000000" --query "id" -o tsv).Trim()

$permissions = @(
    @{ id = "98830695-27a2-44f7-8c18-0c3ebc9698f6"; name = "GroupMember.Read.All" }
    @{ id = "df021288-bdef-4463-88db-98f22de89214"; name = "User.Read.All" }
)

$existing = az rest --method get --resource "https://graph.microsoft.com" `
    --url "https://graph.microsoft.com/v1.0/servicePrincipals/$spId/appRoleAssignments" `
    -o json | ConvertFrom-Json

foreach ($perm in $permissions) {
    $alreadyGranted = $existing.value | Where-Object { $_.appRoleId -eq $perm.id }
    if ($alreadyGranted) {
        Write-Host "  ℹ️  $($perm.name) already granted — skipping."
    } else {
        $body = "{`"principalId`":`"$spId`",`"resourceId`":`"$graphSpId`",`"appRoleId`":`"$($perm.id)`"}"
        $body | Out-File "$env:TEMP\approle.json" -Encoding utf8 -NoNewline
        az rest --method post --resource "https://graph.microsoft.com" `
            --url "https://graph.microsoft.com/v1.0/servicePrincipals/$spId/appRoleAssignments" `
            --body "@$env:TEMP\approle.json" -o none
        Write-Host "  ✓ $($perm.name) granted"
    }
}

# 7 — Output
Write-Host "`n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
Write-Host "✅ Setup complete! Add these to WorkspaceAccessReport.ipynb:"
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
Write-Host ""
Write-Host "  SP_CLIENT_ID     = `"$appId`""
Write-Host "  SP_CLIENT_SECRET = `"$secret`""
Write-Host "  SP_TENANT_ID     = `"$($account.tenantId)`""
Write-Host ""
Write-Host "⚠️  Store the client secret securely. It expires in 1 year."
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━`n"
