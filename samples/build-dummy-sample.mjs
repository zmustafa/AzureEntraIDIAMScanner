#!/usr/bin/env node
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const scannerDir = path.resolve(__dirname, "..");
const inputDir = path.join(__dirname, "dummy-input");
const outputWorkbook = path.join(__dirname, "all-azure-access-sample-ALL-dummy.xlsx");
const outputSummary = path.join(__dirname, "all-azure-access-sample-ALL-dummy-summary.json");
const relativeInputDir = "./samples/dummy-input";
const relativeWorkbook = "./samples/all-azure-access-sample-ALL-dummy.xlsx";
const relativeSummary = "./samples/all-azure-access-sample-ALL-dummy-summary.json";

fs.mkdirSync(inputDir, { recursive: true });

const accessColumns = [
  "surface", "accessModel", "collector", "assignmentState", "assignmentType",
  "principalId", "principalType", "principalDisplayName", "principalUserPrincipalName", "principalAppId",
  "effectivePrincipalId", "effectivePrincipalType", "effectivePrincipalName", "effectivePrincipalUserPrincipalName",
  "accessPath", "groupChain", "sourceGroupId", "sourceGroupName",
  "roleName", "roleDefinitionId", "roleCategory", "roleIsPrivileged", "roleHasDataActions",
  "scope", "scopeType", "scopeDisplayName", "tenantId", "managementGroupId", "managementGroupName",
  "subscriptionId", "subscriptionName", "resourceGroup", "resourceType", "resourceName", "childResourceType", "childResourceName",
  "assignmentId", "assignmentCreatedOn", "assignmentUpdatedOn", "condition", "conditionVersion", "isInherited",
  "sourceApi", "collectionStatus", "errorCode", "errorMessage",
];

function row(overrides) {
  const base = Object.fromEntries(accessColumns.map((column) => [column, ""]));
  return { ...base, tenantId: "tenant-0000", collectionStatus: "Succeeded", ...overrides };
}

