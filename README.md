# Fabric Permissions Tracker

Automated tracking of Microsoft Fabric workspace access permissions with expension off the groups, so you will know all the users!

In Fabric you can see which users and groups have permissions to a workspace, but how do you know who is in a certain group?
Run this powershell script and you will know! It will create a HTML & CSV file with the same content to show you exactly this. Who has what privileges via which group.
If you import the notebook, attach a lakehouse and run it every day, then you will see exactly the same, but you can also see when someone don't have access anymore and since when.



## Overview

This repository contains tools to monitor and track access permissions across all Microsoft Fabric workspaces. It captures daily snapshots of who has access to what, detects when access is granted or revoked, and maintains a complete historical audit trail.

**Key Features:**
- 📊 **Complete Workspace Coverage** - Scans all accessible Fabric workspaces
- 👥 **Security Group Expansion** - Automatically expands Azure AD/Entra security groups to individual members
- 📅 **Temporal Tracking** - Records `granted_on_dt` and `revoked_on_dt` for every access record
- 🔍 **Change Detection** - Identifies new access, continuing access, and removed access
- 💾 **Historical Audit Trail** - Preserves complete access history in Delta Lake format
- ⚡ **Two Deployment Options** - PowerShell script or Fabric Notebook

## Tools

### 1. PowerShell Script (`get-fabric-workspace-access.ps1`)

**Use Case:** One-time reports, ad-hoc analysis, local execution

**Features:**
- Retrieves all workspace access permissions
- Expands security group memberships
- Outputs to console (CSV/JSON export optional)
- No temporal tracking (snapshot only)

**Prerequisites:**
- PowerShell 7+
- Azure CLI (`az login` completed)
- Fabric API permissions

**Usage:**
```powershell
# Run the script
.\get-fabric-workspace-access.ps1

# Output shows workspace name, user, role, and whether from security group expansion
```

---

### 2. Fabric Notebook (`WorkspaceAccessReport.ipynb`)

**Use Case:** Daily automated execution with historical tracking

**Features:**
- Runs daily via Fabric Data Pipeline (scheduled)
- Tracks access over time with granted/revoked dates
- Stores results in Delta Lake table (`workspace_access_report`)
- Preserves historical records with `is_active` flag
- Summary statistics and visualization

**Prerequisites:**
- Microsoft Fabric workspace
- Lakehouse attached to notebook (for Delta table storage)
- Graph API permissions for group member reads
- Fabric API access token

**Schema:**
| Field | Type | Description |
|-------|------|-------------|
| `WorkspaceId` | string | Fabric workspace GUID |
| `WorkspaceName` | string | Workspace display name |
| `PrincipalId` | string | User or group object ID |
| `PrincipalName` | string | User principal name or group name |
| `PrincipalType` | string | `User` or `Group` |
| `Role` | string | `Admin`, `Member`, `Contributor`, `Viewer` |
| `FromGroupExpansion` | boolean | True if derived from security group membership |
| `SourceGroupId` | string | Parent group ID (if `FromGroupExpansion = true`) |
| `SourceGroupName` | string | Parent group name |
| `granted_on_dt` | date | Date access was first detected |
| `revoked_on_dt` | date | Date access was removed (null if active) |
| `is_active` | boolean | True if access currently exists |
| `snapshot_date` | date | Date of this snapshot |

**Setup:**

1. **Upload to Fabric:**
   - Upload `WorkspaceAccessReport.ipynb` to your Fabric workspace
   - Or use the Fabric REST API with the notebook definition

2. **Attach Lakehouse:**
   - Open the notebook in Fabric portal
   - Click "Add Lakehouse" → select or create a lakehouse
   - Set as default lakehouse

3. **First Run:**
   - Execute all cells
   - Creates `workspace_access_report` Delta table
   - Populates initial baseline with `granted_on_dt = today`

4. **Schedule (Optional):**
   - Create a Fabric Data Pipeline
   - Add a Notebook activity pointing to `WorkspaceAccessReport`
   - Set schedule trigger (recommended: daily at 2 AM)

