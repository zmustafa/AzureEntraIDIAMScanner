[CmdletBinding()]
param(
    [string]$OutputRoot = $(if ($env:AZURE_IAM_SCANNER_OUTPUT_ROOT) { $env:AZURE_IAM_SCANNER_OUTPUT_ROOT } else { Join-Path ([System.IO.Path]::GetTempPath()) 'azure-scanners' }),
    [string]$JobId = ([guid]::NewGuid().Guid),
    [string[]]$SubscriptionIds = @(),
    [string[]]$ManagementGroupIds = @(),
    [string[]]$ResourceTypes = @(),
    [switch]$IncludeResourceLevel,
    [switch]$SkipResourceLevel,
    [switch]$IncludeChildDataScopes,
    [switch]$SkipChildDataScopes,
    [switch]$IncludePim,
    [switch]$SkipPim,
    [switch]$IncludeBilling,
    [switch]$SkipBilling,
    [switch]$IncludeReservations,
    [switch]$SkipReservations,
    [switch]$IncludeClassicAdmins,
    [switch]$SkipClassicAdmins,
    [switch]$IncludeKeyVaultAccessPolicies,
    [switch]$SkipKeyVaultAccessPolicies,
    [switch]$FullRoleDefinitionScan,
    [switch]$NoGroupExpansion,
    [switch]$IncludeOtherTenants,
    [switch]$DeepScopeScan,
    [ValidateRange(1, 10)][int]$MaxGroupDepth = 10,
    [int]$MaxGroupMembers = 0,
    [ValidateRange(1, 32)][int]$Parallel = 1,
    [int]$LimitResources = 0,
    [switch]$EmitJson,
    [switch]$NoHttp,
    [ValidateSet('Error', 'Warn', 'Info', 'Debug', 'Trace')][string]$LogLevel = 'Info',
    [int]$MaxLogMegabytes = 50,
    [switch]$RedactLogs,
    [switch]$SupportBundle,
    [switch]$IncludeData,
    [switch]$Quiet,
    [switch]$NoColor,
    [switch]$NoProgress,
    [switch]$NoTranscript,
    [switch]$ContinueOnError,
    [switch]$FailFast
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'lib\AzureScannerCommon.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'lib\AzureScannerLog.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'lib\AzureScannerUI.psm1') -Force -DisableNameChecking

# -Include* forces a collector on, -Skip* forces it off, -Include* wins if both are given.
function Resolve-CollectorToggle {
    param([bool]$Include, [bool]$Skip)
    if ($Include) { return $true }
    if ($Skip) { return $false }
    return $true
}

$doResourceLevel = Resolve-CollectorToggle -Include $IncludeResourceLevel -Skip $SkipResourceLevel
$doChildDataScopes = Resolve-CollectorToggle -Include $IncludeChildDataScopes -Skip $SkipChildDataScopes
$doPim = Resolve-CollectorToggle -Include $IncludePim -Skip $SkipPim
$doBilling = Resolve-CollectorToggle -Include $IncludeBilling -Skip $SkipBilling
$doReservations = Resolve-CollectorToggle -Include $IncludeReservations -Skip $SkipReservations
$doClassicAdmins = Resolve-CollectorToggle -Include $IncludeClassicAdmins -Skip $SkipClassicAdmins
$doKeyVaultAccessPolicies = Resolve-CollectorToggle -Include $IncludeKeyVaultAccessPolicies -Skip $SkipKeyVaultAccessPolicies
$doGroupExpansion = -not $NoGroupExpansion

function Add-FlatValue {
    param([System.Collections.Generic.List[object]]$List, [AllowNull()]$Value)
    if ($null -eq $Value) { return }
    if ($Value -is [System.Array]) {
        foreach ($item in $Value) { Add-FlatValue -List $List -Value $item }
        return
    }
    [void]$List.Add($Value)
}

function Get-PropertyText {
    param([AllowNull()]$Object, [Parameter(Mandatory = $true)][string[]]$Names)
    if ($null -eq $Object) { return '' }
    foreach ($name in $Names) {
        $prop = $Object.PSObject.Properties[$name]
        if ($prop -and $null -ne $prop.Value) {
            $value = ([string]$prop.Value).Trim()
            if ($value) { return $value }
        }
    }
    return ''
}

function Get-ArrayCount {
    param([AllowNull()]$Value)
    if ($null -eq $Value) { return 0 }
    if ($Value -is [System.Array]) { return $Value.Count }
    return 1
}

function Expand-FlatArray {
    param([AllowNull()]$InputObject)
    if ($null -eq $InputObject) { return @() }
    if ($InputObject -is [System.Array]) { return @($InputObject) }
    return @($InputObject)
}

function ConvertTo-CompactJson {
    param([AllowNull()]$Value)
    if ($null -eq $Value) { return '' }
    try { return ($Value | ConvertTo-Json -Depth 12 -Compress) }
    catch { return [string]$Value }
}

function ConvertTo-CommandLineArgument {
    param([AllowNull()][string]$Value)
    $text = [string]$Value
    if ($text -notmatch '[\s"]') { return $text }
    return '"' + ($text -replace '"', '\"') + '"'
}

function Invoke-AzJsonWithTimeout {
    param([Parameter(Mandatory = $true)][string[]]$Arguments, [int]$TimeoutSeconds = 120, [string]$Collector = '', [string]$Scope = '')
    $effectiveArgs = @($Arguments)
    $hasOutput = $false
    foreach ($arg in $effectiveArgs) {
        if ($arg -like '-o=*' -or $arg -eq '-o' -or $arg -like '--output=*' -or $arg -eq '--output') { $hasOutput = $true; break }
    }
    if (-not $hasOutput) { $effectiveArgs += @('-o', 'json') }
    if (-not ($effectiveArgs -contains '--only-show-errors')) { $effectiveArgs += '--only-show-errors' }

    $azCommand = Get-Command az.cmd -ErrorAction SilentlyContinue
    if (-not $azCommand) { $azCommand = Get-Command az -ErrorAction Stop }
    $quoted = @((ConvertTo-CommandLineArgument -Value $azCommand.Source)) + @($effectiveArgs | ForEach-Object { ConvertTo-CommandLineArgument -Value $_ })

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = 'cmd.exe'
    $startInfo.Arguments = '/d /s /c "' + ($quoted -join ' ') + '"'
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $exitCode = -1
    $stdout = ''
    try {
        [void]$process.Start()
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            try { $process.Kill() } catch { }
            throw "az timed out after $TimeoutSeconds seconds: $($effectiveArgs -join ' ')"
        }
        $stdout = $stdoutTask.Result
        $stderr = $stderrTask.Result
        $exitCode = $process.ExitCode
        if ($exitCode -ne 0) { throw "az failed ($exitCode): $($effectiveArgs -join ' ')`n$stderr" }
        if ([string]::IsNullOrWhiteSpace($stdout)) { return $null }
        return ConvertFrom-JsonSafe -Json $stdout
    }
    finally {
        $sw.Stop()
        Write-ScannerApiCall -Collector $Collector -Api (Get-AzApiName -Arguments $effectiveArgs) -Scope $Scope `
            -DurationMs ([int]$sw.ElapsedMilliseconds) -ExitCode $exitCode -Bytes ([string]$stdout).Length `
            -Outcome $(if ($exitCode -eq 0) { 'Succeeded' } else { 'Failed' })
        if ($process) { $process.Dispose() }
    }
}

function ConvertTo-PrincipalType {
    param([AllowNull()][string]$Value)
    $text = ([string]$Value).Trim()
    if (-not $text) { return '' }
    $text = $text -replace '^#microsoft\.graph\.', ''
    switch -Regex ($text.ToLowerInvariant()) {
        '^user$' { return 'User' }
        '^group$' { return 'Group' }
        'serviceprincipal|service_principal' { return 'ServicePrincipal' }
        '^application$' { return 'Application' }
        'managedidentity|msi' { return 'ManagedIdentity' }
        default { return $text.Substring(0, 1).ToUpperInvariant() + $text.Substring(1) }
    }
}

function Get-ScopeType {
    param([AllowNull()][string]$Scope)
    $scopeText = ([string]$Scope).Trim()
    if (-not $scopeText) { return '' }
    if ($scopeText -eq '/') { return 'tenantRoot' }
    if ($scopeText -match '^/providers/Microsoft\.Management/managementGroups/[^/]+$') { return 'managementGroup' }
    if ($scopeText -match '^/subscriptions/[^/]+$') { return 'subscription' }
    if ($scopeText -match '^/subscriptions/[^/]+/resourceGroups/[^/]+$') { return 'resourceGroup' }
    if ($scopeText -match '^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\.Storage/storageAccounts/[^/]+/(blobServices|fileServices)/default/(containers|shares)/[^/]+$') { return 'storageChildScope' }
    if ($scopeText -match '^/subscriptions/[^/]+/resourceGroups/[^/]+/') { return 'resource' }
    if ($scopeText -match '^/providers/Microsoft\.Billing/') { return 'billing' }
    if ($scopeText -match '^/providers/Microsoft\.Capacity/') { return 'reservation' }
    return 'scope'
}

function Get-SubscriptionIdFromScope {
    param([AllowNull()][string]$Scope)
    if ([string]$Scope -match '/subscriptions/([^/]+)') { return $Matches[1] }
    return ''
}

function Get-ResourceGroupFromScope {
    param([AllowNull()][string]$Scope)
    if ([string]$Scope -match '/resourceGroups/([^/]+)') { return [uri]::UnescapeDataString($Matches[1]) }
    return ''
}

function Get-ResourceTypeFromScope {
    param([AllowNull()][string]$Scope)
    $text = [string]$Scope
    if ($text -match '/providers/([^/]+/[^/]+)') { return $Matches[1] }
    return ''
}

function Get-ResourceNameFromScope {
    param([AllowNull()][string]$Scope)
    $parts = @(([string]$Scope).Split('/') | Where-Object { $_ })
    if ($parts.Count -eq 0) { return '' }
    return [uri]::UnescapeDataString($parts[-1])
}

function Get-ManagementGroupIdFromScope {
    param([AllowNull()][string]$Scope)
    if ([string]$Scope -match '/providers/Microsoft\.Management/managementGroups/([^/]+)') { return $Matches[1] }
    return ''
}

function Get-RoleDefinitionKey {
    param([AllowNull()][string]$RoleDefinitionId)
    $text = ([string]$RoleDefinitionId).Trim().ToLowerInvariant()
    if ($text -match '/roledefinitions/([^/]+)$') { return $Matches[1].ToLowerInvariant() }
    return $text
}

function Test-RoleAssignmentObject {
    param([AllowNull()]$Assignment)
    if ($null -eq $Assignment) { return $false }
    if ($Assignment -is [string]) { return $false }
    return [bool]((Get-PropertyText -Object $Assignment -Names @('id', 'principalId', 'roleDefinitionId', 'roleDefinitionName', 'scope')))
}

function Test-PrivilegedRoleName {
    param([AllowNull()][string]$RoleName)
    return ([string]$RoleName) -match '(?i)\b(owner|contributor|administrator|admin|user access administrator|privileged|security|key vault administrator|role management|billing account owner|reservation purchaser)\b'
}

