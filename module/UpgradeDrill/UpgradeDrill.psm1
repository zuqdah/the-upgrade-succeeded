Set-StrictMode -Version Latest

# Every judgement this lab makes lives here, as functions of plain data, so all
# of it is testable without a cluster. The drill script only gathers evidence:
# it never decides anything.

function Get-Field {
    <#
    .SYNOPSIS
    Reads a nested field from a dictionary or an object, or $null if any step is missing.

    .DESCRIPTION
    ConvertFrom-Yaml returns dictionaries and ConvertFrom-Json returns objects;
    both reach the same judgements. A missing step returns $null rather than
    throwing under strict mode, so absence is something the caller decides about.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [AllowNull()][object]$InputObject,
        [Parameter(Mandatory)][string[]]$Path
    )

    $current = $InputObject
    foreach ($step in $Path) {
        if ($null -eq $current) { return $null }
        if ($current -is [System.Collections.IDictionary]) {
            if (-not $current.Contains($step)) { return $null }
            $current = $current[$step]
        }
        else {
            $property = $current.PSObject.Properties[$step]
            if ($null -eq $property) { return $null }
            $current = $property.Value
        }
    }
    return $current
}

function Get-KeyName {
    <#
    .SYNOPSIS
    The keys of a dictionary or the property names of an object.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param([AllowNull()][object]$InputObject)

    if ($null -eq $InputObject) { return @() }
    if ($InputObject -is [System.Collections.IDictionary]) { return @($InputObject.Keys | ForEach-Object { [string]$_ }) }
    return @($InputObject.PSObject.Properties.Name)
}

function Select-UpgradeVersion {
    <#
    .SYNOPSIS
    Picks the two versions a pass upgrades between, from `az aks get-versions`.

    .DESCRIPTION
    The target is the newest patch of the region's default minor version. The
    starting point is the patch before it, or the newest patch of the previous
    minor when the default has only one. Either way the pair is checked against
    the catalogue's own upgrade paths, because AKS refuses an upgrade it does
    not list and that refusal would arrive forty minutes into a drill.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][object]$Catalog)

    $minors = @(Get-Field $Catalog 'values') | Where-Object { $_ -and -not (Get-Field $_ 'isPreview') }
    if (-not $minors) { throw 'The version catalogue lists no generally available Kubernetes versions.' }

    $default = @($minors | Where-Object { (Get-Field $_ 'isDefault') -eq $true })
    if ($default.Count -ne 1) { throw "Expected exactly one default minor version, found $($default.Count)." }
    $default = $default[0]

    $patchesOf = {
        param($minor)
        @(Get-KeyName (Get-Field $minor 'patchVersions') | Sort-Object { [version]$_ })
    }

    $patches = & $patchesOf $default
    if (-not $patches) { throw "The default minor $(Get-Field $default 'version') lists no patch versions." }
    $to = $patches[-1]

    if ($patches.Count -ge 2) {
        $from = $patches[-2]
        $source = Get-Field $default 'patchVersions'
        $why = "patch upgrade within the default minor $(Get-Field $default 'version')"
    }
    else {
        $defaultVersion = [version](Get-Field $default 'version')
        $older = @($minors | Where-Object { [version](Get-Field $_ 'version') -lt $defaultVersion } |
                Sort-Object { [version](Get-Field $_ 'version') })
        if (-not $older) { throw "The default minor $defaultVersion has one patch and there is no older minor to start from." }
        $previous = $older[-1]
        $from = (& $patchesOf $previous)[-1]
        $source = Get-Field $previous 'patchVersions'
        $why = "minor upgrade from $(Get-Field $previous 'version') to the default $defaultVersion"
    }

    $paths = @(Get-Field $source @($from, 'upgrades'))
    if ($paths -notcontains $to) {
        throw "The catalogue does not list an upgrade from $from to $to, so AKS would refuse it."
    }

    [pscustomobject]@{
        From   = $from
        To     = $to
        Reason = $why
    }
}

