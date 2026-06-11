#!/usr/bin/env node
import fs from "node:fs";
import path from "node:path";
import ExcelJS from "exceljs";

function parseArgs(argv) {
  const options = {};
  for (let i = 2; i < argv.length; i += 1) {
    const arg = argv[i];
    if (!arg.startsWith("--")) continue;
    const key = arg.slice(2).replace(/-([a-z])/g, (_, c) => c.toUpperCase());
    const next = argv[i + 1];
    if (!next || next.startsWith("--")) {
      options[key] = true;
    } else {
      options[key] = next;
      i += 1;
    }
  }
  return options;
}

function parseCsv(text) {
  const rows = [];
  let row = [];
  let field = "";
  let inQuotes = false;
  for (let i = 0; i < text.length; i += 1) {
    const ch = text[i];
    const next = text[i + 1];
    if (inQuotes) {
      if (ch === '"' && next === '"') {
        field += '"';
        i += 1;
      } else if (ch === '"') {
        inQuotes = false;
      } else {
        field += ch;
      }
      continue;
    }
    if (ch === '"') inQuotes = true;
    else if (ch === ",") {
      row.push(field);
      field = "";
    } else if (ch === "\n") {
      row.push(field);
      rows.push(row);
      row = [];
      field = "";
    } else if (ch !== "\r") field += ch;
  }
  if (field.length > 0 || row.length > 0) {
    row.push(field);
    rows.push(row);
  }
  if (rows.length === 0) return [];
  const headers = rows.shift().map((h) => h.trim());
  return rows
    .filter((values) => values.some((v) => String(v || "").trim() !== ""))
    .map((values) => {
      const item = {};
      headers.forEach((header, index) => {
        item[header] = values[index] ?? "";
      });
      return item;
    });
}

function readCsv(filePath) {
  if (!filePath || !fs.existsSync(filePath)) return [];
  return parseCsv(fs.readFileSync(filePath, "utf8"));
}

function readJson(filePath, fallback) {
  if (!filePath || !fs.existsSync(filePath)) return fallback;
  return JSON.parse(fs.readFileSync(filePath, "utf8"));
}

function countBy(rows, fields) {
  const map = new Map();
  for (const row of rows) {
    const key = fields.map((field) => row[field] || "").join("\u0001");
    map.set(key, (map.get(key) || 0) + 1);
  }
  return [...map.entries()]
    .map(([key, count]) => {
      const values = key.split("\u0001");
      const item = { count };
      fields.forEach((field, index) => {
        item[field] = values[index];
      });
      return item;
    })
    .sort((a, b) => b.count - a.count || fields.map((field) => String(a[field] || "").localeCompare(String(b[field] || ""))).find(Boolean) || 0);
}

function uniqueCount(rows, field) {
  return new Set(rows.map((row) => row[field]).filter(Boolean)).size;
}

function addSheet(workbook, name, rows, preferredColumns = []) {
  const sheet = workbook.addWorksheet(name.slice(0, 31));
  const keys = preferredColumns.length > 0
    ? preferredColumns
    : [...new Set(rows.flatMap((row) => Object.keys(row)))];
  const columns = keys.map((key) => ({
    header: key,
    key,
    width: Math.min(70, Math.max(12, key.length + 4)),
  }));
  sheet.columns = columns;
  if (rows.length > 0) sheet.addRows(rows);
  sheet.views = [{ state: "frozen", ySplit: 1 }];
  if (columns.length > 0) {
    sheet.autoFilter = {
      from: { row: 1, column: 1 },
      to: { row: 1, column: columns.length },
    };
  }
  const header = sheet.getRow(1);
  header.font = { bold: true, color: { argb: "FFFFFFFF" } };
  header.fill = { type: "pattern", pattern: "solid", fgColor: { argb: "FF1F4E78" } };
  for (const col of sheet.columns) {
    let max = String(col.header || "").length;
    col.eachCell({ includeEmpty: false }, (cell) => {
      max = Math.max(max, String(cell.value ?? "").length);
    });
    col.width = Math.min(80, Math.max(12, max + 2));
  }
  return sheet;
}

