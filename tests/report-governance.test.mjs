import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { randomUUID } from "node:crypto";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import test from "node:test";
import ExcelJS from "exceljs";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const schemas = [
  ["accessCatalogs", "Access Catalogs", "tenantId,id,displayName,description,state,isExternallyVisible,createdDateTime,modifiedDateTime"],
  ["accessPackages", "Access Packages", "tenantId,id,catalogId,displayName,description,isHidden,createdDateTime,modifiedDateTime"],
  ["accessPackagePolicies", "Package Policies", "tenantId,id,packageId,displayName,description,allowedTargetScope,approvalRequired,expirationType,expirationDuration,expirationEndDateTime,reviewsEnabled,reviewSettingsJson,requestApprovalSettingsJson,requestorSettingsJson,automaticRequestSettingsJson,specificAllowedTargetsJson,createdDateTime,modifiedDateTime"],
  ["accessPackageResources", "Package Resources", "tenantId,packageId,id,resourceId,resourceOriginId,originSystem,resourceDisplayName,roleId,roleOriginId,roleDisplayName,scopeId,scopeOriginId,scopeDisplayName"],
  ["accessPackageAssignments", "Package Assignments", "tenantId,id,packageId,policyId,subjectId,principalId,principalType,principalDisplayName,principalName,email,state,status,startDateTime,expirationType,expirationDuration,endDateTime,expiredDateTime"],
  ["accessReviewDefinitions", "Review Definitions", "tenantId,id,displayName,reviewType,status,scopeJson,instanceEnumerationScopeJson,settingsJson,reviewersJson,fallbackReviewersJson,stageSettingsJson,createdDateTime,lastModifiedDateTime"],
  ["accessReviewInstances", "Review Instances", "tenantId,id,definitionId,displayName,reviewType,status,startDateTime,endDateTime,scopeJson,reviewersJson,fallbackReviewersJson,errorsJson"],
  ["accessReviewStages", "Review Stages", "tenantId,id,definitionId,instanceId,status,startDateTime,endDateTime,reviewersJson,fallbackReviewersJson"],
  ["accessReviewDecisions", "Review Decisions", "tenantId,id,definitionId,instanceId,stageId,decisionLevel,reviewType,principalId,principalDisplayName,principalType,resourceId,resourceDisplayName,resourceType,decision,recommendation,justification,reviewedById,reviewedByName,reviewedDateTime,applyResult,applyDescription,appliedById,appliedDateTime,principalLink,resourceLink,permissionJson"],
  ["governanceAccessLinks", "Governance Access Links", "tenantId,assignmentId,packageId,principalId,resourceOriginId,accessAssignmentId,accessCollector,scope,roleName,accessPath,evidence"],
  ["governanceFindings", "Governance Findings", "tenantId,type,recordId,packageId,definitionId,instanceId,principalId,detail"],
].map(([basename, sheet, columns]) => ({ basename, sheet, columns: columns.split(",") }));
const legacySheets = [
  "Executive Summary", "Collector Status", "Coverage", "All Access Raw", "Effective Access",
  "Privileged Access", "Data Plane Access", "Service Principal Owners", "Group Access",
  "Entra Roles", "Azure RBAC", "Management Groups", "Subscriptions", "Resource Groups",
  "Resources", "Storage Child Scopes", "Key Vault Access", "PIM", "Billing Reservations",
  "Classic Admins", "Role Definitions", "Principal Directory", "Errors Warnings",
  "Source Metadata", "Pivots",
];

function fixture(t) {
  // Keep scratch inputs local to the workspace and remove them even on assertion failure.
  const directory = path.join(root, `.report-governance-test-${randomUUID()}`);
  fs.mkdirSync(directory);
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  const input = path.join(directory, "input");
  fs.cpSync(path.join(root, "samples", "dummy-input"), input, { recursive: true });
  return {
    directory,
    input,
    coverage: JSON.parse(fs.readFileSync(path.join(input, "coverageSummary.json"), "utf8")),
  };
}

function writeCsv(f, basename, rows) {
  const { columns } = schemas.find((dataset) => dataset.basename === basename);
  const escape = (value) => `"${String(value ?? "").replaceAll('"', '""')}"`;
  fs.writeFileSync(path.join(f.input, `${basename}.csv`),
    `${[columns, ...rows.map((row) => columns.map((key) => row[key]))]
      .map((row) => row.map(escape).join(",")).join("\r\n")}\r\n`);
  f.coverage.governance.totals[basename] = rows.length;
}

