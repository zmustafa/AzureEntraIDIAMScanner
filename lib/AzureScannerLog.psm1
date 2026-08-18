Set-StrictMode -Version Latest

# Structured run diagnostics: JSONL event log, deduplicated error rollups, API timing,
# redaction, and the support bundle a customer can email back.

$script:LevelRank = @{ 'Error' = 1; 'Warn' = 2; 'Info' = 3; 'Debug' = 4; 'Trace' = 5 }
$script:Log = $null

function Get-LogLevelRank {
    param([string]$Level)
    if ($Level -and $script:LevelRank.ContainsKey($Level)) { return $script:LevelRank[$Level] }
    return 3
}

function Initialize-ScannerLog {
    param(
        [Parameter(Mandatory = $true)][string]$LogDirectory,
        [ValidateSet('Error', 'Warn', 'Info', 'Debug', 'Trace')][string]$LogLevel = 'Info',
        [switch]$RedactOnDisk,
        [string]$TenantId = '',
        [int]$MaxLogMegabytes = 50,
        [int]$MaxSamplesPerError = 5
    )
    if (-not (Test-Path -LiteralPath $LogDirectory)) {
        New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null
    }
    $eventPath = Join-Path $LogDirectory 'events.jsonl'
    $apiPath = Join-Path $LogDirectory 'apiTiming.csv'
    $utf8 = [System.Text.UTF8Encoding]::new($false)

    $eventWriter = [System.IO.StreamWriter]::new($eventPath, $false, $utf8)
    $eventWriter.AutoFlush = $true
    $apiWriter = [System.IO.StreamWriter]::new($apiPath, $false, $utf8)
    $apiWriter.AutoFlush = $true
    $apiWriter.WriteLine('startedUtc,collector,api,scope,durationMs,exitCode,bytes,attempt,outcome')

    $script:Log = [pscustomobject]@{
        Directory        = $LogDirectory
        EventPath        = $eventPath
        ApiPath          = $apiPath
        EventWriter      = $eventWriter
        ApiWriter        = $apiWriter
        Level            = $LogLevel
        LevelRank        = Get-LogLevelRank -Level $LogLevel
        RedactOnDisk     = [bool]$RedactOnDisk
        Salt             = ('azscan|' + [string]$TenantId)
        MaxBytes         = [long]$MaxLogMegabytes * 1MB
        BytesWritten     = [long]0
        Truncated        = $false
        MaxSamples       = $MaxSamplesPerError
        ErrorAggregate   = @{}
        ApiAggregate     = @{}
        SlowestCalls     = [System.Collections.Generic.List[object]]::new()
        PseudonymMap     = @{}
        StartedUtc       = [DateTime]::UtcNow
        Counters         = @{ events = 0; suppressed = 0; apiCalls = 0; apiFailures = 0 }
    }
    return $script:Log
}

function Test-ScannerLogReady {
    return ($null -ne $script:Log)
}

function Get-StableHash {
    param([string]$Value, [int]$Length = 8)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $salt = if ($script:Log) { $script:Log.Salt } else { 'azscan' }
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($salt + '|' + [string]$Value)
        $hash = $sha.ComputeHash($bytes)
        return (-join ($hash | Select-Object -First 8 | ForEach-Object { $_.ToString('x2') })).Substring(0, $Length)
    }
    finally { $sha.Dispose() }
}

function Add-PseudonymMapping {
    param([string]$Original, [string]$Pseudonym)
    if (-not $script:Log) { return }
    if (-not $script:Log.PseudonymMap.ContainsKey($Original)) {
        $script:Log.PseudonymMap[$Original] = $Pseudonym
    }
}

# Stable pseudonymisation: preserves shape and identity so joins still work in a shared log.
function Protect-ScannerText {
    param([AllowNull()][string]$Text)
    $value = [string]$Text
    if (-not $value) { return '' }

    # Unconditional secret scrubbing, applied regardless of redaction mode.
    $value = [regex]::Replace($value, 'eyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]*', '<redacted-jwt>')
    $value = [regex]::Replace($value, '(?i)(bearer)\s+[A-Za-z0-9._\-]+', '$1 <redacted>')
    $value = [regex]::Replace($value, '(?i)("?(?:access_token|refresh_token|id_token|client_secret|password|assertion)"?\s*[:=]\s*"?)[^",\s}]+', '$1<redacted>')

    if (-not $script:Log -or -not $script:Log.RedactOnDisk) { return $value }
    return (Protect-ScannerIdentifier -Text $value)
}