function Test-DrainReadiness {
    <#
    .SYNOPSIS
    Predicts, from manifests alone, whether draining a node will hurt a workload.

    .DESCRIPTION
    Each finding names a rule. Errors are the ones the live drill is expected
    to confirm; warnings are reported and not graded.

      SingleReplica       one replica: every drain is an outage
      NoReadinessProbe    a replacement pod receives traffic before it answers
      NoDisruptionBudget  nothing stops a drain evicting the last ready replica
      DrainBlocked        a budget no eviction can satisfy: the upgrade fails
      NoGracefulStop      no preStop: in-flight requests race the endpoint update
      NoHostSpread        nothing keeps the replicas off the same node
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Document)

    $docs = @($Document | Where-Object { $null -ne $_ })
    $budgets = @($docs | Where-Object { (Get-Field $_ 'kind') -eq 'PodDisruptionBudget' })

    foreach ($deployment in @($docs | Where-Object { (Get-Field $_ 'kind') -eq 'Deployment' })) {
        $namespace = Get-Field $deployment 'metadata', 'namespace'
        if (-not $namespace) { $namespace = 'default' }
        $workload = "$namespace/$(Get-Field $deployment 'metadata', 'name')"

        $replicas = Get-Field $deployment 'spec', 'replicas'
        $replicas = if ($null -eq $replicas) { 1 } else { [int]$replicas }

        $podSpec = Get-Field $deployment 'spec', 'template', 'spec'
        $podLabels = Get-Field $deployment 'spec', 'template', 'metadata', 'labels'
        $containers = @(Get-Field $podSpec 'containers')

        $finding = {
            param($rule, $severity, $detail)
            [pscustomobject]@{ Workload = $workload; Rule = $rule; Severity = $severity; Detail = $detail }
        }

        if ($replicas -lt 2) {
            & $finding 'SingleReplica' 'Error' "$replicas replica: draining its node is an outage, whatever else is configured."
        }

        $unprobed = @($containers | Where-Object { $null -eq (Get-Field $_ 'readinessProbe') } |
                ForEach-Object { Get-Field $_ 'name' })
        if ($unprobed) {
            & $finding 'NoReadinessProbe' 'Error' ("No readiness probe on $($unprobed -join ', '): a replacement pod is " +
                'sent traffic the moment its container starts, not when the application answers.')
        }

        $matching = @($budgets | Where-Object {
                $ns = Get-Field $_ 'metadata', 'namespace'
                if (-not $ns) { $ns = 'default' }
                $selector = Get-Field $_ 'spec', 'selector', 'matchLabels'
                $keys = @(Get-KeyName $selector)
                $ns -eq $namespace -and $keys.Count -gt 0 -and
                    -not @($keys | Where-Object { [string](Get-Field $podLabels $_) -ne [string](Get-Field $selector $_) })
            })

        if (-not $matching) {
            & $finding 'NoDisruptionBudget' 'Error' ('No PodDisruptionBudget selects these pods, so a drain may evict ' +
                'the last ready replica while its replacement is still starting.')
        }

        foreach ($budget in $matching) {
            $allowed = Get-AllowedDisruption -Budget $budget -Replicas $replicas
            if ($allowed -lt 1) {
                & $finding 'DrainBlocked' 'Error' ("PodDisruptionBudget $(Get-Field $budget 'metadata', 'name') allows " +
                    "$allowed disruptions of $replicas replicas. No eviction can satisfy it, so the drain waits out its " +
                    'timeout and the upgrade fails.')
            }
        }

        $stopped = @($containers | Where-Object { $null -ne (Get-Field $_ 'lifecycle', 'preStop') })
        if (-not $stopped) {
            & $finding 'NoGracefulStop' 'Warning' ('No preStop hook: the pod stops while load balancers may still be ' +
                'routing to it.')
        }

        $spread = @(Get-Field $podSpec 'topologySpreadConstraints') |
            Where-Object { $_ -and (Get-Field $_ 'topologyKey') -eq 'kubernetes.io/hostname' }
        $antiAffinity = @(
            @(Get-Field $podSpec 'affinity', 'podAntiAffinity', 'requiredDuringSchedulingIgnoredDuringExecution')
            @(Get-Field $podSpec 'affinity', 'podAntiAffinity', 'preferredDuringSchedulingIgnoredDuringExecution') |
                ForEach-Object { Get-Field $_ 'podAffinityTerm' }
        ) | Where-Object { $_ -and (Get-Field $_ 'topologyKey') -eq 'kubernetes.io/hostname' }
        if ($replicas -ge 2 -and -not $spread -and -not $antiAffinity) {
            & $finding 'NoHostSpread' 'Warning' ('Nothing keeps the replicas on different nodes; if the scheduler ' +
                'puts them together, one drain takes both.')
        }
    }
}