function completeCoverage(f) {
  f.coverage.governance.statuses = [
    { collector: "Governance", status: "Succeeded", rowsAdded: 0, message: "Synthetic successful collection" },
  ];
}

async function report(f, { governance = true, extra = [], failure = false, coverage = true } = {}) {
  fs.writeFileSync(path.join(f.input, "coverageSummary.json"), JSON.stringify(f.coverage));
  const output = path.join(f.directory, `report-${randomUUID()}.xlsx`);
  const summaryFile = output.replace(/\.xlsx$/, ".json");
  const args = [path.join(root, "report.mjs")];
  for (const [option, file] of [
    ["access-csv", "allAzureAccess.csv"], ["effective-csv", "effectiveAccess.csv"],
    ["direct-csv", "directAssignments.csv"], ["group-csv", "groupDerivedAccess.csv"],
    ["service-principal-owners-csv", "servicePrincipalOwners.csv"],
    ["collector-status-csv", "collectorStatus.csv"], ["scope-inventory-csv", "scopeInventory.csv"],
    ["role-definitions-csv", "roleDefinitions.csv"], ["principal-resolution-csv", "principalResolution.csv"],
    ["errors-csv", "errorsWarnings.csv"],
  ]) args.push(`--${option}`, path.join(f.input, file));
  if (coverage) args.push("--coverage-json", path.join(f.input, "coverageSummary.json"));
  if (governance) args.push("--governance-dir", f.input);
  args.push("--output", output, "--summary-json", summaryFile, ...extra);
  const result = spawnSync(process.execPath, args, { cwd: root, encoding: "utf8", timeout: 60000 });
  assert.ifError(result.error);
  const logs = `${result.stdout}${result.stderr}`;
  if (failure) {
    assert.notEqual(result.status, 0, logs);
    assert.equal(fs.existsSync(summaryFile), false);
    return { logs };
  }
  assert.equal(result.status, 0, logs);
  const workbook = new ExcelJS.Workbook();
  await workbook.xlsx.readFile(output);
  return { workbook, summary: JSON.parse(fs.readFileSync(summaryFile, "utf8")), logs };
}

function sheetRows(sheet) {
  const headers = sheet.getRow(1).values.slice(1);
  return Array.from({ length: sheet.rowCount - 1 }, (_, index) =>
    Object.fromEntries(headers.map((key, column) => [key, sheet.getCell(index + 2, column + 1).value ?? ""])));
}

function summaryMetrics(workbook) {
  return Object.fromEntries(sheetRows(workbook.getWorksheet("Executive Summary")).map((row) => [row.metric, row.value]));
}

test("legacy reports retain the exact sheet set and access metrics without --governance-dir", async (t) => {
  const f = fixture(t);
  const { workbook, summary } = await report(f, { governance: false });
  assert.deepEqual(workbook.worksheets.map((sheet) => sheet.name), legacySheets);
  assert.equal(Object.hasOwn(summary, "governance"), false);
  assert.equal(summary.allAccessRows, f.coverage.effectiveAssignments);
  assert.equal(summary.directAssignmentRows, f.coverage.directAssignments);
  assert.equal(summary.groupDerivedRows, f.coverage.groupDerivedAssignments);
  assert.equal(summary.servicePrincipalOwnerRows, f.coverage.servicePrincipalOwnerRows);
  assert.equal(summaryMetrics(workbook)["All access rows"], summary.allAccessRows);
  assert.equal(Object.keys(summaryMetrics(workbook)).some((label) => label.startsWith("Governance ")), false);
});

