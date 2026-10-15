Set-StrictMode -Version Latest

# Console presentation: colour, two-tier progress, and a percentage/ETA that is weighted by
# measured cost rather than pretending every collector is the same size.

$script:Ui = $null

# Seeded from a large-tenant run so the first scan is roughly right; overwritten by
# per-tenant calibration from run 2 onward.
$script:DefaultWeights = @{
    StartupValidation       = 2
    Subscriptions           = 2
    ManagementGroups        = 18
    AzureRoleDefinitions    = 9
    AzureTenantRootRbac     = 3
    ManagementGroupRbac     = 160
    AzureSubscriptionRbac   = 1300
    ScopeInventory          = 1780
    AzureResourceGroupRbac  = 30
    AzureResourceRbac       = 30
    StorageChildScopeRbac   = 120
    EntraRoleAssignments    = 60
    GroupExpansion          = 600
    PrincipalResolution     = 240
    ServicePrincipalOwners  = 400
    KeyVaultAccessPolicies  = 90
    PimDirectoryAssignments = 30
    PimAzureAssignments     = 60
    GovernanceAuthentication = 2
    AccessPackageCatalogs   = 5
    AccessPackages          = 10
    AccessPackagePolicies   = 20
    AccessPackageResources  = 30
    AccessPackageAssignments = 30
    AccessReviewDefinitions = 10
    AccessReviewInstances   = 20
    AccessReviewStages      = 10
    AccessReviewDecisions   = 60
    BillingAccess           = 20
    ReservationAccess       = 20
    ClassicAdmins           = 50
    WorkbookReport          = 120
}

function Initialize-ScannerUi {
    param(
        [switch]$Quiet,
        [switch]$NoColor,
        [switch]$NoProgress,
        [string]$CalibrationPath = '',
        [string[]]$PlannedCollectors = @()
    )
    $redirected = $false
    try { $redirected = [Console]::IsOutputRedirected } catch { $redirected = $false }
    $automation = [bool]($env:CI -or $env:TF_BUILD -or $env:GITHUB_ACTIONS)

    $useColor = -not $Quiet -and -not $NoColor -and -not $env:NO_COLOR -and -not $redirected
    $useProgress = -not $Quiet -and -not $NoProgress -and -not $redirected -and -not $automation

    $unicode = $false
    try { $unicode = ([Console]::OutputEncoding.CodePage -eq 65001) } catch { $unicode = $false }

    $weights = @{}
    foreach ($k in $script:DefaultWeights.Keys) { $weights[$k] = [double]$script:DefaultWeights[$k] }
    $calibrated = $false
    if ($CalibrationPath -and (Test-Path -LiteralPath $CalibrationPath)) {
        try {
            $saved = Get-Content -LiteralPath $CalibrationPath -Raw | ConvertFrom-Json
            foreach ($prop in $saved.PSObject.Properties) {
                $seconds = [double]$prop.Value
                if ($seconds -gt 0) { $weights[$prop.Name] = $seconds; $calibrated = $true }
            }
        }
        catch { $calibrated = $false }
    }

    $script:Ui = [pscustomobject]@{
        Quiet            = [bool]$Quiet
        UseColor         = $useColor
        UseProgress      = $useProgress
        Unicode          = $unicode
        CalibrationPath  = $CalibrationPath
        Calibrated       = $calibrated
        Weights          = $weights
        Planned          = @($PlannedCollectors)
        TotalWeight      = 0.0
        CompletedWeight  = 0.0
        CurrentName      = ''
        CurrentWeight    = 0.0
        CurrentFraction  = 0.0
        StartedUtc       = [DateTime]::UtcNow
        PhaseStartedUtc  = [DateTime]::UtcNow
        LastPercent      = 0
        LastDrawTicks    = 0
        Measured         = @{}
        Completed        = 0
    }
    Set-ScannerPlan -Collectors $PlannedCollectors
    return $script:Ui
}