function Get-AllowedDisruption {
    <#
    .SYNOPSIS
    How many pods a PodDisruptionBudget lets a drain evict at once.

    .DESCRIPTION
    Percentages round the way the disruption controller rounds them: up, for
    both minAvailable and maxUnavailable.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)][object]$Budget,
        [Parameter(Mandatory)][int]$Replicas
    )

    $resolve = {
        param($value)
        if ($value -is [string] -and $value.EndsWith('%')) {
            return [int][math]::Ceiling($Replicas * [double]$value.TrimEnd('%') / 100)
        }
        return [int]$value
    }

    $min = Get-Field $Budget 'spec', 'minAvailable'
    $max = Get-Field $Budget 'spec', 'maxUnavailable'
    if ($null -ne $max) { return [math]::Max(0, (& $resolve $max)) }
    if ($null -ne $min) { return [math]::Max(0, $Replicas - (& $resolve $min)) }

    # A budget with neither field defaults to minAvailable: 1 in the API, but
    # the admission rules reject it, so this branch reports the API's default.
    return [math]::Max(0, $Replicas - 1)
}

function Measure-ProbeResult {
    <#
    .SYNOPSIS
    Summarises probe samples: how many failed, when, and the longest full outage.

    .DESCRIPTION
    A sample is any object with `t` (Unix milliseconds) and `ok` (bool).

    LongestOutageMs is the longest stretch where *every* request failed,
    measured from the first failure to the next success. Failures interleaved
    with successes -- half the requests landing on a pod that is not answering
    yet -- are counted in Failed and grouped into spans, but are not called an
    outage, because some users were still being served.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Sample,
        [int]$SpanGapMs = 5000
    )

    $ordered = @($Sample | Where-Object { $null -ne $_ } | Sort-Object { [long](Get-Field $_ 't') })
    $failed = @($ordered | Where-Object { -not [bool](Get-Field $_ 'ok') })

    $longest = 0L
    $runStart = $null
    $openAtEnd = $false
    foreach ($s in $ordered) {
        $t = [long](Get-Field $s 't')
        if ([bool](Get-Field $s 'ok')) {
            if ($null -ne $runStart) {
                $longest = [math]::Max($longest, $t - $runStart)
                $runStart = $null
            }
        }
        elseif ($null -eq $runStart) {
            $runStart = $t
        }
    }
    if ($null -ne $runStart) {
        # The window ended mid-outage. Report what was observed and say so,
        # rather than inventing an end time.
        $openAtEnd = $true
        $longest = [math]::Max($longest, [long](Get-Field $ordered[-1] 't') - $runStart)
    }

    $spans = [System.Collections.Generic.List[object]]::new()
    foreach ($f in $failed) {
        $t = [long](Get-Field $f 't')
        if ($spans.Count -and $t - $spans[-1].EndMs -le $SpanGapMs) {
            $spans[-1].EndMs = $t
            $spans[-1].Failed++
        }
        else {
            $spans.Add([pscustomobject]@{ StartMs = $t; EndMs = $t; Failed = 1 })
        }
    }

    [pscustomobject]@{
        Total           = $ordered.Count
        Failed          = $failed.Count
        FailureRate     = if ($ordered.Count) { [math]::Round($failed.Count / $ordered.Count, 4) } else { $null }
        FirstFailureMs  = if ($failed.Count) { [long](Get-Field $failed[0] 't') } else { $null }
        LastFailureMs   = if ($failed.Count) { [long](Get-Field $failed[-1] 't') } else { $null }
        LongestOutageMs = $longest
        OutageOpenAtEnd = $openAtEnd
        Spans           = @($spans)
        DurationMs      = if ($ordered.Count -ge 2) { [long](Get-Field $ordered[-1] 't') - [long](Get-Field $ordered[0] 't') } else { 0 }
    }
}