function addSection(sheet, title, rows, columns) {
  const start = sheet.rowCount + 2;
  sheet.getCell(start, 1).value = title;
  sheet.getCell(start, 1).font = { bold: true, size: 12 };
  const header = sheet.getRow(start + 1);
  columns.forEach((column, index) => {
    const cell = header.getCell(index + 1);
    cell.value = column.header;
    cell.font = { bold: true, color: { argb: "FFFFFFFF" } };
    cell.fill = { type: "pattern", pattern: "solid", fgColor: { argb: "FF1F4E78" } };
  });
  rows.forEach((row, rowIndex) => {
    const excelRow = sheet.getRow(start + 2 + rowIndex);
    columns.forEach((column, index) => {
      excelRow.getCell(index + 1).value = row[column.key] ?? "";
    });
  });
}

function top(rows, count = 5000) {
  return rows.slice(0, count);
}

async function main() {
  const options = parseArgs(process.argv);
  if (!options.output) throw new Error("--output is required");
  if (!options.summaryJson) throw new Error("--summary-json is required");

  const accessRows = readCsv(options.accessCsv);
  const effectiveRows = readCsv(options.effectiveCsv);
  const directRows = readCsv(options.directCsv);
  const groupRows = readCsv(options.groupCsv);
  const ownerRows = readCsv(options.servicePrincipalOwnersCsv);
  const statusRows = readCsv(options.collectorStatusCsv);
  const scopeRows = readCsv(options.scopeInventoryCsv);
  const roleRows = readCsv(options.roleDefinitionsCsv);
  const principalRows = readCsv(options.principalResolutionCsv);
  const errorsRows = readCsv(options.errorsCsv);
  const coverage = readJson(options.coverageJson, {});

  fs.mkdirSync(path.dirname(options.output), { recursive: true });
  fs.mkdirSync(path.dirname(options.summaryJson), { recursive: true });

  const workbook = new ExcelJS.Workbook();
  workbook.creator = "all-azure-access";
  workbook.created = new Date();

  const failedCollectors = statusRows.filter((row) => ["Failed", "Unauthorized", "Throttled", "PartiallyCollected", "SucceededWithWarnings"].includes(row.status));
  const summaryRows = [
    { metric: "Generated UTC", value: new Date().toISOString() },
    { metric: "Run directory", value: options.runDir || "" },
    { metric: "All access rows", value: accessRows.length },
    { metric: "Effective access rows", value: effectiveRows.length },
    { metric: "Direct assignment rows", value: directRows.length },
    { metric: "Group-derived rows", value: groupRows.length },
    { metric: "Service principal owner rows", value: ownerRows.length },
    { metric: "Unique effective principals", value: uniqueCount(effectiveRows, "effectivePrincipalId") },
    { metric: "Unique roles", value: uniqueCount(accessRows, "roleName") },
    { metric: "Unique subscriptions", value: uniqueCount(accessRows, "subscriptionId") },
    { metric: "Scopes discovered", value: scopeRows.length },
    { metric: "Role definitions discovered", value: roleRows.length },
    { metric: "Principals resolved", value: principalRows.length },
    { metric: "Collectors", value: statusRows.length },
    { metric: "Collectors needing attention", value: failedCollectors.length },
    { metric: "Subscriptions discovered", value: coverage.subscriptionsDiscovered ?? "" },
    { metric: "Management groups discovered", value: coverage.managementGroupsDiscovered ?? "" },
    { metric: "Resources discovered", value: coverage.resourcesDiscovered ?? "" },
  ];

  addSheet(workbook, "Executive Summary", summaryRows, ["metric", "value"]);
  addSheet(workbook, "Collector Status", statusRows);
  addSheet(workbook, "Coverage", Object.entries(coverage).map(([metric, value]) => ({ metric, value: Array.isArray(value) ? value.join(", ") : value })));
  addSheet(workbook, "All Access Raw", accessRows);
  addSheet(workbook, "Effective Access", effectiveRows);
  addSheet(workbook, "Privileged Access", accessRows.filter((row) => String(row.roleIsPrivileged).toLowerCase() === "true"));
  addSheet(workbook, "Data Plane Access", accessRows.filter((row) => String(row.roleHasDataActions).toLowerCase() === "true" || row.roleCategory === "DataPlane" || row.roleCategory === "Mixed"));
  addSheet(workbook, "Service Principal Owners", ownerRows);
  addSheet(workbook, "Group Access", groupRows);
  addSheet(workbook, "Entra Roles", accessRows.filter((row) => row.accessModel === "EntraIDRBAC"));
  addSheet(workbook, "Azure RBAC", accessRows.filter((row) => row.accessModel === "AzureRBAC" || row.accessModel === "AzureDataPlaneRBAC"));
  addSheet(workbook, "Management Groups", scopeRows.filter((row) => row.scopeType === "managementGroup"));
  addSheet(workbook, "Subscriptions", scopeRows.filter((row) => row.scopeType === "subscription"));
  addSheet(workbook, "Resource Groups", scopeRows.filter((row) => row.scopeType === "resourceGroup"));
  addSheet(workbook, "Resources", scopeRows.filter((row) => row.scopeType === "resource"));
  addSheet(workbook, "Storage Child Scopes", accessRows.filter((row) => row.collector === "StorageChildScopeRbac"));
  addSheet(workbook, "Key Vault Access", accessRows.filter((row) => row.collector === "KeyVaultAccessPolicies"));
  addSheet(workbook, "PIM", accessRows.filter((row) => String(row.assignmentState || "").match(/Eligible|Activated|PIM/i)));
  addSheet(workbook, "Billing Reservations", accessRows.filter((row) => row.collector === "BillingAccess" || row.collector === "ReservationAccess"));
  addSheet(workbook, "Classic Admins", accessRows.filter((row) => row.collector === "ClassicAdmins"));
  addSheet(workbook, "Role Definitions", roleRows);
  addSheet(workbook, "Principal Directory", principalRows);
  addSheet(workbook, "Errors Warnings", errorsRows.length > 0 ? errorsRows : failedCollectors);
  addSheet(workbook, "Source Metadata", [
    { name: "accessCsv", value: options.accessCsv || "" },
    { name: "effectiveCsv", value: options.effectiveCsv || "" },
    { name: "directCsv", value: options.directCsv || "" },
    { name: "collectorStatusCsv", value: options.collectorStatusCsv || "" },
    { name: "coverageJson", value: options.coverageJson || "" },
  ], ["name", "value"]);

  const pivotSheet = workbook.addWorksheet("Pivots");
  pivotSheet.columns = [
    { header: "A", key: "a", width: 42 },
    { header: "B", key: "b", width: 42 },
    { header: "C", key: "c", width: 42 },
    { header: "Count", key: "count", width: 14 },
  ];
  addSection(pivotSheet, "Access By Surface", countBy(accessRows, ["surface"]), [
    { header: "Surface", key: "surface" },
    { header: "Count", key: "count" },
  ]);
  addSection(pivotSheet, "Access By Role", top(countBy(accessRows, ["roleName"])), [
    { header: "Role", key: "roleName" },
    { header: "Count", key: "count" },
  ]);
  addSection(pivotSheet, "Access By Principal Type", countBy(effectiveRows, ["effectivePrincipalType"]), [
    { header: "Principal Type", key: "effectivePrincipalType" },
    { header: "Count", key: "count" },
  ]);
  addSection(pivotSheet, "Access By Principal", top(countBy(effectiveRows, ["effectivePrincipalName", "effectivePrincipalType"])), [
    { header: "Principal", key: "effectivePrincipalName" },
    { header: "Type", key: "effectivePrincipalType" },
    { header: "Count", key: "count" },
  ]);
  addSection(pivotSheet, "Access By Subscription", top(countBy(accessRows, ["subscriptionName", "subscriptionId"])), [
    { header: "Subscription", key: "subscriptionName" },
    { header: "Subscription ID", key: "subscriptionId" },
    { header: "Count", key: "count" },
  ]);
  addSection(pivotSheet, "Access By Management Group", top(countBy(accessRows, ["managementGroupName", "managementGroupId"])), [
    { header: "Management Group", key: "managementGroupName" },
    { header: "Management Group ID", key: "managementGroupId" },
    { header: "Count", key: "count" },
  ]);
  addSection(pivotSheet, "Access By Scope Type", countBy(accessRows, ["scopeType"]), [
    { header: "Scope Type", key: "scopeType" },
    { header: "Count", key: "count" },
  ]);
  addSection(pivotSheet, "Privileged Roles By Principal", top(countBy(accessRows.filter((row) => String(row.roleIsPrivileged).toLowerCase() === "true"), ["effectivePrincipalName", "roleName"])), [
    { header: "Principal", key: "effectivePrincipalName" },
    { header: "Role", key: "roleName" },
    { header: "Count", key: "count" },
  ]);
  addSection(pivotSheet, "Data Plane Roles By Resource Type", top(countBy(accessRows.filter((row) => String(row.roleHasDataActions).toLowerCase() === "true" || row.roleCategory === "DataPlane" || row.roleCategory === "Mixed"), ["resourceType", "roleName"])), [
    { header: "Resource Type", key: "resourceType" },
    { header: "Role", key: "roleName" },
    { header: "Count", key: "count" },
  ]);
  addSection(pivotSheet, "Group-Derived Access By Group", top(countBy(groupRows, ["sourceGroupName", "sourceGroupId"])), [
    { header: "Group", key: "sourceGroupName" },
    { header: "Group ID", key: "sourceGroupId" },
    { header: "Count", key: "count" },
  ]);
  addSection(pivotSheet, "PIM Eligible Vs Active", countBy(accessRows.filter((row) => row.collector && row.collector.includes("Pim")), ["assignmentState", "roleName"]), [
    { header: "State", key: "assignmentState" },
    { header: "Role", key: "roleName" },
    { header: "Count", key: "count" },
  ]);
  addSection(pivotSheet, "Failures By Collector", countBy(failedCollectors, ["collector", "status"]), [
    { header: "Collector", key: "collector" },
    { header: "Status", key: "status" },
    { header: "Count", key: "count" },
  ]);
  addSection(pivotSheet, "Resources Discovered By Type", top(countBy(scopeRows.filter((row) => row.scopeType === "resource"), ["resourceType"])), [
    { header: "Resource Type", key: "resourceType" },
    { header: "Count", key: "count" },
  ]);

  await workbook.xlsx.writeFile(options.output);

  const summary = {
    generatedUtc: new Date().toISOString(),
    runDir: options.runDir || "",
    workbook: options.output,
    allAccessRows: accessRows.length,
    effectiveAccessRows: effectiveRows.length,
    directAssignmentRows: directRows.length,
    groupDerivedRows: groupRows.length,
    servicePrincipalOwnerRows: ownerRows.length,
    uniqueEffectivePrincipals: uniqueCount(effectiveRows, "effectivePrincipalId"),
    uniqueRoles: uniqueCount(accessRows, "roleName"),
    uniqueSubscriptions: uniqueCount(accessRows, "subscriptionId"),
    collectorCount: statusRows.length,
    collectorsNeedingAttention: failedCollectors.length,
    coverage,
  };
  fs.writeFileSync(options.summaryJson, `${JSON.stringify(summary, null, 2)}\n`, "utf8");
  console.log(`All Azure access workbook written to ${options.output}`);
  console.log(`All access rows: ${summary.allAccessRows}`);
  console.log(`Collectors needing attention: ${summary.collectorsNeedingAttention}`);
}

main().catch((error) => {
  console.error(error.stack || error.message);
  process.exit(1);
});
