Set-StrictMode -Version Latest

function Get-GovernanceValue {
    param([AllowNull()]$Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($property) { return $property.Value }
    return $null
}

function ConvertTo-GovernanceJson {
    param([AllowNull()]$Value)
    if ($null -eq $Value) { return '' }
    return ConvertTo-Json -InputObject $Value -Depth 40 -Compress
}

function Get-GovernanceSchemas {
    return [ordered]@{
        accessCatalogs = @('tenantId','id','displayName','description','state','isExternallyVisible','createdDateTime','modifiedDateTime')
        accessPackages = @('tenantId','id','catalogId','displayName','description','isHidden','createdDateTime','modifiedDateTime')
        accessPackagePolicies = @('tenantId','id','packageId','displayName','description','allowedTargetScope','approvalRequired','expirationType','expirationDuration','expirationEndDateTime','reviewsEnabled','reviewSettingsJson','requestApprovalSettingsJson','requestorSettingsJson','automaticRequestSettingsJson','specificAllowedTargetsJson','createdDateTime','modifiedDateTime')
        accessPackageResources = @('tenantId','packageId','id','resourceId','resourceOriginId','originSystem','resourceDisplayName','roleId','roleOriginId','roleDisplayName','scopeId','scopeOriginId','scopeDisplayName')
        accessPackageAssignments = @('tenantId','id','packageId','policyId','subjectId','principalId','principalType','principalDisplayName','principalName','email','state','status','startDateTime','expirationType','expirationDuration','endDateTime','expiredDateTime')
        accessReviewDefinitions = @('tenantId','id','displayName','reviewType','status','scopeJson','instanceEnumerationScopeJson','settingsJson','reviewersJson','fallbackReviewersJson','stageSettingsJson','createdDateTime','lastModifiedDateTime')
        accessReviewInstances = @('tenantId','id','definitionId','displayName','reviewType','status','startDateTime','endDateTime','scopeJson','reviewersJson','fallbackReviewersJson','errorsJson')
        accessReviewStages = @('tenantId','id','definitionId','instanceId','status','startDateTime','endDateTime','reviewersJson','fallbackReviewersJson')
        accessReviewDecisions = @('tenantId','id','definitionId','instanceId','stageId','decisionLevel','reviewType','principalId','principalDisplayName','principalType','resourceId','resourceDisplayName','resourceType','decision','recommendation','justification','reviewedById','reviewedByName','reviewedDateTime','applyResult','applyDescription','appliedById','appliedDateTime','principalLink','resourceLink','permissionJson')
        governanceAccessLinks = @('tenantId','assignmentId','packageId','principalId','resourceOriginId','accessAssignmentId','accessCollector','scope','roleName','accessPath','evidence')
        governanceFindings = @('tenantId','type','recordId','packageId','definitionId','instanceId','principalId','detail')
    }
}

function New-GovernanceState {
    param(
        [Parameter(Mandatory = $true)][string]$TenantId,
        [bool]$IncludePackages = $true,
        [bool]$IncludeReviews = $true,
        [ValidateRange(0, 36500)][int]$LookbackDays = 90,
        [DateTimeOffset]$Now = [DateTimeOffset]::UtcNow
    )
    $data = [ordered]@{}
    foreach ($name in (Get-GovernanceSchemas).Keys) { $data[$name] = [System.Collections.Generic.List[object]]::new() }
    return [pscustomobject]@{
        TenantId = $TenantId
        IncludePackages = $IncludePackages
        IncludeReviews = $IncludeReviews
        LookbackDays = $LookbackDays
        Now = $Now.ToUniversalTime()
        Data = $data
        Statuses = [System.Collections.Generic.List[object]]::new()
        Seen = @{}
        Definitions = @{}
        ExcludedInstances = 0
    }
}

function Add-GovernanceRecord {
    param($State, [string]$Dataset, [string]$Key, [hashtable]$Values)
    $seenKey = $Dataset + '|' + $Key
    if ($State.Seen.ContainsKey($seenKey)) { return }
    $row = [ordered]@{}
    foreach ($column in (Get-GovernanceSchemas)[$Dataset]) {
        $row[$column] = if ($column -eq 'tenantId') { $State.TenantId } elseif ($Values.ContainsKey($column)) { $Values[$column] } else { '' }
    }
    [void]$State.Data[$Dataset].Add([pscustomobject]$row)
    $State.Seen[$seenKey] = $true
}

function Read-GovernanceCollection {
    param([scriptblock]$Request, [string]$Url, [scriptblock]$OnItem)
    $visited = @{}
    while ($Url) {
        if ($visited.ContainsKey($Url)) { throw 'Graph returned a repeated pagination link.' }
        $visited[$Url] = $true
        $response = & $Request $Url
        if ($null -eq $response -or -not $response.PSObject.Properties['value']) { throw 'Graph collection response is missing value.' }
        foreach ($item in @(Get-GovernanceValue $response 'value')) {
            if ($null -ne $item) { & $OnItem $item }
        }
        $Url = [string](Get-GovernanceValue $response '@odata.nextLink')
    }
}

function Read-GovernanceExpansion {
    param([scriptblock]$Request, $Object, [string]$Property, [scriptblock]$OnItem)
    if ($null -eq $Object -or -not $Object.PSObject.Properties[$Property]) { throw "Graph response is missing expanded $Property." }
    foreach ($item in @(Get-GovernanceValue $Object $Property)) {
        if ($null -ne $item) { & $OnItem $item }
    }
    $next = [string](Get-GovernanceValue $Object ($Property + '@odata.nextLink'))
    if ($next) { Read-GovernanceCollection -Request $Request -Url $next -OnItem $OnItem }
}

function Invoke-GovernanceUnit {
    param($Issues, [scriptblock]$Action)
    try { & $Action $Issues }
    catch {
        $statusCode = $_.Exception.Data['StatusCode']
        $code = [string]$_.Exception.Data['ErrorCode']
        $status = if ($statusCode -eq 401 -or $statusCode -eq 403 -or $_.Exception.Message -match '(?i)forbidden|unauthorized|insufficient privileges|authorization|authentication') {
            'Unauthorized'
        } elseif ($statusCode -eq 429 -or $_.Exception.Message -match '429|throttl') { 'Throttled' } else { 'Failed' }
        [void]$Issues.Add([pscustomobject]@{ status = $status; errorCode = $code; message = $_.Exception.Message })
    }
}

function Invoke-GovernancePhase {
    param($State, [string]$Name, [string]$Dataset, [bool]$Enabled, [scriptblock]$Action, [scriptblock]$OnStart, [scriptblock]$OnComplete)
    $start = [DateTime]::UtcNow
    $before = $State.Data[$Dataset].Count
    $issues = [System.Collections.Generic.List[object]]::new()
    if ($Enabled -and $OnStart) { & $OnStart $Name }
    if ($Enabled) { Invoke-GovernanceUnit -Issues $issues -Action $Action }
    $added = $State.Data[$Dataset].Count - $before
    $status = if (-not $Enabled) { 'Skipped' } elseif ($issues.Count -eq 0) { 'Succeeded' } elseif ($added -gt 0) {
        'PartiallyCollected'
    } elseif (@($issues | Where-Object { $_.status -eq 'Unauthorized' }).Count -gt 0) { 'Unauthorized' } elseif (@($issues | Where-Object { $_.status -eq 'Throttled' }).Count -gt 0) { 'Throttled' } else { 'Failed' }
    $end = [DateTime]::UtcNow
    $record = [pscustomobject]@{
        collector = $Name; status = $status; startedUtc = $start.ToString('o'); endedUtc = $end.ToString('o')
        durationSeconds = [Math]::Round(($end - $start).TotalSeconds, 2)
        rowsAdded = $added; totalRows = $State.Data[$Dataset].Count
        message = if (-not $Enabled) { 'Disabled by collector option.' } else { (@($issues | ForEach-Object { $_.message }) -join '; ') }
        issues = @($issues.ToArray())
    }
    [void]$State.Statuses.Add($record)
    if ($OnComplete) { & $OnComplete $record }
}

function Get-GovernanceReviewType {
    param($Scope)
    $text = ConvertTo-GovernanceJson $Scope
    if ($text -match '(?i)accessPackageAssignments') { return 'AccessPackage' }
    if ($text -match '(?i)roleAssignmentScheduleInstances|roleEligibilityScheduleInstances|roleManagement/directory') { return 'DirectoryRole' }
    if ($text -match '(?i)servicePrincipals|appRoleAssignedTo') { return 'Application' }
    if ($text -match '(?i)/groups|[.]/members') { return 'Group' }
    return 'Unknown'
}

function Add-GovernanceDependencyIssue {
    param($State, $Issues, [string[]]$Parents)
    if (@($State.Statuses | Where-Object { $_.collector -in $Parents -and $_.status -ne 'Succeeded' }).Count) {
        [void]$Issues.Add([pscustomobject]@{ status='Failed'; errorCode='IncompleteParent'; message=('Coverage is incomplete because parent collection was incomplete: ' + ($Parents -join ', ')) })
    }
}

function Test-GovernanceInstanceIncluded {
    param($Instance, $State)
    if ($State.LookbackDays -eq 0) { return $true }
    $status = [string](Get-GovernanceValue $Instance 'status')
    if ($status -notin @('Completed','AutoReviewed','Applied')) { return $true }
    $end = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse([string](Get-GovernanceValue $Instance 'endDateTime'), [ref]$end)) { return $true }
    return $end -ge $State.Now.AddDays(-$State.LookbackDays)
}

