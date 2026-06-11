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
    [int]$MaxGroupDepth = 10,
    [int]$Parallel = 1,
    [int]$LimitResources = 0,
    [switch]$ContinueOnError,
    [switch]$FailFast
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$modulePath = Join-Path $PSScriptRoot 'lib\AzureScannerCommon.psm1'
Import-Module $modulePath -Force

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
    param([Parameter(Mandatory = $true)][string[]]$Arguments, [int]$TimeoutSeconds = 120)
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
        if ($process.ExitCode -ne 0) { throw "az failed ($($process.ExitCode)): $($effectiveArgs -join ' ')`n$stderr" }
        if ([string]::IsNullOrWhiteSpace($stdout)) { return $null }
        return $stdout | ConvertFrom-Json
    }
    finally {
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
    Write-Host "[START] $Name"
    try {
        & $ScriptBlock
        Add-CollectorStatus -Collector $Name -Status 'Succeeded' -StartedUtc $started -RowsBefore $rowsBefore
        Write-Host "[OK] $Name rows+=$($script:AccessRows.Count - $rowsBefore)"
    }
    catch {
        $message = $_.Exception.Message
        $status = 'Failed'
        if ($message -match '(?i)authorization|unauthori[sz]ed|forbidden|insufficient privileges|does not have authorization|authentication') { $status = 'Unauthorized' }
        elseif ($message -match '(?i)throttl|too many requests|429') { $status = 'Throttled' }
        elseif ($script:AccessRows.Count -gt $rowsBefore) { $status = 'PartiallyCollected' }
        Add-CollectorStatus -Collector $Name -Status $status -StartedUtc $started -RowsBefore $rowsBefore -Message $message
        Add-ErrorRow -Collector $Name -Status $status -Message $message
        $safeName = ($Name -replace '[^A-Za-z0-9_.-]', '_')
        Write-JsonFile -Path (Join-Path $errorsDir "$safeName.json") -Data @{ collector = $Name; status = $status; error = $message; generatedUtc = Get-UtcTimestamp }
        Write-Warning "[$status] $Name failed, continuing: $message"
        if ($FailFast -or (-not $Optional -and -not $ContinueOnError)) { throw }
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

function Resolve-PrincipalById {
    param([string]$PrincipalId)
    if (-not $PrincipalId) { return $null }
    if ($script:PrincipalById.ContainsKey($PrincipalId)) { return $script:PrincipalById[$PrincipalId] }
    $url = "https://graph.microsoft.com/v1.0/directoryObjects/$PrincipalId"
    $obj = Invoke-AzJson -Arguments @('rest', '--method', 'GET', '--url', $url) -AllowError
    if ($obj) {
        Add-PrincipalResolution -Principal $obj
        return $script:PrincipalById[$PrincipalId]
    }
    return $null
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
    $roleAssignmentArgs = @('role', 'assignment', 'list', '--all', '--scope', $Scope)
    if ($IncludeInherited) { $roleAssignmentArgs += '--include-inherited' }
    if ($SubscriptionId) { $roleAssignmentArgs += @('--subscription', $SubscriptionId) }
    try { $assignments = Invoke-AzJsonWithTimeout -Arguments $roleAssignmentArgs -TimeoutSeconds 180 }
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

Write-Host "[START] all-azure-access run $($context.RunId)"
Write-Host "RUN_DIR=$($context.RunDir)"
Start-Transcript -Path (Join-Path $context.LogDir 'all-azure-access.log') -Force | Out-Null

try {
    Invoke-Collector -Name 'StartupValidation' -ScriptBlock {
        Resolve-AzCommand | Out-Null
        $account = Invoke-AzJson -Arguments @('account', 'show') -AllowError
        if (-not $account) { throw 'Azure CLI is not logged in or account show returned no data.' }
        $script:TenantId = Get-PropertyText -Object $account -Names @('tenantId')
        Add-ScopeRow -Scope '/' -ScopeType 'tenantRoot' -DisplayName 'Tenant Root' -Collector 'StartupValidation'
    }

    Invoke-Collector -Name 'Subscriptions' -ScriptBlock {
        $script:Subscriptions = @(Get-AzSubscriptions -SubscriptionIds $SubscriptionIds -IncludeAllStates | Where-Object { [string]$_.state -eq 'Enabled' -or $SubscriptionIds.Count -gt 0 })
        if ($script:Subscriptions.Count -eq 0) { throw 'No enabled Azure subscriptions were returned.' }
        foreach ($sub in $script:Subscriptions) {
            Add-ScopeRow -Scope ("/subscriptions/{0}" -f $sub.id) -ScopeType 'subscription' -DisplayName $sub.name -SubscriptionId $sub.id -SubscriptionName $sub.name -Collector 'Subscriptions'
        }
    }

    Invoke-Collector -Name 'ManagementGroups' -Optional -ScriptBlock {
        $items = Invoke-AzJson -Arguments @('account', 'management-group', 'list') -AllowError
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
        foreach ($mg in $script:ManagementGroups) {
            $mgId = Get-PropertyText -Object $mg -Names @('name', 'id')
            $displayName = Get-PropertyText -Object $mg -Names @('displayName', 'name')
            if (-not $mgId) { continue }
            Add-RoleAssignmentsForScope -Collector 'ManagementGroupRbac' -Scope "/providers/Microsoft.Management/managementGroups/$mgId" -ManagementGroupId $mgId -ManagementGroupName $displayName -IncludeInherited
        }
    }

    Invoke-Collector -Name 'AzureSubscriptionRbac' -ScriptBlock {
        foreach ($sub in $script:Subscriptions) {
            try { $assignments = Invoke-AzJsonWithTimeout -Arguments @('role', 'assignment', 'list', '--all', '--include-inherited', '--subscription', $sub.id) -TimeoutSeconds 180 }
            catch {
                Add-ErrorRow -Collector 'AzureSubscriptionRbac' -Status 'PartiallyCollected' -Scope ("/subscriptions/{0}" -f $sub.id) -Api 'az role assignment list' -Message $_.Exception.Message
                continue
            }
            foreach ($assignment in @(Expand-FlatArray -InputObject $assignments)) {
                if (-not (Test-RoleAssignmentObject -Assignment $assignment)) { continue }
                $row = Convert-RoleAssignmentToRow -Assignment $assignment -Collector 'AzureSubscriptionRbac' -SubscriptionId $sub.id -SubscriptionName $sub.name
                Add-AccessRow -Row $row -Direct -Effective
            }
        }
    }

    Invoke-Collector -Name 'ScopeInventory' -Optional -ScriptBlock {
        foreach ($sub in $script:Subscriptions) {
            $groups = Invoke-AzJson -Arguments @('group', 'list', '--subscription', $sub.id) -AllowError
            foreach ($group in @(Expand-FlatArray -InputObject $groups)) {
                $rgName = Get-PropertyText -Object $group -Names @('name')
                [void]$script:ResourceGroups.Add([pscustomobject]@{ subscriptionId = $sub.id; subscriptionName = $sub.name; resourceGroup = $rgName; scope = Get-PropertyText -Object $group -Names @('id') })
                Add-ScopeRow -Scope (Get-PropertyText -Object $group -Names @('id')) -ScopeType 'resourceGroup' -DisplayName $rgName -SubscriptionId $sub.id -SubscriptionName $sub.name -ResourceGroup $rgName -Collector 'ScopeInventory'
            }
            if (-not $SkipResourceLevel) {
                $resources = Invoke-AzJson -Arguments @('resource', 'list', '--subscription', $sub.id) -AllowError
                $resourceArray = @(Expand-FlatArray -InputObject $resources)
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
        }
    }

    Invoke-Collector -Name 'AzureResourceGroupRbac' -Optional -ScriptBlock {
        foreach ($rg in $script:ResourceGroups) {
            if (-not $rg.scope) { continue }
            Add-RoleAssignmentsForScope -Collector 'AzureResourceGroupRbac' -Scope $rg.scope -SubscriptionId $rg.subscriptionId -SubscriptionName $rg.subscriptionName -IncludeInherited
        }
    }

    if (-not $SkipResourceLevel) {
        Invoke-Collector -Name 'AzureResourceRbac' -Optional -ScriptBlock {
            foreach ($resource in $script:Resources) {
                if (-not $resource.resourceId) { continue }
                Add-RoleAssignmentsForScope -Collector 'AzureResourceRbac' -Scope $resource.resourceId -SubscriptionId $resource.subscriptionId -SubscriptionName $resource.subscriptionName -IncludeInherited
            }
        }
    }
    else {
        Add-CollectorStatus -Collector 'AzureResourceRbac' -Status 'Skipped' -StartedUtc ([DateTime]::UtcNow) -RowsBefore $script:AccessRows.Count -Message 'Skipped by -SkipResourceLevel'
    }

    if (-not $SkipChildDataScopes) {
        Invoke-Collector -Name 'StorageChildScopeRbac' -Optional -ScriptBlock {
            $storageAccounts = @($script:Resources | Where-Object { [string]$_.type -eq 'Microsoft.Storage/storageAccounts' })
            foreach ($sa in $storageAccounts) {
                $containers = Invoke-AzJson -Arguments @('storage', 'container-rm', 'list', '--storage-account', $sa.name, '--resource-group', $sa.resourceGroup, '--subscription', $sa.subscriptionId) -AllowError
                foreach ($container in @(Expand-FlatArray -InputObject $containers)) {
                    $containerName = Get-PropertyText -Object $container -Names @('name')
                    $scope = "/subscriptions/$($sa.subscriptionId)/resourceGroups/$($sa.resourceGroup)/providers/Microsoft.Storage/storageAccounts/$($sa.name)/blobServices/default/containers/$containerName"
                    Add-ScopeRow -Scope $scope -ScopeType 'storageChildScope' -DisplayName $containerName -SubscriptionId $sa.subscriptionId -SubscriptionName $sa.subscriptionName -ResourceGroup $sa.resourceGroup -ResourceType 'Microsoft.Storage/storageAccounts/blobServices/containers' -ResourceName $sa.name -Collector 'StorageChildScopeRbac'
                    Add-RoleAssignmentsForScope -Collector 'StorageChildScopeRbac' -Scope $scope -SubscriptionId $sa.subscriptionId -SubscriptionName $sa.subscriptionName -IncludeInherited
                }
                $shares = Invoke-AzJson -Arguments @('storage', 'share-rm', 'list', '--storage-account', $sa.name, '--resource-group', $sa.resourceGroup, '--subscription', $sa.subscriptionId) -AllowError
                foreach ($share in @(Expand-FlatArray -InputObject $shares)) {
                    $shareName = Get-PropertyText -Object $share -Names @('name')
                    $scope = "/subscriptions/$($sa.subscriptionId)/resourceGroups/$($sa.resourceGroup)/providers/Microsoft.Storage/storageAccounts/$($sa.name)/fileServices/default/shares/$shareName"
                    Add-ScopeRow -Scope $scope -ScopeType 'storageChildScope' -DisplayName $shareName -SubscriptionId $sa.subscriptionId -SubscriptionName $sa.subscriptionName -ResourceGroup $sa.resourceGroup -ResourceType 'Microsoft.Storage/storageAccounts/fileServices/shares' -ResourceName $sa.name -ChildResourceType 'fileShare' -ChildResourceName $shareName -Collector 'StorageChildScopeRbac'
                    Add-RoleAssignmentsForScope -Collector 'StorageChildScopeRbac' -Scope $scope -SubscriptionId $sa.subscriptionId -SubscriptionName $sa.subscriptionName -IncludeInherited
                }
            }
        }
    }
    else {
        Add-CollectorStatus -Collector 'StorageChildScopeRbac' -Status 'Skipped' -StartedUtc ([DateTime]::UtcNow) -RowsBefore $script:AccessRows.Count -Message 'Skipped by -SkipChildDataScopes'
    }

    Invoke-Collector -Name 'EntraRoleAssignments' -Optional -ScriptBlock {
        $url = 'https://graph.microsoft.com/v1.0/roleManagement/directory/roleAssignments?$expand=roleDefinition($select=id,displayName)&$top=999'
        $assignments = Get-GraphPagedItems -Url $url
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

    if (-not $NoGroupExpansion) {
        Invoke-Collector -Name 'GroupExpansion' -Optional -ScriptBlock {
            $groupAssignments = @($script:DirectRows | Where-Object { $_.principalType -eq 'Group' -and $_.principalId })
            foreach ($assignmentRow in $groupAssignments) {
                $groupId = [string]$assignmentRow.principalId
                if (-not $script:GroupMembersById.ContainsKey($groupId)) {
                    $encoded = [uri]::EscapeDataString($groupId)
                    $url = "https://graph.microsoft.com/v1.0/groups/$encoded/transitiveMembers?`$select=id,displayName,userPrincipalName,mail,appId&`$top=999"
                    $members = @(Get-GraphPagedItems -Url $url)
                    $script:GroupMembersById[$groupId] = $members
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
        }
    }
    else {
        Add-CollectorStatus -Collector 'GroupExpansion' -Status 'Skipped' -StartedUtc ([DateTime]::UtcNow) -RowsBefore $script:AccessRows.Count -Message 'Skipped by -NoGroupExpansion'
    }

    Invoke-Collector -Name 'PrincipalResolution' -Optional -ScriptBlock {
        $ids = @($script:AccessRows | ForEach-Object { $_.principalId; $_.effectivePrincipalId } | Where-Object { $_ } | Sort-Object -Unique)
        for ($offset = 0; $offset -lt $ids.Count; $offset += 100) {
            $batch = @($ids | Select-Object -Skip $offset -First 100)
            $body = @{ ids = @($batch); types = @() } | ConvertTo-Json -Depth 4 -Compress
            $resp = Invoke-AzJson -Arguments @('rest', '--method', 'POST', '--url', 'https://graph.microsoft.com/v1.0/directoryObjects/getByIds', '--headers', 'Content-Type=application/json', '--body', $body) -AllowError
            $valueProp = if ($resp) { $resp.PSObject.Properties['value'] } else { $null }
            if ($valueProp) {
                foreach ($principal in @(Expand-FlatArray -InputObject $valueProp.Value)) { Add-PrincipalResolution -Principal $principal }
            }
        }
        foreach ($id in $ids) {
            if (-not $script:PrincipalById.ContainsKey($id)) { Resolve-PrincipalById -PrincipalId $id | Out-Null }
        }
    }

    Invoke-Collector -Name 'ServicePrincipalOwners' -Optional -ScriptBlock {
        $spIds = @($script:AccessRows | Where-Object { $_.principalType -eq 'ServicePrincipal' -or $_.effectivePrincipalType -eq 'ServicePrincipal' } | ForEach-Object { $_.principalId; $_.effectivePrincipalId } | Where-Object { $_ } | Sort-Object -Unique)
        foreach ($spId in $spIds) {
            $sp = Resolve-PrincipalById -PrincipalId $spId
            $spName = if ($sp) { $sp.displayName } else { $spId }
            $owners = Get-GraphPagedItems -Url "https://graph.microsoft.com/v1.0/servicePrincipals/$spId/owners?`$select=id,displayName,userPrincipalName,mail,appId&`$top=999"
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

    if (-not $SkipKeyVaultAccessPolicies) {
        Invoke-Collector -Name 'KeyVaultAccessPolicies' -Optional -ScriptBlock {
            $vaults = @($script:Resources | Where-Object { [string]$_.type -eq 'Microsoft.KeyVault/vaults' })
            foreach ($vault in $vaults) {
                $details = Invoke-AzJson -Arguments @('keyvault', 'show', '--name', $vault.name, '--resource-group', $vault.resourceGroup, '--subscription', $vault.subscriptionId) -AllowError
                $policies = @()
                if ($details -and $details.properties -and $details.properties.accessPolicies) { $policies = @($details.properties.accessPolicies) }
                foreach ($policy in $policies) {
                    $principalId = Get-PropertyText -Object $policy -Names @('objectId')
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

    if (-not $SkipPim) {
        Invoke-Collector -Name 'PimDirectoryAssignments' -Optional -ScriptBlock {
            $url = 'https://graph.microsoft.com/v1.0/roleManagement/directory/roleEligibilityScheduleInstances?$expand=roleDefinition($select=id,displayName)&$top=999'
            $items = Get-GraphPagedItems -Url $url
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
            foreach ($sub in $script:Subscriptions) {
                $scope = "/subscriptions/$($sub.id)"
                $url = "https://management.azure.com$scope/providers/Microsoft.Authorization/roleEligibilityScheduleInstances?api-version=2020-10-01"
                $resp = Invoke-AzJson -Arguments @('rest', '--method', 'GET', '--url', $url) -AllowError
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

    if (-not $SkipBilling) {
        Invoke-Collector -Name 'BillingAccess' -Optional -ScriptBlock {
            $accounts = Invoke-AzJson -Arguments @('billing', 'account', 'list') -AllowError
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

    if (-not $SkipReservations) {
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

    if (-not $SkipClassicAdmins) {
        Invoke-Collector -Name 'ClassicAdmins' -Optional -ScriptBlock {
            foreach ($sub in $script:Subscriptions) {
                $assignments = Invoke-AzJson -Arguments @('role', 'assignment', 'list', '--include-classic-administrators', '--subscription', $sub.id) -AllowError
                foreach ($assignment in @(Expand-FlatArray -InputObject $assignments)) {
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
        Write-JsonFile -Path $allAccessJson -Data @($script:AccessRows) -Depth 12
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

        $coverage = [ordered]@{
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
                skipResourceLevel = [bool]$SkipResourceLevel
                skipChildDataScopes = [bool]$SkipChildDataScopes
                skipPim = [bool]$SkipPim
                skipBilling = [bool]$SkipBilling
                skipReservations = [bool]$SkipReservations
                fullRoleDefinitionScan = [bool]$FullRoleDefinitionScan
                skipClassicAdmins = [bool]$SkipClassicAdmins
                noGroupExpansion = [bool]$NoGroupExpansion
                limitResources = $LimitResources
            }
        }
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
    try {
        Export-ObjectList -Path (Join-Path $context.OutDir 'collectorStatus.csv') -Columns @('collector','status','startedUtc','endedUtc','durationSeconds','rowsAdded','totalRows','message') -Rows @($script:StatusRows)
        Write-RunManifest -Context $context -ExitCode $exitCode -Extra @{ accessRows = $script:AccessRows.Count; statusRows = $script:StatusRows.Count }
    }
    finally {
        Stop-Transcript | Out-Null
    }
    Write-Host "RUN_DIR=$($context.RunDir)"
    Write-Host "ALL_ACCESS_CSV=$(Join-Path $context.OutDir 'allAzureAccess.csv')"
    Write-Host "COLLECTOR_STATUS=$(Join-Path $context.OutDir 'collectorStatus.csv')"
    Write-Host "RESULTS_JSON=$($context.ResultsJson)"
    Write-Host "RESULTS_ZIP=$(Join-Path $context.OutDir 'results.zip')"
    Write-Host "FINAL_STATUS=$(if ($exitCode -eq 0) { 'Succeeded' } elseif ($exitCode -eq 2) { 'CompletedWithWarnings' } else { 'Failed' })"
}

exit $exitCode