test("governance sheets have exact schemas, complete source counts, and no inflated access totals", async (t) => {
  const f = fixture(t);
  const baseline = await report(f, { governance: false });
  const { workbook, summary, logs } = await report(f);
  assert.deepEqual(workbook.worksheets.map((sheet) => sheet.name), [
    ...legacySheets.slice(0, -2), ...schemas.map((dataset) => dataset.sheet), ...legacySheets.slice(-2),
  ]);
  for (const { basename, sheet: name, columns } of schemas) {
    const sheet = workbook.getWorksheet(name);
    assert.deepEqual(sheet.getRow(1).values.slice(1), columns, name);
    assert.equal(sheet.columnCount, columns.length, name);
    assert.equal(sheet.rowCount - 1, f.coverage.governance.totals[basename], name);
    assert.equal(summary.governance.sourceCounts[basename], f.coverage.governance.totals[basename], name);
    assert.equal(summary.governance.loadedCounts[basename], sheet.rowCount - 1, name);
    assert.equal(sheet.views[0].ySplit, 1, name);
  }
  for (const metric of [
    "allAccessRows", "effectiveAccessRows", "directAssignmentRows", "groupDerivedRows",
    "servicePrincipalOwnerRows", "uniqueEffectivePrincipals", "uniqueRoles", "uniqueSubscriptions",
    "collectorCount", "collectorsNeedingAttention",
  ]) assert.equal(summary[metric], baseline.summary[metric], metric);
  assert.equal(summary.governance.lookbackDays, 0);
  assert.equal(summary.governance.cutoffUtc, null);
  assert.equal(summary.governance.enabledPackages, true);
  assert.equal(summary.governance.enabledReviews, true);
  assert.equal(summary.governance.tenantId, "tenant-0000");
  const definitions = sheetRows(workbook.getWorksheet("Review Definitions"));
  assert.deepEqual(new Set(definitions.map((row) => row.reviewType)),
    new Set(["AccessPackage", "Group", "Application", "DirectoryRole", "Unknown"]));
  const assignments = sheetRows(workbook.getWorksheet("Package Assignments"));
  assert.deepEqual(new Set(assignments.map((row) => row.state)), new Set(["delivered", "partiallyDelivered", "expired"]));
  const external = assignments.find((row) => row.principalType === "ExternalUser");
  assert.equal(external.principalId, "");
  assert.equal(external.email, "external.collaborator@example.invalid");
  assert.equal(workbook.getWorksheet("Governance Access Links").rowCount, 2);
  assert.equal(workbook.getWorksheet("Governance Findings").rowCount, 4);
  const decisions = sheetRows(workbook.getWorksheet("Review Decisions"));
  assert.match(decisions[0].justification, /\n/);
  assert.equal(logs.includes(decisions[0].justification), false);
  const externalDecision = decisions.find((row) => row.principalType === "ExternalUser");
  assert.equal(JSON.parse(externalDecision.permissionJson).subject.objectId, "");
  const coverageSheet = sheetRows(workbook.getWorksheet("Coverage")).find((row) => row.metric === "governance");
  assert.deepEqual(JSON.parse(coverageSheet.value), f.coverage.governance);
});

test("final decisions exclude multistage history and distinguish denial from application", async (t) => {
  const f = fixture(t);
  const { workbook, summary } = await report(f);
  const { metrics, groupings } = summary.governance;
  assert.equal(summary.governance.sourceCounts.accessReviewDecisions, 8);
  assert.equal(summary.governance.sourceCounts.accessReviewStages, 2);
  assert.equal(metrics.finalDecisions, 6);
  assert.equal(metrics.stageDecisions, 2);
  assert.equal(metrics.notReviewed, 1);
  assert.equal(metrics.deniedUnapplied, 1);
  assert.equal(metrics.deniedAppliedSuccessfully, 1);
  assert.equal(metrics.deniedApplicationFailed, 1);
  assert.equal(metrics.deniedApplicationUnknown, 0);
  assert.equal(metrics.configuredPoliciesWithoutReviews, 1);
  assert.equal(metrics.policiesWithUnknownReviewSetting, 1);
  assert.equal(metrics.activeReviews, 1);
  assert.equal(metrics.overdueReviews, 1);
  assert.equal(metrics.reviewsWithUnknownStatus, 1);
  assert.equal(groupings.finalDecisionsByTypeAndDecision.reduce((sum, row) => sum + row.count, 0), 6);
  assert.equal(groupings.stageDecisionsByDecision.reduce((sum, row) => sum + row.count, 0), 2);
  assert.equal(Object.keys(metrics).some((key) => /revok/i.test(key)), false);
  assert.ok(Object.keys(summaryMetrics(workbook)).some((key) => /not proof of revocation/.test(key)));
});

test("unauthorized and partial collection are explicit in executive metrics and pivots", async (t) => {
  const f = fixture(t);
  const { workbook, summary } = await report(f);
  assert.equal(summary.governance.partial, true);
  assert.equal(summary.governance.metrics.partial, true);
  assert.equal(summary.governance.groupings.partial, true);
  assert.equal(summary.governance.truncatedDatasets.length, 0);
  assert.ok(summary.governance.statuses.some((row) => row.status === "Unauthorized" && row.rowsAdded === 0));
  assert.ok(summary.governance.partialReasons.some((reason) => reason.includes("Unauthorized")));
  assert.ok(summary.governance.partialReasons.some((reason) => reason.includes("PartiallyCollected")));
  const executive = summaryMetrics(workbook);
  assert.equal(executive["Governance summary completeness"], "Partial (loaded rows only)");
  assert.equal(executive["Final instance decisions (loaded; partial)"], 6);
  const pivot = workbook.getWorksheet("Pivots");
  const titles = [];
  pivot.eachRow((row) => {
    if (String(row.getCell(1).value).startsWith("Governance:")) titles.push(row.getCell(1).value);
  });
  assert.equal(titles.length, 8);
  assert.ok(titles.every((title) => title.includes("; partial")));
});