function New-AccessRow {
    param(
        [string]$Surface = '', [string]$AccessModel = '', [string]$Collector = '', [string]$AssignmentState = 'Active', [string]$AssignmentType = 'RoleAssignment',
        [string]$PrincipalId = '', [string]$PrincipalType = '', [string]$PrincipalDisplayName = '', [string]$PrincipalUserPrincipalName = '', [string]$PrincipalAppId = '',
        [string]$EffectivePrincipalId = '', [string]$EffectivePrincipalType = '', [string]$EffectivePrincipalName = '', [string]$EffectivePrincipalUserPrincipalName = '',
        [string]$AccessPath = 'Direct', [string]$GroupChain = '', [string]$SourceGroupId = '', [string]$SourceGroupName = '',
        [string]$RoleName = '', [string]$RoleDefinitionId = '', [string]$RoleCategory = '', [bool]$RoleIsPrivileged = $false, [bool]$RoleHasDataActions = $false,
        [string]$Scope = '', [string]$ScopeType = '', [string]$ScopeDisplayName = '', [string]$TenantId = '', [string]$ManagementGroupId = '', [string]$ManagementGroupName = '',
        [string]$SubscriptionId = '', [string]$SubscriptionName = '', [string]$ResourceGroup = '', [string]$ResourceType = '', [string]$ResourceName = '',
        [string]$ChildResourceType = '', [string]$ChildResourceName = '', [string]$AssignmentId = '', [string]$AssignmentCreatedOn = '', [string]$AssignmentUpdatedOn = '',
        [string]$Condition = '', [string]$ConditionVersion = '', [string]$IsInherited = '', [string]$SourceApi = '', [string]$CollectionStatus = 'Succeeded',
        [string]$ErrorCode = '', [string]$ErrorMessage = ''
    )
    if (-not $EffectivePrincipalId) { $EffectivePrincipalId = $PrincipalId }
    if (-not $EffectivePrincipalType) { $EffectivePrincipalType = $PrincipalType }
    if (-not $EffectivePrincipalName) { $EffectivePrincipalName = $PrincipalDisplayName }
    if (-not $EffectivePrincipalUserPrincipalName) { $EffectivePrincipalUserPrincipalName = $PrincipalUserPrincipalName }
    if (-not $ScopeType) { $ScopeType = Get-ScopeType -Scope $Scope }
    if (-not $SubscriptionId) { $SubscriptionId = Get-SubscriptionIdFromScope -Scope $Scope }
    if (-not $ResourceGroup) { $ResourceGroup = Get-ResourceGroupFromScope -Scope $Scope }
    if (-not $ManagementGroupId) { $ManagementGroupId = Get-ManagementGroupIdFromScope -Scope $Scope }
    if (-not $ResourceType) { $ResourceType = Get-ResourceTypeFromScope -Scope $Scope }
    if (-not $ResourceName -and ($ScopeType -eq 'resource' -or $ScopeType -eq 'storageChildScope')) { $ResourceName = Get-ResourceNameFromScope -Scope $Scope }
    [pscustomobject]@{
        surface                           = $Surface
        accessModel                       = $AccessModel
        collector                         = $Collector
        assignmentState                   = $AssignmentState
        assignmentType                    = $AssignmentType
        principalId                       = $PrincipalId
        principalType                     = $PrincipalType
        principalDisplayName              = $PrincipalDisplayName
        principalUserPrincipalName        = $PrincipalUserPrincipalName
        principalAppId                    = $PrincipalAppId
        effectivePrincipalId              = $EffectivePrincipalId
        effectivePrincipalType            = $EffectivePrincipalType
        effectivePrincipalName            = $EffectivePrincipalName
        effectivePrincipalUserPrincipalName = $EffectivePrincipalUserPrincipalName
        accessPath                        = $AccessPath
        groupChain                        = $GroupChain
        sourceGroupId                     = $SourceGroupId
        sourceGroupName                   = $SourceGroupName
        roleName                          = $RoleName
        roleDefinitionId                  = $RoleDefinitionId
        roleCategory                      = $RoleCategory
        roleIsPrivileged                  = [string][bool]$RoleIsPrivileged
        roleHasDataActions                = [string][bool]$RoleHasDataActions
        scope                             = $Scope
        scopeType                         = $ScopeType
        scopeDisplayName                  = $ScopeDisplayName
        tenantId                          = $TenantId
        managementGroupId                 = $ManagementGroupId
        managementGroupName               = $ManagementGroupName
        subscriptionId                    = $SubscriptionId
        subscriptionName                  = $SubscriptionName
        resourceGroup                     = $ResourceGroup
        resourceType                      = $ResourceType
        resourceName                      = $ResourceName
        childResourceType                 = $ChildResourceType
        childResourceName                 = $ChildResourceName
        assignmentId                      = $AssignmentId
        assignmentCreatedOn               = $AssignmentCreatedOn
        assignmentUpdatedOn               = $AssignmentUpdatedOn
        condition                         = $Condition
        conditionVersion                  = $ConditionVersion
        isInherited                       = $IsInherited
        sourceApi                         = $SourceApi
        collectionStatus                  = $CollectionStatus
        errorCode                         = $ErrorCode
        errorMessage                      = $ErrorMessage
    }
}

function Get-AccessColumns {
    return @(
        'surface','accessModel','collector','assignmentState','assignmentType','principalId','principalType','principalDisplayName','principalUserPrincipalName','principalAppId',
        'effectivePrincipalId','effectivePrincipalType','effectivePrincipalName','effectivePrincipalUserPrincipalName','accessPath','groupChain','sourceGroupId','sourceGroupName',
        'roleName','roleDefinitionId','roleCategory','roleIsPrivileged','roleHasDataActions','scope','scopeType','scopeDisplayName','tenantId','managementGroupId','managementGroupName',
        'subscriptionId','subscriptionName','resourceGroup','resourceType','resourceName','childResourceType','childResourceName','assignmentId','assignmentCreatedOn','assignmentUpdatedOn',
        'condition','conditionVersion','isInherited','sourceApi','collectionStatus','errorCode','errorMessage'
    )
}

$context = New-ScanContext -JobType 'all-azure-access' -OutputRoot $OutputRoot -JobId $JobId
$exitCode = 0
$errorsDir = Ensure-Directory -Path (Join-Path $context.RunDir 'errors')
Ensure-Directory -Path (Join-Path $context.RunDir 'cache') | Out-Null
Ensure-Directory -Path (Join-Path $context.RunDir 'raw') | Out-Null
$reportsDir = Ensure-Directory -Path (Join-Path $context.RunDir 'reports')

$plannedCollectors = @(
    'StartupValidation', 'Subscriptions', 'ManagementGroups', 'AzureRoleDefinitions', 'AzureTenantRootRbac',
    'ManagementGroupRbac', 'AzureSubscriptionRbac', 'ScopeInventory', 'AzureResourceGroupRbac'
)
if ($doResourceLevel) { $plannedCollectors += 'AzureResourceRbac' }
if ($doChildDataScopes) { $plannedCollectors += 'StorageChildScopeRbac' }
$plannedCollectors += 'EntraRoleAssignments'
if ($doGroupExpansion) { $plannedCollectors += 'GroupExpansion' }
$plannedCollectors += @('PrincipalResolution', 'ServicePrincipalOwners')
if ($doKeyVaultAccessPolicies) { $plannedCollectors += 'KeyVaultAccessPolicies' }
if ($doPim) { $plannedCollectors += @('PimDirectoryAssignments', 'PimAzureAssignments') }
if ($doBilling) { $plannedCollectors += 'BillingAccess' }
if ($doReservations) { $plannedCollectors += 'ReservationAccess' }
if ($doClassicAdmins) { $plannedCollectors += 'ClassicAdmins' }
$plannedCollectors += 'WorkbookReport'

Initialize-ScannerLog -LogDirectory $context.LogDir -LogLevel $LogLevel -RedactOnDisk:$RedactLogs -MaxLogMegabytes $MaxLogMegabytes | Out-Null
Initialize-ScannerUi -Quiet:$Quiet -NoColor:$NoColor -NoProgress:$NoProgress `
    -CalibrationPath (Join-Path $OutputRoot '.calibration\all-azure-access.json') `
    -PlannedCollectors $plannedCollectors | Out-Null
if ($NoHttp) { Disable-ScannerHttp }

$script:AccessRows = [System.Collections.Generic.List[object]]::new()
$script:DirectRows = [System.Collections.Generic.List[object]]::new()
$script:EffectiveRows = [System.Collections.Generic.List[object]]::new()
$script:GroupRows = [System.Collections.Generic.List[object]]::new()
$script:OwnerRows = [System.Collections.Generic.List[object]]::new()
$script:RoleRows = [System.Collections.Generic.List[object]]::new()
$script:ScopeRows = [System.Collections.Generic.List[object]]::new()
$script:PrincipalRows = [System.Collections.Generic.List[object]]::new()
$script:GroupExpansionRows = [System.Collections.Generic.List[object]]::new()
$script:StatusRows = [System.Collections.Generic.List[object]]::new()
$script:ErrorRows = [System.Collections.Generic.List[object]]::new()
$script:AccessSeen = @{}
$script:RoleByKey = @{}
$script:RoleByName = @{}
$script:RoleDefinitionSeen = @{}
$script:PrincipalById = @{}
$script:GroupMembersById = @{}
$script:Subscriptions = @()
$script:ManagementGroups = @()
$script:Resources = [System.Collections.Generic.List[object]]::new()
$script:ResourceGroups = [System.Collections.Generic.List[object]]::new()
$script:SubscriptionRbacCovered = @{}
$script:UnreachableSubscriptions = @{}
$script:LastHeartbeat = $null
$script:HttpReady = $false
$script:TenantId = ''

function Add-ErrorRow {
    param([string]$Collector, [string]$Status, [string]$Message, [string]$Scope = '', [string]$Api = '', [string]$ErrorCode = '')
    [void]$script:ErrorRows.Add([pscustomobject]@{
        collector = $Collector
        status = $Status
        scope = $Scope
        api = $Api
        errorCode = $ErrorCode
        errorMessage = $Message
        generatedUtc = Get-UtcTimestamp
    })
    $level = if ($Status -eq 'Skipped') { 'Info' } elseif ($Status -eq 'Failed') { 'Error' } else { 'Warn' }
    Write-ScannerEvent -Level $level -Collector $Collector -EventName 'collector-issue' -Message $Message -Scope $Scope -Api $Api -ErrorCode $ErrorCode
}

function Add-CollectorStatus {
    param([string]$Collector, [string]$Status, [datetime]$StartedUtc, [int]$RowsBefore, [string]$Message = '')
    $ended = [DateTime]::UtcNow
    [void]$script:StatusRows.Add([pscustomobject]@{
        collector = $Collector
        status = $Status
        startedUtc = $StartedUtc.ToString('yyyy-MM-ddTHH:mm:ssZ')
        endedUtc = $ended.ToString('yyyy-MM-ddTHH:mm:ssZ')
        durationSeconds = [math]::Round(($ended - $StartedUtc).TotalSeconds, 2)
        rowsAdded = $script:AccessRows.Count - $RowsBefore
        totalRows = $script:AccessRows.Count
        message = $Message
    })
}

function Invoke-Collector {
    param([Parameter(Mandatory = $true)][string]$Name, [Parameter(Mandatory = $true)][scriptblock]$ScriptBlock, [switch]$Optional)
    $started = [DateTime]::UtcNow
    $rowsBefore = $script:AccessRows.Count
    Start-ScannerPhase -Name $Name
    Write-ScannerEvent -Level 'Info' -Collector $Name -EventName 'collector-start'
    try {
        & $ScriptBlock
        $added = $script:AccessRows.Count - $rowsBefore
        Add-CollectorStatus -Collector $Name -Status 'Succeeded' -StartedUtc $started -RowsBefore $rowsBefore
        Write-ScannerEvent -Level 'Info' -Collector $Name -EventName 'collector-end' -DurationMs ([int]([DateTime]::UtcNow - $started).TotalMilliseconds) -Data @{ status = 'Succeeded'; rowsAdded = $added; totalRows = $script:AccessRows.Count }
        Complete-ScannerPhase -Name $Name -Status 'Succeeded' -RowsAdded $added
    }
    catch {
        $message = $_.Exception.Message
        $status = 'Failed'
        if ($message -match '(?i)authorization|unauthori[sz]ed|forbidden|insufficient privileges|does not have authorization|authentication') { $status = 'Unauthorized' }
        elseif ($message -match '(?i)throttl|too many requests|429') { $status = 'Throttled' }
        elseif ($script:AccessRows.Count -gt $rowsBefore) { $status = 'PartiallyCollected' }
        $added = $script:AccessRows.Count - $rowsBefore
        Add-CollectorStatus -Collector $Name -Status $status -StartedUtc $started -RowsBefore $rowsBefore -Message $message
        Add-ErrorRow -Collector $Name -Status $status -Message $message
        $safeName = ($Name -replace '[^A-Za-z0-9_.-]', '_')
        Write-JsonFile -Path (Join-Path $errorsDir "$safeName.json") -Data @{ collector = $Name; status = $status; error = $message; generatedUtc = Get-UtcTimestamp }
        Write-ScannerEvent -Level 'Error' -Collector $Name -EventName 'collector-end' -Message $message -DurationMs ([int]([DateTime]::UtcNow - $started).TotalMilliseconds) -Data @{ status = $status; rowsAdded = $added }
        Complete-ScannerPhase -Name $Name -Status $status -RowsAdded $added -Message $message
        if ($FailFast -or (-not $Optional -and -not $ContinueOnError)) { throw }
    }
}

