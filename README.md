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
- Bearer tokens and other secret-shaped values are never written to the logs. A support bundle contains no access or role-assignment rows unless you explicitly pass `-IncludeData`. See [Diagnostics And Support](#diagnostics-and-support).

## Support Policy

This v1 package is Windows-first. It is tested on both Windows PowerShell 5.1 and PowerShell 7. Cross-platform Linux/macOS support is not the current compatibility target.

## Primary Command

Clone the repository and install the Node dependency used for workbook generation:

```powershell
git clone https://github.com/zmustafa/AzureEntraIDIAMScanner.git
cd AzureEntraIDIAMScanner
npm install
```

Sign in with Azure CLI, then run the scanner:

```powershell
az login
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

Every assignment is multiplied by every member, so one very large group can dominate the output. Use these flags to bound or skip expansion:

```powershell
-NoGroupExpansion
-MaxGroupDepth <1-10>
-MaxGroupMembers <int>
```

`-MaxGroupDepth` defaults to `10`, meaning no limit, which Graph answers in a single `transitiveMembers` call per group. A lower value walks direct members level by level instead. `-MaxGroupMembers` stops expanding a group after the given number of members and records the truncation in `errorsWarnings.csv`.

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

### Access Packages and Access Reviews

The scanner attempts read-only Microsoft Graph v1.0 Identity Governance collection by default:

- Access package catalogs, packages, assignment policies, resource roles/scopes, and assignments.
- Access review definitions for packages, groups, enterprise applications, and Entra privileged roles, including unrecognized scopes without discarding them.
- Review instances, multi-stage history, decisions, recommendations, reviewer justifications, and decision application results.

All visible review definitions are inventoried. Instance/decision history includes active and other non-completed reviews regardless of age, plus completed reviews ending within the last 90 days. `-AccessReviewLookbackDays 0` requests all available history. The cutoff is inclusive and recorded in coverage metadata.

Governance records are separate from the existing access-assignment tables and do not increase their totals. A delivered package assignment is provisioning evidence, not proof of every underlying permission. A denied review decision is not proof of revoked access: `decision` and `applyResult` are reported separately. Stage history is retained but excluded from final instance-decision totals.

`Governance Access Links` correlates delivered package assignments with configured group Member roles and already observed active group-derived access using directory object IDs. It does not infer access from group ownership, expand partially delivered assignments into active permissions, or claim that a package is the exclusive cause of access. External subjects without directory object IDs remain reportable without invented principal IDs.

Each dataset has a CSV export, plus a matching JSON array with `-EmitJson`:

```text
accessCatalogs
accessPackages
accessPackagePolicies
accessPackageResources
accessPackageAssignments
accessReviewDefinitions
accessReviewInstances
accessReviewStages
accessReviewDecisions
governanceAccessLinks
governanceFindings
```

Coverage includes complete source row counts, dataset collector statuses, the history window, and excluded-instance counts. Workbook row limits are disclosed separately; aggregate breakdowns based on truncated or incompletely collected data are not presented as complete. Successful empty collection, disabled collection, and permission failures are distinct. Visibility is limited to the authenticated caller; tenant-wide completeness is not assumed.

#### Governance Authentication

Required Graph read permissions are `EntitlementManagement.Read.All` and `AccessReview.Read.All`, or only the corresponding permission when one feature is disabled. Delegated callers also need the endpoint-specific Entra/catalog roles. Catalog-scoped package queries are supported. Tenant licensing and consent determine which features are available; P2 alone does not guarantee every advanced governance capability.

The existing Azure CLI session is used by default. Its Graph token might not have governance permissions even if the user is an administrator. Such failures are reported as coverage failures, not empty success. To explicitly use Microsoft Graph PowerShell for governance reads:

```powershell
Install-Module Microsoft.Graph.Authentication -Scope CurrentUser
Connect-MgGraph -TenantId <tenant-id> -Scopes EntitlementManagement.Read.All,AccessReview.Read.All -ContextScope Process
.\run.ps1 -SubscriptionIds <subscription-id> -GovernanceOnly -GraphAuthMode GraphPowerShell -EmitJson -ContinueOnError
```

The scanner can initiate delegated sign-in when `-GraphAuthMode GraphPowerShell` is explicitly selected. `-GraphClientId` selects a custom delegated application. An existing app-only Graph context with the required read permissions is also supported, allowing certificate authentication configured outside the scanner. The scanner never creates app registrations, grants permissions, changes packages/reviews, or stores credentials. Other legacy Graph discovery continues using Azure CLI. `-NoHttp` selects the CLI fallback for Azure CLI-backed calls; explicitly selected Graph PowerShell governance reads still use the Graph SDK.

The first explicitly selected subscription establishes the scan's Graph tenant. A mismatched existing Graph PowerShell tenant context is rejected. **Subscription filters constrain ARM discovery, not tenant-scoped governance reads.**

Reviewer justifications and real governance exports are sensitive. They are not emitted in routine logs or included in the default support bundle. Complete package request/approval transaction history and additional PIM assignment surfaces are not included in this extension.

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
output\coverageSummary.json
errors\<collector>.json
logs\events.jsonl
logs\errorSummary.json
logs\all-azure-access.log
```

`collectorStatus.csv`, `errorsWarnings.csv`, `coverageSummary.json`, and `counts.json` are written even when the run is interrupted with Ctrl+C or fails partway through. The event log is flushed as it is written, so it stays readable even if the process is killed outright.

Repeated failures are collapsed: a failure affecting 50,000 scopes produces five examples plus a count in `logs\errorSummary.json`, not 50,000 log lines.

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
support-bundle-<timestamp>.zip
```

`support-bundle-<timestamp>.zip` is present when the run was started with `-SupportBundle`, or whenever the run did not succeed.

## Main Output Files

```text
output\allAzureAccess.csv
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
output\counts.json
output\errorsWarnings.csv
output\results.json
output\results.zip
reports\all-azure-access-report-<timestamp>.xlsx
reports\all-azure-access-summary-<timestamp>.json
```

`output\allAzureAccess.json` is written only when `-EmitJson` is supplied. It contains the same data as `allAzureAccess.csv`, and serialising it is slow and memory-hungry in large tenants.

Diagnostic files are written under `logs\`:

```text
logs\events.jsonl
logs\errorSummary.json
logs\apiTiming.csv
logs\apiSummary.json
logs\environment.json
logs\parameters.json
logs\all-azure-access.log
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
- Access Catalogs
- Access Packages
- Package Policies
- Package Resources
- Package Assignments
- Review Definitions
- Review Instances
- Review Stages
- Review Decisions
- Governance Access Links
- Governance Findings
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

For collectors that have both, `-Include*` forces the collector on, `-Skip*` forces it off, and `-Include*` wins if both are supplied. Every collector listed below is on by default.

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
-IncludeAccessPackages
-SkipAccessPackages
-IncludeAccessReviews
-SkipAccessReviews
```
Enable/disable governance collection independently. Both features default on; explicit `-Include*` wins over `-Skip*`.

```powershell
-AccessReviewLookbackDays 90
```
Completed-review history window in days, inclusive of the UTC cutoff. `0` means all available history. Active reviews are retained regardless of age.

```powershell
-GovernanceOnly
```
Run subscription/context validation, governance collectors, and reporting without legacy access discovery. Existing access sheets remain present but empty.

```powershell
-GraphAuthMode AzureCli
-GraphAuthMode GraphPowerShell
-GraphClientId <application-id>
```
Choose governance authentication explicitly. `AzureCli` is the default. `GraphPowerShell` requires the optional `Microsoft.Graph.Authentication` module and a matching tenant context. The custom client ID is used when initiating delegated Graph sign-in.

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
-IncludeOtherTenants
```
Also scan subscriptions homed in a tenant other than the signed-in one. These are skipped by default because token acquisition fails for them (`AADSTS50020`); skipped subscriptions are listed in `errorsWarnings.csv`.

```powershell
-DeepScopeScan
```
Query every resource group, resource, and storage child scope individually instead of relying on the subscription-wide enumeration that already returns assignments at all nested scopes. This is exhaustive but issues one Azure CLI call per scope, so it is very slow in large tenants.

```powershell
-Parallel <int>
```
Number of Azure CLI processes to run concurrently for per-subscription work (subscription RBAC, scope inventory, Key Vault policies, classic admins, storage child scopes). Defaults to `1`. Values of `4` to `8` are a good starting point; going wider risks ARM throttling, which costs more time than it saves.

```powershell
-MaxGroupDepth <1-10>
```
How many levels of nested group membership to expand. The default `10` means "no limit" and is answered by a single Graph `transitiveMembers` call per group. Any lower value walks direct members level by level, which is slower but bounds the expansion.

```powershell
-MaxGroupMembers <int>
```
Stop expanding a group after this many members (`0` = unlimited). Because every assignment is multiplied by every member, one very large group can dominate the entire output. Truncated groups are recorded in `errorsWarnings.csv`.

```powershell
-EmitJson
```
Also write `allAzureAccess.json`. Off by default because serialising every row is slow and memory-hungry in large tenants; the CSVs contain the same data.

```powershell
-NoHttp
```
Disable direct HTTPS calls and route every Graph/ARM request through `az rest` instead. Much slower; use only if the in-process HTTP path is blocked by your environment.

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

### Console output

```powershell
-Quiet
-NoColor
-NoProgress
```
Suppress the progress display, colour, or the progress bar. Colour and progress are disabled automatically when output is redirected or when `CI`, `TF_BUILD`, or `GITHUB_ACTIONS` is set, and `NO_COLOR` is honoured. The machine-readable `RUN_DIR=`, `ALL_ACCESS_CSV=`, `FINAL_STATUS=` lines are never coloured or suppressed.

The completion estimate is weighted by measured collector cost rather than by collector count, and each run writes timings to `<OutputRoot>\.calibration\all-azure-access.json`. From the second run against the same environment onward, the percentage and ETA are based on your own measured timings.

### Diagnostics

```powershell
-LogLevel Error|Warn|Info|Debug|Trace
```
Defaults to `Info`. `Debug` records every Azure CLI and HTTP call with its duration, exit code, and response size.

```powershell
-RedactLogs
```
Replace user principal names, GUIDs, and resource names in the logs with stable pseudonyms (`user-xxxxxxxx@redacted`, `id-xxxxxxxx`, `name-xxxxxxxx`). Identical values always map to identical pseudonyms, so redacted logs remain correlatable. The reversal map is written to `logs\redaction-map.LOCAL-ONLY.json` and is never included in a support bundle.

Bearer tokens, JWTs, and secret-shaped values are always stripped, regardless of this switch.

```powershell
-SupportBundle
-IncludeData
```
Produce `support-bundle-<runid>.zip` in the run directory. A bundle is created automatically whenever the run does not succeed. It contains the event log, error summary, API timings, environment details, the exact parameters used, collector status, and row counts. It contains **no** access or role-assignment rows unless `-IncludeData` is specified.

```powershell
-NoTranscript
-MaxLogMegabytes <int>
```
Skip the PowerShell transcript, or change the event-log size cap (default 50 MB).

## Diagnostics And Support

Every run writes the following under `logs\`:

| File | Contents |
| --- | --- |
| `events.jsonl` | One JSON object per line. Repeated failures are collapsed to five examples plus a count, so a failure affecting 50,000 scopes produces a handful of lines rather than 50,000. |
| `errorSummary.json` | Every distinct failure class with counts, first/last occurrence, and examples. |
| `apiTiming.csv` | Per-call timing for every Azure CLI and HTTP request. |
| `apiSummary.json` | Call counts and durations per API, plus the 50 slowest calls. |
| `environment.json` | OS, PowerShell, Azure CLI (and extensions), and Node versions. |
| `parameters.json` | The exact parameters the run was started with. |

`collectorStatus.csv`, `errorsWarnings.csv`, `coverageSummary.json`, and `counts.json` are written even if the run is interrupted with Ctrl+C or fails partway through.

To report a problem, re-run with `-LogLevel Debug -RedactLogs -SupportBundle` and send the resulting `support-bundle-<runid>.zip`.

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

Large tenant:

```powershell
powershell -ExecutionPolicy Bypass -File .\run.ps1 -Parallel 8 -MaxGroupMembers 5000 -SkipReservations -SkipBilling -ContinueOnError
```

Reproducing a problem for support:

```powershell
powershell -ExecutionPolicy Bypass -File .\run.ps1 -LogLevel Debug -RedactLogs -SupportBundle -ContinueOnError
```

## Requirements

- Windows PowerShell 5.1 or PowerShell 7; Windows is the supported v1 operating system
- Git, to clone the repository
- Azure CLI available as `az`
- Valid `az login`
- Sufficient Azure RBAC permissions to list assignments and resources
- Microsoft Graph permissions available through the signed-in Azure CLI session for Entra role, principal, group, and owner lookups
- Node.js 18+ for XLSX workbook generation through `report.mjs`
- Local Node dependency install with `npm install`, which installs `exceljs` from `package.json`

## Validate The Package

Clone the repository and run the built-in package validation from the repository root:

```powershell
git clone https://github.com/zmustafa/AzureEntraIDIAMScanner.git
cd AzureEntraIDIAMScanner
npm run validate
```

The validation script parses the scanner/modules and collector tests, runs synthetic governance/transport assertions, verifies log redaction, regenerates the dummy sample workbook, and runs Node workbook regression tests. It needs no Azure connection. Use `.\Test-Package.ps1 -SkipNpmInstall` when dependencies are already restored.

Focused governance checks:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-Governance.ps1
pwsh -NoProfile -File .\tests\Test-Governance.ps1
node --test .\tests\report-governance.test.mjs
```

Synthetic tests cover lifecycle states, external identities, stage/final decision separation, the exact history cutoff, parent/page failures, strict HTTP/CLI errors, expanded paging, correlation deduplication, CSV/JSON shapes, empty/unauthorized reporting, and workbook truncation. Live integration testing uses an owner-authorized tenant with isolated fixtures and separate setup/cleanup; real environment details and outputs stay outside the repository.

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
git clone https://github.com/zmustafa/AzureEntraIDIAMScanner.git
cd AzureEntraIDIAMScanner
npm install

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
- Large tenants take time. Use `-Parallel`, and narrow the run with `-LimitResources`, `-ResourceTypes`, `-SkipResourceLevel`, or `-SkipChildDataScopes`. `-DeepScopeScan` is exhaustive but issues one Azure CLI call per scope and is very slow.
- By default, resource groups and resources are not queried individually, because the subscription-wide enumeration already returns assignments at every nested scope. `-DeepScopeScan` restores per-scope queries if you need to verify this.
- Effective access is expanded for groups where Graph transitive membership is available. If Graph denies membership reads, direct assignment rows still remain in the report and the collector status records the issue.
- Excel caps a worksheet at 1,048,576 rows. `report.mjs` keeps the first `--max-sheet-rows` rows per sheet (250,000 by default) and records any truncation in the report summary; the CSV outputs are always complete.
- Subscriptions homed in another tenant are skipped by default, because a token cannot be acquired for them. Use `-IncludeOtherTenants` to attempt them anyway.
- v1 is Windows-first. Cross-platform PowerShell support may require additional testing and small process-launch changes.
