Set-StrictMode -Version Latest
$script:AzCommand = $null
$script:AzCommandArguments = @()
$script:ApiLogger = $null
$script:HttpClient = $null
$script:TokenCache = @{}
$script:HttpDisabled = $false
$script:AzureScannerOutputRoot = $(if ($env:AZURE_IAM_SCANNER_OUTPUT_ROOT) { $env:AZURE_IAM_SCANNER_OUTPUT_ROOT } else { Join-Path ([System.IO.Path]::GetTempPath()) 'azure-scanners' })

function Get-UtcTimestamp {
    param([switch]$Compact)
    if ($Compact) { return [DateTime]::UtcNow.ToString('yyyyMMdd_HHmmss') }
    return [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
}

function Ensure-Directory {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
    return (Resolve-Path -LiteralPath $Path).Path
}

function New-ScanContext {
    param(
        [Parameter(Mandatory = $true)][string]$JobType,
        [string]$OutputRoot = '',
        [string]$JobId = ([guid]::NewGuid().Guid),
        [switch]$DryRun
    )

    $root = Ensure-Directory -Path $(if ($OutputRoot) { $OutputRoot } else { $script:AzureScannerOutputRoot })
    $jobRoot = Ensure-Directory -Path (Join-Path $root $JobType)
    $runId = Get-UtcTimestamp -Compact
    $runDir = Ensure-Directory -Path (Join-Path $jobRoot $runId)
    $outDir = Ensure-Directory -Path (Join-Path $runDir 'output')
    $logDir = Ensure-Directory -Path (Join-Path $runDir 'logs')
    $taskDir = Ensure-Directory -Path (Join-Path $runDir 'tasks')

    [pscustomobject]@{
        JobId        = $JobId
        JobType      = $JobType
        DryRun       = [bool]$DryRun
        RunId        = $runId
        RunDir       = $runDir
        OutDir       = $outDir
        LogDir       = $logDir
        TaskDir      = $taskDir
        ResultsJson  = Join-Path $outDir 'results.json'
        ManifestJson = Join-Path $runDir 'manifest.json'
        LogFile      = Join-Path $logDir 'run.log'
    }
}

function Write-JsonFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Data,
        [int]$Depth = 25
    )
    $parent = Split-Path -Parent $Path
    if ($parent) { Ensure-Directory -Path $parent | Out-Null }
    [System.IO.File]::WriteAllText($Path, ($Data | ConvertTo-Json -Depth $Depth), [System.Text.UTF8Encoding]::new($false))
}

function Write-RunManifest {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][int]$ExitCode,
        [hashtable]$Extra = @{}
    )
    $payload = @{
        jobId        = $Context.JobId
        jobType      = $Context.JobType
        dryRun       = $Context.DryRun
        runId        = $Context.RunId
        runDir       = $Context.RunDir
        outDir       = $Context.OutDir
        logDir       = $Context.LogDir
        exitCode     = $ExitCode
        generatedUtc = Get-UtcTimestamp
    }
    foreach ($key in $Extra.Keys) { $payload[$key] = $Extra[$key] }
    Write-JsonFile -Path $Context.ManifestJson -Data $payload
}

function Resolve-AzCommand {
    if ($script:AzCommand) { return $script:AzCommand }
    foreach ($candidate in @('az', 'az.cmd', 'az.ps1')) {
        $command = Get-Command $candidate -ErrorAction SilentlyContinue
        if ($command) {
            $resolved = $command.Source
            if ($resolved -like '*.cmd') {
                $pythonPath = Join-Path (Split-Path -Parent $resolved) '..\python.exe'
                if (Test-Path -LiteralPath $pythonPath) {
                    $script:AzCommand = (Resolve-Path -LiteralPath $pythonPath).Path
                    $script:AzCommandArguments = @('-IBm', 'azure.cli')
                    return $script:AzCommand
                }
            }
            $script:AzCommand = $resolved
            $script:AzCommandArguments = @()
            return $script:AzCommand
        }
    }
    foreach ($path in @(
        'C:\Program Files\Microsoft SDKs\Azure\CLI2\wbin\az.cmd',
        'C:\Program Files (x86)\Microsoft SDKs\Azure\CLI2\wbin\az.cmd'
    )) {
        if (Test-Path -LiteralPath $path) {
            $pythonPath = Join-Path (Split-Path -Parent $path) '..\python.exe'
            if (Test-Path -LiteralPath $pythonPath) {
                $script:AzCommand = (Resolve-Path -LiteralPath $pythonPath).Path
                $script:AzCommandArguments = @('-IBm', 'azure.cli')
            }
            else {
                $script:AzCommand = $path
                $script:AzCommandArguments = @()
            }
            return $script:AzCommand
        }
    }
    throw 'Unable to locate az in PATH.'
}