for (const unauthorized of [false, true]) {
  test(`header-only governance exports distinguish ${unauthorized ? "unauthorized" : "successful zero-row"} collection`, async (t) => {
    const f = fixture(t);
    for (const { basename } of schemas) writeCsv(f, basename, []);
    completeCoverage(f);
    if (unauthorized) {
      f.coverage.governance.statuses = [
        { collector: "AccessReviews", status: "Unauthorized", rowsAdded: 0, message: "Synthetic denied endpoint" },
      ];
    }
    const { workbook, summary } = await report(f);
    assert.equal(summary.governance.partial, unauthorized);
    for (const { basename, sheet: name, columns } of schemas) {
      const sheet = workbook.getWorksheet(name);
      assert.equal(sheet.rowCount, 1, name);
      assert.deepEqual(sheet.getRow(1).values.slice(1), columns, name);
      assert.equal(summary.governance.sourceCounts[basename], 0);
      assert.equal(summary.governance.loadedCounts[basename], 0);
    }
    assert.equal(summary.governance.metrics.notReviewed, 0);
    assert.equal(summary.governance.metrics.configuredPoliciesWithoutReviews, 0);
    assert.equal(summary.governance.statuses[0].status, unauthorized ? "Unauthorized" : "Succeeded");
  });
}

test("disabled collectors retain explicit feature flags without marking coverage partial", async (t) => {
  for (const [enabledPackages, enabledReviews] of [[false, false], [true, false], [false, true]]) {
    const f = fixture(t);
    for (const { basename } of schemas) writeCsv(f, basename, []);
    f.coverage.governance.enabledPackages = enabledPackages;
    f.coverage.governance.enabledReviews = enabledReviews;
    f.coverage.governance.statuses = [
      "AccessPackageCatalogs", "AccessPackages", "AccessPackagePolicies", "AccessPackageResources",
      "AccessPackageAssignments", "AccessReviewDefinitions", "AccessReviewInstances", "AccessReviewStages",
      "AccessReviewDecisions",
    ].map((collector) => ({
      collector,
      status: (collector.startsWith("AccessPackage") ? enabledPackages : enabledReviews) ? "Succeeded" : "Skipped",
      rowsAdded: 0,
    }));
    const { summary } = await report(f);
    assert.equal(summary.governance.enabledPackages, enabledPackages);
    assert.equal(summary.governance.enabledReviews, enabledReviews);
    assert.equal(summary.governance.partial, false);
    assert.deepEqual(summary.governance.partialReasons, []);
    assert.ok(summary.governance.statuses.some((row) => row.status === "Skipped"));
  }
});

test("unknown settings, lifecycle values, decision levels and application results are not coerced", async (t) => {
  const f = fixture(t);
  completeCoverage(f);
  writeCsv(f, "accessPackagePolicies", ["False", "True", "", "Unknown", "0"].map((reviewsEnabled, index) =>
    ({ id: `policy-synthetic-${index}`, reviewsEnabled })));
  writeCsv(f, "accessPackageAssignments", [{ id: "assignment-future", state: "FutureLifecycle", status: "FutureStatus" }]);
  writeCsv(f, "accessReviewDecisions", [
    { id: "denied-unknown", decisionLevel: "Instance", reviewType: "Unknown", decision: "Deny", applyResult: "FutureApplicationResult" },
    { id: "denied-empty", decisionLevel: "Instance", decision: "Deny", applyResult: "" },
    { id: "denied-unsupported", decisionLevel: "Instance", decision: "Deny", applyResult: "ApplyNotSupported" },
    { id: "unknown-level", decisionLevel: "FutureLevel", decision: "Deny", applyResult: "New" },
    { id: "empty-level", decisionLevel: "", decision: "NotReviewed", applyResult: "New" },
  ]);
  const { workbook, summary } = await report(f);
  const { metrics, groupings } = summary.governance;
  assert.equal(summary.governance.partial, false);
  assert.equal(metrics.configuredPoliciesWithoutReviews, 1);
  assert.equal(metrics.policiesWithUnknownReviewSetting, 3);
  assert.equal(metrics.finalDecisions, 3);
  assert.equal(metrics.decisionsWithUnknownLevel, 2);
  assert.equal(metrics.notReviewed, 0);
  assert.equal(metrics.deniedUnapplied, 0);
  assert.equal(metrics.deniedApplicationFailed, 0);
  assert.equal(metrics.deniedApplicationUnknown, 2);
  assert.equal(metrics.deniedApplicationUnsupported, 1);
  assert.deepEqual(groupings.assignmentsByLifecycle, [{ state: "FutureLifecycle", status: "FutureStatus", count: 1 }]);
  assert.equal(sheetRows(workbook.getWorksheet("Review Decisions"))[3].decisionLevel, "FutureLevel");
});

