#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Get comprehensive access overview for all Microsoft Fabric workspaces with expanded group membership.
    Generates both HTML and CSV reports in the same directory.

.DESCRIPTION
    This script retrieves all Fabric workspaces, their role assignments, and expands group memberships
    to show all users with access. Produces both:
    - workspace-access-report.html (formatted with styling for viewing)
    - workspace-access-report.csv (flat data for processing)

.PARAMETER OutputDirectory
    Directory to save the reports (defaults to current directory)

.EXAMPLE
    .\get-fabric-workspace-access-html.ps1
    
.EXAMPLE
    .\get-fabric-workspace-access-html.ps1 -OutputDirectory "C:\Reports"
#>

param(
    [Parameter()]
    [string]$OutputDirectory = "."
)

$ErrorActionPreference = 'Stop'

# Load System.Web assembly for HTML encoding
Add-Type -AssemblyName System.Web

# Ensure output directory exists
if (-not (Test-Path $OutputDirectory)) {
    New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
}

# Generate timestamp for filename
$timestamp = Get-Date -Format "yyyy-MM-dd-HHmmss"

# Define output paths
$htmlPath = Join-Path $OutputDirectory "workspace-access-report-$timestamp.html"
$csvPath = Join-Path $OutputDirectory "workspace-access-report-$timestamp.csv"

# Check if user is authenticated, if not trigger login
Write-Host "🔐 Checking Azure authentication..." -ForegroundColor Cyan
try {
    $null = az account show 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw "Not logged in"
    }
    Write-Host "✅ Already authenticated" -ForegroundColor Green
} catch {
    Write-Host "⚠️  Not logged in. Opening browser for authentication..." -ForegroundColor Yellow
    az login
    if ($LASTEXITCODE -ne 0) {
        Write-Host "❌ Authentication failed" -ForegroundColor Red
        exit 1
    }
    Write-Host "✅ Authentication successful" -ForegroundColor Green
}
Write-Host ""

Write-Host "🔍 Retrieving Fabric workspaces..." -ForegroundColor Cyan

# Get all workspaces
$workspacesResponse = az rest --method GET `
    --uri "https://api.fabric.microsoft.com/v1/workspaces" `
    --resource "https://api.fabric.microsoft.com" | ConvertFrom-Json

$workspaces = $workspacesResponse.value

if (-not $workspaces -or $workspaces.Count -eq 0) {
    Write-Host "❌ No workspaces found or insufficient permissions" -ForegroundColor Red
    exit 1
}

Write-Host "✅ Found $($workspaces.Count) workspace(s)" -ForegroundColor Green
Write-Host ""

$allWorkspaceAccess = @()