function Invoke-AzText {
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [switch]$AllowError,
        [string]$Collector = '',
        [string]$Scope = ''
    )
    $command = Resolve-AzCommand
    $effectiveArgs = @($Arguments)
    if (-not ($effectiveArgs -contains '--only-show-errors')) {
        $effectiveArgs += '--only-show-errors'
    }

    $commandPath = [string]$command
    if ($command -is [System.Management.Automation.CommandInfo]) {
        $commandPath = [string]$command.Path
    }

    $allArgs = @($script:AzCommandArguments + $effectiveArgs)
    $quotedArgs = foreach ($arg in $allArgs) {
        $text = [string]$arg
        if ($text -match '[\s"]') {
            '"' + ($text -replace '"', '\"') + '"'
        }
        else {
            $text
        }
    }

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $commandPath
    $startInfo.Arguments = ($quotedArgs -join ' ')
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        Write-Verbose ("Invoke-AzText starting: {0} {1}" -f $startInfo.FileName, $startInfo.Arguments)
        [void]$process.Start()
        $stdout = $process.StandardOutput.ReadToEnd()
        $stderr = $process.StandardError.ReadToEnd()
        $process.WaitForExit()
        $exitCode = $process.ExitCode
        $sw.Stop()
        Write-Verbose ("Invoke-AzText completed: exitCode={0} stdoutLength={1} stderrLength={2}" -f $exitCode, ([string]$stdout).Length, ([string]$stderr).Length)
        Write-AzApiTelemetry -Arguments $effectiveArgs -Collector $Collector -Scope $Scope -DurationMs $sw.ElapsedMilliseconds -ExitCode $exitCode -Bytes ([string]$stdout).Length
        if ($exitCode -ne 0 -and -not $AllowError) {
            throw "az failed ($exitCode): $($effectiveArgs -join ' ')`n$stderr"
        }
        [pscustomobject]@{
            ExitCode = $exitCode
            StdOut   = ([string]$stdout).Trim()
            StdErr   = ([string]$stderr).Trim()
        }
    }
    finally {
        if ($process) {
            $process.Dispose()
        }
    }
}

function Get-AzApiName {
    param([string[]]$Arguments)
    $parts = @()
    foreach ($arg in @($Arguments)) {
        $text = [string]$arg
        if ($text.StartsWith('-')) { break }
        $parts += $text
        if ($parts.Count -ge 3) { break }
    }
    if ($parts.Count -eq 0) { return 'az' }
    return ('az ' + ($parts -join ' '))
}

function Write-AzApiTelemetry {
    param([string[]]$Arguments, [string]$Collector, [string]$Scope, [long]$DurationMs, [int]$ExitCode, [int]$Bytes)
    if ($null -eq $script:ApiLogger) {
        $script:ApiLogger = Get-Command -Name 'Write-ScannerApiCall' -ErrorAction SilentlyContinue
        if (-not $script:ApiLogger) { $script:ApiLogger = 'none' }
    }
    if ($script:ApiLogger -eq 'none') { return }
    $scopeText = $Scope
    if (-not $scopeText) {
        for ($i = 0; $i -lt $Arguments.Count - 1; $i++) {
            if ($Arguments[$i] -eq '--scope' -or $Arguments[$i] -eq '--subscription' -or $Arguments[$i] -eq '--url') { $scopeText = [string]$Arguments[$i + 1]; break }
        }
    }
    & $script:ApiLogger -Collector $Collector -Api (Get-AzApiName -Arguments $Arguments) -Scope $scopeText `
        -DurationMs ([int][math]::Min($DurationMs, [int]::MaxValue)) -ExitCode $ExitCode -Bytes $Bytes `
        -Outcome $(if ($ExitCode -eq 0) { 'Succeeded' } else { 'Failed' })
}