test("review activity uses snapshot status and dates, not simply a past deadline", async (t) => {
  const f = fixture(t);
  completeCoverage(f);
  const instance = (id, status, startDateTime, endDateTime) =>
    ({ id, status, startDateTime, endDateTime, reviewType: "Group" });
  writeCsv(f, "accessReviewInstances", [
    instance("active", "InProgress", "2026-01-01T00:00:00Z", "2026-01-11T00:00:00Z"),
    instance("initializing", "Initializing", "2026-01-01T00:00:00Z", "2026-01-11T00:00:00Z"),
    instance("starting", "Starting", "2026-01-01T00:00:00Z", "2026-01-11T00:00:00Z"),
    instance("automatic", "AutoReviewing", "2026-01-01T00:00:00Z", "2026-01-11T00:00:00Z"),
    instance("overdue", "NotStarted", "2026-01-01T00:00:00Z", "2026-01-09T00:00:00Z"),
    instance("completing", "Completing", "2026-01-01T00:00:00Z", "2026-01-09T00:00:00Z"),
    instance("completed", "Completed", "2026-01-01T00:00:00Z", "2026-01-02T00:00:00Z"),
    instance("automatic-completed", "AutoReviewed", "2026-01-01T00:00:00Z", "2026-01-02T00:00:00Z"),
    instance("applied", "Applied", "2026-01-01T00:00:00Z", "2026-01-02T00:00:00Z"),
    instance("future", "NotStarted", "2026-02-01T00:00:00Z", "2026-02-02T00:00:00Z"),
    instance("unknown", "FutureStatus", "2026-01-01T00:00:00Z", "2026-01-02T00:00:00Z"),
    instance("invalid-date", "InProgress", "invalid", "invalid"),
  ]);
  const { summary } = await report(f);
  assert.equal(summary.governance.asOfUtc, "2026-01-10T00:00:12Z");
  assert.equal(summary.governance.metrics.activeReviews, 4);
  assert.equal(summary.governance.metrics.overdueReviews, 2);
  assert.equal(summary.governance.metrics.reviewsWithUnknownStatus, 1);
});

test("bounded reads preserve complete totals and mark loaded lifecycle/decision summaries partial", async (t) => {
  const f = fixture(t);
  completeCoverage(f);
  const sensitive = 'Synthetic confidential marker, "quoted"\nnot for logs.';
  writeCsv(f, "accessReviewDecisions", Array.from({ length: 1005 }, (_, index) => ({
    tenantId: "tenant-0000", id: `synthetic-decision-${index}`, decisionLevel: "Instance",
    reviewType: "Group", decision: index < 1000 ? "Deny" : "Approve", applyResult: "New",
    justification: sensitive,
  })));
  writeCsv(f, "accessPackageAssignments", Array.from({ length: 1001 }, (_, index) => ({
    id: `synthetic-assignment-${index}`, state: index < 1000 ? "delivered" : "expired", status: "Delivered",
  })));
  const { workbook, summary, logs } = await report(f, { extra: ["--max-sheet-rows", "1"] });
  assert.equal(summary.maxSheetRows, 1000);
  assert.equal(summary.governance.sourceCounts.accessReviewDecisions, 1005);
  assert.equal(summary.governance.loadedCounts.accessReviewDecisions, 1000);
  assert.equal(summary.governance.sourceCounts.accessPackageAssignments, 1001);
  assert.equal(summary.governance.loadedCounts.accessPackageAssignments, 1000);
  assert.equal(workbook.getWorksheet("Review Decisions").rowCount, 1001);
  assert.equal(workbook.getWorksheet("Package Assignments").rowCount, 1001);
  assert.equal(sheetRows(workbook.getWorksheet("Review Decisions"))[999].justification, sensitive);
  assert.equal(logs.includes("Synthetic confidential marker"), false);
  assert.match(logs, /Review Decisions: kept first 1000 rows/);
  assert.equal(summary.governance.metrics.finalDecisions, 1000);
  assert.equal(summary.governance.metrics.deniedUnapplied, 1000);
  assert.equal(summary.governance.partial, true);
  assert.equal(summary.governance.groupings.partial, true);
  assert.equal(summary.governance.metrics.partial, true);
  assert.equal(summary.governance.truncatedDatasets.length, 2);
  for (const metadata of summary.governance.truncatedDatasets) {
    assert.equal(metadata.keptRows, 1000);
    assert.ok(metadata.sourceRows > metadata.keptRows);
    assert.ok(metadata.sourceBytes > 0);
    assert.ok(summary.truncatedSheets.some((entry) => entry.dataset === metadata.dataset));
  }
  const executive = summaryMetrics(workbook);
  assert.equal(executive["Review Decisions source rows"], 1005);
  assert.equal(executive["Review Decisions loaded rows"], 1000);
  assert.equal(executive["Package Assignments source rows"], 1001);
  assert.equal(executive["Final instance decisions (loaded; partial)"], 1000);
});