const accessRows = [
  row({
    surface: "Azure RBAC", accessModel: "AzureRBAC", collector: "AzureSubscriptionRbac", assignmentState: "Active", assignmentType: "RoleAssignment",
    principalId: "user-0001", principalType: "User", principalDisplayName: "Alex Admin", principalUserPrincipalName: "alex.admin@example.invalid",
    effectivePrincipalId: "user-0001", effectivePrincipalType: "User", effectivePrincipalName: "Alex Admin", effectivePrincipalUserPrincipalName: "alex.admin@example.invalid",
    accessPath: "Direct", roleName: "Owner", roleDefinitionId: "role-owner", roleCategory: "ControlPlane", roleIsPrivileged: "True", roleHasDataActions: "False",
    scope: "/subscriptions/sub-0001", scopeType: "subscription", scopeDisplayName: "Example Production Subscription", subscriptionId: "sub-0001", subscriptionName: "Example Production Subscription",
    assignmentId: "ra-0001", assignmentCreatedOn: "2026-01-01T00:00:00Z", assignmentUpdatedOn: "2026-01-02T00:00:00Z", isInherited: "False", sourceApi: "az role assignment list",
  }),
  row({
    surface: "Azure RBAC", accessModel: "AzureRBAC", collector: "AzureResourceGroupRbac", assignmentState: "Active", assignmentType: "RoleAssignment",
    principalId: "group-0001", principalType: "Group", principalDisplayName: "Platform Operators",
    effectivePrincipalId: "group-0001", effectivePrincipalType: "Group", effectivePrincipalName: "Platform Operators",
    accessPath: "Direct", roleName: "Contributor", roleDefinitionId: "role-contributor", roleCategory: "ControlPlane", roleIsPrivileged: "True", roleHasDataActions: "False",
    scope: "/subscriptions/sub-0001/resourceGroups/rg-app", scopeType: "resourceGroup", scopeDisplayName: "rg-app", subscriptionId: "sub-0001", subscriptionName: "Example Production Subscription", resourceGroup: "rg-app",
    assignmentId: "ra-0002", assignmentCreatedOn: "2026-01-03T00:00:00Z", isInherited: "False", sourceApi: "az role assignment list",
  }),
  row({
    surface: "Azure RBAC", accessModel: "AzureRBAC", collector: "GroupExpansion", assignmentState: "Active", assignmentType: "RoleAssignment",
    principalId: "group-0001", principalType: "Group", principalDisplayName: "Platform Operators",
    effectivePrincipalId: "user-0002", effectivePrincipalType: "User", effectivePrincipalName: "Riley Operator", effectivePrincipalUserPrincipalName: "riley.operator@example.invalid",
    accessPath: "GroupTransitive", groupChain: "Platform Operators > Riley Operator", sourceGroupId: "group-0001", sourceGroupName: "Platform Operators",
    roleName: "Contributor", roleDefinitionId: "role-contributor", roleCategory: "ControlPlane", roleIsPrivileged: "True", roleHasDataActions: "False",
    scope: "/subscriptions/sub-0001/resourceGroups/rg-app", scopeType: "resourceGroup", scopeDisplayName: "rg-app", subscriptionId: "sub-0001", subscriptionName: "Example Production Subscription", resourceGroup: "rg-app",
    assignmentId: "ra-0002", assignmentCreatedOn: "2026-01-03T00:00:00Z", isInherited: "False", sourceApi: "Graph groups/transitiveMembers",
  }),
  row({
    surface: "Azure RBAC", accessModel: "AzureDataPlaneRBAC", collector: "StorageChildScopeRbac", assignmentState: "Active", assignmentType: "RoleAssignment",
    principalId: "user-0003", principalType: "User", principalDisplayName: "Morgan Storage", principalUserPrincipalName: "morgan.storage@example.invalid",
    effectivePrincipalId: "user-0003", effectivePrincipalType: "User", effectivePrincipalName: "Morgan Storage", effectivePrincipalUserPrincipalName: "morgan.storage@example.invalid",
    accessPath: "Direct", roleName: "Storage Blob Data Reader", roleDefinitionId: "role-storage-blob-reader", roleCategory: "DataPlane", roleIsPrivileged: "False", roleHasDataActions: "True",
    scope: "/subscriptions/sub-0001/resourceGroups/rg-storage/providers/Microsoft.Storage/storageAccounts/stsampleprod/blobServices/default/containers/invoices", scopeType: "storageChildScope", scopeDisplayName: "invoices", subscriptionId: "sub-0001", subscriptionName: "Example Production Subscription", resourceGroup: "rg-storage", resourceType: "Microsoft.Storage/storageAccounts/blobServices/containers", resourceName: "stsampleprod", childResourceType: "blobContainer", childResourceName: "invoices",
    assignmentId: "ra-0003", assignmentCreatedOn: "2026-01-04T00:00:00Z", sourceApi: "az role assignment list",
  }),
  row({
    surface: "Azure RBAC", accessModel: "AzureDataPlaneRBAC", collector: "GroupExpansion", assignmentState: "Active", assignmentType: "RoleAssignment",
    principalId: "group-0002", principalType: "Group", principalDisplayName: "Finance File Share Users",
    effectivePrincipalId: "user-0004", effectivePrincipalType: "User", effectivePrincipalName: "Finley Finance", effectivePrincipalUserPrincipalName: "finley.finance@example.invalid",
    accessPath: "GroupTransitive", groupChain: "Finance File Share Users > Finley Finance", sourceGroupId: "group-0002", sourceGroupName: "Finance File Share Users",
    roleName: "Storage File Data SMB Share Contributor", roleDefinitionId: "role-storage-file-contributor", roleCategory: "DataPlane", roleIsPrivileged: "False", roleHasDataActions: "True",
    scope: "/subscriptions/sub-0001/resourceGroups/rg-storage/providers/Microsoft.Storage/storageAccounts/stsampleprod/fileServices/default/shares/payroll", scopeType: "storageChildScope", scopeDisplayName: "payroll", subscriptionId: "sub-0001", subscriptionName: "Example Production Subscription", resourceGroup: "rg-storage", resourceType: "Microsoft.Storage/storageAccounts/fileServices/shares", resourceName: "stsampleprod", childResourceType: "fileShare", childResourceName: "payroll",
    assignmentId: "ra-0004", assignmentCreatedOn: "2026-01-05T00:00:00Z", sourceApi: "Graph groups/transitiveMembers",
  }),
  row({
    surface: "Microsoft Entra ID RBAC", accessModel: "EntraIDRBAC", collector: "EntraRoleAssignments", assignmentState: "Active", assignmentType: "DirectoryRoleAssignment",
    principalId: "user-0005", principalType: "User", principalDisplayName: "Taylor TenantAdmin", principalUserPrincipalName: "taylor.tenantadmin@example.invalid",
    effectivePrincipalId: "user-0005", effectivePrincipalType: "User", effectivePrincipalName: "Taylor TenantAdmin", effectivePrincipalUserPrincipalName: "taylor.tenantadmin@example.invalid",
    accessPath: "Direct", roleName: "Global Administrator", roleDefinitionId: "entra-role-global-admin", roleCategory: "ControlPlane", roleIsPrivileged: "True", roleHasDataActions: "False",
    scope: "/", scopeType: "directory", scopeDisplayName: "Tenant", assignmentId: "entra-ra-0001", assignmentCreatedOn: "2026-01-06T00:00:00Z", sourceApi: "Graph roleManagement/directory/roleAssignments",
  }),
  row({
    surface: "PIM Directory Role Eligibility", accessModel: "PIM", collector: "PimDirectoryAssignments", assignmentState: "Eligible", assignmentType: "DirectoryRoleEligibility",
    principalId: "user-0006", principalType: "User", principalDisplayName: "Jordan Eligible", principalUserPrincipalName: "jordan.eligible@example.invalid",
    effectivePrincipalId: "user-0006", effectivePrincipalType: "User", effectivePrincipalName: "Jordan Eligible", effectivePrincipalUserPrincipalName: "jordan.eligible@example.invalid",
    accessPath: "Direct", roleName: "Privileged Role Administrator", roleDefinitionId: "entra-role-pra", roleCategory: "ControlPlane", roleIsPrivileged: "True", roleHasDataActions: "False",
    scope: "/", scopeType: "directory", scopeDisplayName: "Tenant", assignmentId: "pim-0001", assignmentCreatedOn: "2026-01-07T00:00:00Z", sourceApi: "Graph roleEligibilityScheduleInstances",
  }),
  row({
    surface: "Service Principal Ownership", accessModel: "Ownership", collector: "ServicePrincipalOwners", assignmentState: "Active", assignmentType: "Owner",
    principalId: "spn-0001", principalType: "ServicePrincipal", principalDisplayName: "Example Automation SPN", principalAppId: "app-0001",
    effectivePrincipalId: "user-0007", effectivePrincipalType: "User", effectivePrincipalName: "Casey Owner", effectivePrincipalUserPrincipalName: "casey.owner@example.invalid",
    accessPath: "Owner", roleName: "Service Principal Owner", roleDefinitionId: "owner", roleCategory: "ControlPlane", roleIsPrivileged: "True", roleHasDataActions: "False",
    scope: "spn-0001", scopeType: "servicePrincipal", scopeDisplayName: "Example Automation SPN", assignmentId: "owner-0001", sourceApi: "Graph servicePrincipals/owners",
  }),
  row({
    surface: "Key Vault Access Policy", accessModel: "KeyVaultAccessPolicy", collector: "KeyVaultAccessPolicies", assignmentState: "Active", assignmentType: "AccessPolicy",
    principalId: "user-0008", principalType: "User", principalDisplayName: "Sky Secrets", principalUserPrincipalName: "sky.secrets@example.invalid",
    effectivePrincipalId: "user-0008", effectivePrincipalType: "User", effectivePrincipalName: "Sky Secrets", effectivePrincipalUserPrincipalName: "sky.secrets@example.invalid",
    accessPath: "Direct", roleName: "Key Vault Access Policy", roleDefinitionId: "kv-policy", roleCategory: "DataPlane", roleIsPrivileged: "False", roleHasDataActions: "True",
    scope: "/subscriptions/sub-0002/resourceGroups/rg-security/providers/Microsoft.KeyVault/vaults/kv-sample", scopeType: "resource", scopeDisplayName: "kv-sample", subscriptionId: "sub-0002", subscriptionName: "Example Security Subscription", resourceGroup: "rg-security", resourceType: "Microsoft.KeyVault/vaults", resourceName: "kv-sample",
    assignmentId: "kv-policy-0001", condition: "secrets=get|list keys=wrapKey", sourceApi: "az keyvault show properties.accessPolicies",
  }),
  row({
    surface: "Billing RBAC", accessModel: "BillingRBAC", collector: "BillingAccess", assignmentState: "Active", assignmentType: "BillingRoleAssignment",
    principalId: "user-0009", principalType: "User", principalDisplayName: "Blair Billing", principalUserPrincipalName: "blair.billing@example.invalid",
    effectivePrincipalId: "user-0009", effectivePrincipalType: "User", effectivePrincipalName: "Blair Billing", effectivePrincipalUserPrincipalName: "blair.billing@example.invalid",
    accessPath: "Direct", roleName: "Billing Reader", roleDefinitionId: "billing-reader", roleCategory: "ControlPlane", roleIsPrivileged: "False", roleHasDataActions: "False",
    scope: "/providers/Microsoft.Billing/billingAccounts/bill-0001", scopeType: "billing", scopeDisplayName: "Example Billing Account", assignmentId: "billing-ra-0001", sourceApi: "az billing account list and role assignment list",
  }),
  row({
    surface: "Reservation RBAC", accessModel: "ReservationRBAC", collector: "ReservationAccess", assignmentState: "Active", assignmentType: "ReservationRoleAssignment",
    principalId: "user-0010", principalType: "User", principalDisplayName: "Reese Reservations", principalUserPrincipalName: "reese.reservations@example.invalid",
    effectivePrincipalId: "user-0010", effectivePrincipalType: "User", effectivePrincipalName: "Reese Reservations", effectivePrincipalUserPrincipalName: "reese.reservations@example.invalid",
    accessPath: "Direct", roleName: "Reservation Purchaser", roleDefinitionId: "reservation-purchaser", roleCategory: "ControlPlane", roleIsPrivileged: "True", roleHasDataActions: "False",
    scope: "/providers/Microsoft.Capacity/reservationOrders/reservation-order-0001", scopeType: "reservation", scopeDisplayName: "Example Reservation Order", assignmentId: "reservation-ra-0001", sourceApi: "az reservations reservation-order list",
  }),
  row({
    surface: "Classic Subscription Admins", accessModel: "ClassicAzureAdmin", collector: "ClassicAdmins", assignmentState: "Active", assignmentType: "ClassicAdministrator",
    principalId: "user-0011", principalType: "User", principalDisplayName: "Devon Classic", principalUserPrincipalName: "devon.classic@example.invalid",
    effectivePrincipalId: "user-0011", effectivePrincipalType: "User", effectivePrincipalName: "Devon Classic", effectivePrincipalUserPrincipalName: "devon.classic@example.invalid",
    accessPath: "Direct", roleName: "Co-Administrator", roleDefinitionId: "classic-co-admin", roleCategory: "ControlPlane", roleIsPrivileged: "True", roleHasDataActions: "False",
    scope: "/subscriptions/sub-legacy", scopeType: "subscription", scopeDisplayName: "Example Legacy Subscription", subscriptionId: "sub-legacy", subscriptionName: "Example Legacy Subscription", assignmentId: "classic-0001", sourceApi: "az role assignment list --include-classic-administrators",
  }),
  row({
    surface: "Azure RBAC", accessModel: "AzureRBAC", collector: "ManagementGroupRbac", assignmentState: "Active", assignmentType: "RoleAssignment",
    principalId: "group-0003", principalType: "Group", principalDisplayName: "Landing Zone Admins",
    effectivePrincipalId: "group-0003", effectivePrincipalType: "Group", effectivePrincipalName: "Landing Zone Admins",
    accessPath: "Direct", roleName: "User Access Administrator", roleDefinitionId: "role-user-access-admin", roleCategory: "ControlPlane", roleIsPrivileged: "True", roleHasDataActions: "False",
    scope: "/providers/Microsoft.Management/managementGroups/mg-root", scopeType: "managementGroup", scopeDisplayName: "Example Root Management Group", managementGroupId: "mg-root", managementGroupName: "Example Root Management Group", assignmentId: "mg-ra-0001", sourceApi: "az role assignment list",
  }),
];

