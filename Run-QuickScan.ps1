[CmdletBinding()]
param(
    [int]$LimitResources = 25,
    [switch]$IncludeReservations
)

$arguments = @(
    '-ExecutionPolicy', 'Bypass',
    '-File', (Join-Path $PSScriptRoot 'run.ps1'),
    '-LimitResources', [string]$LimitResources,
    '-ContinueOnError'
)

if (-not $IncludeReservations) {
    $arguments += '-SkipReservations'
}

& powershell @arguments
exit $LASTEXITCODE