# ConvertFrom-Json compares object keys case-insensitively and hard-fails on payloads that
# legitimately contain e.g. both 'ClientId' and 'clientId'. Rewrite the later collisions so the
# document still parses instead of losing the whole response.
function Repair-DuplicateJsonKey {
    param([Parameter(Mandatory = $true)][string]$Json)
    $sb = [System.Text.StringBuilder]::new($Json.Length + 64)
    $stack = [System.Collections.Generic.Stack[object]]::new()
    $expectKey = $false
    $i = 0
    while ($i -lt $Json.Length) {
        $ch = $Json[$i]
        if ($ch -eq '"') {
            $start = $i
            $i++
            while ($i -lt $Json.Length -and $Json[$i] -ne '"') {
                if ($Json[$i] -eq '\') { $i++ }
                $i++
            }
            $i++
            $token = $Json.Substring($start, [Math]::Min($i, $Json.Length) - $start)
            if ($expectKey -and $stack.Count -gt 0 -and $null -ne $stack.Peek() -and $token.Length -ge 2 -and $token.EndsWith('"')) {
                $seen = $stack.Peek()
                $name = $token.Substring(1, $token.Length - 2)
                if (-not $seen.Add($name)) {
                    $suffix = 2
                    while (-not $seen.Add(('{0}~{1}' -f $name, $suffix))) { $suffix++ }
                    $token = '"{0}~{1}"' -f $name, $suffix
                }
            }
            $expectKey = $false
            [void]$sb.Append($token)
            continue
        }
        switch ($ch) {
            '{' { $stack.Push([System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)); $expectKey = $true }
            '[' { $stack.Push($null); $expectKey = $false }
            '}' { if ($stack.Count -gt 0) { [void]$stack.Pop() }; $expectKey = $false }
            ']' { if ($stack.Count -gt 0) { [void]$stack.Pop() }; $expectKey = $false }
            ',' { $expectKey = ($stack.Count -gt 0 -and $null -ne $stack.Peek()) }
            ':' { $expectKey = $false }
        }
        [void]$sb.Append($ch)
        $i++
    }
    return $sb.ToString()
}

function ConvertFrom-JsonSafe {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][AllowNull()][string]$Json)
    if ([string]::IsNullOrWhiteSpace($Json)) { return $null }
    try { return ($Json | ConvertFrom-Json) }
    catch {
        # Windows PowerShell says 'duplicated keys'; PowerShell 7 says 'keys with different casing'.
        if ($_.Exception.Message -notmatch '(?i)duplicated keys|different casing') { throw }
        return ((Repair-DuplicateJsonKey -Json $Json) | ConvertFrom-Json)
    }
}

function Invoke-AzJson {
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [switch]$AllowError,
        [string]$Collector = '',
        [string]$Scope = ''
    )
    $hasOutput = $false
    foreach ($arg in $Arguments) {
        if ($arg -like '-o=*' -or $arg -eq '-o' -or $arg -like '--output=*' -or $arg -eq '--output') { $hasOutput = $true; break }
    }
    $effectiveArgs = @($Arguments)
    if (-not $hasOutput) { $effectiveArgs += @('-o', 'json') }
    $result = Invoke-AzText -Arguments $effectiveArgs -AllowError:$AllowError -Collector $Collector -Scope $Scope
    if ([string]::IsNullOrWhiteSpace($result.StdOut)) { return $null }
    try { return ConvertFrom-JsonSafe -Json $result.StdOut }
    catch {
        if ($AllowError) { return $null }
        throw "Failed to parse az JSON for '$($effectiveArgs -join ' ')': $($_.Exception.Message)"
    }
}

function ConvertTo-ObjectArray {
    param([AllowNull()]$InputObject)

    if ($null -eq $InputObject) {
        return ,@()
    }

    if ($InputObject -is [System.Array]) {
        return ,@($InputObject)
    }

    if ($InputObject -is [System.Collections.IEnumerable] -and -not ($InputObject -is [string]) -and -not ($InputObject -is [pscustomobject])) {
        return ,@($InputObject)
    }

    return ,@($InputObject)
}