const directRows = accessRows.filter((item) => !["GroupTransitive", "Owner"].includes(item.accessPath));
const effectiveRows = accessRows;
const groupRows = accessRows.filter((item) => item.accessPath === "GroupTransitive");
const ownerRows = accessRows.filter((item) => item.accessPath === "Owner");

const roleRows = [
  { roleName: "Owner", roleDefinitionId: "role-owner", roleDefinitionGuid: "role-owner", roleType: "BuiltInRole", roleCategory: "ControlPlane", roleIsPrivileged: "True", roleHasDataActions: "False", actionsCount: "1200", dataActionsCount: "0", description: "Dummy owner role", assignableScopes: "[/]", permissions: "actions=*", collector: "AzureRoleDefinitions" },
  { roleName: "Contributor", roleDefinitionId: "role-contributor", roleDefinitionGuid: "role-contributor", roleType: "BuiltInRole", roleCategory: "ControlPlane", roleIsPrivileged: "True", roleHasDataActions: "False", actionsCount: "900", dataActionsCount: "0", description: "Dummy contributor role", assignableScopes: "[/]", permissions: "actions=* notActions=authorization", collector: "AzureRoleDefinitions" },
  { roleName: "Storage Blob Data Reader", roleDefinitionId: "role-storage-blob-reader", roleDefinitionGuid: "role-storage-blob-reader", roleType: "BuiltInRole", roleCategory: "DataPlane", roleIsPrivileged: "False", roleHasDataActions: "True", actionsCount: "4", dataActionsCount: "2", description: "Dummy blob data reader", assignableScopes: "[/]", permissions: "dataActions=blob/read", collector: "AzureRoleDefinitions" },
  { roleName: "Storage File Data SMB Share Contributor", roleDefinitionId: "role-storage-file-contributor", roleDefinitionGuid: "role-storage-file-contributor", roleType: "BuiltInRole", roleCategory: "DataPlane", roleIsPrivileged: "False", roleHasDataActions: "True", actionsCount: "4", dataActionsCount: "4", description: "Dummy file share data contributor", assignableScopes: "[/]", permissions: "dataActions=file/read|write", collector: "AzureRoleDefinitions" },
  { roleName: "Global Administrator", roleDefinitionId: "entra-role-global-admin", roleDefinitionGuid: "entra-role-global-admin", roleType: "EntraRole", roleCategory: "ControlPlane", roleIsPrivileged: "True", roleHasDataActions: "False", actionsCount: "", dataActionsCount: "", description: "Dummy Entra role", assignableScopes: "tenant", permissions: "directory/admin", collector: "EntraRoleAssignments" },
  { roleName: "Privileged Role Administrator", roleDefinitionId: "entra-role-pra", roleDefinitionGuid: "entra-role-pra", roleType: "EntraRole", roleCategory: "ControlPlane", roleIsPrivileged: "True", roleHasDataActions: "False", actionsCount: "", dataActionsCount: "", description: "Dummy PIM eligible role", assignableScopes: "tenant", permissions: "directory/roleManagement", collector: "PimDirectoryAssignments" },
];