function Protect-ScannerIdentifier {
    param([AllowNull()][string]$Text)
    $value = [string]$Text
    if (-not $value) { return '' }

    $value = [regex]::Replace($value, '[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}', {
        param($m)
        $p = 'user-' + (Get-StableHash -Value $m.Value.ToLowerInvariant()) + '@redacted'
        Add-PseudonymMapping -Original $m.Value -Pseudonym $p
        $p
    })
    $value = [regex]::Replace($value, '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}', {
        param($m)
        $p = 'id-' + (Get-StableHash -Value $m.Value.ToLowerInvariant())
        Add-PseudonymMapping -Original $m.Value -Pseudonym $p
        $p
    })
    # Named ARM segments leak org structure; keep the shape, hash the name.
    $value = [regex]::Replace($value, '(?i)(/(?:resourceGroups|managementGroups|providers/[^/]+/[^/]+)/)([^/\s"]+)', {
        param($m)
        $p = $m.Groups[1].Value + 'name-' + (Get-StableHash -Value $m.Groups[2].Value.ToLowerInvariant())
        Add-PseudonymMapping -Original $m.Groups[2].Value -Pseudonym $p
        $p
    })
    return $value
}

# Collapse volatile detail so the same failure aggregates to one bucket.
function Get-MessageTemplate {
    param([AllowNull()][string]$Message)
    $value = [string]$Message
    if (-not $value) { return '' }
    $value = [regex]::Replace($value, '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}', '<guid>')
    $value = [regex]::Replace($value, '[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}', '<upn>')
    $value = [regex]::Replace($value, '/subscriptions/\S*', '<scope>')
    $value = [regex]::Replace($value, '\d+', '<n>')
    $value = [regex]::Replace($value, '\s+', ' ')
    return $value.Trim()
}

function Write-ScannerEvent {
    param(
        [ValidateSet('Error', 'Warn', 'Info', 'Debug', 'Trace')][string]$Level = 'Info',
        [string]$Collector = '',
        [Parameter(Mandatory = $true)][string]$EventName,
        [string]$Message = '',
        [string]$Scope = '',
        [string]$Api = '',
        [string]$ErrorCode = '',
        [Nullable[int]]$DurationMs = $null,
        [hashtable]$Data = $null
    )
    if (-not $script:Log) { return }
    if ((Get-LogLevelRank -Level $Level) -gt $script:Log.LevelRank) { return }

    # Redact first, then derive the template from the redacted text - otherwise secrets
    # reach errorSummary.json through the template field.
    $safeMessage = Protect-ScannerText -Text $Message
    $safeScope = Protect-ScannerText -Text $Scope

    $isProblem = ($Level -eq 'Error' -or $Level -eq 'Warn')
    $sampleIndex = 0
    if ($isProblem) {
        $template = Get-MessageTemplate -Message $safeMessage
        $key = ('{0}|{1}|{2}' -f $Collector, $ErrorCode, $template)
        if (-not $script:Log.ErrorAggregate.ContainsKey($key)) {
            $script:Log.ErrorAggregate[$key] = [pscustomobject]@{
                collector = $Collector
                level     = $Level
                errorCode = $ErrorCode
                template  = $template
                count     = 0
                firstUtc  = (Get-Date).ToUniversalTime().ToString('o')
                lastUtc   = ''
                samples   = [System.Collections.Generic.List[object]]::new()
            }
        }
        $agg = $script:Log.ErrorAggregate[$key]
        $agg.count++
        $agg.lastUtc = (Get-Date).ToUniversalTime().ToString('o')
        $sampleIndex = $agg.count
        if ($agg.samples.Count -lt $script:Log.MaxSamples) {
            [void]$agg.samples.Add(@{ scope = $safeScope; message = $safeMessage })
        }
        else {
            # Already have enough examples of this exact failure; count it and move on.
            $script:Log.Counters.suppressed++
            return
        }
    }

    $record = [ordered]@{
        ts        = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
        level     = $Level
        collector = $Collector
        event     = $EventName
    }
    if ($safeMessage) { $record['message'] = $safeMessage }
    if ($safeScope) { $record['scope'] = $safeScope }
    if ($Api) { $record['api'] = $Api }
    if ($ErrorCode) { $record['errorCode'] = $ErrorCode }
    if ($null -ne $DurationMs) { $record['durationMs'] = $DurationMs }
    if ($isProblem -and $sampleIndex -gt 0) { $record['occurrence'] = $sampleIndex }
    if ($Data) {
        foreach ($k in $Data.Keys) {
            $v = $Data[$k]
            if ($v -is [string]) { $v = Protect-ScannerText -Text $v }
            $record[[string]$k] = $v
        }
    }
    Write-RawLogLine -Record $record
}