function Add-GovernanceDecision {
    param($State, $Item, $Instance, [string]$StageId = '')
    $principal = Get-GovernanceValue $Item 'principal'
    $resource = Get-GovernanceValue $Item 'resource'
    $reviewer = Get-GovernanceValue $Item 'reviewedBy'
    $appliedBy = Get-GovernanceValue $Item 'appliedBy'
    $id = [string](Get-GovernanceValue $Item 'id')
    if (-not $id) { throw 'Graph decision is missing its identifier.' }
    Add-GovernanceRecord $State 'accessReviewDecisions' ($Instance.definitionId + '|' + $Instance.id + '|' + $StageId + '|' + $id) @{
        id = $id; definitionId = $Instance.definitionId; instanceId = $Instance.id; stageId = $StageId
        decisionLevel = $(if ($StageId) { 'Stage' } else { 'Instance' }); reviewType = $Instance.reviewType
        principalId = Get-GovernanceValue $principal 'id'; principalDisplayName = Get-GovernanceValue $principal 'displayName'
        principalType = Get-GovernanceValue $principal '@odata.type'
        resourceId = Get-GovernanceValue $resource 'id'; resourceDisplayName = Get-GovernanceValue $resource 'displayName'
        resourceType = Get-GovernanceValue $resource '@odata.type'
        decision = Get-GovernanceValue $Item 'decision'; recommendation = Get-GovernanceValue $Item 'recommendation'
        justification = Get-GovernanceValue $Item 'justification'; reviewedById = Get-GovernanceValue $reviewer 'id'
        reviewedByName = Get-GovernanceValue $reviewer 'displayName'; reviewedDateTime = Get-GovernanceValue $Item 'reviewedDateTime'
        applyResult = Get-GovernanceValue $Item 'applyResult'; applyDescription = Get-GovernanceValue $Item 'applyDescription'
        appliedById = Get-GovernanceValue $appliedBy 'id'; appliedDateTime = Get-GovernanceValue $Item 'appliedDateTime'
        principalLink = Get-GovernanceValue $Item 'principalLink'; resourceLink = Get-GovernanceValue $Item 'resourceLink'
        permissionJson = ConvertTo-GovernanceJson (Get-GovernanceValue $Item 'permission')
    }
}

