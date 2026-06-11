Set-StrictMode -Version Latest
$script:AzCommand = $null
$script:AzCommandArguments = @()
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
        [switch]$AllowError
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
    try {
        Write-Verbose ("Invoke-AzText starting: {0} {1}" -f $startInfo.FileName, $startInfo.Arguments)
        [void]$process.Start()
        $stdout = $process.StandardOutput.ReadToEnd()
        $stderr = $process.StandardError.ReadToEnd()
        $process.WaitForExit()
        $exitCode = $process.ExitCode
        Write-Verbose ("Invoke-AzText completed: exitCode={0} stdoutLength={1} stderrLength={2}" -f $exitCode, ([string]$stdout).Length, ([string]$stderr).Length)
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

function Invoke-AzJson {
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [switch]$AllowError
    )
    $hasOutput = $false
    foreach ($arg in $Arguments) {
        if ($arg -like '-o=*' -or $arg -eq '-o' -or $arg -like '--output=*' -or $arg -eq '--output') { $hasOutput = $true; break }
    }
    $effectiveArgs = @($Arguments)
    if (-not $hasOutput) { $effectiveArgs += @('-o', 'json') }
    $result = Invoke-AzText -Arguments $effectiveArgs -AllowError:$AllowError
    if ([string]::IsNullOrWhiteSpace($result.StdOut)) { return $null }
    try { return $result.StdOut | ConvertFrom-Json }
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

function Get-GraphPagedItems {
    param([Parameter(Mandatory = $true)][string]$Url)
    $items = @()
    $nextUrl = $Url
    while ($nextUrl) {
        $resp = Invoke-AzJson -Arguments @('rest', '--method', 'GET', '--url', $nextUrl) -AllowError
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
        if ($valueProp) { $items += @($valueProp.Value) }
        $nextLinkProp = $resp.PSObject.Properties['@odata.nextLink']
        $nextUrl = if ($nextLinkProp) { [string]$nextLinkProp.Value } else { '' }
        if (-not $nextUrl) { break }
    }
    return @($items)
}

Export-ModuleMember -Function *-*
