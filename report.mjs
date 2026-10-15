#!/usr/bin/env node
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import ExcelJS from "exceljs";

export const governanceDatasets = [
  { basename: "accessCatalogs", sheet: "Access Catalogs", columns: "tenantId,id,displayName,description,state,isExternallyVisible,createdDateTime,modifiedDateTime" },
  { basename: "accessPackages", sheet: "Access Packages", columns: "tenantId,id,catalogId,displayName,description,isHidden,createdDateTime,modifiedDateTime" },
  { basename: "accessPackagePolicies", sheet: "Package Policies", columns: "tenantId,id,packageId,displayName,description,allowedTargetScope,approvalRequired,expirationType,expirationDuration,expirationEndDateTime,reviewsEnabled,reviewSettingsJson,requestApprovalSettingsJson,requestorSettingsJson,automaticRequestSettingsJson,specificAllowedTargetsJson,createdDateTime,modifiedDateTime" },
  { basename: "accessPackageResources", sheet: "Package Resources", columns: "tenantId,packageId,id,resourceId,resourceOriginId,originSystem,resourceDisplayName,roleId,roleOriginId,roleDisplayName,scopeId,scopeOriginId,scopeDisplayName" },
  { basename: "accessPackageAssignments", sheet: "Package Assignments", columns: "tenantId,id,packageId,policyId,subjectId,principalId,principalType,principalDisplayName,principalName,email,state,status,startDateTime,expirationType,expirationDuration,endDateTime,expiredDateTime" },
  { basename: "accessReviewDefinitions", sheet: "Review Definitions", columns: "tenantId,id,displayName,reviewType,status,scopeJson,instanceEnumerationScopeJson,settingsJson,reviewersJson,fallbackReviewersJson,stageSettingsJson,createdDateTime,lastModifiedDateTime" },
  { basename: "accessReviewInstances", sheet: "Review Instances", columns: "tenantId,id,definitionId,displayName,reviewType,status,startDateTime,endDateTime,scopeJson,reviewersJson,fallbackReviewersJson,errorsJson" },
  { basename: "accessReviewStages", sheet: "Review Stages", columns: "tenantId,id,definitionId,instanceId,status,startDateTime,endDateTime,reviewersJson,fallbackReviewersJson" },
  { basename: "accessReviewDecisions", sheet: "Review Decisions", columns: "tenantId,id,definitionId,instanceId,stageId,decisionLevel,reviewType,principalId,principalDisplayName,principalType,resourceId,resourceDisplayName,resourceType,decision,recommendation,justification,reviewedById,reviewedByName,reviewedDateTime,applyResult,applyDescription,appliedById,appliedDateTime,principalLink,resourceLink,permissionJson" },
  { basename: "governanceAccessLinks", sheet: "Governance Access Links", columns: "tenantId,assignmentId,packageId,principalId,resourceOriginId,accessAssignmentId,accessCollector,scope,roleName,accessPath,evidence" },
  { basename: "governanceFindings", sheet: "Governance Findings", columns: "tenantId,type,recordId,packageId,definitionId,instanceId,principalId,detail" },
].map((dataset) => ({ ...dataset, columns: dataset.columns.split(",") }));

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