**Usage:**
```python
# After initial setup, query historical data:

# Show all active access
spark.sql("""
    SELECT WorkspaceName, PrincipalName, Role, granted_on_dt
    FROM workspace_access_report
    WHERE is_active = true
    ORDER BY WorkspaceName, Role
""").show()

# Show recently granted access (last 7 days)
spark.sql("""
    SELECT WorkspaceName, PrincipalName, Role, granted_on_dt
    FROM workspace_access_report
    WHERE granted_on_dt >= current_date() - 7
    ORDER BY granted_on_dt DESC
""").show()

# Show recently revoked access
spark.sql("""
    SELECT WorkspaceName, PrincipalName, Role, granted_on_dt, revoked_on_dt
    FROM workspace_access_report
    WHERE is_active = false
      AND revoked_on_dt >= current_date() - 7
    ORDER BY revoked_on_dt DESC
""").show()
```

## How It Works

### Change Detection Logic

The notebook compares today's snapshot against historical active records:

1. **New Access** - In current snapshot, NOT in historical active records
   - Sets `granted_on_dt = today`
   - Sets `is_active = true`

2. **Continuing Access** - In BOTH current snapshot AND historical active records
   - Preserves original `granted_on_dt`
   - Keeps `is_active = true`

3. **Removed Access** - In historical active records, NOT in current snapshot
   - Preserves original `granted_on_dt`
   - Sets `revoked_on_dt = today`
   - Sets `is_active = false`

All records are appended to the Delta table, preserving complete audit history.

## Security Group Expansion

Both tools automatically expand Azure AD/Entra security groups to individual user members via Microsoft Graph API:

- When a workspace has a security group assigned as Admin/Member/Contributor/Viewer
- The tool queries Graph API for all members of that group
- Each member appears as an individual record with:
  - `FromGroupExpansion = true`
  - `SourceGroupId` = parent group GUID
  - `SourceGroupName` = parent group display name

This ensures you see **exactly who** has access, not just which groups are assigned.

## Output Examples

### PowerShell Output (Console):
```
WorkspaceName: DataEngineering
├─ Admin
│  ├─ john.doe@contoso.com (Direct)
│  └─ jane.smith@contoso.com (via Group: Data Engineering Admins)
├─ Member
│  └─ alice.jones@contoso.com (Direct)
└─ Viewer
   └─ bob.wilson@contoso.com (via Group: Data Readers)
```

### Notebook Output (Delta Table Sample):
```
+------------------+------------------+-----------+--------------------+
| WorkspaceName    | PrincipalName    | Role      | granted_on_dt      |
+------------------+------------------+-----------+--------------------+
| DataEngineering  | john.doe@...     | Admin     | 2026-05-01         |
| DataEngineering  | jane.smith@...   | Admin     | 2026-05-15         |
| DataEngineering  | alice.jones@...  | Member    | 2026-05-01         |
+------------------+------------------+-----------+--------------------+
```

## Permissions Required

### Fabric API
- Read access to all workspaces you want to monitor
- Authenticated via `az login` (PowerShell) or `notebookutils.credentials.getToken("pbi")` (Notebook)

### Microsoft Graph API
- `Group.Read.All` (Application) or `GroupMember.Read.All` (Delegated)
- Required for security group member expansion
- Authenticated via `az login` (PowerShell) or `notebookutils.credentials.getToken("https://graph.microsoft.com")` (Notebook)

## Troubleshooting

**Q: "Empty results" or "No workspaces found"**  
A: Verify your authentication has Fabric workspace read access. Try `az account show` to confirm correct tenant.

**Q: "Group expansion failed"**  
A: Check Graph API permissions. You need `Group.Read.All` or `GroupMember.Read.All`.

**Q: "Notebook shows empty when opened in portal"**  
A: If uploading via REST API, ensure you're using proper Fabric notebook format with cell markers.

**Q: "Delta table not found"**  
A: Ensure lakehouse is attached to notebook before first run. The table is created on first execution.

## Contributing

Contributions welcome! Please:
- Test changes against a non-production Fabric workspace
- Update README if adding new features
- Include sample output for new query patterns

## License

MIT License - see LICENSE file for details

## Support

For issues or questions:
- Open a GitHub Issue
- Include error messages and Fabric/PowerShell versions
- Sanitize any sensitive workspace/user names from logs

---

**Built with:** GitHub Copilot + Microsoft Fabric  
**Last Updated:** May 28, 2026