const scopeRows = [
  { scope: "/", scopeType: "tenantRoot", displayName: "Example Tenant Root", subscriptionId: "", subscriptionName: "", managementGroupId: "", managementGroupName: "", resourceGroup: "", resourceType: "", resourceName: "", collector: "StartupValidation" },
  { scope: "/providers/Microsoft.Management/managementGroups/mg-root", scopeType: "managementGroup", displayName: "Example Root Management Group", subscriptionId: "", subscriptionName: "", managementGroupId: "mg-root", managementGroupName: "Example Root Management Group", resourceGroup: "", resourceType: "", resourceName: "", collector: "ManagementGroups" },
  { scope: "/subscriptions/sub-0001", scopeType: "subscription", displayName: "Example Production Subscription", subscriptionId: "sub-0001", subscriptionName: "Example Production Subscription", managementGroupId: "", managementGroupName: "", resourceGroup: "", resourceType: "", resourceName: "", collector: "Subscriptions" },
  { scope: "/subscriptions/sub-0001/resourceGroups/rg-app", scopeType: "resourceGroup", displayName: "rg-app", subscriptionId: "sub-0001", subscriptionName: "Example Production Subscription", managementGroupId: "", managementGroupName: "", resourceGroup: "rg-app", resourceType: "", resourceName: "", collector: "ScopeInventory" },
  { scope: "/subscriptions/sub-0002/resourceGroups/rg-security/providers/Microsoft.KeyVault/vaults/kv-sample", scopeType: "resource", displayName: "kv-sample", subscriptionId: "sub-0002", subscriptionName: "Example Security Subscription", managementGroupId: "", managementGroupName: "", resourceGroup: "rg-security", resourceType: "Microsoft.KeyVault/vaults", resourceName: "kv-sample", collector: "ScopeInventory" },
  { scope: "/subscriptions/sub-0001/resourceGroups/rg-storage/providers/Microsoft.Storage/storageAccounts/stsampleprod/fileServices/default/shares/payroll", scopeType: "storageChildScope", displayName: "payroll", subscriptionId: "sub-0001", subscriptionName: "Example Production Subscription", managementGroupId: "", managementGroupName: "", resourceGroup: "rg-storage", resourceType: "Microsoft.Storage/storageAccounts/fileServices/shares", resourceName: "stsampleprod", collector: "StorageChildScopeRbac" },
  { scope: "/providers/Microsoft.Billing/billingAccounts/bill-0001", scopeType: "billing", displayName: "Example Billing Account", subscriptionId: "", subscriptionName: "", managementGroupId: "", managementGroupName: "", resourceGroup: "", resourceType: "", resourceName: "", collector: "BillingAccess" },
  { scope: "/providers/Microsoft.Capacity/reservationOrders/reservation-order-0001", scopeType: "reservation", displayName: "Example Reservation Order", subscriptionId: "", subscriptionName: "", managementGroupId: "", managementGroupName: "", resourceGroup: "", resourceType: "", resourceName: "", collector: "ReservationAccess" },
];

