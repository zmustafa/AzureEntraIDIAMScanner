# Azure and EntraID IAM Scanner Plan

## Purpose

Create `all-azure-access`, a console-runnable Azure and EntraID IAM Scanner that inventories direct and effective access across Microsoft Entra ID roles, Azure ARM RBAC, data-plane RBAC roles assigned through ARM, management groups, subscriptions, resource groups, resources, selected child data scopes, service principal/application owners, Key Vault access policies, PIM where permitted, billing/reservation access where permitted, and classic subscription admins where available.

Primary command:

```powershell
powershell -ExecutionPolicy Bypass -File .\run.ps1
```

Default output root:

```text
%TEMP%\azure-scanners\all-azure-access\<timestamp>\
```

## Failure Philosophy

The scanner is designed for console use in a real tenant where some APIs may be unavailable, unauthorized, throttled, or intermittently failing. A failure in one collector must not stop the whole run. Each collector records its own status, error details, and row count, then the scanner continues.

Collector statuses:

```text
Succeeded
SucceededWithWarnings
Skipped
Failed
Unauthorized
Throttled
PartiallyCollected
```

Exit codes:

```text
0 = completed with all critical collectors successful
2 = completed with partial failures, warnings, skipped optional collectors, or unauthorized optional APIs
1 = startup failure such as missing Azure CLI/login or inability to create output folders
```

## Run Structure

Each run folder contains:

```text
output\
logs\
errors\
cache\
raw\
reports\
```

Core outputs:

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
output\results.json
output\results.zip
reports\all-azure-access-report-<timestamp>.xlsx
reports\all-azure-access-summary-<timestamp>.json
```

## Collector Modules

Initial collectors:

```text
StartupValidation
Subscriptions
ManagementGroups
AzureRoleDefinitions
AzureSubscriptionRbac
AzureResourceGroupRbac
AzureResourceRbac
StorageChildScopeRbac
EntraRoleAssignments
GroupExpansion
PrincipalResolution
ServicePrincipalOwners
KeyVaultAccessPolicies
PimDirectoryAssignments
PimAzureAssignments
BillingAccess
ReservationAccess
ClassicAdmins
WorkbookReport
```

Each collector uses the same wrapper behavior:

1. Record start time.
2. Run best-effort collection.
3. Write raw evidence when useful.
4. Add normalized rows.
5. Catch errors and record structured status.
6. Continue to the next collector.

## Normalized Access Row Model

Every access row should answer who has access, through what path, to what scope, under what role, whether active or eligible, whether direct/group/nested/owner-derived, whether control-plane or data-plane, and which API produced the evidence.

Suggested normalized columns:

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

## Detailed Reporting

The scanner should produce raw CSV/JSON plus an Excel workbook with useful pivots and discovery coverage. Workbook sheets:

```text
Executive Summary
Collector Status
Coverage
All Access Raw
Effective Access
Privileged Access
Data Plane Access
Service Principal Owners
Group Access
Entra Roles
Azure RBAC
Management Groups
Subscriptions
Resource Groups
Resources
Storage Child Scopes
Key Vault Access
PIM
Billing Reservations
Classic Admins
Role Definitions
Principal Directory
Errors Warnings
Source Metadata
Pivots
```

Required pivot-style summaries:

```text
Access by Surface
Access by Role
Access by Principal Type
Access by Principal
Access by Subscription
Access by Management Group
Access by Scope Type
Privileged Roles by Principal
Data Plane Roles by Resource Type
Group-Derived Access by Group
Nested Group Access Paths
Service Principals with Owners
PIM Eligible vs Active
Failures by Collector
Unauthorized APIs by Collector
Resources Discovered by Type
```

## Default Behavior

Default run should be broad but practical:

- collect Entra role assignments
- collect all visible management groups
- collect all visible subscriptions
- collect subscription/resource group/resource RBAC
- include inherited assignments where available
- classify data-plane roles by role definition dataActions
- expand groups transitively where permitted
- collect service principal/application owners
- collect Key Vault access policies
- attempt storage child data scopes
- attempt PIM, billing, reservations, and classic admins best-effort
- generate CSV, JSON, Excel workbook, pivots, and ZIP

## Useful Flags

```powershell
-SubscriptionIds <string[]>
-ManagementGroupIds <string[]>
-ResourceTypes <string[]>
-IncludeResourceLevel
-SkipResourceLevel
-IncludeChildDataScopes
-SkipChildDataScopes
-IncludePim
-SkipPim
-IncludeBilling
-SkipBilling
-IncludeReservations
-SkipReservations
-IncludeClassicAdmins
-SkipClassicAdmins
-IncludeKeyVaultAccessPolicies
-SkipKeyVaultAccessPolicies
-NoGroupExpansion
-MaxGroupDepth 10
-MaxGroupMembers 0
-Parallel 8
-LimitResources 0
-DeepScopeScan
-IncludeOtherTenants
-EmitJson
-NoHttp
-LogLevel Debug
-RedactLogs
-SupportBundle
-Quiet / -NoColor / -NoProgress
-ContinueOnError
-FailFast
```

`-Include*` forces a collector on, `-Skip*` forces it off, and `-Include*` wins if both are supplied.

Default behavior implies `-ContinueOnError`.

## Build Sequence

1. Scanner skeleton, run folders, logging, collector framework, graceful failure handling.
2. Shared output schema and collector status tracking.
3. Azure RBAC across management groups, subscriptions, resource groups, and resources.
4. Role definition classification, including data-plane role detection.
5. Entra role assignments.
6. Principal resolution.
7. Group and nested group expansion.
8. Service principal/application owners.
9. Key Vault access policies.
10. Storage child scopes, especially file shares and blob containers.
11. PIM active/eligible assignments.
12. Billing, reservations, cost, classic admins.
13. Excel workbook and pivots.
14. Final ZIP, summary JSON, console summary.
