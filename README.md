# Fabric Permissions Tracker

Ever wondered who **exactly** has access to your Microsoft Fabric workspaces? Fabric shows you which users and groups are assigned, but not who is inside those groups. This repo solves that — it expands every group to individual users so you always have a complete picture.

Two tools are included depending on your use case:

| Tool | Best for |
|---|---|
| `get-fabric-workspace-access.ps1` | One-off report, no setup required |
| `WorkspaceAccessReport.ipynb` | Daily automated tracking with full history |

---

## PowerShell Script

### What it does

Run it locally and it will:

1. Connect to your Fabric tenant using your existing Azure CLI login
2. Retrieve every workspace you have access to
3. For each workspace, pull all role assignments (Admin, Member, Contributor, Viewer)
4. Expand any Entra security groups to their individual members via the Graph API
5. Generate two output files:
   - `workspace-access-report-<timestamp>.html` — a styled report you can open in any browser
   - `workspace-access-report-<timestamp>.csv` — a flat file for Excel or further analysis

### How to run it

**Prerequisites:**
- PowerShell 7+
- Azure CLI (`az`) installed and logged in (`az login`)

```powershell
# Run from the repo directory
.\get-fabric-workspace-access.ps1

# Or specify an output directory
.\get-fabric-workspace-access.ps1 -OutputDirectory "C:\Reports"
```

The script automatically opens the browser for login if you are not yet authenticated. When it finishes it prints the paths to both output files.

---

## Fabric Notebook

### What it does

The notebook does everything the PowerShell script does, but runs inside Fabric on a schedule. It:

1. Retrieves all workspace role assignments and expands group memberships
2. Compares today's snapshot against the previous run to detect changes
3. Marks new access with a `granted_on_dt` date
4. Marks removed access with a `revoked_on_dt` date
5. Appends all records to a Delta Lake table (`workspace_access_report`) in your lakehouse

Run it daily and you will have a full audit trail of who got access when, and when they lost it.

**Delta table schema:**

| Column | Description |
|---|---|
| `WorkspaceId` | Fabric workspace GUID |
| `WorkspaceName` | Workspace display name |
| `PrincipalType` | `User` or group-expanded `User` |
| `PrincipalId` | Entra object ID |
| `UserPrincipalName` | UPN of the user |
| `PrincipalDisplayName` | Display name |
| `Role` | `Admin`, `Member`, `Contributor`, or `Viewer` |
| `GroupName` | Source group name (if access comes via a group) |
| `GroupId` | Source group ID |
| `granted_on_dt` | Date access was first detected |
| `revoked_on_dt` | Date access was removed (`null` if still active) |
| `snapshot_date` | Date of this run |
| `access_key` | Unique key: `WorkspaceId|PrincipalId|Role` |

### Setup

#### Step 1 — Create the service principal

The notebook needs a service principal to call the Microsoft Graph API from Fabric Spark (the built-in token provider does not support Graph). Run the included setup script:

```powershell
# Requires: az CLI installed, logged in as Global Admin or Privileged Role Admin
.\setup-service-principal.ps1
```

The script will:
- Create an app registration named `FabricWorkspaceAccessReport`
- Create a service principal for it
- Generate a client secret (valid 1 year)
- Grant `GroupMember.Read.All` with admin consent (needed to read group members)
- Print the three values you need for the next step

Output looks like:

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
✅ Setup complete! Add these to WorkspaceAccessReport.ipynb:
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  SP_CLIENT_ID     = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
  SP_CLIENT_SECRET = "your-generated-secret"
  SP_TENANT_ID     = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"

⚠️  Store the client secret securely. It expires in 1 year.
```

#### Step 2 — Upload the notebook to Fabric

1. Go to your Fabric workspace
2. Click **New → Import notebook**
3. Upload `WorkspaceAccessReport.ipynb`

#### Step 3 — Attach a lakehouse

1. Open the notebook in Fabric
2. Click **Add lakehouse** (left panel)
3. Select or create a lakehouse — this is where the Delta table will be stored

#### Step 4 — Fill in the service principal credentials

At the top of the first code cell, paste the values from Step 1:

```python
SP_CLIENT_ID     = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
SP_CLIENT_SECRET = "your-generated-secret"
SP_TENANT_ID     = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
```

> 💡 For production use, pass these as Fabric Pipeline parameters or retrieve the secret from Azure Key Vault:
> ```python
> SP_CLIENT_SECRET = notebookutils.credentials.getSecretWithLS("your-kv-name", "sp-client-secret")
> ```

#### Step 5 — Run and schedule

Run all cells manually first to verify everything works and create the initial baseline.

To run it daily:
1. Create a **Fabric Data Pipeline**
2. Add a **Notebook activity** pointing to `WorkspaceAccessReport`
3. Set a **schedule trigger** (e.g. daily at 06:00)

---

## Querying the history

Once the notebook has run a few times you can query the Delta table directly in Fabric:

```python
# Everyone with access right now
spark.sql("""
    SELECT WorkspaceName, PrincipalDisplayName, Role, GroupName, granted_on_dt
    FROM workspace_access_report
    WHERE revoked_on_dt IS NULL
    ORDER BY WorkspaceName, Role
""").show()

# Access granted in the last 7 days
spark.sql("""
    SELECT WorkspaceName, PrincipalDisplayName, Role, granted_on_dt
    FROM workspace_access_report
    WHERE granted_on_dt >= current_date() - 7
    ORDER BY granted_on_dt DESC
""").show()

# Access revoked in the last 30 days
spark.sql("""
    SELECT WorkspaceName, PrincipalDisplayName, Role, granted_on_dt, revoked_on_dt
    FROM workspace_access_report
    WHERE revoked_on_dt >= current_date() - 30
    ORDER BY revoked_on_dt DESC
""").show()
```

---

## Required permissions

| What | Where | Permission needed |
|---|---|---|
| Read workspaces and roles | Fabric API | At least Viewer on each workspace (or Fabric Admin for all) |
| Expand group members | Microsoft Graph | `GroupMember.Read.All` (granted by `setup-service-principal.ps1`) |

---

## License

MIT