const principalRows = [
  { principalId: "user-0001", principalType: "User", displayName: "Alex Admin", userPrincipalName: "alex.admin@example.invalid", appId: "", accountEnabled: "true", source: "Dummy" },
  { principalId: "user-0002", principalType: "User", displayName: "Riley Operator", userPrincipalName: "riley.operator@example.invalid", appId: "", accountEnabled: "true", source: "Dummy" },
  { principalId: "user-0003", principalType: "User", displayName: "Morgan Storage", userPrincipalName: "morgan.storage@example.invalid", appId: "", accountEnabled: "true", source: "Dummy" },
  { principalId: "group-0001", principalType: "Group", displayName: "Platform Operators", userPrincipalName: "", appId: "", accountEnabled: "", source: "Dummy" },
  { principalId: "group-0002", principalType: "Group", displayName: "Finance File Share Users", userPrincipalName: "", appId: "", accountEnabled: "", source: "Dummy" },
  { principalId: "spn-0001", principalType: "ServicePrincipal", displayName: "Example Automation SPN", userPrincipalName: "", appId: "app-0001", accountEnabled: "true", source: "Dummy" },
];

const groupExpansionRows = [
  { sourceGroupId: "group-0001", sourceGroupName: "Platform Operators", memberId: "user-0002", memberType: "User", memberDisplayName: "Riley Operator", memberUserPrincipalName: "riley.operator@example.invalid", memberAppId: "", accessPath: "GroupTransitive" },
  { sourceGroupId: "group-0002", sourceGroupName: "Finance File Share Users", memberId: "user-0004", memberType: "User", memberDisplayName: "Finley Finance", memberUserPrincipalName: "finley.finance@example.invalid", memberAppId: "", accessPath: "GroupTransitive" },
];