function Get-AzSubscriptions {
    param([string[]]$SubscriptionIds, [int]$Limit = 0, [switch]$IncludeAllStates)
    if ($SubscriptionIds -and $SubscriptionIds.Count -gt 0) {
        $items = foreach ($id in $SubscriptionIds) {
            $clean = ([string]$id).Trim()
            if (-not $clean) { continue }
            $sub = Invoke-AzJson -Arguments @('account', 'show', '--subscription', $clean) -AllowError
            if ($sub) {
                [pscustomobject]@{
                    id            = $sub.id
                    name          = if ($sub.name) { $sub.name } else { $sub.id }
                    tenantId      = $sub.tenantId
                    homeTenantId  = $sub.homeTenantId
                    state         = $sub.state
                    isDefault     = $sub.isDefault
                }
            }
        }
    }
    else {
        $subs = ConvertTo-ObjectArray -InputObject (Invoke-AzJson -Arguments @('account', 'list', '--all') -AllowError)
        if (-not $IncludeAllStates) {
            $subs = @($subs | Where-Object { [string]$_.state -eq 'Enabled' })
        }
        $items = @($subs | Sort-Object name, id | ForEach-Object {
            [pscustomobject]@{
                id            = $_.id
                name          = if ($_.name) { $_.name } else { $_.id }
                tenantId      = $_.tenantId
                homeTenantId  = $_.homeTenantId
                state         = $_.state
                isDefault     = $_.isDefault
            }
        })
    }
    if ($Limit -gt 0) { return @($items | Select-Object -First $Limit) }
    return @($items)
}

function Export-ObjectList {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string[]]$Columns,
        [AllowNull()][array]$Rows = @(),
        [string]$Delimiter = ','
    )
    $parent = Split-Path -Parent $Path
    if ($parent) { Ensure-Directory -Path $parent | Out-Null }
    if (-not $Rows -or $Rows.Count -eq 0) {
        [System.IO.File]::WriteAllText($Path, (($Columns -join $Delimiter) + [Environment]::NewLine), [System.Text.UTF8Encoding]::new($false))
        return
    }
    $selected = foreach ($row in $Rows) {
        $ordered = [ordered]@{}
        foreach ($column in $Columns) {
            if ($row -is [hashtable] -or $row -is [System.Collections.IDictionary]) { $ordered[$column] = $row[$column] }
            else { $ordered[$column] = $row.$column }
        }
        [pscustomobject]$ordered
    }
    [System.IO.File]::WriteAllLines($Path, ($selected | ConvertTo-Csv -NoTypeInformation -Delimiter $Delimiter), [System.Text.UTF8Encoding]::new($false))
}

function Write-StandardFindingOutputs {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [AllowNull()][array]$Rows = @(),
        [string]$OpenStatus = 'OPEN'
    )
    $columns = @('check_id', 'resource_id', 'resource_name', 'region', 'owner_email', 'status', 'severity', 'title', 'details')
    $rawPath = Join-Path $Context.OutDir 'raw_results.csv'
    $openPath = Join-Path $Context.OutDir 'open_findings.csv'
    $rows = @($Rows)
    $openRows = @($rows | Where-Object { $_.status -eq $OpenStatus })
    Export-ObjectList -Path $rawPath -Columns $columns -Rows $rows
    Export-ObjectList -Path $openPath -Columns $columns -Rows $openRows
    Write-JsonFile -Path $Context.ResultsJson -Data @{
        jobId         = $Context.JobId
        cloud         = 'azure'
        jobType       = $Context.JobType
        dryRun        = $Context.DryRun
        generatedUtc  = Get-UtcTimestamp
        totalFindings = $rows.Count
        openFindings  = $openRows.Count
        outputs       = @{ rawResultsCsv = $rawPath; openFindingsCsv = $openPath }
    }
    Compress-ResultFiles -DestinationPath (Join-Path $Context.OutDir 'results.zip') -LiteralPaths @($rawPath, $openPath, $Context.ResultsJson)
}

function Compress-ResultFiles {
    param([Parameter(Mandatory = $true)][string]$DestinationPath, [Parameter(Mandatory = $true)][string[]]$LiteralPaths)
    $existing = @($LiteralPaths | Where-Object { $_ -and (Test-Path -LiteralPath $_) })
    if ($existing.Count -eq 0) { return }
    Remove-Item -LiteralPath $DestinationPath -Force -ErrorAction SilentlyContinue
    Compress-Archive -LiteralPath $existing -DestinationPath $DestinationPath -Force
}

function Test-TcpPort {
    param([Parameter(Mandatory = $true)][string]$Host, [Parameter(Mandatory = $true)][int]$Port, [int]$TimeoutMs = 2000)
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $async = $client.BeginConnect($Host, $Port, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne($TimeoutMs)) { $client.Close(); return 'TIMEOUT' }
        $client.EndConnect($async)
        return 'OPEN'
    } catch { return 'CLOSED' } finally { $client.Dispose() }
}