function Test-UpgradeHappened {
    <#
    .SYNOPSIS
    Proves from the cluster itself that the upgrade under test actually ran.

    .DESCRIPTION
    Zero failed requests means nothing if no node was drained. Every node in
    the pool must have started at From and finished at To, and every pod
    present before must be gone afterwards. Missing evidence is $null --
    unknown -- never $true.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][AllowNull()][object]$Before,
        [Parameter(Mandatory)][AllowNull()][object]$After,
        [Parameter(Mandatory)][string]$FromVersion,
        [Parameter(Mandatory)][string]$ToVersion
    )

    $verdict = { param($happened, $detail) [pscustomobject]@{ Happened = $happened; Detail = $detail } }

    $beforeNodes = @(Get-Field $Before 'nodes' | Where-Object { $_ })
    $afterNodes = @(Get-Field $After 'nodes' | Where-Object { $_ })
    $beforePods = @(Get-Field $Before 'pods' | Where-Object { $_ })
    $afterPods = @(Get-Field $After 'pods' | Where-Object { $_ })

    if (-not $beforeNodes -or -not $afterNodes) {
        return & $verdict $null 'The pool''s nodes could not be read before and after, so there is no evidence the upgrade ran.'
    }
    if (-not $beforePods -or -not $afterPods) {
        return & $verdict $null 'The workload''s pods could not be read before and after, so there is no evidence they were drained.'
    }

    $notAtStart = @($beforeNodes | Where-Object { (Get-Field $_ 'kubeletVersion') -ne "v$FromVersion" })
    if ($notAtStart) {
        return & $verdict $null ("Before the upgrade, $(@($notAtStart | ForEach-Object { "$(Get-Field $_ 'name')=$(Get-Field $_ 'kubeletVersion')" }) -join ', ') " +
            "instead of v$FromVersion, so the upgrade measured is not the one declared.")
    }

    $notAtEnd = @($afterNodes | Where-Object { (Get-Field $_ 'kubeletVersion') -ne "v$ToVersion" })
    if ($notAtEnd) {
        return & $verdict $false ("After the upgrade, $(@($notAtEnd | ForEach-Object { "$(Get-Field $_ 'name')=$(Get-Field $_ 'kubeletVersion')" }) -join ', ') " +
            "instead of v$ToVersion.")
    }

    $beforeIds = @($beforePods | ForEach-Object { Get-Field $_ 'uid' })
    $survivors = @($afterPods | Where-Object { $beforeIds -contains (Get-Field $_ 'uid') })
    if ($survivors) {
        return & $verdict $false ("Pod(s) $(@($survivors | ForEach-Object { Get-Field $_ 'name' }) -join ', ') survived the " +
            'upgrade, so not every node was drained.')
    }

    & $verdict $true ("All $($afterNodes.Count) node(s) went from v$FromVersion to v$ToVersion and all " +
        "$($beforePods.Count) pod(s) were replaced.")
}