const collectorRows = [
  { collector: "StartupValidation", status: "Succeeded", startedUtc: "2026-01-10T00:00:00Z", endedUtc: "2026-01-10T00:00:01Z", durationSeconds: "1", rowsAdded: "0", totalRows: "0", message: "Dummy successful startup" },
  { collector: "AzureSubscriptionRbac", status: "Succeeded", startedUtc: "2026-01-10T00:00:01Z", endedUtc: "2026-01-10T00:00:05Z", durationSeconds: "4", rowsAdded: "3", totalRows: "3", message: "Dummy Azure RBAC rows" },
  { collector: "EntraRoleAssignments", status: "Succeeded", startedUtc: "2026-01-10T00:00:05Z", endedUtc: "2026-01-10T00:00:08Z", durationSeconds: "3", rowsAdded: "1", totalRows: "4", message: "Dummy Entra roles" },
  { collector: "GroupExpansion", status: "Succeeded", startedUtc: "2026-01-10T00:00:08Z", endedUtc: "2026-01-10T00:00:09Z", durationSeconds: "1", rowsAdded: "2", totalRows: "6", message: "Dummy transitive members" },
  { collector: "ServicePrincipalOwners", status: "Succeeded", startedUtc: "2026-01-10T00:00:09Z", endedUtc: "2026-01-10T00:00:10Z", durationSeconds: "1", rowsAdded: "1", totalRows: "7", message: "Dummy SPN owner" },
  { collector: "ReservationAccess", status: "Skipped", startedUtc: "2026-01-10T00:00:10Z", endedUtc: "2026-01-10T00:00:10Z", durationSeconds: "0", rowsAdded: "1", totalRows: "8", message: "Dummy skipped collector example" },
  { collector: "PartnerWorkloadAccess", status: "Unauthorized", startedUtc: "2026-01-10T00:00:10Z", endedUtc: "2026-01-10T00:00:11Z", durationSeconds: "1", rowsAdded: "0", totalRows: "8", message: "Dummy unauthorized optional API example" },
];