function Invoke-WorkerTasks {
    param(
        [array]$Tasks,
        [Parameter(Mandatory = $true)][string]$ScriptPath,
        [Parameter(Mandatory = $true)][string]$TaskDirectory,
        [int]$Throttle = 5,
        [int]$GlobalTimeoutSeconds = 1800
    )
    $Tasks = @($Tasks)
    if ($Tasks.Count -eq 0) { return [pscustomobject]@{ WorkerCount = 0; Failures = @() } }
    Ensure-Directory -Path $TaskDirectory | Out-Null
    $workers = @()
    $deadline = [DateTime]::UtcNow.AddSeconds($GlobalTimeoutSeconds)
    $index = 0
    function Start-OneWorker {
        param([object]$Task,[int]$TaskIndex)
        $taskPath = Join-Path $TaskDirectory ("task_{0:d5}.json" -f $TaskIndex)
        Write-JsonFile -Path $taskPath -Data $Task
        $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$ScriptPath,'-WorkerTaskPath',$taskPath) -PassThru -WindowStyle Hidden
        [pscustomobject]@{ Process=$proc; TaskPath=$taskPath; Index=$TaskIndex }
    }
    foreach ($task in $Tasks) {
        while (@($workers | Where-Object { -not $_.Process.HasExited }).Count -ge $Throttle) {
            if ([DateTime]::UtcNow -gt $deadline) {
                foreach ($worker in $workers | Where-Object { -not $_.Process.HasExited }) { Stop-Process -Id $worker.Process.Id -Force -ErrorAction SilentlyContinue }
                throw "Worker pool exceeded timeout of $GlobalTimeoutSeconds seconds."
            }
            Start-Sleep -Milliseconds 500
        }
        $index += 1
        $workers += Start-OneWorker -Task $task -TaskIndex $index
    }
    while (@($workers | Where-Object { -not $_.Process.HasExited }).Count -gt 0) {
        if ([DateTime]::UtcNow -gt $deadline) {
            foreach ($worker in $workers | Where-Object { -not $_.Process.HasExited }) { Stop-Process -Id $worker.Process.Id -Force -ErrorAction SilentlyContinue }
            throw "Worker pool exceeded timeout of $GlobalTimeoutSeconds seconds."
        }
        Start-Sleep -Milliseconds 500
    }
    $failures = @($workers | Where-Object { $_.Process.ExitCode -ne 0 })
    [pscustomobject]@{ WorkerCount = $workers.Count; Failures = $failures }
}

# ---------------------------------------------------------------------------
# In-process HTTP core.
# Each `az` invocation costs a whole OS process; reusing a cached token with
# HttpClient turns a ~1-3s call into ~50-150ms and exposes Retry-After/request ids.
# ---------------------------------------------------------------------------