# Periodic "still alive" marker so a killed run still shows where it stopped.
function Write-CollectorHeartbeat {
    param([string]$Collector, [int]$Current, [int]$Total, [string]$Activity = 'working')
    Set-ScannerPhaseProgress -Current $Current -Total $Total -Activity $Activity
    if (-not $script:LastHeartbeat) { $script:LastHeartbeat = [DateTime]::UtcNow }
    if (([DateTime]::UtcNow - $script:LastHeartbeat).TotalSeconds -lt 60) { return }
    $script:LastHeartbeat = [DateTime]::UtcNow
    Write-ScannerHeartbeat -Collector $Collector -Rows $script:AccessRows.Count -Current $Current -Total $Total
    Write-ScannerEvent -Level 'Info' -Collector $Collector -EventName 'heartbeat' -Data @{
        current = $Current; total = $Total; rows = $script:AccessRows.Count
        workingSetMb = [math]::Round(([System.Diagnostics.Process]::GetCurrentProcess().WorkingSet64 / 1MB), 0)
    }
}

function Add-RoleDefinition {
    param([AllowNull()]$Role, [string]$Collector = 'AzureRoleDefinitions')
    if ($null -eq $Role) { return }
    $roleName = Get-PropertyText -Object $Role -Names @('roleName', 'roleDefinitionName', 'displayName')
    if (-not $roleName) { $roleName = Get-PropertyText -Object $Role -Names @('name') }
    $roleId = Get-PropertyText -Object $Role -Names @('id')
    $roleGuid = Get-PropertyText -Object $Role -Names @('name')
    $type = Get-PropertyText -Object $Role -Names @('type', 'roleType')
    $description = Get-PropertyText -Object $Role -Names @('description')
    $dataActionsCount = 0
    $actionsCount = 0
    $permissionsJson = ''
    $permissionsProp = $Role.PSObject.Properties['permissions']
    if ($permissionsProp -and $permissionsProp.Value) {
        $permissionsJson = ConvertTo-CompactJson -Value $permissionsProp.Value
        foreach ($permission in @($permissionsProp.Value)) {
            $dataActionsProp = $permission.PSObject.Properties['dataActions']
            $notDataActionsProp = $permission.PSObject.Properties['notDataActions']
            $actionsProp = $permission.PSObject.Properties['actions']
            if ($dataActionsProp) { $dataActionsCount += Get-ArrayCount -Value $dataActionsProp.Value }
            if ($notDataActionsProp) { $dataActionsCount += Get-ArrayCount -Value $notDataActionsProp.Value }
            if ($actionsProp) { $actionsCount += Get-ArrayCount -Value $actionsProp.Value }
        }
    }
    $category = if ($dataActionsCount -gt 0 -and $actionsCount -gt 0) { 'Mixed' } elseif ($dataActionsCount -gt 0) { 'DataPlane' } else { 'ControlPlane' }
    $assignableScopesProp = $Role.PSObject.Properties['assignableScopes']
    $assignableScopes = if ($assignableScopesProp) { $assignableScopesProp.Value } else { @() }
    $row = [pscustomobject]@{
        roleName = $roleName
        roleDefinitionId = $roleId
        roleDefinitionGuid = $roleGuid
        roleType = $type
        roleCategory = $category
        roleIsPrivileged = [string][bool](Test-PrivilegedRoleName -RoleName $roleName)
        roleHasDataActions = [string][bool]($dataActionsCount -gt 0)
        actionsCount = $actionsCount
        dataActionsCount = $dataActionsCount
        description = $description
        assignableScopes = ConvertTo-CompactJson -Value $assignableScopes
        permissions = $permissionsJson
        collector = $Collector
    }
    $keys = @((Get-RoleDefinitionKey -RoleDefinitionId $roleId), (Get-RoleDefinitionKey -RoleDefinitionId $roleGuid)) | Where-Object { $_ }
    foreach ($key in $keys) { $script:RoleByKey[$key] = $row }
    if ($roleName) { $script:RoleByName[$roleName.ToLowerInvariant()] = $row }
    $seenKey = if ($roleId) { $roleId.ToLowerInvariant() } elseif ($roleName) { $roleName.ToLowerInvariant() } else { '' }
    if (@($keys).Count -gt 0 -and $seenKey -and -not $script:RoleDefinitionSeen.ContainsKey($seenKey)) {
        $script:RoleDefinitionSeen[$seenKey] = $true
        [void]$script:RoleRows.Add($row)
    }
}

function Add-InferredRoleDefinition {
    param([string]$RoleName, [string]$RoleDefinitionId, [object]$RoleMeta, [string]$Collector)
    if (-not $RoleName -and -not $RoleDefinitionId) { return }
    $seenKey = if ($RoleDefinitionId) { $RoleDefinitionId.ToLowerInvariant() } else { $RoleName.ToLowerInvariant() }
    if ($script:RoleDefinitionSeen.ContainsKey($seenKey)) { return }
    $script:RoleDefinitionSeen[$seenKey] = $true
    [void]$script:RoleRows.Add([pscustomobject]@{
        roleName = $RoleName
        roleDefinitionId = $RoleDefinitionId
        roleDefinitionGuid = Get-RoleDefinitionKey -RoleDefinitionId $RoleDefinitionId
        roleType = 'Observed'
        roleCategory = $RoleMeta.roleCategory
        roleIsPrivileged = [string]$RoleMeta.roleIsPrivileged
        roleHasDataActions = [string]$RoleMeta.roleHasDataActions
        actionsCount = ''
        dataActionsCount = ''
        description = 'Observed from role assignment; full role definition was not retrieved.'
        assignableScopes = ''
        permissions = ''
        collector = $Collector
    })
}

function Get-RoleMeta {
    param([string]$RoleDefinitionId, [string]$RoleName)
    $key = Get-RoleDefinitionKey -RoleDefinitionId $RoleDefinitionId
    if ($key -and $script:RoleByKey.ContainsKey($key)) { return $script:RoleByKey[$key] }
    $nameKey = ([string]$RoleName).Trim().ToLowerInvariant()
    if ($nameKey -and $script:RoleByName.ContainsKey($nameKey)) { return $script:RoleByName[$nameKey] }
    return [pscustomobject]@{
        roleCategory = if ($RoleName -match '(?i)\bdata\b|Storage Blob|Storage File|Key Vault Secrets|Event Hubs Data|Service Bus Data') { 'DataPlane' } else { 'ControlPlane' }
        roleIsPrivileged = [string][bool](Test-PrivilegedRoleName -RoleName $RoleName)
        roleHasDataActions = [string][bool]($RoleName -match '(?i)\bdata\b|Storage Blob|Storage File|Key Vault Secrets|Key Vault Crypto|Event Hubs Data|Service Bus Data')
    }
}

function Add-ScopeRow {
    param([string]$Scope, [string]$ScopeType, [string]$DisplayName = '', [string]$SubscriptionId = '', [string]$SubscriptionName = '', [string]$ManagementGroupId = '', [string]$ManagementGroupName = '', [string]$ResourceGroup = '', [string]$ResourceType = '', [string]$ResourceName = '', [string]$Collector = '')
    [void]$script:ScopeRows.Add([pscustomobject]@{
        scope = $Scope
        scopeType = $ScopeType
        displayName = $DisplayName
        subscriptionId = $SubscriptionId
        subscriptionName = $SubscriptionName
        managementGroupId = $ManagementGroupId
        managementGroupName = $ManagementGroupName
        resourceGroup = $ResourceGroup
        resourceType = $ResourceType
        resourceName = $ResourceName
        collector = $Collector
    })
}

function Add-PrincipalResolution {
    param([object]$Principal)
    if ($null -eq $Principal) { return }
    $id = Get-PropertyText -Object $Principal -Names @('id')
    if (-not $id -or $script:PrincipalById.ContainsKey($id)) { return }
    $odataType = Get-PropertyText -Object $Principal -Names @('@odata.type')
    $principalTypeValue = if ($odataType) { $odataType } else { Get-PropertyText -Object $Principal -Names @('principalType', 'type') }
    $type = ConvertTo-PrincipalType $principalTypeValue
    $row = [pscustomobject]@{
        principalId = $id
        principalType = $type
        displayName = Get-PropertyText -Object $Principal -Names @('displayName', 'principalName')
        userPrincipalName = Get-PropertyText -Object $Principal -Names @('userPrincipalName', 'mail')
        appId = Get-PropertyText -Object $Principal -Names @('appId')
        accountEnabled = Get-PropertyText -Object $Principal -Names @('accountEnabled')
        source = 'Graph'
    }
    $script:PrincipalById[$id] = $row
    [void]$script:PrincipalRows.Add($row)
}

function Add-AccessRow {
    param([object]$Row, [switch]$Direct, [switch]$Effective, [switch]$GroupDerived, [switch]$OwnerDerived)
    $key = @($Row.collector, $Row.assignmentId, $Row.scope, $Row.roleName, $Row.principalId, $Row.effectivePrincipalId, $Row.accessPath) -join '|'
    if ($script:AccessSeen.ContainsKey($key)) { return }
    $script:AccessSeen[$key] = $true
    [void]$script:AccessRows.Add($Row)
    if ($Direct) { [void]$script:DirectRows.Add($Row) }
    if ($Effective -or $Direct -or $GroupDerived -or $OwnerDerived) { [void]$script:EffectiveRows.Add($Row) }
    if ($GroupDerived) { [void]$script:GroupRows.Add($Row) }
    if ($OwnerDerived) { [void]$script:OwnerRows.Add($Row) }
}

function Convert-RoleAssignmentToRow {
    param([object]$Assignment, [string]$Collector, [string]$Surface = 'Azure RBAC', [string]$AccessModel = 'AzureRBAC', [string]$SubscriptionId = '', [string]$SubscriptionName = '', [string]$ManagementGroupId = '', [string]$ManagementGroupName = '')
    $roleName = Get-PropertyText -Object $Assignment -Names @('roleDefinitionName', 'roleName')
    $roleDefinitionId = Get-PropertyText -Object $Assignment -Names @('roleDefinitionId')
    $scope = Get-PropertyText -Object $Assignment -Names @('scope')
    $role = Get-RoleMeta -RoleDefinitionId $roleDefinitionId -RoleName $roleName
    Add-InferredRoleDefinition -RoleName $roleName -RoleDefinitionId $roleDefinitionId -RoleMeta $role -Collector $Collector
    $principalId = Get-PropertyText -Object $Assignment -Names @('principalId')
    $principalName = Get-PropertyText -Object $Assignment -Names @('principalName', 'signInName')
    $principalType = ConvertTo-PrincipalType (Get-PropertyText -Object $Assignment -Names @('principalType'))
    if (-not $AccessModel -or $AccessModel -eq 'AzureRBAC') {
        if ([string]$role.roleHasDataActions -eq 'True' -or [string]$role.roleCategory -eq 'DataPlane') { $AccessModel = 'AzureDataPlaneRBAC' }
    }
    return New-AccessRow `
        -Surface $Surface -AccessModel $AccessModel -Collector $Collector -AssignmentState 'Active' -AssignmentType 'RoleAssignment' `
        -PrincipalId $principalId -PrincipalType $principalType -PrincipalDisplayName $principalName -PrincipalUserPrincipalName $(if ($principalType -eq 'User') { $principalName } else { '' }) `
        -RoleName $roleName -RoleDefinitionId $roleDefinitionId -RoleCategory $role.roleCategory -RoleIsPrivileged ([bool]::Parse([string]$role.roleIsPrivileged)) -RoleHasDataActions ([bool]::Parse([string]$role.roleHasDataActions)) `
        -Scope $scope -ScopeType (Get-ScopeType -Scope $scope) -ScopeDisplayName $scope `
        -TenantId $script:TenantId -ManagementGroupId $ManagementGroupId -ManagementGroupName $ManagementGroupName -SubscriptionId $SubscriptionId -SubscriptionName $SubscriptionName `
        -AssignmentId (Get-PropertyText -Object $Assignment -Names @('id')) -AssignmentCreatedOn (Get-PropertyText -Object $Assignment -Names @('createdOn', 'createdDateTime')) -AssignmentUpdatedOn (Get-PropertyText -Object $Assignment -Names @('updatedOn', 'updatedDateTime')) `
        -Condition (Get-PropertyText -Object $Assignment -Names @('condition')) -ConditionVersion (Get-PropertyText -Object $Assignment -Names @('conditionVersion')) `
        -IsInherited (Get-PropertyText -Object $Assignment -Names @('isInherited')) -SourceApi 'az role assignment list'
}