function Write-RawLogLine {
    param([Parameter(Mandatory = $true)]$Record)
    if (-not $script:Log) { return }
    if ($script:Log.Truncated) { return }
    $line = ($Record | ConvertTo-Json -Depth 6 -Compress)
    $script:Log.BytesWritten += $line.Length + 2
    if ($script:Log.BytesWritten -gt $script:Log.MaxBytes) {
        $script:Log.Truncated = $true
        $notice = ([ordered]@{
            ts    = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
            level = 'Warn'
            event = 'log-truncated'
            message = ("Event log exceeded {0} bytes; further per-event records are suppressed. Rollups are still written at run end." -f $script:Log.MaxBytes)
        } | ConvertTo-Json -Depth 4 -Compress)
        $script:Log.EventWriter.WriteLine($notice)
        return
    }
    $script:Log.EventWriter.WriteLine($line)
    $script:Log.Counters.events++
}

function Write-ScannerApiCall {
    param(
        [string]$Collector = '',
        [string]$Api = '',
        [string]$Scope = '',
        [int]$DurationMs = 0,
        [int]$ExitCode = 0,
        [int]$Bytes = 0,
        [int]$Attempt = 1,
        [string]$Outcome = 'Succeeded'
    )
    if (-not $script:Log) { return }
    $script:Log.Counters.apiCalls++
    if ($Outcome -ne 'Succeeded') { $script:Log.Counters.apiFailures++ }

    $key = ('{0}|{1}' -f $Collector, $Api)
    if (-not $script:Log.ApiAggregate.ContainsKey($key)) {
        $script:Log.ApiAggregate[$key] = [pscustomobject]@{
            collector = $Collector; api = $Api; calls = 0; failures = 0; totalMs = [long]0; maxMs = 0
        }
    }
    $agg = $script:Log.ApiAggregate[$key]
    $agg.calls++
    if ($Outcome -ne 'Succeeded') { $agg.failures++ }
    $agg.totalMs += $DurationMs
    if ($DurationMs -gt $agg.maxMs) { $agg.maxMs = $DurationMs }

    [void]$script:Log.SlowestCalls.Add([pscustomobject]@{
        collector = $Collector; api = $Api; scope = (Protect-ScannerText -Text $Scope); durationMs = $DurationMs; outcome = $Outcome
    })
    if ($script:Log.SlowestCalls.Count -gt 2000) {
        $trimmed = @($script:Log.SlowestCalls | Sort-Object durationMs -Descending | Select-Object -First 200)
        $script:Log.SlowestCalls.Clear()
        foreach ($item in $trimmed) { [void]$script:Log.SlowestCalls.Add($item) }
    }

    $safeScope = (Protect-ScannerText -Text $Scope) -replace '"', "'"
    $safeApi = ([string]$Api) -replace '"', "'"
    $script:Log.ApiWriter.WriteLine(('{0},"{1}","{2}","{3}",{4},{5},{6},{7},{8}' -f `
        (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ'), $Collector, $safeApi, $safeScope, $DurationMs, $ExitCode, $Bytes, $Attempt, $Outcome))
}

function Get-ScannerErrorSummary {
    if (-not $script:Log) { return @() }
    return @($script:Log.ErrorAggregate.Values | Sort-Object count -Descending | ForEach-Object {
        [ordered]@{
            collector = $_.collector
            level     = $_.level
            errorCode = $_.errorCode
            template  = $_.template
            count     = $_.count
            firstUtc  = $_.firstUtc
            lastUtc   = $_.lastUtc
            samples   = @($_.samples)
        }
    })
}

function Get-ScannerApiSummary {
    if (-not $script:Log) { return [ordered]@{} }
    $byApi = @($script:Log.ApiAggregate.Values | Sort-Object totalMs -Descending | ForEach-Object {
        [ordered]@{
            collector = $_.collector
            api       = $_.api
            calls     = $_.calls
            failures  = $_.failures
            totalMs   = $_.totalMs
            avgMs     = if ($_.calls -gt 0) { [math]::Round($_.totalMs / $_.calls) } else { 0 }
            maxMs     = $_.maxMs
        }
    })
    return [ordered]@{
        totalCalls   = $script:Log.Counters.apiCalls
        failedCalls  = $script:Log.Counters.apiFailures
        byApi        = $byApi
        slowestCalls = @($script:Log.SlowestCalls | Sort-Object durationMs -Descending | Select-Object -First 50)
    }
}

function Get-ScannerEnvironment {
    param([hashtable]$Extra = @{})
    $azVersion = ''
    $azExtensions = @()
    try {
        $raw = (& az version -o json 2>$null | Out-String)
        if ($raw) {
            $parsed = $raw | ConvertFrom-Json
            $azVersion = [string]$parsed.'azure-cli'
            $extProp = $parsed.PSObject.Properties['extensions']
            if ($extProp -and $extProp.Value) {
                $azExtensions = @($extProp.Value.PSObject.Properties | ForEach-Object { ('{0}={1}' -f $_.Name, $_.Value) })
            }
        }
    }
    catch { $azVersion = 'unavailable' }

    $nodeVersion = ''
    try { $nodeVersion = ((& node --version 2>$null | Out-String)).Trim() } catch { $nodeVersion = 'unavailable' }

    $elevated = $false
    try {
        $elevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    catch { $elevated = $false }

    $edition = 'Desktop'
    if ($PSVersionTable.PSObject.Properties['PSEdition']) { $edition = [string]$PSVersionTable.PSEdition }

    $env = [ordered]@{
        generatedUtc      = (Get-Date).ToUniversalTime().ToString('o')
        psVersion         = [string]$PSVersionTable.PSVersion
        psEdition         = $edition
        os                = [string][System.Environment]::OSVersion.VersionString
        os64Bit           = [System.Environment]::Is64BitOperatingSystem
        processorCount    = [System.Environment]::ProcessorCount
        culture           = (Get-Culture).Name
        elevated          = $elevated
        azVersion         = $azVersion
        azExtensions      = $azExtensions
        nodeVersion       = $nodeVersion
        consoleEncoding   = [string]([Console]::OutputEncoding.WebName)
        proxyConfigured   = [bool]($env:HTTPS_PROXY -or $env:HTTP_PROXY -or $env:ALL_PROXY)
    }
    foreach ($k in $Extra.Keys) { $env[[string]$k] = $Extra[$k] }
    return $env
}

function Close-ScannerLog {
    param([hashtable]$Summary = @{})
    if (-not $script:Log) { return $null }

    $errorSummary = Get-ScannerErrorSummary
    $apiSummary = Get-ScannerApiSummary
    $utf8 = [System.Text.UTF8Encoding]::new($false)

    $rollup = [ordered]@{
        ts             = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
        level          = 'Info'
        event          = 'run-summary'
        elapsedSeconds = [math]::Round(([DateTime]::UtcNow - $script:Log.StartedUtc).TotalSeconds, 2)
        events         = $script:Log.Counters.events
        suppressed     = $script:Log.Counters.suppressed
        apiCalls       = $script:Log.Counters.apiCalls
        apiFailures    = $script:Log.Counters.apiFailures
        errorClasses   = @($errorSummary).Count
    }
    foreach ($k in $Summary.Keys) { $rollup[[string]$k] = $Summary[$k] }
    $script:Log.Truncated = $false
    Write-RawLogLine -Record $rollup

    [System.IO.File]::WriteAllText(
        (Join-Path $script:Log.Directory 'errorSummary.json'),
        (@{ generatedUtc = (Get-Date).ToUniversalTime().ToString('o'); errorClasses = @($errorSummary) } | ConvertTo-Json -Depth 8),
        $utf8)
    [System.IO.File]::WriteAllText(
        (Join-Path $script:Log.Directory 'apiSummary.json'),
        ($apiSummary | ConvertTo-Json -Depth 8),
        $utf8)

    if ($script:Log.PseudonymMap.Count -gt 0) {
        [System.IO.File]::WriteAllText(
            (Join-Path $script:Log.Directory 'redaction-map.LOCAL-ONLY.json'),
            (@{
                warning = 'Local use only. This file reverses the redaction in events.jsonl. Do NOT include it in a support bundle.'
                mappings = $script:Log.PseudonymMap
            } | ConvertTo-Json -Depth 4),
            $utf8)
    }

    try { $script:Log.EventWriter.Flush(); $script:Log.EventWriter.Dispose() } catch { }
    try { $script:Log.ApiWriter.Flush(); $script:Log.ApiWriter.Dispose() } catch { }

    $result = [pscustomobject]@{
        EventPath    = $script:Log.EventPath
        ApiPath      = $script:Log.ApiPath
        Directory    = $script:Log.Directory
        ErrorClasses = @($errorSummary).Count
        ApiCalls     = $script:Log.Counters.apiCalls
    }
    $script:Log = $null
    return $result
}

function New-ScannerSupportBundle {
    param(
        [Parameter(Mandatory = $true)][string]$RunDirectory,
        [Parameter(Mandatory = $true)][string]$DestinationPath,
        [switch]$IncludeData
    )
    $staging = Join-Path ([System.IO.Path]::GetTempPath()) ('azscan-bundle-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $staging -Force | Out-Null
    try {
        $always = @(
            'manifest.json',
            'logs\events.jsonl',
            'logs\errorSummary.json',
            'logs\apiSummary.json',
            'logs\apiTiming.csv',
            'logs\environment.json',
            'logs\parameters.json',
            'output\collectorStatus.csv',
            'output\errorsWarnings.csv',
            'output\coverageSummary.json',
            'output\counts.json'
        )
        foreach ($relative in $always) {
            $source = Join-Path $RunDirectory $relative
            if (-not (Test-Path -LiteralPath $source)) { continue }
            $target = Join-Path $staging ($relative -replace '\\', '_')
            Copy-Item -LiteralPath $source -Destination $target -Force
        }

        $errorsDir = Join-Path $RunDirectory 'errors'
        if (Test-Path -LiteralPath $errorsDir) {
            foreach ($file in @(Get-ChildItem -LiteralPath $errorsDir -Filter '*.json' -File)) {
                Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $staging ('errors_' + $file.Name)) -Force
            }
        }

        if ($IncludeData) {
            $outDir = Join-Path $RunDirectory 'output'
            foreach ($name in @('allAzureAccess.csv', 'effectiveAccess.csv', 'directAssignments.csv', 'scopeInventory.csv', 'roleDefinitions.csv')) {
                $source = Join-Path $outDir $name
                if (Test-Path -LiteralPath $source) { Copy-Item -LiteralPath $source -Destination (Join-Path $staging ('data_' + $name)) -Force }
            }
        }

        $readme = @(
            'Azure Entra ID / IAM Scanner - support bundle',
            '',
            ('Generated (UTC): {0}' -f (Get-Date).ToUniversalTime().ToString('o')),
            ('Source run directory: {0}' -f $RunDirectory),
            ('Access data included: {0}' -f $(if ($IncludeData) { 'YES (-IncludeData was specified)' } else { 'no' })),
            '',
            'Contents',
            '  logs_events.jsonl        Structured run events, one JSON object per line.',
            '  logs_errorSummary.json   Every distinct failure class with counts and up to 5 examples.',
            '  logs_apiSummary.json     Per-API call counts and durations, plus the 50 slowest calls.',
            '  logs_apiTiming.csv       Raw per-call timing.',
            '  logs_environment.json    OS, PowerShell, Azure CLI, Node versions.',
            '  logs_parameters.json     The exact parameters this run was started with.',
            '  output_collectorStatus.csv / output_errorsWarnings.csv / output_coverageSummary.json',
            '  output_counts.json       Row counts only - no access data.',
            '',
            'Redaction',
            '  Bearer tokens, JWTs, and secret-shaped values are always removed.',
            '  If the run used -RedactLogs, user principal names, GUIDs and resource names are',
            '  replaced with stable pseudonyms (user-xxxxxxxx@redacted, id-xxxxxxxx, name-xxxxxxxx).',
            '  Identical values map to identical pseudonyms so the data can still be correlated.',
            '  The reversal map is written to logs\redaction-map.LOCAL-ONLY.json in the run',
            '  directory and is deliberately NOT included in this bundle.',
            '',
            'This bundle contains no access/role-assignment rows unless -IncludeData was used.'
        ) -join [Environment]::NewLine
        [System.IO.File]::WriteAllText((Join-Path $staging 'README-support.txt'), $readme, [System.Text.UTF8Encoding]::new($false))

        $files = @(Get-ChildItem -LiteralPath $staging -File)
        if ($files.Count -eq 0) { return '' }
        Remove-Item -LiteralPath $DestinationPath -Force -ErrorAction SilentlyContinue
        Compress-Archive -LiteralPath @($files | ForEach-Object { $_.FullName }) -DestinationPath $DestinationPath -Force
        return $DestinationPath
    }
    finally {
        Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Export-ModuleMember -Function *-*