const errorRows = [
  { collector: "PartnerWorkloadAccess", status: "Unauthorized", scope: "partner-center", api: "dummy optional api", errorCode: "DummyUnauthorized", errorMessage: "Synthetic example only. No real API was called.", generatedUtc: "2026-01-10T00:00:11Z" },
];

const coverage = {
  generatedUtc: "2026-01-10T00:00:12Z",
  runDir: "samples/dummy-input",
  subscriptionsDiscovered: 3,
  managementGroupsDiscovered: 1,
  resourceGroupsDiscovered: 4,
  resourcesDiscovered: 6,
  scopesDiscovered: scopeRows.length,
  roleDefinitionsDiscovered: roleRows.length,
  directAssignments: directRows.length,
  effectiveAssignments: effectiveRows.length,
  groupDerivedAssignments: groupRows.length,
  servicePrincipalOwnerRows: ownerRows.length,
  collectorFailures: 1,
  skippedCollectors: 1,
  options: {
    dummyData: true,
    skipReservations: false,
    fullRoleDefinitionScan: true,
    note: "Synthetic sample only. No real tenant data.",
  },
};

function csvEscape(value) {
  const text = String(value ?? "");
  return `"${text.replaceAll('"', '""')}"`;
}

function writeCsv(fileName, columns, rows) {
  const lines = [columns.map(csvEscape).join(",")];
  for (const item of rows) {
    lines.push(columns.map((column) => csvEscape(item[column])).join(","));
  }
  fs.writeFileSync(path.join(inputDir, fileName), `${lines.join("\n")}\n`, "utf8");
}