function Set-ScannerPlan {
    param([string[]]$Collectors = @())
    if (-not $script:Ui) { return }
    $script:Ui.Planned = @($Collectors)
    $total = 0.0
    foreach ($name in $script:Ui.Planned) {
        $total += (Get-CollectorWeight -Name $name)
    }
    if ($total -le 0) { $total = 1 }
    $script:Ui.TotalWeight = $total
}

function Get-CollectorWeight {
    param([string]$Name)
    if (-not $script:Ui) { return 1.0 }
    if ($script:Ui.Weights.ContainsKey($Name)) { return [double]$script:Ui.Weights[$Name] }
    return 25.0
}

function Get-ScannerColor {
    param([string]$Level)
    switch ($Level) {
        'Header'  { return 'Cyan' }
        'Phase'   { return 'Cyan' }
        'Ok'      { return 'Green' }
        'Warn'    { return 'Yellow' }
        'Error'   { return 'Red' }
        'Detail'  { return 'DarkGray' }
        'Value'   { return 'White' }
        default   { return 'Gray' }
    }
}

function Write-ScannerLine {
    param(
        [string]$Text = '',
        [ValidateSet('Header', 'Phase', 'Ok', 'Warn', 'Error', 'Detail', 'Value', 'Plain')][string]$Level = 'Plain',
        [switch]$Force
    )
    if ($script:Ui -and $script:Ui.Quiet -and -not $Force) { return }
    if ($script:Ui -and $script:Ui.UseColor) {
        Write-Host $Text -ForegroundColor (Get-ScannerColor -Level $Level)
    }
    else {
        Write-Host $Text
    }
}

function Get-ScannerGlyph {
    param([ValidateSet('Ok', 'Warn', 'Error', 'Skip', 'Run')][string]$Kind)
    $unicode = ($script:Ui -and $script:Ui.Unicode)
    switch ($Kind) {
        'Ok'    { return $(if ($unicode) { '[OK]' } else { '[OK]' }) }
        'Warn'  { return '[!!]' }
        'Error' { return '[XX]' }
        'Skip'  { return '[--]' }
        'Run'   { return '[>>]' }
    }
    return '[..]'
}

function Format-Duration {
    param([double]$Seconds)
    if ($Seconds -lt 0) { $Seconds = 0 }
    $ts = [TimeSpan]::FromSeconds([math]::Round($Seconds))
    if ($ts.TotalHours -ge 1) { return ('{0:00}:{1:00}:{2:00}' -f [int]$ts.TotalHours, $ts.Minutes, $ts.Seconds) }
    return ('{0:00}:{1:00}' -f $ts.Minutes, $ts.Seconds)
}

function Get-ScannerPercent {
    if (-not $script:Ui) { return 0 }
    $done = $script:Ui.CompletedWeight + ($script:Ui.CurrentWeight * $script:Ui.CurrentFraction)
    $pct = [int][math]::Floor(($done / $script:Ui.TotalWeight) * 100)
    if ($pct -lt 0) { $pct = 0 }
    if ($pct -gt 99) { $pct = 99 }
    # Never let the bar walk backwards; a shrinking estimate reads as a bug.
    if ($pct -lt $script:Ui.LastPercent) { $pct = $script:Ui.LastPercent }
    $script:Ui.LastPercent = $pct
    return $pct
}

function Get-ScannerEta {
    if (-not $script:Ui) { return -1 }
    $elapsed = ([DateTime]::UtcNow - $script:Ui.StartedUtc).TotalSeconds
    $done = $script:Ui.CompletedWeight + ($script:Ui.CurrentWeight * $script:Ui.CurrentFraction)
    if ($done -le 0 -or $elapsed -lt 5) { return -1 }
    $rate = $elapsed / $done
    return [math]::Max(0, ($script:Ui.TotalWeight - $done) * $rate)
}