function Get-PassVerdict {
    <#
    .SYNOPSIS
    Grades one pass against what was declared for it before it ran.

    .DESCRIPTION
    Confirmed, Contradicted or Unknown. Unknown is not a soft pass: it means a
    precondition for measuring anything failed, and the drill fails on it.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Pass,
        [Parameter(Mandatory)][object]$Expectation,
        [Parameter(Mandatory)][object]$Baseline,
        [Parameter(Mandatory)][object]$Upgrade,
        [Parameter(Mandatory)][object]$Happened,
        [AllowNull()][Nullable[int]]$TerraformExit,
        [AllowNull()][AllowEmptyString()][string]$ProvisioningState,
        [int]$MinimumBaselineSamples = 60,
        [int]$MinimumSamples = 300
    )

    $reported = ($TerraformExit -eq 0) -and ($ProvisioningState -eq 'Succeeded')
    $reasons = [System.Collections.Generic.List[string]]::new()
    $result = $null

    if ((Get-Field $Expectation 'reportedSucceeded') -eq $true -and -not $reported) {
        $result = 'Contradicted'
        $reasons.Add("Expected the upgrade to be reported as succeeded; Terraform exited $TerraformExit and the pool's provisioning state is '$ProvisioningState'.")
    }

    if (-not $result) {
        if ($Baseline.Total -lt $MinimumBaselineSamples) {
            $reasons.Add("Only $($Baseline.Total) baseline samples (need $MinimumBaselineSamples), so there is no evidence the app was healthy before the upgrade.")
        }
        if ($Baseline.Failed -gt 0) {
            $reasons.Add("$($Baseline.Failed) of $($Baseline.Total) requests failed BEFORE the upgrade began, so failures during it cannot be blamed on it.")
        }
        if ($Upgrade.Total -lt $MinimumSamples) {
            $reasons.Add("Only $($Upgrade.Total) samples during the upgrade (need $MinimumSamples); the probe did not watch it.")
        }
        if ($Happened.Happened -ne $true) {
            $reasons.Add("No evidence the upgrade drained anything: $($Happened.Detail)")
        }
        if ($reasons.Count) { $result = 'Unknown' }
    }

    if (-not $result) {
        $expect = Get-Field $Expectation 'expect'
        switch ($expect) {
            'outage' {
                if ($Upgrade.Failed -gt 0) {
                    $result = 'Confirmed'
                    $reasons.Add("Reported succeeded while $($Upgrade.Failed) of $($Upgrade.Total) requests failed; longest full outage $([math]::Round($Upgrade.LongestOutageMs / 1000, 1))s.")
                }
                else {
                    $result = 'Contradicted'
                    $reasons.Add("Expected failed requests during the upgrade and saw none in $($Upgrade.Total).")
                }
            }
            'noFailures' {
                $max = [int](Get-Field $Expectation 'maxFailed')
                if ($Upgrade.Failed -le $max) {
                    $result = 'Confirmed'
                    $reasons.Add("$($Upgrade.Failed) of $($Upgrade.Total) requests failed during the upgrade (allowed $max).")
                }
                else {
                    $result = 'Contradicted'
                    $reasons.Add("$($Upgrade.Failed) of $($Upgrade.Total) requests failed during the upgrade (allowed $max); longest full outage $([math]::Round($Upgrade.LongestOutageMs / 1000, 1))s.")
                }
            }
            default { throw "Pass '$Pass' declares an unknown expectation '$expect'." }
        }
    }

    [pscustomobject]@{
        Pass              = $Pass
        Result            = $result
        ReportedSucceeded = $reported
        Failed            = $Upgrade.Failed
        Total             = $Upgrade.Total
        LongestOutageMs   = $Upgrade.LongestOutageMs
        Reasons           = @($reasons)
    }
}

Export-ModuleMember -Function Get-Field, Select-UpgradeVersion, Test-DrainReadiness, Get-AllowedDisruption,
    Measure-ProbeResult, Test-UpgradeHappened, Get-PassVerdict