function Get-ScannerHttpClient {
    if ($script:HttpClient) { return $script:HttpClient }
    try { Add-Type -AssemblyName System.Net.Http -ErrorAction SilentlyContinue } catch { }
    try { [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12 } catch { }
    $client = [System.Net.Http.HttpClient]::new()
    $client.Timeout = [TimeSpan]::FromSeconds(180)
    $script:HttpClient = $client
    return $script:HttpClient
}

function Get-AzResourceToken {
    param([Parameter(Mandatory = $true)][string]$Resource)
    if ($script:HttpDisabled) { return $null }
    $now = [DateTime]::UtcNow
    if ($script:TokenCache.ContainsKey($Resource)) {
        $entry = $script:TokenCache[$Resource]
        if ($entry.ExpiresUtc -gt $now.AddMinutes(5)) { return $entry.Token }
    }
    $result = Invoke-AzText -Arguments @('account', 'get-access-token', '--resource', $Resource, '-o', 'json') -AllowError
    if ($result.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($result.StdOut)) { return $null }
    $parsed = $null
    try { $parsed = ConvertFrom-JsonSafe -Json $result.StdOut } catch { return $null }
    if (-not $parsed) { return $null }
    $tokenProp = $parsed.PSObject.Properties['accessToken']
    if (-not $tokenProp -or -not $tokenProp.Value) { return $null }

    $expires = $now.AddMinutes(50)
    $epochProp = $parsed.PSObject.Properties['expires_on']
    if ($epochProp -and $epochProp.Value) {
        try { $expires = [DateTimeOffset]::FromUnixTimeSeconds([long]$epochProp.Value).UtcDateTime } catch { }
    }
    else {
        $onProp = $parsed.PSObject.Properties['expiresOn']
        if ($onProp -and $onProp.Value) {
            try { $expires = ([datetime]::Parse([string]$onProp.Value)).ToUniversalTime() } catch { }
        }
    }
    $script:TokenCache[$Resource] = [pscustomobject]@{ Token = [string]$tokenProp.Value; ExpiresUtc = $expires }
    return [string]$tokenProp.Value
}

function Invoke-ScannerHttp {
    param(
        [string]$Method = 'GET',
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$Resource,
        [string]$Body = '',
        [int]$MaxAttempts = 5,
        [string]$Collector = ''
    )
    $token = Get-AzResourceToken -Resource $Resource
    if (-not $token) { return $null }
    $client = Get-ScannerHttpClient

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $request = $null
        $response = $null
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::new($Method), $Url)
            [void]$request.Headers.TryAddWithoutValidation('Authorization', ('Bearer ' + $token))
            [void]$request.Headers.TryAddWithoutValidation('Accept', 'application/json')
            if ($Body) {
                $request.Content = [System.Net.Http.StringContent]::new($Body, [System.Text.Encoding]::UTF8, 'application/json')
            }
            $response = $client.SendAsync($request).GetAwaiter().GetResult()
            $status = [int]$response.StatusCode
            $text = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            $sw.Stop()

            $requestId = ''
            $idValues = $null
            if ($response.Headers.TryGetValues('x-ms-request-id', [ref]$idValues)) { $requestId = @($idValues)[0] }

            $outcome = if ($status -ge 200 -and $status -lt 300) { 'Succeeded' } else { ('Http' + $status) }
            Write-HttpTelemetry -Collector $Collector -Url $Url -Method $Method -DurationMs $sw.ElapsedMilliseconds -Status $status -Bytes ([string]$text).Length -Attempt $attempt -Outcome $outcome

            if ($status -eq 429 -or $status -eq 503 -or $status -eq 504) {
                if ($attempt -ge $MaxAttempts) {
                    return [pscustomobject]@{ Status = $status; Body = $text; RequestId = $requestId; Throttled = $true }
                }
                $delay = [math]::Min(60, [math]::Pow(2, $attempt))
                $retryValues = $null
                if ($response.Headers.TryGetValues('Retry-After', [ref]$retryValues)) {
                    $parsedDelay = 0
                    if ([int]::TryParse(@($retryValues)[0], [ref]$parsedDelay) -and $parsedDelay -gt 0) { $delay = [math]::Min(120, $parsedDelay) }
                }
                Start-Sleep -Seconds $delay
                continue
            }
            return [pscustomobject]@{ Status = $status; Body = $text; RequestId = $requestId; Throttled = $false }
        }
        catch {
            $sw.Stop()
            Write-HttpTelemetry -Collector $Collector -Url $Url -Method $Method -DurationMs $sw.ElapsedMilliseconds -Status 0 -Bytes 0 -Attempt $attempt -Outcome 'Exception'
            if ($attempt -ge $MaxAttempts) { throw }
            Start-Sleep -Seconds ([math]::Min(30, [math]::Pow(2, $attempt)))
        }
        finally {
            if ($response) { $response.Dispose() }
            if ($request) { $request.Dispose() }
        }
    }
    return $null
}