writeCsv("allAzureAccess.csv", accessColumns, accessRows);
writeCsv("effectiveAccess.csv", accessColumns, effectiveRows);
writeCsv("directAssignments.csv", accessColumns, directRows);
writeCsv("groupDerivedAccess.csv", accessColumns, groupRows);
writeCsv("servicePrincipalOwners.csv", accessColumns, ownerRows);
writeCsv("collectorStatus.csv", ["collector", "status", "startedUtc", "endedUtc", "durationSeconds", "rowsAdded", "totalRows", "message"], collectorRows);
writeCsv("scopeInventory.csv", ["scope", "scopeType", "displayName", "subscriptionId", "subscriptionName", "managementGroupId", "managementGroupName", "resourceGroup", "resourceType", "resourceName", "collector"], scopeRows);
writeCsv("roleDefinitions.csv", ["roleName", "roleDefinitionId", "roleDefinitionGuid", "roleType", "roleCategory", "roleIsPrivileged", "roleHasDataActions", "actionsCount", "dataActionsCount", "description", "assignableScopes", "permissions", "collector"], roleRows);
writeCsv("principalResolution.csv", ["principalId", "principalType", "displayName", "userPrincipalName", "appId", "accountEnabled", "source"], principalRows);
writeCsv("groupExpansion.csv", ["sourceGroupId", "sourceGroupName", "memberId", "memberType", "memberDisplayName", "memberUserPrincipalName", "memberAppId", "accessPath"], groupExpansionRows);
writeCsv("errorsWarnings.csv", ["collector", "status", "scope", "api", "errorCode", "errorMessage", "generatedUtc"], errorRows);
fs.writeFileSync(path.join(inputDir, "coverageSummary.json"), `${JSON.stringify(coverage, null, 2)}\n`, "utf8");

const args = [
  "./report.mjs",
  "--run-dir", relativeInputDir,
  "--access-csv", `${relativeInputDir}/allAzureAccess.csv`,
  "--effective-csv", `${relativeInputDir}/effectiveAccess.csv`,
  "--direct-csv", `${relativeInputDir}/directAssignments.csv`,
  "--group-csv", `${relativeInputDir}/groupDerivedAccess.csv`,
  "--service-principal-owners-csv", `${relativeInputDir}/servicePrincipalOwners.csv`,
  "--collector-status-csv", `${relativeInputDir}/collectorStatus.csv`,
  "--scope-inventory-csv", `${relativeInputDir}/scopeInventory.csv`,
  "--role-definitions-csv", `${relativeInputDir}/roleDefinitions.csv`,
  "--principal-resolution-csv", `${relativeInputDir}/principalResolution.csv`,
  "--errors-csv", `${relativeInputDir}/errorsWarnings.csv`,
  "--coverage-json", `${relativeInputDir}/coverageSummary.json`,
  "--output", relativeWorkbook,
  "--summary-json", relativeSummary,
];

const result = spawnSync(process.execPath, args, { cwd: scannerDir, stdio: "inherit" });
if (result.status !== 0) process.exit(result.status ?? 1);
console.log(`Dummy sample workbook: ${outputWorkbook}`);
console.log("All sample identities and IDs are synthetic.");