// Excel caps a sheet at 1,048,576 rows, and readFileSync on a multi-GB CSV blows V8's
// string limit long before that. Read in chunks and stop at maxRows.
function readCsvBounded(filePath, maxRows) {
  const result = { rows: [], truncated: false, bytes: 0 };
  if (!filePath || !fs.existsSync(filePath)) return result;
  result.bytes = fs.statSync(filePath).size;

  const fd = fs.openSync(filePath, "r");
  try {
    const buffer = Buffer.alloc(1 << 22);
    const decoder = new TextDecoder("utf-8");
    let headers = null;
    let row = [];
    let field = "";
    let inQuotes = false;
    let quoteSeen = false;
    let done = false;

    const pushRow = () => {
      row.push(field);
      field = "";
      if (headers === null) {
        headers = row.map((h) => h.trim());
      } else if (row.some((v) => String(v || "").trim() !== "")) {
        const item = {};
        headers.forEach((header, index) => {
          item[header] = row[index] ?? "";
        });
        // Look ahead one record so a file exactly at the limit is not truncated.
        if (result.rows.length >= maxRows) {
          result.truncated = true;
          done = true;
        } else result.rows.push(item);
      }
      row = [];
    };

    const feed = (text) => {
      for (let i = 0; i < text.length && !done; i += 1) {
        const ch = text[i];
        if (quoteSeen) {
          quoteSeen = false;
          if (ch === '"') {
            field += '"';
            continue;
          }
          inQuotes = false;
        }
        if (inQuotes) {
          if (ch === '"') quoteSeen = true;
          else field += ch;
          continue;
        }
        if (ch === '"') inQuotes = true;
        else if (ch === ",") {
          row.push(field);
          field = "";
        } else if (ch === "\n") pushRow();
        else if (ch !== "\r") field += ch;
      }
    };

    while (!done) {
      const read = fs.readSync(fd, buffer, 0, buffer.length, null);
      if (read <= 0) break;
      feed(decoder.decode(buffer.subarray(0, read), { stream: true }));
    }
    if (!done) {
      feed(decoder.decode());
      if (field.length > 0 || row.length > 0) pushRow();
    }
  } finally {
    fs.closeSync(fd);
  }
  return result;
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

function loadGovernance(directory, coverage, maxRows, truncatedSheets) {
  if (typeof directory !== "string" || !fs.existsSync(directory) || !fs.statSync(directory).isDirectory()) {
    throw new Error("--governance-dir must point to an existing scanner output directory");
  }
  const data = {};
  const sourceCounts = {};
  const loadedCounts = {};
  const truncatedDatasets = [];
  const metadata = coverage.governance || {};
  const partialReasons = [];
  for (const dataset of governanceDatasets) {
    const filePath = path.join(directory, `${dataset.basename}.csv`);
    if (!fs.existsSync(filePath) || !fs.statSync(filePath).isFile()) {
      throw new Error(`Missing governance input: ${filePath}`);
    }
    const result = readCsvBounded(filePath, maxRows);
    data[dataset.basename] = result.rows;
    loadedCounts[dataset.basename] = result.rows.length;
    const total = metadata.totals?.[dataset.basename];
    sourceCounts[dataset.basename] = Number.isSafeInteger(total) && total >= 0 ? total : null;
    if (sourceCounts[dataset.basename] === null) {
      partialReasons.push(`Complete source count unavailable: ${dataset.basename}`);
    } else if (total < result.rows.length || (!result.truncated && total !== result.rows.length)) {
      partialReasons.push(`Source count differs from CSV: ${dataset.basename}`);
    }
    if (result.truncated) {
      const truncation = {
        dataset: dataset.basename, sheet: dataset.sheet, keptRows: result.rows.length,
        sourceRows: sourceCounts[dataset.basename], sourceBytes: result.bytes,
      };
      truncatedDatasets.push(truncation);
      truncatedSheets.push(truncation);
      partialReasons.push(`Truncated dataset: ${dataset.basename}`);
      console.warn(`[warn] ${dataset.sheet}: kept first ${result.rows.length} rows (--max-sheet-rows); source file is ${result.bytes} bytes.`);
    }
  }
  const statuses = Array.isArray(metadata.statuses) ? metadata.statuses : [];
  for (const status of statuses) {
    if (!["succeeded", "skipped", "disabled", "notrequested"].includes(String(status.status || "").toLowerCase())) {
      partialReasons.push(`Collector ${status.collector || "Unknown"}: ${status.status || "Unknown"}`);
    }
  }
  if (!Array.isArray(metadata.statuses)) partialReasons.push("Governance collector status unavailable");

  const normalized = (value) => String(value ?? "").trim().toLowerCase();
  const decisions = data.accessReviewDecisions;
  const finalDecisions = decisions.filter((row) => normalized(row.decisionLevel) === "instance");
  const stageDecisions = decisions.filter((row) => normalized(row.decisionLevel) === "stage");
  const denied = finalDecisions.filter((row) => normalized(row.decision) === "deny");
  const applicationState = (row) => {
    const result = normalized(row.applyResult);
    if (result === "appliedsuccessfully") return "appliedSuccessfully";
    if (["new", "notapplied", "pending", "applying"].includes(result)) return "unapplied";
    if (/fail|error/.test(result)) return "failed";
    if (result === "applynotsupported") return "unsupported";
    return "unknown";
  };
  const timestamp = [metadata.generatedUtc, coverage.generatedUtc].find((value) => Number.isFinite(Date.parse(value)));
  const asOfUtc = timestamp || new Date().toISOString();
  const asOf = Date.parse(asOfUtc);
  const pendingStatuses = ["notstarted", "inprogress", "initializing", "starting", "completing", "autoreviewing"];
  const knownStatuses = [...pendingStatuses, "completed", "autoreviewed", "applying", "applied", "expired", "cancelled", "canceled"];
  const pending = data.accessReviewInstances.filter((row) => pendingStatuses.includes(normalized(row.status)));
  const metrics = {
    configuredPoliciesWithoutReviews: data.accessPackagePolicies.filter((row) => normalized(row.reviewsEnabled) === "false").length,
    policiesWithUnknownReviewSetting: data.accessPackagePolicies.filter((row) => !["true", "false"].includes(normalized(row.reviewsEnabled))).length,
    activeReviews: pending.filter((row) =>
      (!row.startDateTime || Date.parse(row.startDateTime) <= asOf)
      && (!row.endDateTime || Date.parse(row.endDateTime) >= asOf)).length,
    overdueReviews: pending.filter((row) => Date.parse(row.endDateTime) < asOf
      && (!row.startDateTime || Date.parse(row.startDateTime) <= asOf)).length,
    reviewsWithUnknownStatus: data.accessReviewInstances.filter((row) => !knownStatuses.includes(normalized(row.status))).length,
    finalDecisions: finalDecisions.length,
    stageDecisions: stageDecisions.length,
    decisionsWithUnknownLevel: decisions.length - finalDecisions.length - stageDecisions.length,
    notReviewed: finalDecisions.filter((row) => normalized(row.decision) === "notreviewed").length,
    deniedUnapplied: denied.filter((row) => applicationState(row) === "unapplied").length,
    deniedApplicationFailed: denied.filter((row) => applicationState(row) === "failed").length,
    deniedAppliedSuccessfully: denied.filter((row) => applicationState(row) === "appliedSuccessfully").length,
    deniedApplicationUnsupported: denied.filter((row) => applicationState(row) === "unsupported").length,
    deniedApplicationUnknown: denied.filter((row) => applicationState(row) === "unknown").length,
  };
  const partial = partialReasons.length > 0;
  return {
    data,
    summary: {
      enabledPackages: metadata.enabledPackages ?? null,
      enabledReviews: metadata.enabledReviews ?? null,
      lookbackDays: metadata.lookbackDays ?? null,
      cutoffUtc: metadata.cutoffUtc ?? null,
      generatedUtc: metadata.generatedUtc ?? null,
      tenantId: metadata.tenantId ?? null,
      asOfUtc, sourceCounts, loadedCounts, truncatedDatasets, statuses, partial, partialReasons,
      metrics: { partial, ...metrics },
      groupings: {
        partial,
        assignmentsByLifecycle: countBy(data.accessPackageAssignments, ["state", "status"]),
        definitionsByTypeAndStatus: countBy(data.accessReviewDefinitions, ["reviewType", "status"]),
        instancesByTypeAndStatus: countBy(data.accessReviewInstances, ["reviewType", "status"]),
        finalDecisionsByTypeAndDecision: countBy(finalDecisions, ["reviewType", "decision"]),
        finalDecisionsByApplicationResult: countBy(finalDecisions, ["decision", "applyResult"]),
        decisionsByLevel: countBy(decisions, ["decisionLevel"]),
        stageDecisionsByDecision: countBy(stageDecisions, ["decision"]),
        findingsByType: countBy(data.governanceFindings, ["type"]),
      },
    },
  };
}

async function main() {
  const options = parseArgs(process.argv);
  if (!options.output) throw new Error("--output is required");
  if (!options.summaryJson) throw new Error("--summary-json is required");

  const maxSheetRows = Math.max(1000, Number(options.maxSheetRows) || 250000);
  const truncatedSheets = [];
  const load = (filePath, label) => {
    const result = readCsvBounded(filePath, maxSheetRows);
    if (result.truncated) {
      truncatedSheets.push({ sheet: label, keptRows: result.rows.length, sourceBytes: result.bytes });
      console.warn(`[warn] ${label}: kept first ${result.rows.length} rows (--max-sheet-rows); source file is ${result.bytes} bytes.`);
    }
    return result.rows;
  };

  const accessRows = load(options.accessCsv, "All access");
  const effectiveRows = load(options.effectiveCsv, "Effective access");
  const directRows = load(options.directCsv, "Direct assignments");
  const groupRows = load(options.groupCsv, "Group derived");
  const ownerRows = load(options.servicePrincipalOwnersCsv, "SP owners");
  const statusRows = load(options.collectorStatusCsv, "Collector status");
  const scopeRows = load(options.scopeInventoryCsv, "Scope inventory");
  const roleRows = load(options.roleDefinitionsCsv, "Role definitions");
  const principalRows = load(options.principalResolutionCsv, "Principal resolution");
  const errorsRows = load(options.errorsCsv, "Errors and warnings");
  if (options.governanceDir !== undefined && options.coverageJson
    && (typeof options.coverageJson !== "string" || !fs.existsSync(options.coverageJson))) {
    throw new Error("Missing explicitly specified governance coverage input (--coverage-json)");
  }
  const coverage = readJson(options.coverageJson, {});
  const governance = options.governanceDir === undefined
    ? null : loadGovernance(options.governanceDir, coverage, maxSheetRows, truncatedSheets);

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
  if (governance) {
    const summary = governance.summary;
    summaryRows.push(
      { metric: "Governance packages enabled", value: summary.enabledPackages ?? "Unknown" },
      { metric: "Governance reviews enabled", value: summary.enabledReviews ?? "Unknown" },
      { metric: "Governance summary completeness", value: summary.partial ? "Partial (loaded rows only)" : "Complete (collected window)" },
      { metric: "Governance review snapshot UTC", value: summary.asOfUtc },
      { metric: "Governance lookback days (0 = all)", value: summary.lookbackDays ?? "Unknown" },
    );
    for (const dataset of governanceDatasets) {
      summaryRows.push(
        { metric: `${dataset.sheet} source rows`, value: summary.sourceCounts[dataset.basename] ?? "Unknown" },
        { metric: `${dataset.sheet} loaded rows`, value: summary.loadedCounts[dataset.basename] },
      );
    }
    const labels = {
      configuredPoliciesWithoutReviews: "Configured policies without reviews (false only)",
      policiesWithUnknownReviewSetting: "Policies with unknown review setting",
      activeReviews: "Active reviews at snapshot",
      overdueReviews: "Overdue reviews at snapshot",
      reviewsWithUnknownStatus: "Reviews with unknown status",
      finalDecisions: "Final instance decisions",
      stageDecisions: "Stage history decisions (not final)",
      decisionsWithUnknownLevel: "Decisions with unknown level",
      notReviewed: "Final NotReviewed decisions",
      deniedUnapplied: "Denied decisions not yet applied",
      deniedApplicationFailed: "Denied decisions with failed application",
      deniedAppliedSuccessfully: "Denied decisions applied successfully (not proof of revocation)",
      deniedApplicationUnsupported: "Denied decisions with unsupported application",
      deniedApplicationUnknown: "Denied decisions with unknown application",
    };
    for (const [key, label] of Object.entries(labels)) {
      summaryRows.push({ metric: `${label} (loaded${summary.partial ? "; partial" : ""})`, value: summary.metrics[key] });
    }
  }

  addSheet(workbook, "Executive Summary", summaryRows, ["metric", "value"]);
  addSheet(workbook, "Collector Status", statusRows);
  addSheet(workbook, "Coverage", Object.entries(coverage).map(([metric, value]) => ({
    metric, value: metric === "governance" ? JSON.stringify(value) : Array.isArray(value) ? value.join(", ") : value,
  })));
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
  if (governance) {
    for (const dataset of governanceDatasets) {
      addSheet(workbook, dataset.sheet, governance.data[dataset.basename], dataset.columns);
    }
  }
  addSheet(workbook, "Source Metadata", [
    { name: "accessCsv", value: options.accessCsv || "" },
    { name: "effectiveCsv", value: options.effectiveCsv || "" },
    { name: "directCsv", value: options.directCsv || "" },
    { name: "collectorStatusCsv", value: options.collectorStatusCsv || "" },
    { name: "coverageJson", value: options.coverageJson || "" },
    ...(governance ? [{ name: "governanceDir", value: options.governanceDir }] : []),
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
  if (governance) {
    const { groupings, partial } = governance.summary;
    for (const [title, key, fields] of [
      ["Package assignments by lifecycle", "assignmentsByLifecycle", ["state", "status"]],
      ["Review definitions by type and status", "definitionsByTypeAndStatus", ["reviewType", "status"]],
      ["Review instances by type and status", "instancesByTypeAndStatus", ["reviewType", "status"]],
      ["Final instance decisions (stage history excluded)", "finalDecisionsByTypeAndDecision", ["reviewType", "decision"]],
      ["Final decision application results (not proof of revocation)", "finalDecisionsByApplicationResult", ["decision", "applyResult"]],
      ["Decision levels", "decisionsByLevel", ["decisionLevel"]],
      ["Stage decision history (not final)", "stageDecisionsByDecision", ["decision"]],
      ["Governance findings", "findingsByType", ["type"]],
    ]) {
      addSection(pivotSheet, `Governance: ${title} (loaded${partial ? "; partial" : ""})`, top(groupings[key]), [
        ...fields.map((field) => ({ header: field, key: field })),
        { header: "Count", key: "count" },
      ]);
    }
  }

  await workbook.xlsx.writeFile(options.output);

  const summary = {
    generatedUtc: new Date().toISOString(),
    runDir: options.runDir || "",
    workbook: options.output,
    maxSheetRows,
    truncatedSheets,
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
    ...(governance ? { governance: governance.summary } : {}),
  };
  fs.writeFileSync(options.summaryJson, `${JSON.stringify(summary, null, 2)}\n`, "utf8");
  console.log(`All Azure access workbook written to ${options.output}`);
  console.log(`All access rows: ${summary.allAccessRows}`);
  console.log(`Collectors needing attention: ${summary.collectorsNeedingAttention}`);
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch((error) => {
    console.error(error.stack || error.message);
    process.exit(1);
  });
}
