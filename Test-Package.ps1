[CmdletBinding()]
param(
    [switch]$SkipNpmInstall
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = $PSScriptRoot
Set-Location $root

function Test-PowerShellParse {
    param([Parameter(Mandatory = $true)][string]$Path)
    $errors = $null
    [System.Management.Automation.PSParser]::Tokenize((Get-Content -LiteralPath $Path -Raw), [ref]$errors) | Out-Null
    if ($errors) {
        $details = ($errors | ForEach-Object { "{0}: {1}" -f $_.Token.StartLine, $_.Message }) -join [Environment]::NewLine
        throw "PowerShell parse failed for $Path`n$details"
    }
    Write-Host "[OK] PowerShell parse: $Path"
}

Test-PowerShellParse -Path (Join-Path $root 'run.ps1')
Test-PowerShellParse -Path (Join-Path $root 'Run-QuickScan.ps1')
Test-PowerShellParse -Path (Join-Path $root 'lib\AzureScannerCommon.psm1')
Test-PowerShellParse -Path (Join-Path $root 'lib\AzureScannerLog.psm1')
Test-PowerShellParse -Path (Join-Path $root 'lib\AzureScannerUI.psm1')
Test-PowerShellParse -Path (Join-Path $root 'lib\AzureScannerGovernance.psm1')
Test-PowerShellParse -Path (Join-Path $root 'tests\Test-Governance.ps1')

& (Join-Path $root 'tests\Test-Governance.ps1')

# Logs get emailed to support, so a token or UPN reaching disk is a release blocker.
Import-Module (Join-Path $root 'lib\AzureScannerLog.psm1') -Force -WarningAction SilentlyContinue
$redactionDir = Join-Path ([System.IO.Path]::GetTempPath()) ('azscan-redaction-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
try {
    Initialize-ScannerLog -LogDirectory $redactionDir -LogLevel 'Trace' -RedactOnDisk -TenantId 'test-tenant' | Out-Null
    $secret = 'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk'
    Write-ScannerEvent -Level 'Error' -Collector 'RedactionTest' -EventName 'leak-probe' `
        -Message ("Authorization: Bearer $secret for jane.doe@contoso.com with access_token=$secret") `
        -Scope '/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg-secret-name'
    Write-ScannerEvent -Level 'Warn' -Collector 'RedactionTest' -EventName 'leak-probe-2' -Message "client_secret: hunter2-should-not-appear"
    Close-ScannerLog | Out-Null

    $forbidden = @('eyJhbGciOiJIUzI1NiJ9', 'jane\.doe@contoso\.com', 'hunter2', 'rg-secret-name', '11111111-2222-3333-4444-555555555555')
    foreach ($file in @(Get-ChildItem -LiteralPath $redactionDir -File | Where-Object { $_.Name -notlike '*LOCAL-ONLY*' })) {
        $content = Get-Content -LiteralPath $file.FullName -Raw
        foreach ($pattern in $forbidden) {
            if ($content -match $pattern) { throw "Redaction failure: '$pattern' leaked into $($file.Name)" }
        }
    }
    Write-Host "[OK] Redaction: no tokens, UPNs, GUIDs or resource names leaked into shareable log files"
}
finally {
    Remove-Item -LiteralPath $redactionDir -Recurse -Force -ErrorAction SilentlyContinue
}

if (-not $SkipNpmInstall) {
    if (Test-Path -LiteralPath (Join-Path $root 'package-lock.json')) {
        npm ci
    }
    else {
        npm install
    }
}

npm run sample
if ($LASTEXITCODE -ne 0) { throw "Dummy sample generation failed with exit code $LASTEXITCODE." }
node --test (Join-Path $root 'tests\report-governance.test.mjs')
if ($LASTEXITCODE -ne 0) { throw "Governance report tests failed with exit code $LASTEXITCODE." }

$sampleWorkbook = Join-Path $root 'samples\all-azure-access-sample-ALL-dummy.xlsx'
$sampleSummary = Join-Path $root 'samples\all-azure-access-sample-ALL-dummy-summary.json'
if (-not (Test-Path -LiteralPath $sampleWorkbook)) { throw "Sample workbook was not generated: $sampleWorkbook" }
if (-not (Test-Path -LiteralPath $sampleSummary)) { throw "Sample summary was not generated: $sampleSummary" }

$summary = Get-Content -LiteralPath $sampleSummary -Raw | ConvertFrom-Json
if ([int]$summary.allAccessRows -le 0) { throw 'Sample summary has no access rows.' }

Write-Host "[OK] Sample workbook: $sampleWorkbook"
Write-Host "[OK] Sample rows: $($summary.allAccessRows)"
Write-Host '[OK] Package validation completed.'