foreach ($workspace in $workspaces) {
    Write-Host "📊 Processing: $($workspace.displayName)" -ForegroundColor Yellow
    
    # Get role assignments for this workspace
    $roleAssignmentsResponse = az rest --method GET `
        --uri "https://api.fabric.microsoft.com/v1/workspaces/$($workspace.id)/roleAssignments" `
        --resource "https://api.fabric.microsoft.com" | ConvertFrom-Json
    
    $roleAssignments = $roleAssignmentsResponse.value
    
    $workspaceData = @{
        WorkspaceId = $workspace.id
        WorkspaceName = $workspace.displayName
        Capacity = $workspace.capacityId
        Type = $workspace.type
        RoleAssignments = @()
        EffectiveUsers = @()
    }
    
    foreach ($assignment in $roleAssignments) {
        $assignmentData = @{
            PrincipalId = $assignment.principal.id
            PrincipalType = $assignment.principal.type
            PrincipalDisplayName = $assignment.principal.displayName
            Role = $assignment.role
            Members = @()
        }
        
        # If it's a group, expand membership
        if ($assignment.principal.type -eq 'Group') {
            Write-Host "  📁 Expanding group: $($assignment.principal.displayName)" -ForegroundColor Gray
            
            try {
                $membersResponse = az rest --method GET `
                    --uri "https://graph.microsoft.com/v1.0/groups/$($assignment.principal.id)/members?`$select=id,displayName,userPrincipalName,mail" | ConvertFrom-Json
                
                $members = $membersResponse.value
                
                foreach ($member in $members) {
                    $memberData = @{
                        Id = $member.id
                        DisplayName = $member.displayName
                        UserPrincipalName = $member.userPrincipalName
                        Mail = $member.mail
                        Type = if ($member.'@odata.type' -eq '#microsoft.graph.user') { 'User' } else { 'Group' }
                    }
                    
                    $assignmentData.Members += $memberData
                    
                    # Add to effective users if it's a user
                    if ($memberData.Type -eq 'User') {
                        $effectiveUser = @{
                            DisplayName = $memberData.DisplayName
                            UserPrincipalName = $memberData.UserPrincipalName
                            Role = $assignment.role
                            Source = "Via group: $($assignment.principal.displayName)"
                        }
                        
                        # Check if user already has direct access or higher role
                        $existingUser = $workspaceData.EffectiveUsers | Where-Object { $_.UserPrincipalName -eq $memberData.UserPrincipalName }
                        if (-not $existingUser) {
                            $workspaceData.EffectiveUsers += $effectiveUser
                        } elseif ($assignment.role -eq 'Admin') {
                            # Admin role always wins
                            $existingUser.Role = 'Admin'
                            $existingUser.Source += " + Via group: $($assignment.principal.displayName)"
                        }
                    }
                }
                
                Write-Host "    ✅ Found $($members.Count) member(s)" -ForegroundColor Green
            } catch {
                Write-Host "    ⚠️  Failed to expand group: $_" -ForegroundColor Yellow
            }
        } else {
            # Direct user assignment
            $effectiveUser = @{
                DisplayName = $assignment.principal.displayName
                UserPrincipalName = $assignment.principal.userPrincipalName
                Role = $assignment.role
                Source = "Direct assignment"
            }
            
            # Check if user already exists (might be in a group)
            $existingUser = $workspaceData.EffectiveUsers | Where-Object { $_.UserPrincipalName -eq $assignment.principal.userPrincipalName }
            if ($existingUser) {
                # If direct assignment is Admin, it wins
                if ($assignment.role -eq 'Admin') {
                    $existingUser.Role = 'Admin'
                }
                # Combine direct assignment with any existing group sources
                $groupSources = ""
                if ($existingUser.Source -match "Via group") {
                    $groupParts = $existingUser.Source -split " \+ " | Where-Object { $_ -match "Via group" }
                    if ($groupParts) {
                        $groupSources = " + " + ($groupParts -join " + ")
                    }
                }
                $existingUser.Source = "Direct assignment" + $groupSources
            } else {
                $workspaceData.EffectiveUsers += $effectiveUser
            }
        }
        
        $workspaceData.RoleAssignments += $assignmentData
    }
    
    $allWorkspaceAccess += $workspaceData
    Write-Host ""
}