function Write-HttpTelemetry {
    param([string]$Collector, [string]$Url, [string]$Method, [long]$DurationMs, [int]$Status, [int]$Bytes, [int]$Attempt, [string]$Outcome)
    if ($null -eq $script:ApiLogger) {
        $script:ApiLogger = Get-Command -Name 'Write-ScannerApiCall' -ErrorAction SilentlyContinue
        if (-not $script:ApiLogger) { $script:ApiLogger = 'none' }
    }
    if ($script:ApiLogger -eq 'none') { return }
    $api = 'http ' + $Method
    if ($Url -match 'graph\.microsoft\.com/[^/]+/([^/?]+)') { $api = 'graph ' + $Matches[1] }
    elseif ($Url -match 'management\.azure\.com.*/providers/([^/?]+/[^/?]+)') { $api = 'arm ' + $Matches[1] }
    & $script:ApiLogger -Collector $Collector -Api $api -Scope $Url -DurationMs ([int][math]::Min($DurationMs, [int]::MaxValue)) `
        -ExitCode $Status -Bytes $Bytes -Attempt $Attempt -Outcome $Outcome
}

function Test-ScannerHttpAvailable {
    param([string]$Resource = 'https://graph.microsoft.com/')
    if ($script:HttpDisabled) { return $false }
    return [bool](Get-AzResourceToken -Resource $Resource)
}

function Disable-ScannerHttp {
    $script:HttpDisabled = $true
}

function Get-GraphPagedItems {
    param([Parameter(Mandatory = $true)][string]$Url, [string]$Collector = '')
    $items = [System.Collections.Generic.List[object]]::new()
    $nextUrl = $Url
    $useHttp = -not $script:HttpDisabled
    while ($nextUrl) {
        $resp = $null
        if ($useHttp) {
            $raw = Invoke-ScannerHttp -Method 'GET' -Url $nextUrl -Resource 'https://graph.microsoft.com/' -Collector $Collector
            if ($null -eq $raw) { $useHttp = $false }
            elseif ($raw.Status -ge 400) {
                $detail = ''
                try {
                    $parsed = ConvertFrom-JsonSafe -Json $raw.Body
                    if ($parsed -and $parsed.PSObject.Properties['error']) { $detail = [string]$parsed.error.message }
                }
                catch { $detail = '' }
                throw ("Graph request failed (HTTP {0}): {1}" -f $raw.Status, $detail)
            }
            else { $resp = ConvertFrom-JsonSafe -Json $raw.Body }
        }
        if (-not $useHttp) {
            $resp = Invoke-AzJson -Arguments @('rest', '--method', 'GET', '--url', $nextUrl) -AllowError
        }
        if (-not $resp) { break }
        $errorProp = $resp.PSObject.Properties['error']
        if ($errorProp -and $errorProp.Value) {
            $err = $errorProp.Value
            $codeProp = $err.PSObject.Properties['code']
            $msgProp = $err.PSObject.Properties['message']
            $code = if ($codeProp) { [string]$codeProp.Value } else { 'GraphError' }
            $message = if ($msgProp) { [string]$msgProp.Value } else { 'Unknown Graph error.' }
            throw "Graph request failed ($code): $message"
        }
        $valueProp = $resp.PSObject.Properties['value']
        if ($valueProp) { foreach ($item in @($valueProp.Value)) { [void]$items.Add($item) } }
        $nextLinkProp = $resp.PSObject.Properties['@odata.nextLink']
        $nextUrl = if ($nextLinkProp) { [string]$nextLinkProp.Value } else { '' }
        if (-not $nextUrl) { break }
    }
    return @($items)
}

# Graph $batch: up to 20 requests per round trip. Requests are @{ id; url }.
function Invoke-GraphBatch {
    param(
        [Parameter(Mandatory = $true)][array]$Requests,
        [string]$Collector = '',
        [int]$ChunkSize = 20
    )
    $results = @{}
    if (@($Requests).Count -eq 0) { return $results }
    if ($script:HttpDisabled) { return $null }

    $all = @($Requests)
    for ($offset = 0; $offset -lt $all.Count; $offset += $ChunkSize) {
        $chunk = @($all | Select-Object -Skip $offset -First $ChunkSize)
        $payload = @{
            requests = @($chunk | ForEach-Object { @{ id = [string]$_.id; method = 'GET'; url = [string]$_.url } })
        } | ConvertTo-Json -Depth 6 -Compress

        $raw = Invoke-ScannerHttp -Method 'POST' -Url 'https://graph.microsoft.com/v1.0/$batch' -Resource 'https://graph.microsoft.com/' -Body $payload -Collector $Collector
        if ($null -eq $raw) { return $null }
        if ($raw.Status -ge 400) { throw ('Graph batch request failed (HTTP {0})' -f $raw.Status) }
        $parsed = ConvertFrom-JsonSafe -Json $raw.Body
        if (-not $parsed) { continue }
        $responsesProp = $parsed.PSObject.Properties['responses']
        if (-not $responsesProp) { continue }
        foreach ($response in @($responsesProp.Value)) {
            $id = [string]$response.id
            $status = 0
            if ($response.PSObject.Properties['status']) { $status = [int]$response.status }
            $bodyProp = $response.PSObject.Properties['body']
            $results[$id] = [pscustomobject]@{
                Status = $status
                Body   = $(if ($bodyProp) { $bodyProp.Value } else { $null })
            }
        }
    }
    return $results
}

# ---------------------------------------------------------------------------
# Parallel az execution.
# Fans out at the OS-process level rather than with runspaces: az is an external
# process anyway, so this needs no thread-safe state and works on 5.1 and 7 alike.
# ---------------------------------------------------------------------------
function Invoke-AzJsonParallel {
    param(
        [Parameter(Mandatory = $true)][array]$Jobs,
        [int]$Throttle = 4,
        [int]$TimeoutSeconds = 600,
        [string]$Collector = '',
        [scriptblock]$OnProgress = $null
    )
    $results = @{}
    $queue = @($Jobs)
    if ($queue.Count -eq 0) { return $results }
    if ($Throttle -lt 1) { $Throttle = 1 }

    $command = Resolve-AzCommand
    $commandPath = [string]$command
    if ($command -is [System.Management.Automation.CommandInfo]) { $commandPath = [string]$command.Path }

    $running = [System.Collections.Generic.List[object]]::new()
    $nextIndex = 0
    $completed = 0

    while ($completed -lt $queue.Count) {
        while ($running.Count -lt $Throttle -and $nextIndex -lt $queue.Count) {
            $job = $queue[$nextIndex]
            $nextIndex++

            $effectiveArgs = @($job.Arguments)
            $hasOutput = $false
            foreach ($arg in $effectiveArgs) {
                if ($arg -like '-o=*' -or $arg -eq '-o' -or $arg -like '--output=*' -or $arg -eq '--output') { $hasOutput = $true; break }
            }
            if (-not $hasOutput) { $effectiveArgs += @('-o', 'json') }
            if (-not ($effectiveArgs -contains '--only-show-errors')) { $effectiveArgs += '--only-show-errors' }

            $allArgs = @($script:AzCommandArguments + $effectiveArgs)
            $quoted = foreach ($arg in $allArgs) {
                $text = [string]$arg
                if ($text -match '[\s"]') { '"' + ($text -replace '"', '\"') + '"' } else { $text }
            }

            $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
            $startInfo.FileName = $commandPath
            $startInfo.Arguments = ($quoted -join ' ')
            $startInfo.UseShellExecute = $false
            $startInfo.RedirectStandardOutput = $true
            $startInfo.RedirectStandardError = $true
            $startInfo.CreateNoWindow = $true

            $process = [System.Diagnostics.Process]::new()
            $process.StartInfo = $startInfo
            [void]$process.Start()
            [void]$running.Add([pscustomobject]@{
                Key        = $job.Key
                Args       = $effectiveArgs
                Process    = $process
                StdOutTask = $process.StandardOutput.ReadToEndAsync()
                StdErrTask = $process.StandardError.ReadToEndAsync()
                Started    = [DateTime]::UtcNow
                Stopwatch  = [System.Diagnostics.Stopwatch]::StartNew()
            })
        }

        Start-Sleep -Milliseconds 50
        $finished = @($running | Where-Object { $_.Process.HasExited -or (([DateTime]::UtcNow - $_.Started).TotalSeconds -gt $TimeoutSeconds) })
        foreach ($item in $finished) {
            $timedOut = -not $item.Process.HasExited
            if ($timedOut) { try { $item.Process.Kill() } catch { } }
            $item.Stopwatch.Stop()

            $stdout = ''
            $stderr = ''
            try { $stdout = $item.StdOutTask.Result } catch { $stdout = '' }
            try { $stderr = $item.StdErrTask.Result } catch { $stderr = '' }
            $exitCode = if ($timedOut) { -1 } else { $item.Process.ExitCode }

            Write-AzApiTelemetry -Arguments $item.Args -Collector $Collector -Scope '' -DurationMs $item.Stopwatch.ElapsedMilliseconds -ExitCode $exitCode -Bytes ([string]$stdout).Length

            $entry = [pscustomobject]@{ Key = $item.Key; Ok = $false; Data = $null; Error = ''; DurationMs = $item.Stopwatch.ElapsedMilliseconds }
            if ($timedOut) {
                $entry.Error = "az timed out after $TimeoutSeconds seconds: $($item.Args -join ' ')"
            }
            elseif ($exitCode -ne 0) {
                $entry.Error = "az failed ($exitCode): $($item.Args -join ' ')`n$stderr"
            }
            else {
                try {
                    $entry.Data = ConvertFrom-JsonSafe -Json $stdout
                    $entry.Ok = $true
                }
                catch { $entry.Error = "Failed to parse az JSON: $($_.Exception.Message)" }
            }
            $results[$item.Key] = $entry

            try { $item.Process.Dispose() } catch { }
            [void]$running.Remove($item)
            $completed++
            if ($OnProgress) { & $OnProgress $completed $queue.Count }
        }
    }
    return $results
}

Export-ModuleMember -Function *-*
