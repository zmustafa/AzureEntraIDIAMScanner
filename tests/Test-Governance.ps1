[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'lib\AzureScannerCommon.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $root 'lib\AzureScannerGovernance.psm1') -Force -DisableNameChecking
$script:assertions = 0

function Assert-Equal {
    param($Actual, $Expected, [string]$Message)
    if ($Actual -ne $Expected) { throw "$Message (expected '$Expected', got '$Actual')" }
    $script:assertions++
}

function New-TestRequest {
    param([hashtable]$Options = @{})
    $now = [DateTimeOffset]'2026-10-15T12:00:00Z'
    return {
        param($url)
        if ($Options.ContainsKey('FailAll')) {
            $errorObject = [InvalidOperationException]::new('Forbidden fixture request.')
            $errorObject.Data['StatusCode'] = 403
            throw $errorObject
        }
        if ($url -like '*/page2') { throw 'Graph request failed (HTTP 503, synthetic page failure).' }
        if ($url -like '*/catalogs') { return [pscustomobject]@{value=@([pscustomobject]@{id='catalog';displayName='Synthetic catalog'})} }
        if ($url -like '*/catalogs/catalog/resources') {
            return [pscustomobject]@{value=@([pscustomobject]@{id='em-group';originId='directory-group';originSystem='AadGroup';displayName='Synthetic group'})}
        }
        if ($url -match '/resourceRoles[?]') {
            if ($url -notmatch '\$filter=') { throw 'Resource role discovery requires a resource-scoped filter.' }
            $roles = foreach ($name in @('Member','Owner')) {
                [pscustomobject]@{id=($(if($Options.ContainsKey('EphemeralRoleIds')){'temporary-'}else{'role-'})+$name);originId=($name+'_group');originSystem='AadGroup';resource=[pscustomobject]@{id='em-group';originId='directory-group';originSystem='AadGroup';displayName='Synthetic group'}}
            }
            return [pscustomobject]@{value=@($roles)}
        }
        if ($url -match '/accessPackages[?]') {
            $packages = @('package1','package2','package3') | ForEach-Object { [pscustomobject]@{id=$_;displayName=$_;catalog=[pscustomobject]@{id='catalog'}} }
            if ($Options.ContainsKey('FailPage')) { return [pscustomobject]@{value=@($packages[0]);'@odata.nextLink'='https://graph.microsoft.com/v1.0/page2'} }
            return [pscustomobject]@{value=@($packages)}
        }
        if ($url -match '/accessPackages/([^?]+)[?]') {
            $packageId = $Matches[1]
            if ($url -like '*assignmentPolicies*') {
                if ($Options.ContainsKey('FailPolicy') -and $packageId -eq 'package1') { throw 'Forbidden synthetic policy.' }
                $settings = if ($packageId -eq 'package3') { $null } else { [pscustomobject]@{isEnabled=($packageId -eq 'package2')} }
                $response = [pscustomobject]@{assignmentPolicies=@([pscustomobject]@{id=('policy-' + $packageId);reviewSettings=$settings;requestApprovalSettings=[pscustomobject]@{isApprovalRequiredForAdd=$true};expiration=[pscustomobject]@{type='afterDuration';duration='P30D'}})}
                if ($Options.ContainsKey('ExpandedPage') -and $packageId -eq 'package1') {
                    $response | Add-Member NoteProperty 'assignmentPolicies@odata.nextLink' 'https://graph.microsoft.com/v1.0/policy-page'
                }
                return $response
            }
            $role = if ($packageId -eq 'package3') { 'Owner' } else { 'Member' }
            return [pscustomobject]@{resourceRoleScopes=@([pscustomobject]@{
                id=('resource-' + $packageId)
                role=[pscustomobject]@{id=('role-'+$role);displayName=$role;originId=($role + '_group');originSystem='AadGroup'}
                scope=[pscustomobject]@{id='scope';originId='directory-group'}
            })}
        }
        if ($url -like '*/policy-page') { return [pscustomobject]@{value=@([pscustomobject]@{id='policy-extra';reviewSettings=[pscustomobject]@{isEnabled=$true}})} }
        if ($url -like '*/assignments?*') {
            $decoded = [Uri]::UnescapeDataString($url)
            if ($decoded -notmatch "accessPackage/id eq '(package[123])'") { throw 'Missing package-scoped assignment filter.' }
            $packageId = $Matches[1]
            $items = @([pscustomobject]@{
                id=('assignment-' + $packageId);state='delivered';status='Delivered'
                target=[pscustomobject]@{id='unstable-subject';objectId='directory-user';subjectType='user';displayName='Synthetic user';principalName='user@example.invalid'}
                assignmentPolicy=[pscustomobject]@{id=('policy-' + $packageId)}
                schedule=[pscustomobject]@{startDateTime='2026-01-01T00:00:00Z';expiration=[pscustomobject]@{type='noExpiration'}}
            })
            if ($packageId -eq 'package1') {
                $items += [pscustomobject]@{id='partial';state='partiallyDelivered';target=[pscustomobject]@{objectId='directory-user'}}
                $items += [pscustomobject]@{id='external';state='expired';target=[pscustomobject]@{id='external-subject';objectId=$null;email='external@example.invalid'}}
            }
            return [pscustomobject]@{value=$items}
        }
        if ($url -like '*/accessReviews/definitions') {
            $queries = @('/identityGovernance/entitlementManagement/accessPackageAssignments','/groups/group/members','/servicePrincipals/app/appRoleAssignedTo','/roleManagement/directory/roleAssignmentScheduleInstances','/futureResource')
            $items = for ($i=0; $i -lt $queries.Count; $i++) {
                [pscustomobject]@{id=('definition' + $i);displayName=('Synthetic review ' + $i);scope=[pscustomobject]@{query=$queries[$i]};stageSettings=$(if ($i -eq 1) { @([pscustomobject]@{stageId=1}) } else { @() })}
            }
            return [pscustomobject]@{value=@($items)}
        }
        if ($url -match '/definitions/(definition[0-4])/instances$') {
            return [pscustomobject]@{value=@(
                [pscustomobject]@{id='active';status='InProgress';startDateTime=$now.AddDays(-120).ToString('o');endDateTime=$now.AddDays(-100).ToString('o')},
                [pscustomobject]@{id='recent';status='Completed';endDateTime=$now.AddDays(-1).ToString('o')},
                [pscustomobject]@{id='boundary';status='Completed';endDateTime=$now.AddDays(-90).ToString('o')},
                [pscustomobject]@{id='old';status='Completed';endDateTime=$now.AddDays(-91).ToString('o')}
            )}
        }
        if ($url -like '*/stages') { return [pscustomobject]@{value=@([pscustomobject]@{id='stage1';status='Completed'})} }
        if ($url -like '*/decisions') {
            $result = if ($url -like '*/definition3/*') { 'AppliedSuccessfully' } else { 'New' }
            return [pscustomobject]@{value=@([pscustomobject]@{
                id='decision';decision='Deny';applyResult=$result;justification='Synthetic justification, not for logs.'
                principal=[pscustomobject]@{id='directory-user';displayName='Synthetic user';'@odata.type'='#microsoft.graph.userIdentity'}
                resource=[pscustomobject]@{id='directory-group';displayName='Synthetic group'}
                reviewedBy=[pscustomobject]@{id='reviewer';displayName='Synthetic reviewer'}
            })}
        }
        throw "Unexpected synthetic request: $url"
    }.GetNewClosure()
}

$now = [DateTimeOffset]'2026-10-15T12:00:00Z'
$state = New-GovernanceState -TenantId 'synthetic-tenant' -Now $now
Invoke-GovernanceScan -State $state -Request (New-TestRequest)
Assert-Equal @($state.Statuses | Where-Object { $_.status -ne 'Succeeded' }).Count 0 'All synthetic collectors succeed'
Assert-Equal $state.Data.accessPackages.Count 3 'Package inventory'
Assert-Equal $state.Data.accessPackageAssignments.Count 5 'Assignment inventory'
Assert-Equal $state.Data.accessReviewDefinitions.Count 5 'All known and unknown review scopes'
Assert-Equal $state.Data.accessReviewInstances.Count 15 'Active, recent, and exact-boundary instances'
Assert-Equal $state.ExcludedInstances 5 'Old completed instances excluded'
Assert-Equal $state.Data.accessReviewStages.Count 3 'Stages collected only for multistage definitions'
Assert-Equal $state.Data.accessReviewDecisions.Count 18 'Instance and stage history retained'
Assert-Equal @($state.Data.accessReviewDecisions | Where-Object { $_.decisionLevel -eq 'Instance' }).Count 15 'Final decisions distinguish stages'
Assert-Equal ($state.Data.accessPackageAssignments | Where-Object { $_.id -eq 'assignment-package1' }).principalId 'directory-user' 'Use stable directory object ID'
Assert-Equal ([string]($state.Data.accessPackageAssignments | Where-Object { $_.id -eq 'external' }).principalId) '' 'External subject does not invent a directory object ID'
Assert-Equal ($state.Data.accessPackageAssignments | Where-Object { $_.id -eq 'partial' }).state 'partiallyDelivered' 'Preserve partial delivery state'
Assert-Equal @($state.Data.accessReviewDefinitions | Where-Object { $_.reviewType -eq 'Unknown' }).Count 1 'Unknown review scopes retained'
Assert-Equal @($state.Data.accessPackagePolicies | Where-Object { $_.reviewsEnabled -eq $true }).Count 1 'Review-enabled policy mapped'
$observed = [pscustomobject]@{sourceGroupId='directory-group';effectivePrincipalId='directory-user';assignmentState='Active';collector='AzureSubscriptionRbac';assignmentId='rbac';scope='/subscriptions/synthetic';roleName='Reader';accessPath='GroupTransitive'}
Complete-GovernanceAnalysis -State $state -AccessRows @($observed,$observed)
Assert-Equal $state.Data.governanceAccessLinks.Count 2 'Two provenance links, duplicate observations and Owner role excluded'
Assert-Equal @($state.Data.governanceFindings | Where-Object { $_.type -eq 'PolicyWithoutReviews' }).Count 1 'Absent review settings are not disabled settings'
Assert-Equal @($state.Data.governanceFindings | Where-Object { $_.type -eq 'OverdueReview' }).Count 5 'Old active reviews remain and are overdue'
Assert-Equal @($state.Data.governanceFindings | Where-Object { $_.type -eq 'DeniedAwaitingApplication' }).Count 12 'Unapplied denies counted only at instance level'
Complete-GovernanceAnalysis -State $state -AccessRows @($observed)
Assert-Equal $state.Data.governanceAccessLinks.Count 2 'Analysis is idempotent'
$lifecycle = New-GovernanceState -TenantId 'synthetic' -Now $now
foreach ($status in @('Initializing','NotStarted','Starting','InProgress','Completing','AutoReviewing','Completed','AutoReviewed','FutureStatus')) {
    [void]$lifecycle.Data.accessReviewInstances.Add([pscustomobject]@{id=$status;definitionId='lifecycle';status=$status;endDateTime=$now.AddDays(-1).ToString('o')})
}
Complete-GovernanceAnalysis -State $lifecycle
Assert-Equal $lifecycle.Data.governanceFindings.Count 6 'All open review lifecycle states can be overdue'
foreach ($status in @('Completed','AutoReviewed','FutureStatus')) {
    Assert-Equal @($lifecycle.Data.governanceFindings | Where-Object recordId -eq $status).Count 0 ('Do not mark a terminal or unknown lifecycle state overdue: ' + $status)
}
$all = New-GovernanceState -TenantId 'synthetic' -Now $now -LookbackDays 0
Invoke-GovernanceScan -State $all -Request (New-TestRequest)
Assert-Equal $all.Data.accessReviewInstances.Count 20 'Zero lookback includes all available history'
$partial = New-GovernanceState -TenantId 'synthetic' -Now $now -IncludeReviews $false
Invoke-GovernanceScan -State $partial -Request (New-TestRequest @{FailPage=$true})
Assert-Equal $partial.Data.accessPackages.Count 1 'Retain a page collected before a failure'
Assert-Equal ($partial.Statuses | Where-Object { $_.collector -eq 'AccessPackages' }).status 'PartiallyCollected' 'Later page failure is not empty success'
Assert-Equal ($partial.Statuses | Where-Object { $_.collector -eq 'AccessPackagePolicies' }).status 'PartiallyCollected' 'Propagate incomplete parent coverage'
Assert-Equal @($partial.Statuses | Where-Object { $_.collector -like 'AccessReview*' -and $_.status -eq 'Skipped' }).Count 4 'Disabled reviews recorded as skipped'
$denied = New-GovernanceState -TenantId 'synthetic' -Now $now
Invoke-GovernanceScan -State $denied -Request (New-TestRequest @{FailAll=$true})
Assert-Equal ($denied.Statuses | Where-Object { $_.collector -eq 'AccessPackages' }).status 'Unauthorized' '403 classification'
Assert-Equal ($denied.Statuses | Where-Object { $_.collector -eq 'AccessReviewDecisions' }).status 'Failed' 'Failed parents do not yield successful empty decisions'
$expanded = New-GovernanceState -TenantId 'synthetic' -IncludeReviews $false
Invoke-GovernanceScan -State $expanded -Request (New-TestRequest @{ExpandedPage=$true})
Assert-Equal $expanded.Data.accessPackagePolicies.Count 4 'Expanded relationship pagination'
$ephemeral = New-GovernanceState -TenantId 'synthetic' -IncludeReviews $false
Invoke-GovernanceScan -State $ephemeral -Request (New-TestRequest @{EphemeralRoleIds=$true})
Assert-Equal @($ephemeral.Data.accessPackageResources | Where-Object resourceOriginId -eq 'directory-group').Count 3 'Resolve resource metadata through unambiguous origin keys when role IDs differ'
$itemFailure = New-GovernanceState -TenantId 'synthetic' -IncludeReviews $false
Invoke-GovernanceScan -State $itemFailure -Request (New-TestRequest @{FailPolicy=$true})
Assert-Equal $itemFailure.Data.accessPackagePolicies.Count 2 'One failed package does not discard other packages'
Assert-Equal ($itemFailure.Statuses | Where-Object collector -eq 'AccessPackagePolicies').status 'PartiallyCollected' 'Per-package failure is explicit'
$cycle = New-GovernanceState -TenantId 'synthetic'
Invoke-GovernanceScan -State $cycle -Request {param($url) [pscustomobject]@{value=@();'@odata.nextLink'=$url}}
Assert-Equal ($cycle.Statuses | Where-Object collector -eq 'AccessPackages').status 'Failed' 'Cyclic paging terminates explicitly'
$empty = New-GovernanceState -TenantId 'synthetic'
Invoke-GovernanceScan -State $empty -Request {param($url) [pscustomobject]@{value=@()}}
Assert-Equal @($empty.Statuses | Where-Object { $_.status -ne 'Succeeded' }).Count 0 'Actual empty tenant is successful'
$malformed = New-GovernanceState -TenantId 'synthetic'
Invoke-GovernanceScan -State $malformed -Request {param($url) [pscustomobject]@{unexpected='invalid'}}
Assert-Equal ($malformed.Statuses | Where-Object { $_.collector -eq 'AccessPackages' }).status 'Failed' 'Malformed data is not empty success'

$common = Get-Module AzureScannerCommon
& $common {
    function script:Invoke-ScannerHttp { param($Method,$Url,$Resource,$Collector) [pscustomobject]@{Status=403;Body='{"error":{"code":"Authorization_RequestDenied"}}'} }
}
$caught = $false
try { Invoke-GraphReadRequest -Url 'https://graph.microsoft.com/v1.0/groups' }
catch { $caught = $_.Exception.Data['StatusCode'] -eq 403 }
Assert-Equal $caught $true 'HTTP errors preserve structured status'
& $common {
    $script:HttpDisabled = $true
    function script:Invoke-AzJson { param($Arguments,$Collector) throw 'Synthetic CLI failure.' }
}
$caught = $false
try { Get-GraphPagedItems -Url 'https://graph.microsoft.com/v1.0/groups' }
catch { $caught = $_.Exception.Message -eq 'Synthetic CLI failure.' }
Assert-Equal $caught $true 'CLI fallback failures are not swallowed'
$caught = $false
try { Invoke-GraphReadRequest -Url 'https://example.invalid/v1.0/groups' }
catch { $caught = $true }
Assert-Equal $caught $true 'Reject off-host pagination before sending credentials'

Import-Module (Join-Path $root 'lib\AzureScannerCommon.psm1') -Force -DisableNameChecking
$common = Get-Module AzureScannerCommon
$retryResults = & $common {
    Add-Type -AssemblyName System.Net.Http
    $script:Delays = [Collections.Generic.List[int]]::new()
    function script:Start-Sleep { param([int]$Seconds) [void]$script:Delays.Add($Seconds) }
    function script:Get-AzResourceToken { param($Resource) return 'synthetic-token' }
    $script:HttpDisabled = $false
    $script:Client = [pscustomobject]@{ Responses=[Collections.Generic.Queue[object]]::new(); Calls=0 }
    $script:Client | Add-Member ScriptMethod SendAsync {
        param($request)
        $this.Calls++
        $response = $this.Responses.Dequeue()
        $source = [Threading.Tasks.TaskCompletionSource[Net.Http.HttpResponseMessage]]::new()
        $source.SetResult($response)
        return $source.Task
    }
    function script:Get-ScannerHttpClient { return $script:Client }
    foreach ($code in @(429,503,200)) {
        $response = [Net.Http.HttpResponseMessage]::new([Enum]::ToObject([Net.HttpStatusCode],$code))
        $response.Content = [Net.Http.StringContent]::new('{"value":[]}')
        if ($code -eq 429) { $response.Headers.Add('Retry-After','7') }
        $script:Client.Responses.Enqueue($response)
    }
    $result = Invoke-ScannerHttp -Method GET -Url 'https://graph.microsoft.com/v1.0/groups' -Resource 'https://graph.microsoft.com/' -MaxAttempts 3
    $first = [pscustomobject]@{status=$result.Status;calls=$script:Client.Calls;delays=($script:Delays -join ',')}
    $script:Client.Calls = 0
    $script:Delays.Clear()
    foreach ($code in @(429,429)) {
        $response = [Net.Http.HttpResponseMessage]::new([Enum]::ToObject([Net.HttpStatusCode],$code))
        $response.Content = [Net.Http.StringContent]::new('{"error":{"code":"TooManyRequests"}}')
        $script:Client.Responses.Enqueue($response)
    }
    $exhausted = Invoke-ScannerHttp -Method GET -Url 'https://graph.microsoft.com/v1.0/groups' -Resource 'https://graph.microsoft.com/' -MaxAttempts 2
    [pscustomobject]@{first=$first;status=$exhausted.Status;throttled=$exhausted.Throttled;calls=$script:Client.Calls}
}
Assert-Equal $retryResults.first.status 200 'Transient HTTP errors recover'
Assert-Equal $retryResults.first.calls 3 'Bounded retry count'
Assert-Equal $retryResults.first.delays '7,4' 'Retry-After and exponential delay values'
Assert-Equal $retryResults.status 429 'Exhausted retries preserve HTTP failure'
Assert-Equal $retryResults.throttled $true 'Exhausted retries retain throttling indicator'
Assert-Equal $retryResults.calls 2 'No retry beyond configured maximum'

& $common {
    $script:GraphTenantId = 'expected-tenant'
    $script:GraphAuthMode = 'GraphPowerShell'
    $script:GraphAuthReady = $true
    function script:Get-MgContext { [pscustomobject]@{TenantId='different-tenant'} }
    function script:Invoke-ScannerHttp { param($Method,$Url,$Resource,$Collector) [pscustomobject]@{Status=200;Body='{"value":[]}'} }
}
$caught = $false
try { Invoke-GraphReadRequest -Url 'https://graph.microsoft.com/v1.0/groups' -UseGovernanceAuthentication }
catch { $caught = $_.Exception.Message -match 'no longer matches' }
Assert-Equal $caught $true 'Refuse mismatched Graph tenant before reading'
$legacy = Invoke-GraphReadRequest -Url 'https://graph.microsoft.com/v1.0/groups'
Assert-Equal @($legacy.value).Count 0 'Governance provider does not replace legacy CLI-backed reads'

$temp = Join-Path ([IO.Path]::GetTempPath()) ('azscan-governance-' + [guid]::NewGuid().ToString('N'))
try {
    $files = @(Export-GovernanceOutputs -State $state -OutputDirectory $temp -EmitJson)
    Assert-Equal $files.Count 22 'CSV and optional JSON outputs'
    foreach ($entry in (Get-GovernanceSchemas).GetEnumerator()) {
        $header = Get-Content -LiteralPath (Join-Path $temp ($entry.Key + '.csv')) -TotalCount 1
        Assert-Equal (($header -replace '"','') -join ',') ($entry.Value -join ',') ('Schema ' + $entry.Key)
    }
    $jsonRows = Get-Content -LiteralPath (Join-Path $temp 'accessPackageAssignments.json') -Raw | ConvertFrom-Json
    Assert-Equal @($jsonRows).Count 5 'JSON contains complete assignment rows'
    $singleJson = Get-Content -LiteralPath (Join-Path $temp 'accessCatalogs.json') -Raw
    Assert-Equal $singleJson.TrimStart().StartsWith('[') $true 'Singleton dataset retains JSON array shape'
    $emptyFiles = @(Export-GovernanceOutputs -State $empty -OutputDirectory $temp -EmitJson)
    $emptyJson = Get-Content -LiteralPath (Join-Path $temp 'accessCatalogs.json') -Raw
    Assert-Equal ($emptyJson -replace '\s','') '[]' 'Empty dataset is a valid JSON array'
}
finally {
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Recurse -Force }
}
Write-Host "[OK] Governance: $script:assertions assertions passed."