function Invoke-GovernanceScan {
    param([Parameter(Mandatory = $true)]$State, [Parameter(Mandatory = $true)][scriptblock]$Request, [scriptblock]$OnStart, [scriptblock]$OnComplete)
    $base = 'https://graph.microsoft.com/v1.0/identityGovernance'
    $em = $base + '/entitlementManagement'
    $ar = $base + '/accessReviews/definitions'
    Invoke-GovernancePhase $State 'AccessPackageCatalogs' 'accessCatalogs' $State.IncludePackages {
        param($issues)
        Read-GovernanceCollection $Request ($em + '/catalogs') {
            param($item)
            $id = [string](Get-GovernanceValue $item 'id')
            if (-not $id) { throw 'Graph catalog is missing its identifier.' }
            $values = @{}
            foreach ($key in @('id','displayName','description','state','isExternallyVisible','createdDateTime','modifiedDateTime')) { $values[$key] = Get-GovernanceValue $item $key }
            Add-GovernanceRecord $State 'accessCatalogs' $id $values
        }
    } $OnStart $OnComplete
    Invoke-GovernancePhase $State 'AccessPackages' 'accessPackages' $State.IncludePackages {
        param($issues)
        Read-GovernanceCollection $Request ($em + '/accessPackages?$expand=catalog') {
            param($item)
            $id = [string](Get-GovernanceValue $item 'id')
            if (-not $id) { throw 'Graph package is missing its identifier.' }
            $values = @{ catalogId = Get-GovernanceValue (Get-GovernanceValue $item 'catalog') 'id' }
            foreach ($key in @('id','displayName','description','isHidden','createdDateTime','modifiedDateTime')) { $values[$key] = Get-GovernanceValue $item $key }
            Add-GovernanceRecord $State 'accessPackages' $id $values
        }
    } $OnStart $OnComplete
    Invoke-GovernancePhase $State 'AccessPackagePolicies' 'accessPackagePolicies' $State.IncludePackages {
        param($issues)
        Add-GovernanceDependencyIssue $State $issues @('AccessPackages')
        foreach ($package in $State.Data.accessPackages) {
            Invoke-GovernanceUnit $issues {
                $response = & $Request ($em + '/accessPackages/' + [Uri]::EscapeDataString($package.id) + '?$expand=assignmentPolicies')
                Read-GovernanceExpansion $Request $response 'assignmentPolicies' {
                    param($item)
                    $id = [string](Get-GovernanceValue $item 'id')
                    if (-not $id) { throw 'Graph policy is missing its identifier.' }
                    $approval = Get-GovernanceValue $item 'requestApprovalSettings'
                    $expiration = Get-GovernanceValue $item 'expiration'
                    $reviews = Get-GovernanceValue $item 'reviewSettings'
                    $values = @{
                        packageId = $package.id
                        approvalRequired = Get-GovernanceValue $approval 'isApprovalRequiredForAdd'
                        expirationType = Get-GovernanceValue $expiration 'type'
                        expirationDuration = Get-GovernanceValue $expiration 'duration'
                        expirationEndDateTime = Get-GovernanceValue $expiration 'endDateTime'
                        reviewsEnabled = Get-GovernanceValue $reviews 'isEnabled'
                    }
                    foreach ($key in @('id','displayName','description','allowedTargetScope','createdDateTime','modifiedDateTime')) { $values[$key] = Get-GovernanceValue $item $key }
                    foreach ($key in @('reviewSettings','requestApprovalSettings','requestorSettings','automaticRequestSettings','specificAllowedTargets')) { $values[$key + 'Json'] = ConvertTo-GovernanceJson (Get-GovernanceValue $item $key) }
                    Add-GovernanceRecord $State 'accessPackagePolicies' $id $values
                }
            }
        }
    } $OnStart $OnComplete
    Invoke-GovernancePhase $State 'AccessPackageResources' 'accessPackageResources' $State.IncludePackages {
        param($issues)
        Add-GovernanceDependencyIssue $State $issues @('AccessPackages')
        $catalogRoles = @{}
        foreach ($package in $State.Data.accessPackages) {
            if ($package.catalogId -and -not $catalogRoles.ContainsKey($package.catalogId)) {
                $catalogRoles[$package.catalogId] = @{}
                Invoke-GovernanceUnit $issues {
                    $catalogResources = [System.Collections.Generic.List[object]]::new()
                    $catalogUrl = $em + '/catalogs/' + [Uri]::EscapeDataString($package.catalogId)
                    Read-GovernanceCollection $Request ($catalogUrl + '/resources') {
                        param($item)
                        [void]$catalogResources.Add($item)
                    }
                    foreach ($catalogResource in $catalogResources) {
                        Invoke-GovernanceUnit $issues {
                            $originSystem = [string](Get-GovernanceValue $catalogResource 'originSystem')
                            $resourceId = [string](Get-GovernanceValue $catalogResource 'id')
                            $filter = [Uri]::EscapeDataString("(originSystem eq '$($originSystem -replace "'", "''")' and resource/id eq '$($resourceId -replace "'", "''")')")
                            Read-GovernanceCollection $Request ($catalogUrl + '/resourceRoles?$filter=' + $filter + '&$expand=resource') {
                                param($item)
                                $metadata = Get-GovernanceValue $item 'resource'
                                if ($null -eq $metadata) { $metadata = $catalogResource }
                                $id = [string](Get-GovernanceValue $item 'id')
                                if ($id) {
                                    $idKey = 'id|' + $id
                                    if ($catalogRoles[$package.catalogId].ContainsKey($idKey) -and (Get-GovernanceValue $catalogRoles[$package.catalogId][$idKey] 'id') -ne $resourceId) { $catalogRoles[$package.catalogId][$idKey] = $null }
                                    else { $catalogRoles[$package.catalogId][$idKey] = $metadata }
                                }
                                $originKey = 'origin|' + $originSystem + '|' + [string](Get-GovernanceValue $item 'originId')
                                if ($catalogRoles[$package.catalogId].ContainsKey($originKey) -and (Get-GovernanceValue $catalogRoles[$package.catalogId][$originKey] 'id') -ne $resourceId) {
                                    $catalogRoles[$package.catalogId][$originKey] = $null
                                }
                                else { $catalogRoles[$package.catalogId][$originKey] = $metadata }
                            }
                        }
                    }
                }
            }
            Invoke-GovernanceUnit $issues {
                $response = & $Request ($em + '/accessPackages/' + [Uri]::EscapeDataString($package.id) + '?$expand=resourceRoleScopes($expand=role,scope)')
                Read-GovernanceExpansion $Request $response 'resourceRoleScopes' {
                    param($item)
                    $role = Get-GovernanceValue $item 'role'
                    $scope = Get-GovernanceValue $item 'scope'
                    $resource = Get-GovernanceValue $role 'resource'
                    $roleId = [string](Get-GovernanceValue $role 'id')
                    if ($null -eq $resource -and $package.catalogId) {
                        $roles = $catalogRoles[$package.catalogId]
                        $originKey = 'origin|' + [string](Get-GovernanceValue $role 'originSystem') + '|' + [string](Get-GovernanceValue $role 'originId')
                        if ($roles.ContainsKey('id|' + $roleId)) { $resource = $roles['id|' + $roleId] }
                        if ($null -eq $resource -and $roles.ContainsKey($originKey)) { $resource = $roles[$originKey] }
                    }
                    if ($null -eq $resource) {
                        [void]$issues.Add([pscustomobject]@{status='Failed';errorCode='UnresolvedResource';message='A collected package resource role could not be matched to catalog resource metadata.'})
                    }
                    $id = [string](Get-GovernanceValue $item 'id')
                    if (-not $id) { throw 'Graph resource role scope is missing its identifier.' }
                    Add-GovernanceRecord $State 'accessPackageResources' ($package.id + '|' + $id) @{
                        packageId = $package.id; id = $id; resourceId = Get-GovernanceValue $resource 'id'
                        resourceOriginId = Get-GovernanceValue $resource 'originId'; originSystem = Get-GovernanceValue $resource 'originSystem'
                        resourceDisplayName = Get-GovernanceValue $resource 'displayName'; roleId = Get-GovernanceValue $role 'id'
                        roleOriginId = Get-GovernanceValue $role 'originId'; roleDisplayName = Get-GovernanceValue $role 'displayName'
                        scopeId = Get-GovernanceValue $scope 'id'; scopeOriginId = Get-GovernanceValue $scope 'originId'
                        scopeDisplayName = Get-GovernanceValue $scope 'displayName'
                    }
                }
            }
        }
    } $OnStart $OnComplete
    Invoke-GovernancePhase $State 'AccessPackageAssignments' 'accessPackageAssignments' $State.IncludePackages {
        param($issues)
        Add-GovernanceDependencyIssue $State $issues @('AccessPackages')
        foreach ($package in $State.Data.accessPackages) {
            Invoke-GovernanceUnit $issues {
                $filter = [Uri]::EscapeDataString("accessPackage/id eq '$($package.id -replace "'", "''")'")
                Read-GovernanceCollection $Request ($em + '/assignments?$filter=' + $filter + '&$expand=target,assignmentPolicy') {
                    param($item)
                    $target = Get-GovernanceValue $item 'target'
                    $schedule = Get-GovernanceValue $item 'schedule'
                    $expiration = Get-GovernanceValue $schedule 'expiration'
                    $id = [string](Get-GovernanceValue $item 'id')
                    if (-not $id) { throw 'Graph assignment is missing its identifier.' }
                    Add-GovernanceRecord $State 'accessPackageAssignments' $id @{
                        id = $id; packageId = $package.id; policyId = Get-GovernanceValue (Get-GovernanceValue $item 'assignmentPolicy') 'id'
                        subjectId = Get-GovernanceValue $target 'id'; principalId = Get-GovernanceValue $target 'objectId'
                        principalType = Get-GovernanceValue $target 'subjectType'; principalDisplayName = Get-GovernanceValue $target 'displayName'
                        principalName = Get-GovernanceValue $target 'principalName'; email = Get-GovernanceValue $target 'email'
                        state = Get-GovernanceValue $item 'state'; status = Get-GovernanceValue $item 'status'
                        startDateTime = Get-GovernanceValue $schedule 'startDateTime'
                        expirationType = Get-GovernanceValue $expiration 'type'; expirationDuration = Get-GovernanceValue $expiration 'duration'
                        endDateTime = Get-GovernanceValue $expiration 'endDateTime'; expiredDateTime = Get-GovernanceValue $item 'expiredDateTime'
                    }
                }
            }
        }
    } $OnStart $OnComplete
    Invoke-GovernancePhase $State 'AccessReviewDefinitions' 'accessReviewDefinitions' $State.IncludeReviews {
        param($issues)
        Read-GovernanceCollection $Request $ar {
            param($item)
            $id = [string](Get-GovernanceValue $item 'id')
            if (-not $id) { throw 'Graph review definition is missing its identifier.' }
            $values = @{ reviewType = Get-GovernanceReviewType (Get-GovernanceValue $item 'scope') }
            foreach ($key in @('id','displayName','status','createdDateTime','lastModifiedDateTime')) { $values[$key] = Get-GovernanceValue $item $key }
            foreach ($key in @('scope','instanceEnumerationScope','settings','reviewers','fallbackReviewers','stageSettings')) { $values[$key + 'Json'] = ConvertTo-GovernanceJson (Get-GovernanceValue $item $key) }
            Add-GovernanceRecord $State 'accessReviewDefinitions' $id $values
            $State.Definitions[$id] = $item
        }
    } $OnStart $OnComplete
    Invoke-GovernancePhase $State 'AccessReviewInstances' 'accessReviewInstances' $State.IncludeReviews {
        param($issues)
        Add-GovernanceDependencyIssue $State $issues @('AccessReviewDefinitions')
        foreach ($definition in $State.Data.accessReviewDefinitions) {
            Invoke-GovernanceUnit $issues {
                Read-GovernanceCollection $Request ($ar + '/' + [Uri]::EscapeDataString($definition.id) + '/instances') {
                    param($item)
                    if (-not (Test-GovernanceInstanceIncluded $item $State)) { $State.ExcludedInstances++; return }
                    $id = [string](Get-GovernanceValue $item 'id')
                    if (-not $id) { throw 'Graph review instance is missing its identifier.' }
                    $values = @{ definitionId = $definition.id; displayName = $definition.displayName; reviewType = $definition.reviewType }
                    foreach ($key in @('id','status','startDateTime','endDateTime')) { $values[$key] = Get-GovernanceValue $item $key }
                    foreach ($key in @('scope','reviewers','fallbackReviewers','errors')) { $values[$key + 'Json'] = ConvertTo-GovernanceJson (Get-GovernanceValue $item $key) }
                    Add-GovernanceRecord $State 'accessReviewInstances' ($definition.id + '|' + $id) $values
                }
            }
        }
    } $OnStart $OnComplete
    Invoke-GovernancePhase $State 'AccessReviewStages' 'accessReviewStages' $State.IncludeReviews {
        param($issues)
        Add-GovernanceDependencyIssue $State $issues @('AccessReviewInstances')
        foreach ($instance in $State.Data.accessReviewInstances) {
            if (@(Get-GovernanceValue $State.Definitions[$instance.definitionId] 'stageSettings').Count -eq 0) { continue }
            Invoke-GovernanceUnit $issues {
                Read-GovernanceCollection $Request ($ar + '/' + [Uri]::EscapeDataString($instance.definitionId) + '/instances/' + [Uri]::EscapeDataString($instance.id) + '/stages') {
                    param($item)
                    $id = [string](Get-GovernanceValue $item 'id')
                    if (-not $id) { throw 'Graph review stage is missing its identifier.' }
                    $values = @{ definitionId = $instance.definitionId; instanceId = $instance.id }
                    foreach ($key in @('id','status','startDateTime','endDateTime')) { $values[$key] = Get-GovernanceValue $item $key }
                    foreach ($key in @('reviewers','fallbackReviewers')) { $values[$key + 'Json'] = ConvertTo-GovernanceJson (Get-GovernanceValue $item $key) }
                    Add-GovernanceRecord $State 'accessReviewStages' ($instance.definitionId + '|' + $instance.id + '|' + $id) $values
                }
            }
        }
    } $OnStart $OnComplete
    Invoke-GovernancePhase $State 'AccessReviewDecisions' 'accessReviewDecisions' $State.IncludeReviews {
        param($issues)
        Add-GovernanceDependencyIssue $State $issues @('AccessReviewInstances','AccessReviewStages')
        foreach ($instance in $State.Data.accessReviewInstances) {
            $instanceUrl = $ar + '/' + [Uri]::EscapeDataString($instance.definitionId) + '/instances/' + [Uri]::EscapeDataString($instance.id)
            Invoke-GovernanceUnit $issues {
                Read-GovernanceCollection $Request ($instanceUrl + '/decisions') {
                    param($item)
                    Add-GovernanceDecision $State $item $instance
                }
            }
            foreach ($stage in @($State.Data.accessReviewStages | Where-Object { $_.definitionId -eq $instance.definitionId -and $_.instanceId -eq $instance.id })) {
                Invoke-GovernanceUnit $issues {
                    Read-GovernanceCollection $Request ($instanceUrl + '/stages/' + [Uri]::EscapeDataString($stage.id) + '/decisions') {
                        param($item)
                        Add-GovernanceDecision $State $item $instance $stage.id
                    }
                }
            }
        }
    } $OnStart $OnComplete
}

function Complete-GovernanceAnalysis {
    param($State, [AllowEmptyCollection()][object[]]$AccessRows = @())
    foreach ($policy in $State.Data.accessPackagePolicies) {
        if ([string]$policy.reviewsEnabled -eq 'False') {
            Add-GovernanceRecord $State 'governanceFindings' ('PolicyWithoutReviews|' + $policy.id) @{
                type = 'PolicyWithoutReviews'; recordId = $policy.id; packageId = $policy.packageId
                detail = 'The collected assignment policy explicitly disables access reviews.'
            }
        }
    }
    foreach ($instance in $State.Data.accessReviewInstances) {
        $end = [DateTimeOffset]::MinValue
        if ($instance.status -in @('Initializing','NotStarted','Starting','InProgress','Completing','AutoReviewing') -and [DateTimeOffset]::TryParse([string]$instance.endDateTime, [ref]$end) -and $end -lt $State.Now) {
            Add-GovernanceRecord $State 'governanceFindings' ('OverdueReview|' + $instance.definitionId + '|' + $instance.id) @{
                type = 'OverdueReview'; recordId = $instance.id; definitionId = $instance.definitionId; instanceId = $instance.id
                detail = 'The review is still active after its scheduled end time.'
            }
        }
    }
    foreach ($decision in $State.Data.accessReviewDecisions) {
        if ($decision.decisionLevel -ne 'Instance' -or $decision.decision -ne 'Deny' -or $decision.applyResult -eq 'AppliedSuccessfully') { continue }
        $type = if ($decision.applyResult -eq 'New') { 'DeniedAwaitingApplication' } else { 'DeniedApplicationNeedsAttention' }
        Add-GovernanceRecord $State 'governanceFindings' ($type + '|' + $decision.definitionId + '|' + $decision.instanceId + '|' + $decision.id) @{
            type = $type; recordId = $decision.id; definitionId = $decision.definitionId; instanceId = $decision.instanceId; principalId = $decision.principalId
            detail = 'A denied decision does not establish revoked access. Reported apply result: ' + $decision.applyResult
        }
    }
    $observed = @{}
    foreach ($row in $AccessRows) {
        if (-not $row.sourceGroupId -or -not $row.effectivePrincipalId -or $row.assignmentState -ne 'Active') { continue }
        $key = $row.sourceGroupId + '|' + $row.effectivePrincipalId
        if (-not $observed.ContainsKey($key)) { $observed[$key] = [System.Collections.Generic.List[object]]::new() }
        [void]$observed[$key].Add($row)
    }
    $resourcesByPackage = @{}
    foreach ($resource in $State.Data.accessPackageResources) {
        if ($resource.originSystem -ne 'AadGroup' -or -not $resource.resourceOriginId -or ($resource.roleDisplayName -ne 'Member' -and $resource.roleOriginId -notmatch '^Member(?:_|$)')) { continue }
        if (-not $resourcesByPackage.ContainsKey($resource.packageId)) { $resourcesByPackage[$resource.packageId] = [System.Collections.Generic.List[object]]::new() }
        [void]$resourcesByPackage[$resource.packageId].Add($resource)
    }
    foreach ($assignment in $State.Data.accessPackageAssignments) {
        if ($assignment.state -ne 'delivered' -or -not $assignment.principalId -or $assignment.expiredDateTime -or -not $resourcesByPackage.ContainsKey($assignment.packageId)) { continue }
        foreach ($resource in $resourcesByPackage[$assignment.packageId]) {
            $key = $resource.resourceOriginId + '|' + $assignment.principalId
            if (-not $observed.ContainsKey($key)) { continue }
            foreach ($row in $observed[$key]) {
                $linkKey = @($assignment.id,$row.collector,$row.assignmentId,$row.scope,$row.roleName,$row.accessPath,$resource.resourceOriginId) -join '|'
                Add-GovernanceRecord $State 'governanceAccessLinks' $linkKey @{
                    assignmentId = $assignment.id; packageId = $assignment.packageId; principalId = $assignment.principalId
                    resourceOriginId = $resource.resourceOriginId; accessAssignmentId = $row.assignmentId; accessCollector = $row.collector
                    scope = $row.scope; roleName = $row.roleName; accessPath = $row.accessPath
                    evidence = 'Delivered package assignment; configured group Member role; matching observed active group-derived access. This does not establish exclusive causation.'
                }
            }
        }
    }
}

function Get-GovernanceCoverage {
    param($State)
    $totals = [ordered]@{}
    foreach ($name in $State.Data.Keys) { $totals[$name] = $State.Data[$name].Count }
    return [ordered]@{
        tenantId = $State.TenantId; enabledPackages = $State.IncludePackages; enabledReviews = $State.IncludeReviews
        lookbackDays = $State.LookbackDays
        cutoffUtc = $(if ($State.LookbackDays -eq 0) { '' } else { $State.Now.AddDays(-$State.LookbackDays).ToString('o') })
        generatedUtc = $State.Now.ToString('o'); excludedReviewInstances = $State.ExcludedInstances
        visibility = 'Objects visible to the authenticated caller; tenant-wide completeness is not assumed.'
        totals = $totals
        statuses = @($State.Statuses | Select-Object collector,status,rowsAdded,message)
    }
}

function Export-GovernanceOutputs {
    param($State, [string]$OutputDirectory, [switch]$EmitJson)
    $paths = [System.Collections.Generic.List[string]]::new()
    foreach ($name in $State.Data.Keys) {
        $csv = Join-Path $OutputDirectory ($name + '.csv')
        Export-ObjectList -Path $csv -Rows @($State.Data[$name].ToArray()) -Columns (Get-GovernanceSchemas)[$name]
        [void]$paths.Add($csv)
        if ($EmitJson) {
            $json = Join-Path $OutputDirectory ($name + '.json')
            Write-JsonFile -Path $json -Data @($State.Data[$name].ToArray()) -Depth 40
            [void]$paths.Add($json)
        }
    }
    return $paths.ToArray()
}

Export-ModuleMember -Function New-GovernanceState, Invoke-GovernanceScan, Complete-GovernanceAnalysis, Get-GovernanceCoverage, Get-GovernanceSchemas, Export-GovernanceOutputs