function Update-ScannerProgress {
    param([string]$Activity = '', [switch]$Force)
    if (-not $script:Ui -or -not $script:Ui.UseProgress) { return }
    $now = [DateTime]::UtcNow.Ticks
    if (-not $Force -and ($now - $script:Ui.LastDrawTicks) -lt 2500000) { return }  # ~250ms
    $script:Ui.LastDrawTicks = $now

    $pct = Get-ScannerPercent
    $eta = Get-ScannerEta
    $status = ('{0}% complete' -f $pct)
    if ($eta -ge 0) { $status += (' - ETA {0}' -f (Format-Duration -Seconds $eta)) }
    if (-not $script:Ui.Calibrated) { $status += ' (estimate)' }

    Write-Progress -Id 0 -Activity 'All Azure access scan' -Status $status -PercentComplete $pct
    if ($Activity) {
        $childPct = [int][math]::Floor($script:Ui.CurrentFraction * 100)
        if ($childPct -lt 0) { $childPct = 0 }
        if ($childPct -gt 100) { $childPct = 100 }
        Write-Progress -Id 1 -ParentId 0 -Activity $script:Ui.CurrentName -Status $Activity -PercentComplete $childPct
    }
}

function Start-ScannerPhase {
    param([Parameter(Mandatory = $true)][string]$Name)
    if (-not $script:Ui) { return }
    $script:Ui.CurrentName = $Name
    $script:Ui.CurrentWeight = Get-CollectorWeight -Name $Name
    $script:Ui.CurrentFraction = 0.0
    $script:Ui.PhaseStartedUtc = [DateTime]::UtcNow
    Write-ScannerLine -Text ('{0} {1}' -f (Get-ScannerGlyph -Kind 'Run'), $Name) -Level 'Phase'
    Update-ScannerProgress -Activity 'starting' -Force
}

function Set-ScannerPhaseProgress {
    param([int]$Current = 0, [int]$Total = 0, [string]$Activity = '')
    if (-not $script:Ui) { return }
    if ($Total -gt 0) {
        $fraction = [double]$Current / [double]$Total
        if ($fraction -lt 0) { $fraction = 0 }
        if ($fraction -gt 1) { $fraction = 1 }
        $script:Ui.CurrentFraction = $fraction
    }
    $text = $Activity
    if ($Total -gt 0) { $text = ('{0} ({1}/{2})' -f $Activity, $Current, $Total) }
    Update-ScannerProgress -Activity $text
}

function Complete-ScannerPhase {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [string]$Status = 'Succeeded',
        [int]$RowsAdded = 0,
        [int]$Units = 0,
        [string]$Message = ''
    )
    if (-not $script:Ui) { return }
    $seconds = ([DateTime]::UtcNow - $script:Ui.PhaseStartedUtc).TotalSeconds
    $script:Ui.Measured[$Name] = [math]::Round($seconds, 2)
    $script:Ui.CompletedWeight += $script:Ui.CurrentWeight
    $script:Ui.CurrentFraction = 0.0
    $script:Ui.CurrentWeight = 0.0
    $script:Ui.Completed++

    $level = 'Ok'; $glyph = Get-ScannerGlyph -Kind 'Ok'
    switch ($Status) {
        'Skipped'           { $level = 'Detail'; $glyph = Get-ScannerGlyph -Kind 'Skip' }
        'PartiallyCollected'{ $level = 'Warn';   $glyph = Get-ScannerGlyph -Kind 'Warn' }
        'Unauthorized'      { $level = 'Warn';   $glyph = Get-ScannerGlyph -Kind 'Warn' }
        'Throttled'         { $level = 'Warn';   $glyph = Get-ScannerGlyph -Kind 'Warn' }
        'Failed'            { $level = 'Error';  $glyph = Get-ScannerGlyph -Kind 'Error' }
    }
    $text = ('{0} {1}  {2}  rows +{3}  {4}' -f $glyph, $Name.PadRight(24), (Format-Duration -Seconds $seconds), $RowsAdded, $Status)
    Write-ScannerLine -Text $text -Level $level
    if ($Message) { Write-ScannerLine -Text ('     ' + $Message) -Level 'Detail' }
    if ($Units -gt 0) { $script:Ui.Measured[($Name + '#units')] = $Units }
    Update-ScannerProgress -Activity 'done' -Force
}