function Add-RoleAssignmentsForScope {
    param([string]$Collector, [string]$Scope, [string]$SubscriptionId = '', [string]$SubscriptionName = '', [string]$ManagementGroupId = '', [string]$ManagementGroupName = '', [switch]$IncludeInherited)
    # az rejects --all together with --scope ('group or scope are not required when --all is used').
    $roleAssignmentArgs = @('role', 'assignment', 'list', '--scope', $Scope)
    if ($IncludeInherited) { $roleAssignmentArgs += '--include-inherited' }
    if ($SubscriptionId) { $roleAssignmentArgs += @('--subscription', $SubscriptionId) }
    try { $assignments = Invoke-AzJsonWithTimeout -Arguments $roleAssignmentArgs -TimeoutSeconds 180 -Collector $Collector -Scope $Scope }
    catch {
        Add-ErrorRow -Collector $Collector -Status 'PartiallyCollected' -Scope $Scope -Api 'az role assignment list' -Message $_.Exception.Message
        return
    }
    foreach ($assignment in @(Expand-FlatArray -InputObject $assignments)) {
        if (-not (Test-RoleAssignmentObject -Assignment $assignment)) { continue }
        $row = Convert-RoleAssignmentToRow -Assignment $assignment -Collector $Collector -SubscriptionId $SubscriptionId -SubscriptionName $SubscriptionName -ManagementGroupId $ManagementGroupId -ManagementGroupName $ManagementGroupName
        Add-AccessRow -Row $row -Direct -Effective
    }
}

# Depth 10 means "no limit", which Graph answers in one transitiveMembers call.
# A smaller limit requires walking direct members level by level.
function Get-GroupMembership {
    param([string]$GroupId, [int]$MaxDepth = 10, [int]$MaxMembers = 0)
    $encoded = [uri]::EscapeDataString($GroupId)
    $select = 'id,displayName,userPrincipalName,mail,appId'
    $members = [System.Collections.Generic.List[object]]::new()
    $truncated = $false

    if ($MaxDepth -ge 10) {
        $url = "https://graph.microsoft.com/v1.0/groups/$encoded/transitiveMembers?`$select=$select&`$top=999"
        foreach ($member in @(Get-GraphPagedItems -Url $url -Collector 'GroupExpansion')) {
            if ($MaxMembers -gt 0 -and $members.Count -ge $MaxMembers) { $truncated = $true; break }
            [void]$members.Add($member)
        }
        return [pscustomobject]@{ Members = @($members); Truncated = $truncated }
    }

    $seen = @{ $GroupId = $true }
    $frontier = @($GroupId)
    for ($depth = 1; $depth -le $MaxDepth; $depth++) {
        $next = [System.Collections.Generic.List[object]]::new()
        foreach ($current in $frontier) {
            $currentEncoded = [uri]::EscapeDataString([string]$current)
            $url = "https://graph.microsoft.com/v1.0/groups/$currentEncoded/members?`$select=$select&`$top=999"
            foreach ($member in @(Get-GraphPagedItems -Url $url -Collector 'GroupExpansion')) {
                $memberId = Get-PropertyText -Object $member -Names @('id')
                if (-not $memberId -or $seen.ContainsKey($memberId)) { continue }
                $seen[$memberId] = $true
                if ($MaxMembers -gt 0 -and $members.Count -ge $MaxMembers) { $truncated = $true; break }
                [void]$members.Add($member)
                if ((ConvertTo-PrincipalType (Get-PropertyText -Object $member -Names @('@odata.type'))) -eq 'Group') { [void]$next.Add($memberId) }
            }
            if ($truncated) { break }
        }
        if ($truncated -or $next.Count -eq 0) { break }
        $frontier = @($next)
    }
    return [pscustomobject]@{ Members = @($members); Truncated = $truncated }
}

function Get-CoverageSummary {
    return [ordered]@{
        generatedUtc = Get-UtcTimestamp
        runDir = $context.RunDir
        subscriptionsDiscovered = $script:Subscriptions.Count
        managementGroupsDiscovered = $script:ManagementGroups.Count
        resourceGroupsDiscovered = $script:ResourceGroups.Count
        resourcesDiscovered = $script:Resources.Count
        scopesDiscovered = $script:ScopeRows.Count
        roleDefinitionsDiscovered = $script:RoleRows.Count
        directAssignments = $script:DirectRows.Count
        effectiveAssignments = $script:EffectiveRows.Count
        groupDerivedAssignments = $script:GroupRows.Count
        servicePrincipalOwnerRows = $script:OwnerRows.Count
        collectorFailures = @($script:StatusRows | Where-Object { $_.status -ne 'Succeeded' -and $_.status -ne 'Skipped' }).Count
        skippedCollectors = @($script:StatusRows | Where-Object { $_.status -eq 'Skipped' }).Count
        options = @{
            subscriptionIds = @($SubscriptionIds)
            managementGroupIds = @($ManagementGroupIds)
            resourceTypes = @($ResourceTypes)
            resourceLevel = $doResourceLevel
            childDataScopes = $doChildDataScopes
            pim = $doPim
            billing = $doBilling
            reservations = $doReservations
            classicAdmins = $doClassicAdmins
            keyVaultAccessPolicies = $doKeyVaultAccessPolicies
            groupExpansion = $doGroupExpansion
            fullRoleDefinitionScan = [bool]$FullRoleDefinitionScan
            includeOtherTenants = [bool]$IncludeOtherTenants
            deepScopeScan = [bool]$DeepScopeScan
            maxGroupDepth = $MaxGroupDepth
            maxGroupMembers = $MaxGroupMembers
            parallel = $Parallel
            limitResources = $LimitResources
        }
    }
}

# Written from the WorkbookReport collector AND from finally, so an aborted run still
# leaves behind everything needed to diagnose it.
function Write-DiagnosticOutputs {
    Export-ObjectList -Path (Join-Path $context.OutDir 'collectorStatus.csv') -Columns @('collector','status','startedUtc','endedUtc','durationSeconds','rowsAdded','totalRows','message') -Rows @($script:StatusRows)
    Export-ObjectList -Path (Join-Path $context.OutDir 'errorsWarnings.csv') -Columns @('collector','status','scope','api','errorCode','errorMessage','generatedUtc') -Rows @($script:ErrorRows)
    Write-JsonFile -Path (Join-Path $context.OutDir 'coverageSummary.json') -Data (Get-CoverageSummary) -Depth 10
    Write-JsonFile -Path (Join-Path $context.OutDir 'counts.json') -Data ([ordered]@{
        generatedUtc = Get-UtcTimestamp
        accessRows = $script:AccessRows.Count
        directRows = $script:DirectRows.Count
        effectiveRows = $script:EffectiveRows.Count
        groupDerivedRows = $script:GroupRows.Count
        ownerRows = $script:OwnerRows.Count
        principalRows = $script:PrincipalRows.Count
        groupExpansionRows = $script:GroupExpansionRows.Count
        roleRows = $script:RoleRows.Count
        scopeRows = $script:ScopeRows.Count
        errorRows = $script:ErrorRows.Count
    }) -Depth 4
}

Write-ScannerLine -Text ('All Azure access scan  run {0}' -f $context.RunId) -Level 'Header'
Write-ScannerLine -Text ('Run directory: {0}' -f $context.RunDir) -Level 'Detail'
Write-Host "RUN_DIR=$($context.RunDir)"
if (-not $NoTranscript) {
    Start-Transcript -Path (Join-Path $context.LogDir 'all-azure-access.log') -Force | Out-Null
}

Write-JsonFile -Path (Join-Path $context.LogDir 'environment.json') -Data (Get-ScannerEnvironment -Extra @{
    runId = $context.RunId; jobId = $context.JobId; scannerRoot = $PSScriptRoot
}) -Depth 6
Write-JsonFile -Path (Join-Path $context.LogDir 'parameters.json') -Data ([ordered]@{
    generatedUtc = Get-UtcTimestamp
    bound = ($PSBoundParameters.Keys | Sort-Object)
    effective = [ordered]@{
        subscriptionIds = @($SubscriptionIds); managementGroupIds = @($ManagementGroupIds); resourceTypes = @($ResourceTypes)
        resourceLevel = $doResourceLevel; childDataScopes = $doChildDataScopes; pim = $doPim; billing = $doBilling
        reservations = $doReservations; classicAdmins = $doClassicAdmins; keyVaultAccessPolicies = $doKeyVaultAccessPolicies
        groupExpansion = $doGroupExpansion; maxGroupDepth = $MaxGroupDepth; maxGroupMembers = $MaxGroupMembers
        parallel = $Parallel; limitResources = $LimitResources; deepScopeScan = [bool]$DeepScopeScan
        includeOtherTenants = [bool]$IncludeOtherTenants; fullRoleDefinitionScan = [bool]$FullRoleDefinitionScan
        logLevel = $LogLevel; redactLogs = [bool]$RedactLogs; noHttp = [bool]$NoHttp; emitJson = [bool]$EmitJson
    }
}) -Depth 6