# Generate HTML report
$html = @"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Fabric Workspace Access Report</title>
    <style>
        * {
            margin: 0;
            padding: 0;
            box-sizing: border-box;
        }
        
        body {
            font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            padding: 20px;
            min-height: 100vh;
        }
        
        .container {
            max-width: 1400px;
            margin: 0 auto;
            background: white;
            border-radius: 12px;
            box-shadow: 0 20px 60px rgba(0,0,0,0.3);
            overflow: hidden;
        }
        
        .header {
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            color: white;
            padding: 40px;
            text-align: center;
        }
        
        .header h1 {
            font-size: 2.5em;
            margin-bottom: 10px;
            text-shadow: 2px 2px 4px rgba(0,0,0,0.2);
        }
        
        .header .subtitle {
            font-size: 1.2em;
            opacity: 0.9;
        }
        
        .summary {
            background: #f8f9fa;
            padding: 20px 40px;
            border-bottom: 1px solid #dee2e6;
            display: flex;
            justify-content: space-around;
            flex-wrap: wrap;
        }
        
        .summary-item {
            text-align: center;
            padding: 10px 20px;
        }
        
        .summary-item .number {
            font-size: 2.5em;
            font-weight: bold;
            color: #667eea;
        }
        
        .summary-item .label {
            color: #6c757d;
            font-size: 0.9em;
            text-transform: uppercase;
            letter-spacing: 1px;
        }
        
        .content {
            padding: 40px;
        }
        
        .workspace {
            margin-bottom: 40px;
            border: 1px solid #e0e0e0;
            border-radius: 8px;
            overflow: hidden;
            transition: box-shadow 0.3s ease;
        }
        
        .workspace:hover {
            box-shadow: 0 4px 12px rgba(0,0,0,0.1);
        }
        
        .workspace-header {
            background: linear-gradient(to right, #667eea, #764ba2);
            color: white;
            padding: 20px;
            cursor: pointer;
        }
        
        .workspace-header h2 {
            font-size: 1.5em;
            margin-bottom: 5px;
        }
        
        .workspace-header .workspace-id {
            font-size: 0.85em;
            opacity: 0.8;
            font-family: 'Courier New', monospace;
        }
        
        .workspace-body {
            padding: 20px;
            background: #fff;
        }
        
        .section {
            margin-bottom: 25px;
        }
        
        .section h3 {
            color: #495057;
            margin-bottom: 15px;
            padding-bottom: 10px;
            border-bottom: 2px solid #667eea;
            font-size: 1.2em;
        }
        
        table {
            width: 100%;
            border-collapse: collapse;
            margin-top: 10px;
        }
        
        thead {
            background: #f8f9fa;
        }
        
        th {
            text-align: left;
            padding: 12px;
            font-weight: 600;
            color: #495057;
            border-bottom: 2px solid #dee2e6;
        }
        
        td {
            padding: 12px;
            border-bottom: 1px solid #dee2e6;
        }
        
        tr:hover {
            background: #f8f9fa;
        }
        
        .badge {
            display: inline-block;
            padding: 4px 12px;
            border-radius: 12px;
            font-size: 0.85em;
            font-weight: 600;
        }
        
        .badge-admin {
            background: #dc3545;
            color: white;
        }
        
        .badge-contributor {
            background: #fd7e14;
            color: white;
        }
        
        .badge-viewer {
            background: #28a745;
            color: white;
        }
        
        .badge-user {
            background: #007bff;
            color: white;
        }
        
        .badge-group {
            background: #6f42c1;
            color: white;
        }
        
        .badge-sp {
            background: #6c757d;
            color: white;
        }
        
        .source-info {
            color: #6c757d;
            font-size: 0.9em;
            font-style: italic;
        }
        
        .no-data {
            text-align: center;
            padding: 20px;
            color: #6c757d;
            font-style: italic;
        }
        
        .footer {
            background: #f8f9fa;
            padding: 20px;
            text-align: center;
            color: #6c757d;
            border-top: 1px solid #dee2e6;
        }
        
        @media print {
            body {
                background: white;
                padding: 0;
            }
            
            .container {
                box-shadow: none;
            }
            
            .workspace {
                page-break-inside: avoid;
            }
        }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h1>🏢 Fabric Workspace Access Report</h1>
            <div class="subtitle">Comprehensive access overview with group expansion</div>
        </div>
        
        <div class="summary">
            <div class="summary-item">
                <div class="number">$($allWorkspaceAccess.Count)</div>
                <div class="label">Workspaces</div>
            </div>
            <div class="summary-item">
                <div class="number">$(($allWorkspaceAccess | ForEach-Object { $_.EffectiveUsers.Count } | Measure-Object -Sum).Sum)</div>
                <div class="label">Total Users</div>
            </div>
            <div class="summary-item">
                <div class="number">$(($allWorkspaceAccess | ForEach-Object { $_.RoleAssignments.Count } | Measure-Object -Sum).Sum)</div>
                <div class="label">Role Assignments</div>
            </div>
        </div>
        
        <div class="content">
"@

foreach ($ws in $allWorkspaceAccess) {
    $html += @"
            <div class="workspace">
                <div class="workspace-header">
                    <h2>$([System.Web.HttpUtility]::HtmlEncode($ws.WorkspaceName))</h2>
                    <div class="workspace-id">ID: $($ws.WorkspaceId)</div>
                </div>
                <div class="workspace-body">
                    <div class="section">
                        <h3>Direct Role Assignments</h3>
"@
    
    if ($ws.RoleAssignments.Count -eq 0) {
        $html += @"
                        <div class="no-data">No direct role assignments</div>
"@
    } else {
        $html += @"
                        <table>
                            <thead>
                                <tr>
                                    <th>Principal</th>
                                    <th>Type</th>
                                    <th>Role</th>
                                    <th>Members</th>
                                </tr>
                            </thead>
                            <tbody>
"@
        
        foreach ($assignment in $ws.RoleAssignments) {
            $typeBadgeClass = switch ($assignment.PrincipalType) {
                'User' { 'badge-user' }
                'Group' { 'badge-group' }
                'ServicePrincipal' { 'badge-sp' }
                default { 'badge-user' }
            }
            
            $roleBadgeClass = switch ($assignment.Role) {
                'Admin' { 'badge-admin' }
                'Contributor' { 'badge-contributor' }
                'Viewer' { 'badge-viewer' }
                default { 'badge-viewer' }
            }
            
            $membersHtml = ""
            if ($assignment.Members.Count -gt 0) {
                $membersList = ($assignment.Members | ForEach-Object { "$($_.DisplayName) ($($_.UserPrincipalName))" }) -join "<br>"
                $membersHtml = $membersList
            } else {
                $membersHtml = "-"
            }
            
            $html += @"
                                <tr>
                                    <td><strong>$([System.Web.HttpUtility]::HtmlEncode($assignment.PrincipalDisplayName))</strong></td>
                                    <td><span class="badge $typeBadgeClass">$($assignment.PrincipalType)</span></td>
                                    <td><span class="badge $roleBadgeClass">$($assignment.Role)</span></td>
                                    <td>$membersHtml</td>
                                </tr>
"@
        }
        
        $html += @"
                            </tbody>
                        </table>
"@
    }
    
    $html += @"
                    </div>
                    
                    <div class="section">
                        <h3>Effective User Access ($($ws.EffectiveUsers.Count) user(s))</h3>
"@
    
    if ($ws.EffectiveUsers.Count -eq 0) {
        $html += @"
                        <div class="no-data">No users with access</div>
"@
    } else {
        $html += @"
                        <table>
                            <thead>
                                <tr>
                                    <th>Display Name</th>
                                    <th>User Principal Name</th>
                                    <th>Role</th>
                                    <th>Source</th>
                                </tr>
                            </thead>
                            <tbody>
"@
        
        # Sort by role (Admin first) then by name
        $sortedUsers = $ws.EffectiveUsers | Sort-Object @{Expression={if($_.Role -eq 'Admin'){0}else{1}}}, DisplayName
        
        foreach ($user in $sortedUsers) {
            $roleBadgeClass = switch ($user.Role) {
                'Admin' { 'badge-admin' }
                'Contributor' { 'badge-contributor' }
                'Viewer' { 'badge-viewer' }
                default { 'badge-viewer' }
            }
            
            $html += @"
                                <tr>
                                    <td><strong>$([System.Web.HttpUtility]::HtmlEncode($user.DisplayName))</strong></td>
                                    <td>$([System.Web.HttpUtility]::HtmlEncode($user.UserPrincipalName))</td>
                                    <td><span class="badge $roleBadgeClass">$($user.Role)</span></td>
                                    <td><span class="source-info">$([System.Web.HttpUtility]::HtmlEncode($user.Source))</span></td>
                                </tr>
"@
        }
        
        $html += @"
                            </tbody>
                        </table>
"@
    }
    
    $html += @"
                    </div>
                </div>
            </div>
"@
}

$html += @"
        </div>
        
        <div class="footer">
            Generated on $(Get-Date -Format "yyyy-MM-dd HH:mm:ss") | Microsoft Fabric Workspace Access Report
        </div>
    </div>
</body>
</html>
"@

# Add System.Web assembly for HTML encoding
Add-Type -AssemblyName System.Web

# Save HTML report
$html | Out-File -FilePath $htmlPath -Encoding UTF8
Write-Host "✅ Saved HTML report to: $htmlPath" -ForegroundColor Green

# Generate and save CSV report
Write-Host "📊 Generating CSV report..." -ForegroundColor Cyan
$csvData = @()
foreach ($ws in $allWorkspaceAccess) {
    foreach ($user in $ws.EffectiveUsers) {
        $csvData += [PSCustomObject]@{
            WorkspaceName = $ws.WorkspaceName
            WorkspaceId = $ws.WorkspaceId
            UserDisplayName = $user.DisplayName
            UserPrincipalName = $user.UserPrincipalName
            Role = $user.Role
            Source = $user.Source
        }
    }
}

$csvData | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
Write-Host "✅ Saved CSV report to: $csvPath" -ForegroundColor Green

Write-Host ""
Write-Host "📁 Reports saved to: $OutputDirectory" -ForegroundColor Yellow
Write-Host "   • HTML: $(Split-Path -Leaf $htmlPath) (open in browser)" -ForegroundColor White
Write-Host "   • CSV:  $(Split-Path -Leaf $csvPath) (import to Excel/analysis tools)" -ForegroundColor White