function Write-ScannerHeartbeat {
    param([string]$Collector = '', [int]$Rows = 0, [int]$Current = 0, [int]$Total = 0)
    if (-not $script:Ui) { return }
    $elapsed = ([DateTime]::UtcNow - $script:Ui.StartedUtc).TotalSeconds
    $memMb = [math]::Round(([System.Diagnostics.Process]::GetCurrentProcess().WorkingSet64 / 1MB), 0)
    Write-ScannerLine -Text ('     ... {0} | {1} | {2}/{3} | rows {4} | {5} MB' -f `
        (Format-Duration -Seconds $elapsed), $Collector, $Current, $Total, $Rows, $memMb) -Level 'Detail'
}

function Save-ScannerCalibration {
    if (-not $script:Ui -or -not $script:Ui.CalibrationPath) { return }
    if ($script:Ui.Measured.Count -eq 0) { return }
    try {
        $parent = Split-Path -Parent $script:Ui.CalibrationPath
        if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
        $payload = @{}
        foreach ($k in $script:Ui.Measured.Keys) {
            if ([string]$k -like '*#units') { continue }
            $payload[[string]$k] = $script:Ui.Measured[$k]
        }
        [System.IO.File]::WriteAllText($script:Ui.CalibrationPath, ($payload | ConvertTo-Json -Depth 4), [System.Text.UTF8Encoding]::new($false))
    }
    catch { }
}

function Complete-ScannerUi {
    if (-not $script:Ui) { return }
    if ($script:Ui.UseProgress) {
        Write-Progress -Id 1 -Activity 'done' -Completed
        Write-Progress -Id 0 -Activity 'done' -Completed
    }
    Save-ScannerCalibration
}

function Write-ScannerSummary {
    param(
        [array]$StatusRows = @(),
        [array]$ErrorClasses = @(),
        [System.Collections.IDictionary]$Totals = @{}
    )
    if (-not $script:Ui -or $script:Ui.Quiet) { return }
    $elapsed = ([DateTime]::UtcNow - $script:Ui.StartedUtc).TotalSeconds

    Write-ScannerLine -Text '' -Level 'Plain'
    Write-ScannerLine -Text ('Scan finished in {0}' -f (Format-Duration -Seconds $elapsed)) -Level 'Header'
    Write-ScannerLine -Text ('{0}  {1}  {2}  {3}' -f 'Collector'.PadRight(26), 'Status'.PadRight(20), 'Duration'.PadRight(10), 'Rows') -Level 'Detail'

    foreach ($row in @($StatusRows)) {
        $status = [string]$row.status
        $level = 'Ok'
        if ($status -eq 'Skipped') { $level = 'Detail' }
        elseif ($status -eq 'Failed') { $level = 'Error' }
        elseif ($status -ne 'Succeeded') { $level = 'Warn' }
        Write-ScannerLine -Text ('{0}  {1}  {2}  {3}' -f `
            ([string]$row.collector).PadRight(26), $status.PadRight(20), (Format-Duration -Seconds ([double]$row.durationSeconds)).PadRight(10), $row.rowsAdded) -Level $level
    }

    if (@($ErrorClasses).Count -gt 0) {
        Write-ScannerLine -Text '' -Level 'Plain'
        Write-ScannerLine -Text ('Top issues ({0} distinct classes)' -f @($ErrorClasses).Count) -Level 'Warn'
        foreach ($cls in @($ErrorClasses | Select-Object -First 5)) {
            $template = [string]$cls.template
            if ($template.Length -gt 110) { $template = $template.Substring(0, 110) + '...' }
            Write-ScannerLine -Text ('  x{0}  [{1}] {2}' -f $cls.count, $cls.collector, $template) -Level 'Warn'
        }
    }

    if ($Totals.Count -gt 0) {
        Write-ScannerLine -Text '' -Level 'Plain'
        foreach ($k in $Totals.Keys) {
            Write-ScannerLine -Text ('{0}: {1}' -f ([string]$k).PadRight(26), $Totals[$k]) -Level 'Value'
        }
    }
}

Export-ModuleMember -Function *-*