test("a CSV exactly at maxSheetRows is not falsely marked truncated", async (t) => {
  const f = fixture(t);
  completeCoverage(f);
  writeCsv(f, "accessReviewDecisions", Array.from({ length: 1000 }, (_, index) => ({
    id: `synthetic-decision-${index}`, decisionLevel: "Instance", decision: "NotReviewed",
  })));
  const { summary } = await report(f, { extra: ["--max-sheet-rows", "1000"] });
  assert.equal(summary.governance.partial, false);
  assert.equal(summary.governance.metrics.notReviewed, 1000);
  assert.deepEqual(summary.governance.truncatedDatasets, []);
  assert.deepEqual(summary.truncatedSheets, []);
});

test("unavailable or inconsistent complete-count metadata is never reported as complete", async (t) => {
  const f = fixture(t);
  completeCoverage(f);
  delete f.coverage.governance.totals.accessPackages;
  f.coverage.governance.totals.accessReviewDecisions = 99;
  const { summary, workbook } = await report(f);
  assert.equal(summary.governance.sourceCounts.accessPackages, null);
  assert.equal(summary.governance.sourceCounts.accessReviewDecisions, 99);
  assert.equal(summary.governance.loadedCounts.accessReviewDecisions, 8);
  assert.equal(summary.governance.partial, true);
  assert.ok(summary.governance.partialReasons.some((reason) => reason.includes("Complete source count unavailable")));
  assert.ok(summary.governance.partialReasons.some((reason) => reason.includes("Source count differs")));
  assert.equal(summaryMetrics(workbook)["Access Packages source rows"], "Unknown");
});

test("governance without coverage retains rows but explicitly marks source counts and completeness unknown", async (t) => {
  const f = fixture(t);
  const { summary } = await report(f, { coverage: false });
  assert.equal(summary.governance.enabledPackages, null);
  assert.equal(summary.governance.sourceCounts.accessPackages, null);
  assert.equal(summary.governance.loadedCounts.accessPackages, 2);
  assert.equal(summary.governance.partial, true);
  assert.ok(summary.governance.partialReasons.includes("Governance collector status unavailable"));
});

test("explicitly missing governance directory, CSV or coverage file fails loudly", async (t) => {
  const f = fixture(t);
  const missingDirectory = await report(f, {
    extra: ["--governance-dir", path.join(f.directory, "missing")], failure: true,
  });
  assert.match(missingDirectory.logs, /--governance-dir must point to an existing/);
  const missingValue = await report(f, { extra: ["--governance-dir"], failure: true });
  assert.match(missingValue.logs, /--governance-dir must point to an existing/);
  const missingCoverage = await report(f, {
    extra: ["--coverage-json", path.join(f.directory, "missing.json")], failure: true,
  });
  assert.match(missingCoverage.logs, /Missing explicitly specified governance coverage input/);
  fs.unlinkSync(path.join(f.input, "accessReviewStages.csv"));
  const missingCsv = await report(f, { failure: true });
  assert.match(missingCsv.logs, /Missing governance input: .*accessReviewStages\.csv/);
});
