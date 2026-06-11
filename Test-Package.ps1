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

if (-not $SkipNpmInstall) {
    if (Test-Path -LiteralPath (Join-Path $root 'package-lock.json')) {
        npm ci
    }
    else {
        npm install
    }
}

npm run sample

$sampleWorkbook = Join-Path $root 'samples\all-azure-access-sample-ALL-dummy.xlsx'
$sampleSummary = Join-Path $root 'samples\all-azure-access-sample-ALL-dummy-summary.json'
if (-not (Test-Path -LiteralPath $sampleWorkbook)) { throw "Sample workbook was not generated: $sampleWorkbook" }
if (-not (Test-Path -LiteralPath $sampleSummary)) { throw "Sample summary was not generated: $sampleSummary" }

$summary = Get-Content -LiteralPath $sampleSummary -Raw | ConvertFrom-Json
if ([int]$summary.allAccessRows -le 0) { throw 'Sample summary has no access rows.' }

Write-Host "[OK] Sample workbook: $sampleWorkbook"
Write-Host "[OK] Sample rows: $($summary.allAccessRows)"
Write-Host '[OK] Package validation completed.'