try {
    Invoke-Collector -Name 'StartupValidation' -ScriptBlock {
        Resolve-AzCommand | Out-Null
        $account = Invoke-AzJson -Arguments @('account', 'show') -AllowError -Collector 'StartupValidation'
        if (-not $account) { throw 'Azure CLI is not logged in or account show returned no data.' }
        $script:TenantId = Get-PropertyText -Object $account -Names @('tenantId')
        Add-ScopeRow -Scope '/' -ScopeType 'tenantRoot' -DisplayName 'Tenant Root' -Collector 'StartupValidation'

        $script:HttpReady = $false
        if (-not $NoHttp) {
            $script:HttpReady = Test-ScannerHttpAvailable -Resource 'https://graph.microsoft.com/'
            if (-not $script:HttpReady) {
                Disable-ScannerHttp
                Add-ErrorRow -Collector 'StartupValidation' -Status 'Skipped' -ErrorCode 'HttpUnavailable' `
                    -Message 'Could not acquire a Microsoft Graph token directly; falling back to one az process per Graph call (much slower).'
            }
        }
        Write-ScannerEvent -Level 'Info' -Collector 'StartupValidation' -EventName 'transport' -Data @{
            directHttp = [bool]$script:HttpReady; parallel = $Parallel
        }
        Write-ScannerLine -Text ('     transport: {0} | parallel: {1}' -f $(if ($script:HttpReady) { 'direct HTTP + cached token' } else { 'az CLI per call' }), $Parallel) -Level 'Detail'
    }

    Invoke-Collector -Name 'Subscriptions' -ScriptBlock {
        $discovered = @(Get-AzSubscriptions -SubscriptionIds $SubscriptionIds -IncludeAllStates | Where-Object { [string]$_.state -eq 'Enabled' -or $SubscriptionIds.Count -gt 0 })
        if (-not $IncludeOtherTenants -and $script:TenantId -and $SubscriptionIds.Count -eq 0) {
            foreach ($sub in @($discovered | Where-Object { $_.tenantId -and [string]$_.tenantId -ne $script:TenantId })) {
                Add-ErrorRow -Collector 'Subscriptions' -Status 'Skipped' -Scope ("/subscriptions/{0}" -f $sub.id) -Api 'az account list' -ErrorCode 'ForeignTenant' `
                    -Message ("Subscription is homed in tenant {0}, not the signed-in tenant {1}; token acquisition would fail. Re-run with -IncludeOtherTenants to attempt it." -f $sub.tenantId, $script:TenantId)
            }
            $discovered = @($discovered | Where-Object { -not $_.tenantId -or [string]$_.tenantId -eq $script:TenantId })
        }
        $script:Subscriptions = $discovered
        if ($script:Subscriptions.Count -eq 0) { throw 'No enabled Azure subscriptions were returned.' }
        foreach ($sub in $script:Subscriptions) {
            Add-ScopeRow -Scope ("/subscriptions/{0}" -f $sub.id) -ScopeType 'subscription' -DisplayName $sub.name -SubscriptionId $sub.id -SubscriptionName $sub.name -Collector 'Subscriptions'
        }
    }

    Invoke-Collector -Name 'ManagementGroups' -Optional -ScriptBlock {
        $items = Invoke-AzJson -Arguments @('account', 'management-group', 'list') -AllowError -Collector 'ManagementGroups'
        $script:ManagementGroups = @(Expand-FlatArray -InputObject $items)
        if ($ManagementGroupIds.Count -gt 0) {
            $wanted = @($ManagementGroupIds | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })
            $script:ManagementGroups = @($script:ManagementGroups | Where-Object { $wanted -contains ([string]$_.name) -or $wanted -contains ([string]$_.id) })
        }
        foreach ($mg in $script:ManagementGroups) {
            $mgId = Get-PropertyText -Object $mg -Names @('name', 'id')
            $displayName = Get-PropertyText -Object $mg -Names @('displayName', 'name')
            Add-ScopeRow -Scope ("/providers/Microsoft.Management/managementGroups/{0}" -f $mgId) -ScopeType 'managementGroup' -DisplayName $displayName -ManagementGroupId $mgId -ManagementGroupName $displayName -Collector 'ManagementGroups'
        }
    }

    Invoke-Collector -Name 'AzureRoleDefinitions' -Optional -ScriptBlock {
        $subScanCount = 0
        foreach ($sub in $script:Subscriptions) {
            try {
                $defs = Invoke-AzJsonWithTimeout -Arguments @('role', 'definition', 'list', '--subscription', $sub.id) -TimeoutSeconds 180
                foreach ($def in @(Expand-FlatArray -InputObject $defs)) { Add-RoleDefinition -Role $def }
                $subScanCount++
                if (-not $FullRoleDefinitionScan -and $script:RoleRows.Count -gt 0) { break }
            }
            catch {
                Add-ErrorRow -Collector 'AzureRoleDefinitions' -Status 'PartiallyCollected' -Scope ("/subscriptions/{0}" -f $sub.id) -Api 'az role definition list' -Message $_.Exception.Message
                if ($FullRoleDefinitionScan) { continue }
            }
        }
        if ($FullRoleDefinitionScan) {
            foreach ($mg in $script:ManagementGroups) {
                $mgId = Get-PropertyText -Object $mg -Names @('name', 'id')
                if (-not $mgId) { continue }
                $scope = "/providers/Microsoft.Management/managementGroups/$mgId"
                try {
                    $defs = Invoke-AzJsonWithTimeout -Arguments @('role', 'definition', 'list', '--scope', $scope) -TimeoutSeconds 180
                    foreach ($def in @(Expand-FlatArray -InputObject $defs)) { Add-RoleDefinition -Role $def -Collector 'AzureRoleDefinitions.ManagementGroup' }
                }
                catch {
                    Add-ErrorRow -Collector 'AzureRoleDefinitions' -Status 'PartiallyCollected' -Scope $scope -Api 'az role definition list' -Message $_.Exception.Message
                }
            }
        }
        if ($script:RoleRows.Count -eq 0) { Add-ErrorRow -Collector 'AzureRoleDefinitions' -Status 'PartiallyCollected' -Message 'No role definitions were retrieved; assignments will use inferred role metadata.' }
    }

    Invoke-Collector -Name 'AzureTenantRootRbac' -Optional -ScriptBlock {
        Add-RoleAssignmentsForScope -Collector 'AzureTenantRootRbac' -Scope '/' -IncludeInherited
    }

    Invoke-Collector -Name 'ManagementGroupRbac' -Optional -ScriptBlock {
        $index = 0
        foreach ($mg in $script:ManagementGroups) {
            $index++
            $mgId = Get-PropertyText -Object $mg -Names @('name', 'id')
            $displayName = Get-PropertyText -Object $mg -Names @('displayName', 'name')
            if (-not $mgId) { continue }
            Write-CollectorHeartbeat -Collector 'ManagementGroupRbac' -Current $index -Total $script:ManagementGroups.Count -Activity $displayName
            Add-RoleAssignmentsForScope -Collector 'ManagementGroupRbac' -Scope "/providers/Microsoft.Management/managementGroups/$mgId" -ManagementGroupId $mgId -ManagementGroupName $displayName -IncludeInherited
        }
    }

    Invoke-Collector -Name 'AzureSubscriptionRbac' -ScriptBlock {
        $jobs = @($script:Subscriptions | ForEach-Object {
            @{ Key = [string]$_.id; Arguments = @('role', 'assignment', 'list', '--all', '--include-inherited', '--subscription', $_.id) }
        })
        $total = $jobs.Count
        $results = Invoke-AzJsonParallel -Jobs $jobs -Throttle $Parallel -TimeoutSeconds 900 -Collector 'AzureSubscriptionRbac' -OnProgress {
            param($done, $count)
            Write-CollectorHeartbeat -Collector 'AzureSubscriptionRbac' -Current $done -Total $count -Activity 'enumerating subscriptions'
        }
        foreach ($sub in $script:Subscriptions) {
            $result = $results[[string]$sub.id]
            if (-not $result -or -not $result.Ok) {
                $message = if ($result) { $result.Error } else { 'No result returned for subscription.' }
                if ($message -match '(?i)AADSTS|interactive authentication is needed') { $script:UnreachableSubscriptions[[string]$sub.id] = $true }
                Add-ErrorRow -Collector 'AzureSubscriptionRbac' -Status 'PartiallyCollected' -Scope ("/subscriptions/{0}" -f $sub.id) -Api 'az role assignment list' -Message $message
                continue
            }
            # This one call returns every assignment in the subscription, at every nested scope.
            $script:SubscriptionRbacCovered[[string]$sub.id] = $true
            foreach ($assignment in @(Expand-FlatArray -InputObject $result.Data)) {
                if (-not (Test-RoleAssignmentObject -Assignment $assignment)) { continue }
                $row = Convert-RoleAssignmentToRow -Assignment $assignment -Collector 'AzureSubscriptionRbac' -SubscriptionId $sub.id -SubscriptionName $sub.name
                Add-AccessRow -Row $row -Direct -Effective
            }
        }
        Set-ScannerPhaseProgress -Current $total -Total $total -Activity 'done'
    }

    Invoke-Collector -Name 'ScopeInventory' -Optional -ScriptBlock {
        $targets = @($script:Subscriptions | Where-Object { -not $script:UnreachableSubscriptions.ContainsKey([string]$_.id) })
        $jobs = [System.Collections.Generic.List[object]]::new()
        foreach ($sub in $targets) {
            [void]$jobs.Add(@{ Key = ('rg|' + $sub.id); Arguments = @('group', 'list', '--subscription', $sub.id, '--query', '[].{id:id,name:name}') })
            if ($doResourceLevel) {
                [void]$jobs.Add(@{ Key = ('res|' + $sub.id); Arguments = @('resource', 'list', '--subscription', $sub.id, '--query', '[].{id:id,name:name,type:type,resourceGroup:resourceGroup}') })
            }
        }
        $results = Invoke-AzJsonParallel -Jobs @($jobs) -Throttle $Parallel -TimeoutSeconds 900 -Collector 'ScopeInventory' -OnProgress {
            param($done, $count)
            Write-CollectorHeartbeat -Collector 'ScopeInventory' -Current $done -Total $count -Activity 'inventorying scopes'
        }

        foreach ($sub in $targets) {
            $rgResult = $results[('rg|' + $sub.id)]
            if ($rgResult -and $rgResult.Ok) {
                foreach ($group in @(Expand-FlatArray -InputObject $rgResult.Data)) {
                    $rgName = Get-PropertyText -Object $group -Names @('name')
                    $rgScope = Get-PropertyText -Object $group -Names @('id')
                    [void]$script:ResourceGroups.Add([pscustomobject]@{ subscriptionId = $sub.id; subscriptionName = $sub.name; resourceGroup = $rgName; scope = $rgScope })
                    Add-ScopeRow -Scope $rgScope -ScopeType 'resourceGroup' -DisplayName $rgName -SubscriptionId $sub.id -SubscriptionName $sub.name -ResourceGroup $rgName -Collector 'ScopeInventory'
                }
            }
            elseif ($rgResult) {
                Add-ErrorRow -Collector 'ScopeInventory' -Status 'PartiallyCollected' -Scope ("/subscriptions/{0}" -f $sub.id) -Api 'az group list' -Message $rgResult.Error
            }

            if (-not $doResourceLevel) { continue }
            $resResult = $results[('res|' + $sub.id)]
            if (-not $resResult -or -not $resResult.Ok) {
                if ($resResult) { Add-ErrorRow -Collector 'ScopeInventory' -Status 'PartiallyCollected' -Scope ("/subscriptions/{0}" -f $sub.id) -Api 'az resource list' -Message $resResult.Error }
                continue
            }
            $resourceArray = @(Expand-FlatArray -InputObject $resResult.Data)
            if ($ResourceTypes.Count -gt 0) {
                $wantedTypes = @($ResourceTypes | ForEach-Object { ([string]$_).Trim().ToLowerInvariant() } | Where-Object { $_ })
                $resourceArray = @($resourceArray | Where-Object { $wantedTypes -contains ([string]$_.type).ToLowerInvariant() })
            }
            if ($LimitResources -gt 0) { $resourceArray = @($resourceArray | Select-Object -First $LimitResources) }
            foreach ($resource in $resourceArray) {
                $resourceScope = Get-PropertyText -Object $resource -Names @('id')
                $resourceName = Get-PropertyText -Object $resource -Names @('name')
                $resourceType = Get-PropertyText -Object $resource -Names @('type')
                $rgName = Get-ResourceGroupFromScope -Scope $resourceScope
                [void]$script:Resources.Add([pscustomobject]@{ subscriptionId = $sub.id; subscriptionName = $sub.name; resourceGroup = $rgName; resourceId = $resourceScope; name = $resourceName; type = $resourceType })
                Add-ScopeRow -Scope $resourceScope -ScopeType 'resource' -DisplayName $resourceName -SubscriptionId $sub.id -SubscriptionName $sub.name -ResourceGroup $rgName -ResourceType $resourceType -ResourceName $resourceName -Collector 'ScopeInventory'
            }
        }
        Write-ScannerEvent -Level 'Info' -Collector 'ScopeInventory' -EventName 'inventory' -Data @{
            subscriptions = $targets.Count; resourceGroups = $script:ResourceGroups.Count; resources = $script:Resources.Count
        }
    }

    Invoke-Collector -Name 'AzureResourceGroupRbac' -Optional -ScriptBlock {
        $covered = 0
        $index = 0
        foreach ($rg in $script:ResourceGroups) {
            $index++
            if (-not $rg.scope) { continue }
            if (-not $DeepScopeScan -and $script:SubscriptionRbacCovered.ContainsKey([string]$rg.subscriptionId)) { $covered++; continue }
            Write-CollectorHeartbeat -Collector 'AzureResourceGroupRbac' -Current $index -Total $script:ResourceGroups.Count -Activity $rg.resourceGroup
            Add-RoleAssignmentsForScope -Collector 'AzureResourceGroupRbac' -Scope $rg.scope -SubscriptionId $rg.subscriptionId -SubscriptionName $rg.subscriptionName -IncludeInherited
        }
        if ($covered -gt 0) {
            Add-ErrorRow -Collector 'AzureResourceGroupRbac' -Status 'Skipped' -Api 'az role assignment list' -ErrorCode 'AlreadyCovered' `
                -Message ("{0} resource groups were already enumerated by AzureSubscriptionRbac; use -DeepScopeScan to query each scope individually." -f $covered)
        }
    }

    if ($doResourceLevel) {
        Invoke-Collector -Name 'AzureResourceRbac' -Optional -ScriptBlock {
            $covered = 0
            $index = 0
            foreach ($resource in $script:Resources) {
                $index++
                if (-not $resource.resourceId) { continue }
                if (-not $DeepScopeScan -and $script:SubscriptionRbacCovered.ContainsKey([string]$resource.subscriptionId)) { $covered++; continue }
                Write-CollectorHeartbeat -Collector 'AzureResourceRbac' -Current $index -Total $script:Resources.Count -Activity $resource.name
                Add-RoleAssignmentsForScope -Collector 'AzureResourceRbac' -Scope $resource.resourceId -SubscriptionId $resource.subscriptionId -SubscriptionName $resource.subscriptionName -IncludeInherited
            }
            if ($covered -gt 0) {
                Add-ErrorRow -Collector 'AzureResourceRbac' -Status 'Skipped' -Api 'az role assignment list' -ErrorCode 'AlreadyCovered' `
                    -Message ("{0} resources were already enumerated by AzureSubscriptionRbac; use -DeepScopeScan to query each scope individually." -f $covered)
            }
        }
    }
    else {
        Add-CollectorStatus -Collector 'AzureResourceRbac' -Status 'Skipped' -StartedUtc ([DateTime]::UtcNow) -RowsBefore $script:AccessRows.Count -Message 'Skipped by -SkipResourceLevel'
    }

    if ($doChildDataScopes) {
        Invoke-Collector -Name 'StorageChildScopeRbac' -Optional -ScriptBlock {
            $storageAccounts = @($script:Resources | Where-Object { [string]$_.type -eq 'Microsoft.Storage/storageAccounts' })
            if ($storageAccounts.Count -eq 0) { return }
            $jobs = [System.Collections.Generic.List[object]]::new()
            foreach ($sa in $storageAccounts) {
                [void]$jobs.Add(@{ Key = ('c|' + $sa.resourceId); Arguments = @('storage', 'container-rm', 'list', '--storage-account', $sa.name, '--resource-group', $sa.resourceGroup, '--subscription', $sa.subscriptionId, '--query', '[].{name:name}') })
                [void]$jobs.Add(@{ Key = ('s|' + $sa.resourceId); Arguments = @('storage', 'share-rm', 'list', '--storage-account', $sa.name, '--resource-group', $sa.resourceGroup, '--subscription', $sa.subscriptionId, '--query', '[].{name:name}') })
            }
            $results = Invoke-AzJsonParallel -Jobs @($jobs) -Throttle $Parallel -TimeoutSeconds 600 -Collector 'StorageChildScopeRbac' -OnProgress {
                param($done, $count)
                Write-CollectorHeartbeat -Collector 'StorageChildScopeRbac' -Current $done -Total $count -Activity 'listing containers and shares'
            }
            foreach ($sa in $storageAccounts) {
                $childScopeCovered = (-not $DeepScopeScan -and $script:SubscriptionRbacCovered.ContainsKey([string]$sa.subscriptionId))
                $containerResult = $results[('c|' + $sa.resourceId)]
                if ($containerResult -and $containerResult.Ok) {
                    foreach ($container in @(Expand-FlatArray -InputObject $containerResult.Data)) {
                        $containerName = Get-PropertyText -Object $container -Names @('name')
                        if (-not $containerName) { continue }
                        $scope = "/subscriptions/$($sa.subscriptionId)/resourceGroups/$($sa.resourceGroup)/providers/Microsoft.Storage/storageAccounts/$($sa.name)/blobServices/default/containers/$containerName"
                        Add-ScopeRow -Scope $scope -ScopeType 'storageChildScope' -DisplayName $containerName -SubscriptionId $sa.subscriptionId -SubscriptionName $sa.subscriptionName -ResourceGroup $sa.resourceGroup -ResourceType 'Microsoft.Storage/storageAccounts/blobServices/containers' -ResourceName $sa.name -Collector 'StorageChildScopeRbac'
                        if ($childScopeCovered) { continue }
                        Add-RoleAssignmentsForScope -Collector 'StorageChildScopeRbac' -Scope $scope -SubscriptionId $sa.subscriptionId -SubscriptionName $sa.subscriptionName -IncludeInherited
                    }
                }
                $shareResult = $results[('s|' + $sa.resourceId)]
                if ($shareResult -and $shareResult.Ok) {
                    foreach ($share in @(Expand-FlatArray -InputObject $shareResult.Data)) {
                        $shareName = Get-PropertyText -Object $share -Names @('name')
                        if (-not $shareName) { continue }
                        $scope = "/subscriptions/$($sa.subscriptionId)/resourceGroups/$($sa.resourceGroup)/providers/Microsoft.Storage/storageAccounts/$($sa.name)/fileServices/default/shares/$shareName"
                        Add-ScopeRow -Scope $scope -ScopeType 'storageChildScope' -DisplayName $shareName -SubscriptionId $sa.subscriptionId -SubscriptionName $sa.subscriptionName -ResourceGroup $sa.resourceGroup -ResourceType 'Microsoft.Storage/storageAccounts/fileServices/shares' -ResourceName $sa.name -ChildResourceType 'fileShare' -ChildResourceName $shareName -Collector 'StorageChildScopeRbac'
                        if ($childScopeCovered) { continue }
                        Add-RoleAssignmentsForScope -Collector 'StorageChildScopeRbac' -Scope $scope -SubscriptionId $sa.subscriptionId -SubscriptionName $sa.subscriptionName -IncludeInherited
                    }
                }
            }
        }
    }
    else {
        Add-CollectorStatus -Collector 'StorageChildScopeRbac' -Status 'Skipped' -StartedUtc ([DateTime]::UtcNow) -RowsBefore $script:AccessRows.Count -Message 'Skipped by -SkipChildDataScopes'
    }

    Invoke-Collector -Name 'EntraRoleAssignments' -Optional -ScriptBlock {
        $url = 'https://graph.microsoft.com/v1.0/roleManagement/directory/roleAssignments?$expand=roleDefinition($select=id,displayName)&$top=999'
        $assignments = Get-GraphPagedItems -Url $url -Collector 'EntraRoleAssignments'
        foreach ($assignment in $assignments) {
            $roleName = Get-PropertyText -Object $assignment.roleDefinition -Names @('displayName')
            $roleId = Get-PropertyText -Object $assignment.roleDefinition -Names @('id')
            $principalId = Get-PropertyText -Object $assignment -Names @('principalId')
            $principalType = ConvertTo-PrincipalType (Get-PropertyText -Object $assignment -Names @('principalType'))
            $scope = Get-PropertyText -Object $assignment -Names @('directoryScopeId', 'appScopeId')
            if (-not $scope) { $scope = '/' }
            $row = New-AccessRow -Surface 'Microsoft Entra ID RBAC' -AccessModel 'EntraIDRBAC' -Collector 'EntraRoleAssignments' -AssignmentState 'Active' -AssignmentType 'DirectoryRoleAssignment' `
                -PrincipalId $principalId -PrincipalType $principalType -PrincipalDisplayName $principalId -RoleName $roleName -RoleDefinitionId $roleId -RoleCategory 'ControlPlane' -RoleIsPrivileged (Test-PrivilegedRoleName -RoleName $roleName) -RoleHasDataActions $false `
                -Scope $scope -ScopeType 'directory' -ScopeDisplayName $scope -TenantId $script:TenantId -AssignmentId (Get-PropertyText -Object $assignment -Names @('id')) -AssignmentCreatedOn (Get-PropertyText -Object $assignment -Names @('createdDateTime')) -SourceApi 'Graph roleManagement/directory/roleAssignments'
            Add-AccessRow -Row $row -Direct -Effective
        }
    }

    if ($doGroupExpansion) {
        Invoke-Collector -Name 'GroupExpansion' -Optional -ScriptBlock {
            $groupAssignments = @($script:DirectRows | Where-Object { $_.principalType -eq 'Group' -and $_.principalId })
            $index = 0
            $truncatedGroups = 0
            foreach ($assignmentRow in $groupAssignments) {
                $index++
                $groupId = [string]$assignmentRow.principalId
                Write-CollectorHeartbeat -Collector 'GroupExpansion' -Current $index -Total $groupAssignments.Count -Activity 'expanding groups'
                if (-not $script:GroupMembersById.ContainsKey($groupId)) {
                    $expansion = Get-GroupMembership -GroupId $groupId -MaxDepth $MaxGroupDepth -MaxMembers $MaxGroupMembers
                    $members = @($expansion.Members)
                    $script:GroupMembersById[$groupId] = $members
                    if ($expansion.Truncated) {
                        $truncatedGroups++
                        Add-ErrorRow -Collector 'GroupExpansion' -Status 'PartiallyCollected' -Scope $groupId -Api 'Graph group members' -ErrorCode 'MemberLimit' `
                            -Message ("Group '{0}' has more than {1} members; expansion was truncated by -MaxGroupMembers." -f $assignmentRow.principalDisplayName, $MaxGroupMembers)
                    }
                    foreach ($member in $members) {
                        Add-PrincipalResolution -Principal $member
                        [void]$script:GroupExpansionRows.Add([pscustomobject]@{
                            sourceGroupId = $groupId
                            sourceGroupName = $assignmentRow.principalDisplayName
                            memberId = Get-PropertyText -Object $member -Names @('id')
                            memberType = ConvertTo-PrincipalType (Get-PropertyText -Object $member -Names @('@odata.type'))
                            memberDisplayName = Get-PropertyText -Object $member -Names @('displayName')
                            memberUserPrincipalName = Get-PropertyText -Object $member -Names @('userPrincipalName', 'mail')
                            memberAppId = Get-PropertyText -Object $member -Names @('appId')
                            accessPath = 'GroupTransitive'
                        })
                    }
                }
                foreach ($member in @($script:GroupMembersById[$groupId])) {
                    $memberId = Get-PropertyText -Object $member -Names @('id')
                    if (-not $memberId) { continue }
                    $memberType = ConvertTo-PrincipalType (Get-PropertyText -Object $member -Names @('@odata.type'))
                    $memberName = Get-PropertyText -Object $member -Names @('displayName')
                    $memberUpn = Get-PropertyText -Object $member -Names @('userPrincipalName', 'mail')
                    $memberAppId = Get-PropertyText -Object $member -Names @('appId')
                    $derived = $assignmentRow.PSObject.Copy()
                    $derived.effectivePrincipalId = $memberId
                    $derived.effectivePrincipalType = $memberType
                    $derived.effectivePrincipalName = if ($memberName) { $memberName } else { $memberUpn }
                    $derived.effectivePrincipalUserPrincipalName = $memberUpn
                    $derived.principalAppId = if ($assignmentRow.principalAppId) { $assignmentRow.principalAppId } else { $memberAppId }
                    $derived.accessPath = 'GroupTransitive'
                    $derived.groupChain = "$($assignmentRow.principalDisplayName) > $($derived.effectivePrincipalName)"
                    $derived.sourceGroupId = $groupId
                    $derived.sourceGroupName = $assignmentRow.principalDisplayName
                    $derived.collector = 'GroupExpansion'
                    Add-AccessRow -Row $derived -Effective -GroupDerived
                }
            }
            Write-ScannerEvent -Level 'Info' -Collector 'GroupExpansion' -EventName 'expansion' -Data @{
                groupAssignments = $groupAssignments.Count; distinctGroups = $script:GroupMembersById.Count
                edges = $script:GroupExpansionRows.Count; truncatedGroups = $truncatedGroups; maxDepth = $MaxGroupDepth
            }
        }
    }
    else {
        Add-CollectorStatus -Collector 'GroupExpansion' -Status 'Skipped' -StartedUtc ([DateTime]::UtcNow) -RowsBefore $script:AccessRows.Count -Message 'Skipped by -NoGroupExpansion'
    }

    Invoke-Collector -Name 'PrincipalResolution' -Optional -ScriptBlock {
        $ids = @($script:AccessRows | ForEach-Object { $_.principalId; $_.effectivePrincipalId } | Where-Object { $_ } | Sort-Object -Unique)
        $batches = [math]::Ceiling($ids.Count / 100)
        $batchIndex = 0
        for ($offset = 0; $offset -lt $ids.Count; $offset += 100) {
            $batchIndex++
            Write-CollectorHeartbeat -Collector 'PrincipalResolution' -Current $batchIndex -Total $batches -Activity 'resolving principals'
            $batch = @($ids | Select-Object -Skip $offset -First 100)
            $body = @{ ids = @($batch); types = @() } | ConvertTo-Json -Depth 4 -Compress
            $resp = $null
            if (-not $NoHttp -and $script:HttpReady) {
                $raw = Invoke-ScannerHttp -Method 'POST' -Url 'https://graph.microsoft.com/v1.0/directoryObjects/getByIds' -Resource 'https://graph.microsoft.com/' -Body $body -Collector 'PrincipalResolution'
                if ($raw -and $raw.Status -lt 400) { $resp = ConvertFrom-JsonSafe -Json $raw.Body }
            }
            if (-not $resp) {
                $resp = Invoke-AzJson -Arguments @('rest', '--method', 'POST', '--url', 'https://graph.microsoft.com/v1.0/directoryObjects/getByIds', '--headers', 'Content-Type=application/json', '--body', $body) -AllowError -Collector 'PrincipalResolution'
            }
            $valueProp = if ($resp) { $resp.PSObject.Properties['value'] } else { $null }
            if ($valueProp) {
                foreach ($principal in @(Expand-FlatArray -InputObject $valueProp.Value)) { Add-PrincipalResolution -Principal $principal }
            }
        }
        # getByIds already reports everything the directory knows about. Anything still
        # missing is deleted or invisible, so per-id retries would just burn calls.
        $unresolved = @($ids | Where-Object { -not $script:PrincipalById.ContainsKey($_) })
        if ($unresolved.Count -gt 0) {
            Add-ErrorRow -Collector 'PrincipalResolution' -Status 'PartiallyCollected' -Api 'Graph directoryObjects/getByIds' -ErrorCode 'UnresolvedPrincipals' `
                -Message ("{0} of {1} principal ids could not be resolved (most likely deleted directory objects)." -f $unresolved.Count, $ids.Count)
        }
        Write-ScannerEvent -Level 'Info' -Collector 'PrincipalResolution' -EventName 'resolution' -Data @{
            requested = $ids.Count; resolved = ($ids.Count - $unresolved.Count); unresolved = $unresolved.Count
        }
    }

    Invoke-Collector -Name 'ServicePrincipalOwners' -Optional -ScriptBlock {
        $spIds = @($script:AccessRows | Where-Object { $_.principalType -eq 'ServicePrincipal' -or $_.effectivePrincipalType -eq 'ServicePrincipal' } | ForEach-Object { $_.principalId; $_.effectivePrincipalId } | Where-Object { $_ } | Sort-Object -Unique)
        if ($spIds.Count -eq 0) { return }

        $ownersById = @{}
        $batched = $false
        if (-not $NoHttp -and $script:HttpReady) {
            # 20 owner lookups per HTTP round trip instead of one az process each.
            $requests = @($spIds | ForEach-Object { @{ id = $_; url = ("/servicePrincipals/{0}/owners?`$select=id,displayName,userPrincipalName,mail,appId&`$top=999" -f $_) } })
            $done = 0
            for ($offset = 0; $offset -lt $requests.Count; $offset += 200) {
                $slice = @($requests | Select-Object -Skip $offset -First 200)
                $responses = Invoke-GraphBatch -Requests $slice -Collector 'ServicePrincipalOwners'
                if ($null -eq $responses) { $ownersById.Clear(); break }
                foreach ($key in $responses.Keys) {
                    $entry = $responses[$key]
                    if ($entry.Status -ge 400 -or -not $entry.Body) { continue }
                    $valueProp = $entry.Body.PSObject.Properties['value']
                    if ($valueProp) { $ownersById[$key] = @(Expand-FlatArray -InputObject $valueProp.Value) }
                }
                $done += $slice.Count
                Write-CollectorHeartbeat -Collector 'ServicePrincipalOwners' -Current $done -Total $requests.Count -Activity 'batched owner lookup'
                $batched = $true
            }
        }

        $index = 0
        foreach ($spId in $spIds) {
            $index++
            Write-CollectorHeartbeat -Collector 'ServicePrincipalOwners' -Current $index -Total $spIds.Count -Activity 'service principal owners'
            $sp = $script:PrincipalById[$spId]
            $spName = if ($sp) { $sp.displayName } else { $spId }
            $owners = if ($batched -and $ownersById.ContainsKey($spId)) { @($ownersById[$spId]) }
                      elseif ($batched) { @() }
                      else { @(Get-GraphPagedItems -Url "https://graph.microsoft.com/v1.0/servicePrincipals/$spId/owners?`$select=id,displayName,userPrincipalName,mail,appId&`$top=999" -Collector 'ServicePrincipalOwners') }
            foreach ($owner in $owners) {
                Add-PrincipalResolution -Principal $owner
                $ownerId = Get-PropertyText -Object $owner -Names @('id')
                $ownerType = ConvertTo-PrincipalType (Get-PropertyText -Object $owner -Names @('@odata.type'))
                $ownerName = Get-PropertyText -Object $owner -Names @('displayName')
                $ownerUpn = Get-PropertyText -Object $owner -Names @('userPrincipalName', 'mail')
                $row = New-AccessRow -Surface 'Service Principal Ownership' -AccessModel 'Ownership' -Collector 'ServicePrincipalOwners' -AssignmentState 'Active' -AssignmentType 'Owner' `
                    -PrincipalId $spId -PrincipalType 'ServicePrincipal' -PrincipalDisplayName $spName -EffectivePrincipalId $ownerId -EffectivePrincipalType $ownerType -EffectivePrincipalName $ownerName -EffectivePrincipalUserPrincipalName $ownerUpn `
                    -AccessPath 'Owner' -RoleName 'Service Principal Owner' -RoleCategory 'ControlPlane' -RoleIsPrivileged $true -RoleHasDataActions $false -Scope $spId -ScopeType 'servicePrincipal' -ScopeDisplayName $spName -TenantId $script:TenantId -SourceApi 'Graph servicePrincipals/owners'
                Add-AccessRow -Row $row -Effective -OwnerDerived
            }
        }
    }

    if ($doKeyVaultAccessPolicies) {
        Invoke-Collector -Name 'KeyVaultAccessPolicies' -Optional -ScriptBlock {
            $vaults = @($script:Resources | Where-Object { [string]$_.type -eq 'Microsoft.KeyVault/vaults' })
            if ($vaults.Count -eq 0) { return }
            $jobs = @($vaults | ForEach-Object {
                @{ Key = [string]$_.resourceId; Arguments = @('keyvault', 'show', '--name', $_.name, '--resource-group', $_.resourceGroup, '--subscription', $_.subscriptionId, '--query', 'properties.accessPolicies') }
            })
            $results = Invoke-AzJsonParallel -Jobs $jobs -Throttle $Parallel -TimeoutSeconds 300 -Collector 'KeyVaultAccessPolicies' -OnProgress {
                param($done, $count)
                Write-CollectorHeartbeat -Collector 'KeyVaultAccessPolicies' -Current $done -Total $count -Activity 'reading vault access policies'
            }
            foreach ($vault in $vaults) {
                $result = $results[[string]$vault.resourceId]
                if (-not $result -or -not $result.Ok) { continue }
                foreach ($policy in @(Expand-FlatArray -InputObject $result.Data)) {
                    $principalId = Get-PropertyText -Object $policy -Names @('objectId')
                    if (-not $principalId) { continue }
                    $permissions = ConvertTo-CompactJson -Value $policy.permissions
                    $row = New-AccessRow -Surface 'Key Vault Access Policy' -AccessModel 'KeyVaultAccessPolicy' -Collector 'KeyVaultAccessPolicies' -AssignmentState 'Active' -AssignmentType 'AccessPolicy' `
                        -PrincipalId $principalId -PrincipalType 'Unknown' -PrincipalDisplayName $principalId -RoleName 'Key Vault Access Policy' -RoleCategory 'DataPlane' -RoleIsPrivileged $false -RoleHasDataActions $true `
                        -Scope $vault.resourceId -ScopeType 'resource' -ScopeDisplayName $vault.name -TenantId $script:TenantId -SubscriptionId $vault.subscriptionId -SubscriptionName $vault.subscriptionName -ResourceGroup $vault.resourceGroup -ResourceType $vault.type -ResourceName $vault.name -Condition $permissions -SourceApi 'az keyvault show properties.accessPolicies'
                    Add-AccessRow -Row $row -Direct -Effective
                }
            }
        }
    }
    else {
        Add-CollectorStatus -Collector 'KeyVaultAccessPolicies' -Status 'Skipped' -StartedUtc ([DateTime]::UtcNow) -RowsBefore $script:AccessRows.Count -Message 'Skipped by -SkipKeyVaultAccessPolicies'
    }

    if ($doPim) {
        Invoke-Collector -Name 'PimDirectoryAssignments' -Optional -ScriptBlock {
            $url = 'https://graph.microsoft.com/v1.0/roleManagement/directory/roleEligibilityScheduleInstances?$expand=roleDefinition($select=id,displayName)&$top=999'
            $items = Get-GraphPagedItems -Url $url -Collector 'PimDirectoryAssignments'
            foreach ($item in $items) {
                $roleName = Get-PropertyText -Object $item.roleDefinition -Names @('displayName')
                $principalId = Get-PropertyText -Object $item -Names @('principalId')
                $scope = Get-PropertyText -Object $item -Names @('directoryScopeId')
                if (-not $scope) { $scope = '/' }
                $row = New-AccessRow -Surface 'PIM Directory Role Eligibility' -AccessModel 'PIM' -Collector 'PimDirectoryAssignments' -AssignmentState 'Eligible' -AssignmentType 'DirectoryRoleEligibility' `
                    -PrincipalId $principalId -PrincipalType 'Unknown' -PrincipalDisplayName $principalId -RoleName $roleName -RoleDefinitionId (Get-PropertyText -Object $item.roleDefinition -Names @('id')) -RoleCategory 'ControlPlane' -RoleIsPrivileged (Test-PrivilegedRoleName -RoleName $roleName) -RoleHasDataActions $false `
                    -Scope $scope -ScopeType 'directory' -TenantId $script:TenantId -AssignmentId (Get-PropertyText -Object $item -Names @('id')) -AssignmentCreatedOn (Get-PropertyText -Object $item -Names @('createdDateTime')) -SourceApi 'Graph roleEligibilityScheduleInstances'
                Add-AccessRow -Row $row -Direct -Effective
            }
        }

        Invoke-Collector -Name 'PimAzureAssignments' -Optional -ScriptBlock {
            $index = 0
            foreach ($sub in $script:Subscriptions) {
                $index++
                Write-CollectorHeartbeat -Collector 'PimAzureAssignments' -Current $index -Total $script:Subscriptions.Count -Activity 'PIM eligibility'
                $scope = "/subscriptions/$($sub.id)"
                $url = "https://management.azure.com$scope/providers/Microsoft.Authorization/roleEligibilityScheduleInstances?api-version=2020-10-01"
                $resp = $null
                if (-not $NoHttp -and $script:HttpReady) {
                    $raw = Invoke-ScannerHttp -Method 'GET' -Url $url -Resource 'https://management.azure.com/' -Collector 'PimAzureAssignments'
                    if ($raw -and $raw.Status -lt 400) { $resp = ConvertFrom-JsonSafe -Json $raw.Body }
                }
                if (-not $resp) {
                    $resp = Invoke-AzJson -Arguments @('rest', '--method', 'GET', '--url', $url) -AllowError -Collector 'PimAzureAssignments'
                }
                $valueProp = if ($resp) { $resp.PSObject.Properties['value'] } else { $null }
                $eligibleItems = if ($valueProp) { @(Expand-FlatArray -InputObject $valueProp.Value) } else { @() }
                foreach ($item in $eligibleItems) {
                    $props = $item.properties
                    $roleDefinitionId = Get-PropertyText -Object $props -Names @('roleDefinitionId')
                    $principalId = Get-PropertyText -Object $props -Names @('principalId')
                    $role = Get-RoleMeta -RoleDefinitionId $roleDefinitionId -RoleName ''
                    $row = New-AccessRow -Surface 'PIM Azure RBAC Eligibility' -AccessModel 'PIM' -Collector 'PimAzureAssignments' -AssignmentState 'Eligible' -AssignmentType 'AzureRoleEligibility' `
                        -PrincipalId $principalId -PrincipalType 'Unknown' -PrincipalDisplayName $principalId -RoleName (Get-PropertyText -Object $role -Names @('roleName')) -RoleDefinitionId $roleDefinitionId -RoleCategory $role.roleCategory -RoleIsPrivileged ([bool]::Parse([string]$role.roleIsPrivileged)) -RoleHasDataActions ([bool]::Parse([string]$role.roleHasDataActions)) `
                        -Scope (Get-PropertyText -Object $props -Names @('scope')) -TenantId $script:TenantId -SubscriptionId $sub.id -SubscriptionName $sub.name -AssignmentId (Get-PropertyText -Object $item -Names @('id')) -SourceApi 'ARM roleEligibilityScheduleInstances'
                    Add-AccessRow -Row $row -Direct -Effective
                }
            }
        }
    }
    else {
        Add-CollectorStatus -Collector 'PimDirectoryAssignments' -Status 'Skipped' -StartedUtc ([DateTime]::UtcNow) -RowsBefore $script:AccessRows.Count -Message 'Skipped by -SkipPim'
        Add-CollectorStatus -Collector 'PimAzureAssignments' -Status 'Skipped' -StartedUtc ([DateTime]::UtcNow) -RowsBefore $script:AccessRows.Count -Message 'Skipped by -SkipPim'
    }

    if ($doBilling) {
        Invoke-Collector -Name 'BillingAccess' -Optional -ScriptBlock {
            $accounts = Invoke-AzJson -Arguments @('billing', 'account', 'list') -AllowError -Collector 'BillingAccess'
            foreach ($account in @(Expand-FlatArray -InputObject $accounts)) {
                $scope = Get-PropertyText -Object $account -Names @('id')
                if (-not $scope) { continue }
                Add-ScopeRow -Scope $scope -ScopeType 'billing' -DisplayName (Get-PropertyText -Object $account -Names @('displayName', 'name')) -Collector 'BillingAccess'
                Add-RoleAssignmentsForScope -Collector 'BillingAccess' -Scope $scope -IncludeInherited
            }
        }
    }
    else {
        Add-CollectorStatus -Collector 'BillingAccess' -Status 'Skipped' -StartedUtc ([DateTime]::UtcNow) -RowsBefore $script:AccessRows.Count -Message 'Skipped by -SkipBilling'
    }

    if ($doReservations) {
        Invoke-Collector -Name 'ReservationAccess' -Optional -ScriptBlock {
            $orders = Invoke-AzJsonWithTimeout -Arguments @('reservations', 'reservation-order', 'list') -TimeoutSeconds 90
            foreach ($order in @(Expand-FlatArray -InputObject $orders)) {
                $scope = Get-PropertyText -Object $order -Names @('id')
                if (-not $scope) { continue }
                Add-ScopeRow -Scope $scope -ScopeType 'reservation' -DisplayName (Get-PropertyText -Object $order -Names @('name')) -Collector 'ReservationAccess'
                Add-RoleAssignmentsForScope -Collector 'ReservationAccess' -Scope $scope -IncludeInherited
            }
        }
    }
    else {
        Add-CollectorStatus -Collector 'ReservationAccess' -Status 'Skipped' -StartedUtc ([DateTime]::UtcNow) -RowsBefore $script:AccessRows.Count -Message 'Skipped by -SkipReservations'
    }

    if ($doClassicAdmins) {
        Invoke-Collector -Name 'ClassicAdmins' -Optional -ScriptBlock {
            $jobs = @($script:Subscriptions | ForEach-Object {
                @{ Key = [string]$_.id; Arguments = @('role', 'assignment', 'list', '--include-classic-administrators', '--subscription', $_.id) }
            })
            $results = Invoke-AzJsonParallel -Jobs $jobs -Throttle $Parallel -TimeoutSeconds 300 -Collector 'ClassicAdmins' -OnProgress {
                param($done, $count)
                Write-CollectorHeartbeat -Collector 'ClassicAdmins' -Current $done -Total $count -Activity 'classic administrators'
            }
            foreach ($sub in $script:Subscriptions) {
                $result = $results[[string]$sub.id]
                if (-not $result -or -not $result.Ok) { continue }
                foreach ($assignment in @(Expand-FlatArray -InputObject $result.Data)) {
                    $roleName = Get-PropertyText -Object $assignment -Names @('roleDefinitionName', 'roleName')
                    if ($roleName -notmatch '(?i)classic|administrator|co-administrator|service administrator|account administrator') { continue }
                    $row = Convert-RoleAssignmentToRow -Assignment $assignment -Collector 'ClassicAdmins' -Surface 'Classic Subscription Admins' -AccessModel 'ClassicAzureAdmin' -SubscriptionId $sub.id -SubscriptionName $sub.name
                    Add-AccessRow -Row $row -Direct -Effective
                }
            }
        }
    }
    else {
        Add-CollectorStatus -Collector 'ClassicAdmins' -Status 'Skipped' -StartedUtc ([DateTime]::UtcNow) -RowsBefore $script:AccessRows.Count -Message 'Skipped by -SkipClassicAdmins'
    }

    Invoke-Collector -Name 'WorkbookReport' -Optional -ScriptBlock {
        $columns = Get-AccessColumns
        $allAccessCsv = Join-Path $context.OutDir 'allAzureAccess.csv'
        $allAccessJson = Join-Path $context.OutDir 'allAzureAccess.json'
        $effectiveCsv = Join-Path $context.OutDir 'effectiveAccess.csv'
        $directCsv = Join-Path $context.OutDir 'directAssignments.csv'
        $groupCsv = Join-Path $context.OutDir 'groupDerivedAccess.csv'
        $nestedCsv = Join-Path $context.OutDir 'nestedGroupAccess.csv'
        $ownerCsv = Join-Path $context.OutDir 'servicePrincipalOwners.csv'
        $principalCsv = Join-Path $context.OutDir 'principalResolution.csv'
        $groupExpansionCsv = Join-Path $context.OutDir 'groupExpansion.csv'
        $roleCsv = Join-Path $context.OutDir 'roleDefinitions.csv'
        $scopeCsv = Join-Path $context.OutDir 'scopeInventory.csv'
        $statusCsv = Join-Path $context.OutDir 'collectorStatus.csv'
        $errorsCsv = Join-Path $context.OutDir 'errorsWarnings.csv'
        $coverageJson = Join-Path $context.OutDir 'coverageSummary.json'
        $workbook = Join-Path $reportsDir ("all-azure-access-report-{0}.xlsx" -f $context.RunId)
        $summaryJson = Join-Path $reportsDir ("all-azure-access-summary-{0}.json" -f $context.RunId)

        Export-ObjectList -Path $allAccessCsv -Columns $columns -Rows @($script:AccessRows)
        if ($EmitJson) {
            Write-JsonFile -Path $allAccessJson -Data @($script:AccessRows) -Depth 12
        }
        Export-ObjectList -Path $effectiveCsv -Columns $columns -Rows @($script:EffectiveRows)
        Export-ObjectList -Path $directCsv -Columns $columns -Rows @($script:DirectRows)
        Export-ObjectList -Path $groupCsv -Columns $columns -Rows @($script:GroupRows)
        Export-ObjectList -Path $nestedCsv -Columns $columns -Rows @($script:GroupRows | Where-Object { $_.accessPath -match 'Nested|Transitive' })
        Export-ObjectList -Path $ownerCsv -Columns $columns -Rows @($script:OwnerRows)
        Export-ObjectList -Path $principalCsv -Columns @('principalId','principalType','displayName','userPrincipalName','appId','accountEnabled','source') -Rows @($script:PrincipalRows)
        Export-ObjectList -Path $groupExpansionCsv -Columns @('sourceGroupId','sourceGroupName','memberId','memberType','memberDisplayName','memberUserPrincipalName','memberAppId','accessPath') -Rows @($script:GroupExpansionRows)
        Export-ObjectList -Path $roleCsv -Columns @('roleName','roleDefinitionId','roleDefinitionGuid','roleType','roleCategory','roleIsPrivileged','roleHasDataActions','actionsCount','dataActionsCount','description','assignableScopes','permissions','collector') -Rows @($script:RoleRows)
        Export-ObjectList -Path $scopeCsv -Columns @('scope','scopeType','displayName','subscriptionId','subscriptionName','managementGroupId','managementGroupName','resourceGroup','resourceType','resourceName','collector') -Rows @($script:ScopeRows)
        Export-ObjectList -Path $statusCsv -Columns @('collector','status','startedUtc','endedUtc','durationSeconds','rowsAdded','totalRows','message') -Rows @($script:StatusRows)
        Export-ObjectList -Path $errorsCsv -Columns @('collector','status','scope','api','errorCode','errorMessage','generatedUtc') -Rows @($script:ErrorRows)

        $coverage = Get-CoverageSummary
        Write-JsonFile -Path $coverageJson -Data $coverage -Depth 10

        $node = Get-Command node -ErrorAction SilentlyContinue
        $reportScript = Join-Path $PSScriptRoot 'report.mjs'
        if ($node -and (Test-Path -LiteralPath $reportScript)) {
            & $node.Source $reportScript `
                --run-dir $context.RunDir `
                --access-csv $allAccessCsv `
                --effective-csv $effectiveCsv `
                --direct-csv $directCsv `
                --group-csv $groupCsv `
                --service-principal-owners-csv $ownerCsv `
                --collector-status-csv $statusCsv `
                --scope-inventory-csv $scopeCsv `
                --role-definitions-csv $roleCsv `
                --principal-resolution-csv $principalCsv `
                --errors-csv $errorsCsv `
                --coverage-json $coverageJson `
                --output $workbook `
                --summary-json $summaryJson
            if ($LASTEXITCODE -ne 0) { throw "report.mjs exited with code $LASTEXITCODE" }
        }
        else {
            Add-ErrorRow -Collector 'WorkbookReport' -Status 'Skipped' -Message 'node or report.mjs was not found; CSV/JSON outputs were still written.'
        }

        Write-JsonFile -Path $context.ResultsJson -Data @{
            jobId = $context.JobId
            cloud = 'azure'
            jobType = 'all-azure-access'
            generatedUtc = Get-UtcTimestamp
            runDir = $context.RunDir
            count = $script:AccessRows.Count
            outputs = @{
                allAccessCsv = $allAccessCsv
                allAccessJson = $allAccessJson
                effectiveAccessCsv = $effectiveCsv
                directAssignmentsCsv = $directCsv
                groupDerivedAccessCsv = $groupCsv
                servicePrincipalOwnersCsv = $ownerCsv
                principalResolutionCsv = $principalCsv
                groupExpansionCsv = $groupExpansionCsv
                roleDefinitionsCsv = $roleCsv
                scopeInventoryCsv = $scopeCsv
                collectorStatusCsv = $statusCsv
                coverageSummaryJson = $coverageJson
                workbook = if (Test-Path -LiteralPath $workbook) { $workbook } else { '' }
                reportSummaryJson = if (Test-Path -LiteralPath $summaryJson) { $summaryJson } else { '' }
            }
            stats = $coverage
        } -Depth 12

        Compress-ResultFiles -DestinationPath (Join-Path $context.OutDir 'results.zip') -LiteralPaths @($allAccessCsv,$allAccessJson,$effectiveCsv,$directCsv,$groupCsv,$nestedCsv,$ownerCsv,$principalCsv,$groupExpansionCsv,$roleCsv,$scopeCsv,$statusCsv,$errorsCsv,$coverageJson,$context.ResultsJson,$workbook,$summaryJson)
    }

    $attention = @($script:StatusRows | Where-Object { $_.status -ne 'Succeeded' -and $_.status -ne 'Skipped' }).Count
    if ($attention -gt 0) { $exitCode = 2 }
}
catch {
    $exitCode = 1
    Add-ErrorRow -Collector 'Fatal' -Status 'Failed' -Message $_.Exception.Message
    throw
}
finally {
    $bundlePath = ''
    try {
        Write-DiagnosticOutputs
        Write-RunManifest -Context $context -ExitCode $exitCode -Extra @{ accessRows = $script:AccessRows.Count; statusRows = $script:StatusRows.Count }
    }
    catch {
        Write-ScannerLine -Text ("Failed to write diagnostic outputs: {0}" -f $_.Exception.Message) -Level 'Error'
    }

    $logResult = $null
    try {
        $logResult = Close-ScannerLog -Summary @{
            exitCode = $exitCode
            accessRows = $script:AccessRows.Count
            collectors = $script:StatusRows.Count
        }
    }
    catch { $logResult = $null }

    $errorClasses = @()
    try {
        $summaryFile = Join-Path $context.LogDir 'errorSummary.json'
        if (Test-Path -LiteralPath $summaryFile) {
            $errorClasses = @((Get-Content -LiteralPath $summaryFile -Raw | ConvertFrom-Json).errorClasses)
        }
    }
    catch { $errorClasses = @() }

    # Always bundle when something went wrong - that is exactly when it is needed.
    if ($SupportBundle -or $exitCode -ne 0) {
        try {
            $bundlePath = New-ScannerSupportBundle -RunDirectory $context.RunDir `
                -DestinationPath (Join-Path $context.RunDir ("support-bundle-{0}.zip" -f $context.RunId)) -IncludeData:$IncludeData
        }
        catch { $bundlePath = '' }
    }

    try { Complete-ScannerUi } catch { }
    try {
        Write-ScannerSummary -StatusRows @($script:StatusRows) -ErrorClasses $errorClasses -Totals ([ordered]@{
            'Access rows'   = $script:AccessRows.Count
            'Scopes'        = $script:ScopeRows.Count
            'Principals'    = $script:PrincipalRows.Count
            'API calls'     = $(if ($logResult) { $logResult.ApiCalls } else { 0 })
            'Issue classes' = @($errorClasses).Count
        })
    }
    catch { }

    if (-not $NoTranscript) { try { Stop-Transcript | Out-Null } catch { } }

    Write-ScannerLine -Text '' -Level 'Plain'
    if ($bundlePath) {
        Write-ScannerLine -Text ('Support bundle (safe to send): {0}' -f $bundlePath) -Level 'Header' -Force
    }
    elseif (-not $SupportBundle) {
        Write-ScannerLine -Text 'Re-run with -SupportBundle to produce a redacted diagnostics zip.' -Level 'Detail'
    }

    Write-Host "RUN_DIR=$($context.RunDir)"
    Write-Host "ALL_ACCESS_CSV=$(Join-Path $context.OutDir 'allAzureAccess.csv')"
    Write-Host "COLLECTOR_STATUS=$(Join-Path $context.OutDir 'collectorStatus.csv')"
    Write-Host "RESULTS_JSON=$($context.ResultsJson)"
    Write-Host "RESULTS_ZIP=$(Join-Path $context.OutDir 'results.zip')"
    Write-Host "EVENT_LOG=$(Join-Path $context.LogDir 'events.jsonl')"
    Write-Host "SUPPORT_BUNDLE=$bundlePath"
    Write-Host "FINAL_STATUS=$(if ($exitCode -eq 0) { 'Succeeded' } elseif ($exitCode -eq 2) { 'CompletedWithWarnings' } else { 'Failed' })"
}

exit $exitCode
