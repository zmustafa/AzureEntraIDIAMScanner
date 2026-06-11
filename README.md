# Azure and EntraID IAM Scanner

[![CI](https://github.com/zmustafa/AzureEntraIDIAMScanner/actions/workflows/ci.yml/badge.svg)](https://github.com/zmustafa/AzureEntraIDIAMScanner/actions/workflows/ci.yml)
[![CodeQL](https://github.com/zmustafa/AzureEntraIDIAMScanner/actions/workflows/codeql.yml/badge.svg)](https://github.com/zmustafa/AzureEntraIDIAMScanner/actions/workflows/codeql.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![PowerShell 5.1+](https://img.shields.io/badge/PowerShell-5.1%2B-5391FE?logo=powershell&logoColor=white)](https://learn.microsoft.com/powershell/)
[![Node.js 18+](https://img.shields.io/badge/Node.js-18%2B-339933?logo=node.js&logoColor=white)](https://nodejs.org/)
[![Read-only](https://img.shields.io/badge/access-read--only-success)](SECURITY.md)

`all-azure-access` is the package and scanner command identity for Azure and EntraID IAM Scanner, a console-runnable Azure and Microsoft Entra access discovery scanner. It is designed to inventory broad access across Azure control plane, Azure data plane role assignments, Entra directory roles, group-derived access, service principal ownership, Key Vault access policies, and optional/best-effort access surfaces such as PIM, billing, reservations, and classic subscription administrators.

The scanner is intentionally resilient: each access area is collected independently, failures are recorded in the output, and the run continues wherever possible.

## Safety Notes

- The scanner performs read-only discovery through Azure CLI, Microsoft Graph, and Azure Resource Manager APIs.
- The scanner uses your existing local `az login` session. It does not ask for or store passwords, client secrets, certificates, refresh tokens, or private keys.
- Real scan outputs can contain sensitive access data, including privileged users, groups, service principals, ownership relationships, subscriptions, resources, and role assignments.
- Do not commit real scan outputs to a public repository.
- Real scan outputs are written outside the repository by default under the OS temp folder, for example `%TEMP%\azure-scanners\all-azure-access\<timestamp>\` on Windows.

## Support Policy

This v1 package is Windows-first and is tested with Windows PowerShell. PowerShell 7 may work for many paths, but cross-platform Linux/macOS support is not the current compatibility target.

## Primary Command

From this standalone folder:

```powershell
npm install
powershell -ExecutionPolicy Bypass -File .\run.ps1 -ContinueOnError
```

A practical bounded validation run:

```powershell
powershell -ExecutionPolicy Bypass -File .\run.ps1 -LimitResources 25 -SkipReservations -ContinueOnError
```

Target one or more subscriptions:

```powershell
powershell -ExecutionPolicy Bypass -File .\run.ps1 -SubscriptionIds <subscription-id-1>,<subscription-id-2> -ContinueOnError
```

Choose a custom output root:

```powershell
powershell -ExecutionPolicy Bypass -File .\run.ps1 -OutputRoot D:\AzureScannerOutput -LimitResources 25 -SkipReservations -ContinueOnError
```

You can also set a default output root for your shell session:

```powershell
$env:AZURE_IAM_SCANNER_OUTPUT_ROOT = 'D:\AzureScannerOutput'
powershell -ExecutionPolicy Bypass -File .\run.ps1 -LimitResources 25 -SkipReservations -ContinueOnError
```

## What It Discovers

### Microsoft Entra ID RBAC

Collects Entra directory role assignments through Microsoft Graph role management APIs.

Examples of roles represented in this surface:

- Global Administrator
- Privileged Role Administrator
- User Administrator
- Application Administrator
- Groups Administrator
- Security Administrator
- Exchange Administrator
- Teams Administrator
- SharePoint Administrator
- Intune Administrator
- Compliance and security portal roles exposed through Entra role APIs

Captured details include role name, principal id/type, assignment state, directory scope, app scope when present, assignment id, and source API metadata.

### Azure RBAC

Collects Azure Resource Manager role assignments across visible Azure subscriptions and scopes.

Supported scope levels include:

- tenant root scope, best effort
- management groups, best effort
- subscriptions
- resource groups
- resources
- selected child-resource scopes such as storage containers and file shares

Examples of Azure RBAC roles represented in this surface:

- Owner
- Contributor
- Reader
- User Access Administrator
- Network Contributor
- Virtual Machine Contributor
- Key Vault Contributor
- Storage Account Contributor
- custom Azure roles

The scanner preserves scope, scope type, role definition id, assignment id, assignment timestamps, conditions, condition version, inherited flag when returned, subscription name/id, resource group, resource type, and resource name.

### Azure Data-Plane RBAC

Azure data-plane roles are usually assigned through Azure RBAC but grant access to data inside services rather than only management of the ARM resource shell.

The scanner classifies role definitions and observed assignments as control-plane, data-plane, or mixed where possible.

Examples:

- Storage Blob Data Reader
- Storage Blob Data Contributor
- Storage Blob Data Owner
- Storage File Data SMB Share Reader
- Storage File Data SMB Share Contributor
- Key Vault Secrets User
- Key Vault Crypto Officer
- Event Hubs Data Receiver
- Event Hubs Data Sender
- Service Bus Data Sender
- Service Bus Data Receiver

### Storage Child Scopes

The scanner attempts child-scope discovery for common Storage RBAC data scopes, including:

- blob containers
- file shares

When those scopes are visible and supported by the Azure CLI in the current environment, role assignments are queried at the child scope and included in the normalized output.

### Group and Nested Group Expansion

For assignments granted to Entra groups, the scanner attempts to expand transitive group membership through Microsoft Graph.

It records:

- the assigned group
- effective members resolved through transitive membership
- access path as `GroupTransitive`
- group chain text where available
- source group id/name

This lets the report answer both questions:

- Who was directly assigned?
- Who effectively receives access through group membership?

Use this flag to skip group expansion:

```powershell
-NoGroupExpansion
```

### Service Principal and Application Ownership

For service principals observed in access assignments, the scanner attempts to retrieve service principal owners through Microsoft Graph.

Owner rows are emitted as effective ownership access because owners may be able to control credentials, federated credentials, or operational identity configuration depending on tenant policy.

Output includes:

- service principal id/name
- owner principal id/type/name
- owner UPN when available
- access path `Owner`
- assignment type `Owner`

### Key Vault Access Policies

The scanner handles Key Vault legacy access policies separately from Azure RBAC.

This matters because older Key Vaults may still grant data-plane permissions using access policies rather than Azure RBAC roles.

Captured details include:

- vault scope
- policy object id
- serialized key/secret/certificate/storage permissions
- subscription/resource group/vault metadata

### PIM / Eligible Access

The scanner attempts to collect eligible assignments where permitted.

Best-effort collectors include:

- Entra directory role eligibility through Graph
- Azure role eligibility through ARM authorization APIs

PIM is not treated as a separate permission model. Rows are marked with assignment states such as `Eligible` so the workbook can distinguish active access from eligible/JIT access.

### Billing, Reservations, and Cost-Adjacent Access

Billing and reservation APIs often require separate permissions. These collectors are best-effort and record status rather than blocking the run.

Best-effort surfaces include:

- billing accounts
- billing scopes
- reservation orders
- reservation scopes
- role assignments at billing/reservation scopes where the Azure CLI/API supports them

For console stability, reservation collection can be skipped:

```powershell
-SkipReservations
```

### Classic Subscription Administrators

The scanner attempts to include classic administrator style assignments where the Azure CLI returns them.

Examples:

- Account Administrator
- Service Administrator
- Co-Administrator

Classic admin rows are labeled with the `ClassicAzureAdmin` access model.

## Failure Handling

The scanner is built around independent collectors. If one collector fails, the failure is recorded and the scan continues.

Collector statuses include:

- `Succeeded`
- `SucceededWithWarnings`
- `Skipped`
- `Failed`
- `Unauthorized`
- `Throttled`
- `PartiallyCollected`

Exit codes:

- `0`: completed successfully
- `2`: completed with warnings, partial failures, or unauthorized optional collectors
- `1`: startup-level failure, such as missing Azure CLI, no login, or output folder failure

Errors and warnings are written to:

```text
output\collectorStatus.csv
output\errorsWarnings.csv
errors\<collector>.json
logs\all-azure-access.log
```

## Output Location

Each run writes beneath:

```text
%TEMP%\azure-scanners\all-azure-access\<timestamp>\
```

The run folder contains:

```text
output\
logs\
errors\
cache\
raw\
reports\
```

## Main Output Files

```text
output\allAzureAccess.csv
output\allAzureAccess.json
output\effectiveAccess.csv
output\directAssignments.csv
output\groupDerivedAccess.csv
output\nestedGroupAccess.csv
output\servicePrincipalOwners.csv
output\principalResolution.csv
output\groupExpansion.csv
output\roleDefinitions.csv
output\scopeInventory.csv
output\collectorStatus.csv
output\coverageSummary.json
output\errorsWarnings.csv
output\results.json
output\results.zip
reports\all-azure-access-report-<timestamp>.xlsx
reports\all-azure-access-summary-<timestamp>.json
```

## Workbook Sheets

The generated workbook is designed for review and pivot-style discovery.

Sheets include:

- Executive Summary
- Collector Status
- Coverage
- All Access Raw
- Effective Access
- Privileged Access
- Data Plane Access
- Service Principal Owners
- Group Access
- Entra Roles
- Azure RBAC
- Management Groups
- Subscriptions
- Resource Groups
- Resources
- Storage Child Scopes
- Key Vault Access
- PIM
- Billing Reservations
- Classic Admins
- Role Definitions
- Principal Directory
- Errors Warnings
- Source Metadata
- Pivots

## Pivot-Style Summaries

The workbook includes precomputed summary sections such as:

- Access by Surface
- Access by Role
- Access by Principal Type
- Access by Principal
- Access by Subscription
- Access by Management Group
- Access by Scope Type
- Privileged Roles by Principal
- Data Plane Roles by Resource Type
- Group-Derived Access by Group
- PIM Eligible vs Active
- Failures by Collector
- Resources Discovered by Type

## Normalized Access Columns

The primary normalized output uses a wide schema so different access models can be compared in one workbook.

Important columns include:

```text
surface
accessModel
collector
assignmentState
assignmentType
principalId
principalType
principalDisplayName
principalUserPrincipalName
principalAppId
effectivePrincipalId
effectivePrincipalType
effectivePrincipalName
effectivePrincipalUserPrincipalName
accessPath
groupChain
sourceGroupId
sourceGroupName
roleName
roleDefinitionId
roleCategory
roleIsPrivileged
roleHasDataActions
scope
scopeType
scopeDisplayName
tenantId
managementGroupId
managementGroupName
subscriptionId
subscriptionName
resourceGroup
resourceType
resourceName
childResourceType
childResourceName
assignmentId
assignmentCreatedOn
assignmentUpdatedOn
condition
conditionVersion
isInherited
sourceApi
collectionStatus
errorCode
errorMessage
```

## Useful Flags

```powershell
-SubscriptionIds <string[]>
```
Limit scan to specific subscriptions.

```powershell
-ManagementGroupIds <string[]>
```
Limit management group RBAC collection to specific management groups.

```powershell
-ResourceTypes <string[]>
```
Limit resource inventory to specific ARM resource types.

```powershell
-LimitResources <int>
```
Limit resources per subscription during resource-level discovery. Useful for validation runs.

```powershell
-SkipResourceLevel
```
Skip resource-level role assignment checks.

```powershell
-SkipChildDataScopes
```
Skip storage child-scope discovery such as blob containers and file shares.

```powershell
-SkipPim
```
Skip PIM eligibility collectors.

```powershell
-SkipBilling
```
Skip billing collectors.

```powershell
-SkipReservations
```
Skip reservation collectors. Recommended for faster console runs unless reservation access is explicitly needed.

```powershell
-SkipClassicAdmins
```
Skip classic subscription administrator checks.

```powershell
-SkipKeyVaultAccessPolicies
```
Skip legacy Key Vault access policy collection.

```powershell
-NoGroupExpansion
```
Do not expand group assignments into effective transitive user/service principal rows.

```powershell
-FullRoleDefinitionScan
```
Collect role definitions from every visible subscription and management group. Without this flag, the scanner collects role definitions from a responsive subscription and infers metadata from observed assignments to keep console runs fast.

```powershell
-ContinueOnError
```
Continue on collector failures. This is the expected operating mode for broad tenant discovery.

```powershell
-FailFast
```
Stop on the first non-optional collector failure.

```powershell
-OutputRoot <path>
```
Write run outputs beneath a custom root. If omitted, the scanner uses `AZURE_IAM_SCANNER_OUTPUT_ROOT` when set, otherwise the OS temp folder plus `azure-scanners`.

## Recommended Run Modes

Fast validation:

```powershell
powershell -ExecutionPolicy Bypass -File .\run.ps1 -LimitResources 25 -SkipReservations -ContinueOnError
```

Single subscription validation:

```powershell
powershell -ExecutionPolicy Bypass -File .\run.ps1 -SubscriptionIds <subscription-id> -LimitResources 10 -SkipReservations -ContinueOnError
```

Broader tenant run:

```powershell
powershell -ExecutionPolicy Bypass -File .\run.ps1 -SkipReservations -ContinueOnError
```

Deep run with full role definition coverage:

```powershell
powershell -ExecutionPolicy Bypass -File .\run.ps1 -FullRoleDefinitionScan -ContinueOnError
```

## Requirements

- Windows PowerShell 5.1 or later; Windows is the supported v1 operating system
- Azure CLI available as `az`
- Valid `az login`
- Sufficient Azure RBAC permissions to list assignments and resources
- Microsoft Graph permissions available through the signed-in Azure CLI session for Entra role, principal, group, and owner lookups
- Node.js 18+ for XLSX workbook generation through `report.mjs`
- Local Node dependency install with `npm install`, which installs `exceljs` from `package.json`

## Validate The Package

Run the built-in package validation from the repository root:

```powershell
npm run validate
```

The validation script parses PowerShell files, installs npm dependencies when needed, regenerates the dummy sample workbook, and verifies the sample summary contains rows.

## Sample Workbook With Dummy Data

A dummy-only sample workbook is provided at:

```text
samples\all-azure-access-sample-ALL-dummy.xlsx
```

The sample workbook is generated only from synthetic inputs under:

```text
samples\dummy-input\
```

The sample uses fake IDs, fake subscriptions, and `example.invalid` identities. It does not contain real tenant data.

To regenerate the sample workbook from the dummy inputs:

```powershell
node .\report.mjs `
  --run-dir .\samples\dummy-input `
  --access-csv .\samples\dummy-input\allAzureAccess.csv `
  --effective-csv .\samples\dummy-input\effectiveAccess.csv `
  --direct-csv .\samples\dummy-input\directAssignments.csv `
  --group-csv .\samples\dummy-input\groupDerivedAccess.csv `
  --service-principal-owners-csv .\samples\dummy-input\servicePrincipalOwners.csv `
  --collector-status-csv .\samples\dummy-input\collectorStatus.csv `
  --scope-inventory-csv .\samples\dummy-input\scopeInventory.csv `
  --role-definitions-csv .\samples\dummy-input\roleDefinitions.csv `
  --principal-resolution-csv .\samples\dummy-input\principalResolution.csv `
  --errors-csv .\samples\dummy-input\errorsWarnings.csv `
  --coverage-json .\samples\dummy-input\coverageSummary.json `
  --output .\samples\all-azure-access-sample-ALL-dummy.xlsx `
  --summary-json .\samples\all-azure-access-sample-ALL-dummy-summary.json
```

## Current Limitations

- Workload-specific access models such as Exchange RBAC, SharePoint item permissions, Teams membership, Intune RBAC, Azure DevOps permissions, SQL database permissions, and AKS Kubernetes RBAC are not fully implemented in this scanner. They require separate workload APIs and data models.
- Some billing, reservation, PIM, and management group APIs may return no data or unauthorized responses depending on the signed-in account.
- Resource-level and child-scope scans can be slow in large tenants. Use `-LimitResources`, `-ResourceTypes`, `-SkipResourceLevel`, or `-SkipChildDataScopes` for targeted validation.
- Effective access is expanded for groups where Graph transitive membership is available. If Graph denies membership reads, direct assignment rows still remain in the report and the collector status records the issue.
- v1 is Windows-first. Cross-platform PowerShell support may require additional testing and small process-launch changes.
