#Requires -Version 7.2
<#
.SYNOPSIS
Runs one pass: create an app pool at the old version, deploy, watch an upgrade, collect evidence.

.DESCRIPTION
This script gathers evidence and decides nothing. Grading lives in the module
and runs afterwards in Measure-Drill.ps1, so every judgement is unit-tested and
a reviewer can re-grade a run from its artifact without a cluster.

The upgrade itself is a Terraform apply that changes the pool's
orchestrator_version -- the way a team managing AKS with Terraform would do
it -- and its exit code is recorded alongside the provisioning state Azure
reports for the pool afterwards. Both are the "succeeded" in this lab's name.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('unprotected', 'protected')][string]$Pass,
    [Parameter(Mandatory)][string]$FromVersion,
    [Parameter(Mandatory)][string]$ToVersion,
    [Parameter(Mandatory)][string]$RunnerIp,
    [Parameter(Mandatory)][string]$ResourceGroup,
    [Parameter(Mandatory)][string]$ClusterName,
    [ValidateRange(10, 600)][int]$BaselineSeconds = 30,
    [ValidateRange(0, 600)][int]$TailSeconds = 60,
    [string]$OutDirectory = 'out'
)

$ErrorActionPreference = 'Stop'
$InformationPreference = 'Continue'

$root = Split-Path $PSScriptRoot -Parent
$infra = Join-Path $root 'infra'
New-Item -ItemType Directory -Force -Path $OutDirectory | Out-Null
$out = (Resolve-Path $OutDirectory).Path

function Invoke-Checked {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$ArgumentList
    )
    $result = & $FilePath @ArgumentList
    if ($LASTEXITCODE -ne 0) { throw "$FilePath $($ArgumentList -join ' ') exited $LASTEXITCODE." }
    return $result
}

function Get-Json {
    param([Parameter(Mandatory)][string[]]$ArgumentList, [string]$FilePath = 'kubectl')
    (Invoke-Checked -FilePath $FilePath -ArgumentList $ArgumentList) -join "`n" | ConvertFrom-Json
}

function Invoke-PoolApply {
    # Writes the pool map Terraform reads and applies it. Returns the exit code
    # rather than throwing: a failed upgrade is evidence, not a crash.
    param([Parameter(Mandatory)][hashtable]$Pools)
    $body = @{ app_pools = $Pools } | ConvertTo-Json -Depth 3
    [System.IO.File]::WriteAllText((Join-Path $infra 'app-pools.auto.tfvars.json'), $body, [System.Text.UTF8Encoding]::new($false))
    & terraform "-chdir=$infra" apply -input=false -auto-approve | Out-Host
    return $LASTEXITCODE
}

function Get-PoolSnapshot {
    $nodes = @((Get-Json -ArgumentList @('get', 'nodes', '-l', "kubernetes.azure.com/agentpool=$Pass", '-o', 'json')).items | ForEach-Object {
            [pscustomobject]@{
                name           = $_.metadata.name
                kubeletVersion = $_.status.nodeInfo.kubeletVersion
                bootId         = $_.status.nodeInfo.bootID
                created        = $_.metadata.creationTimestamp
            }
        })
    $pods = @((Get-Json -ArgumentList @('get', 'pods', '-n', $Pass, '-o', 'json')).items | ForEach-Object {
            [pscustomobject]@{
                name  = $_.metadata.name
                uid   = $_.metadata.uid
                node  = $_.spec.nodeName
                phase = $_.status.phase
            }
        })
    [pscustomobject]@{
        at    = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
        nodes = $nodes
        pods  = $pods
    }
}

function Wait-Until {
    param(
        [Parameter(Mandatory)][scriptblock]$Condition,
        [Parameter(Mandatory)][string]$What,
        [int]$TimeoutSeconds = 300,
        [int]$IntervalSeconds = 5
    )
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTimeOffset]::UtcNow -lt $deadline) {
        $value = & $Condition
        if ($value) { return $value }
        Start-Sleep -Seconds $IntervalSeconds
    }
    throw "Timed out after ${TimeoutSeconds}s waiting for $What."
}

$evidence = [ordered]@{
    pass           = $Pass
    fromVersion    = $FromVersion
    toVersion      = $ToVersion
    samplesFile    = "probe-$Pass.ndjson"
    upgradeStartMs = $null
    upgradeEndMs   = $null
    terraformExit  = $null
    nodePool       = $null
    before         = $null
    after          = $null
    events         = @()
    error          = $null
}

$samples = Join-Path $out $evidence.samplesFile
$stop = Join-Path $out "probe-$Pass.stop"
$probe = $null

try {
    # At most one app pool exists at a time: the regional quota is 10 vCPUs and
    # two pools plus a surge node would need 12. Remove the other pass's pool
    # first, then create this one.
    Write-Information "[$Pass] Removing any other app pool"
    if ((Invoke-PoolApply -Pools @{}) -ne 0) { throw 'Could not remove the previous app pool.' }

    Write-Information "[$Pass] Creating the '$Pass' pool at $FromVersion"
    if ((Invoke-PoolApply -Pools @{ $Pass = $FromVersion }) -ne 0) { throw "Could not create the '$Pass' pool at $FromVersion." }

    Write-Information "[$Pass] Deploying the $Pass manifest"
    $manifest = [System.IO.File]::ReadAllText((Join-Path $root "manifests/$Pass/app.yaml")).Replace('__RUNNER_CIDR__', "$RunnerIp/32")
    $rendered = Join-Path $out "app-$Pass.yaml"
    [System.IO.File]::WriteAllText($rendered, $manifest, [System.Text.UTF8Encoding]::new($false))
    Invoke-Checked -FilePath kubectl -ArgumentList @('apply', '-f', $rendered) | Out-Host
    Invoke-Checked -FilePath kubectl -ArgumentList @('rollout', 'status', 'deployment/web', '-n', $Pass, '--timeout=5m') | Out-Host

    $ip = Wait-Until -What 'the load balancer address' -TimeoutSeconds 300 -Condition {
        $svc = Get-Json -ArgumentList @('get', 'service', 'web', '-n', $Pass, '-o', 'json')
        $ingress = $svc.status.loadBalancer.PSObject.Properties['ingress']
        if ($ingress -and $ingress.Value) { $ingress.Value[0].ip }
    }
    $url = "http://$ip/"

    # A rollout reports complete before an app with no readiness probe can
    # answer. Wait for a run of successes so the baseline starts from health.
    Write-Information "[$Pass] Waiting for the app to answer at the load balancer"
    $streak = 0
    Wait-Until -What 'twenty consecutive successful requests' -TimeoutSeconds 300 -IntervalSeconds 0 -Condition {
        try {
            Invoke-WebRequest -Uri $url -TimeoutSec 2 -DisableKeepAlive | Out-Null
            $script:streak++
        }
        catch {
            $script:streak = 0
            Start-Sleep -Milliseconds 500
        }
        $script:streak -ge 20
    } | Out-Null

    $evidence.before = Get-PoolSnapshot

    Write-Information "[$Pass] Probing $url; baseline for ${BaselineSeconds}s"
    Remove-Item -LiteralPath $stop -ErrorAction SilentlyContinue
    $probe = Start-Process -PassThru -FilePath (Get-Process -Id $PID).Path -ArgumentList @(
        '-NoProfile', '-File', (Join-Path $PSScriptRoot 'Start-Probe.ps1'),
        '-Url', $url, '-OutFile', $samples, '-StopFile', $stop
    )
    Start-Sleep -Seconds $BaselineSeconds
    if ($probe.HasExited) { throw "The probe exited early with code $($probe.ExitCode)." }

    Write-Information "[$Pass] Upgrading the '$Pass' pool from $FromVersion to $ToVersion"
    $evidence.upgradeStartMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $evidence.terraformExit = Invoke-PoolApply -Pools @{ $Pass = $ToVersion }
    $evidence.upgradeEndMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    Write-Information "[$Pass] Terraform exited $($evidence.terraformExit) after $([math]::Round(($evidence.upgradeEndMs - $evidence.upgradeStartMs) / 1000))s"

    $pool = Get-Json -FilePath az -ArgumentList @('aks', 'nodepool', 'show', '--resource-group', $ResourceGroup,
        '--cluster-name', $ClusterName, '--name', $Pass, '-o', 'json')
    $evidence.nodePool = [ordered]@{
        provisioningState          = $pool.provisioningState
        orchestratorVersion        = $pool.orchestratorVersion
        currentOrchestratorVersion = $pool.currentOrchestratorVersion
        maxSurge                   = $pool.upgradeSettings.maxSurge
        drainTimeoutInMinutes      = $pool.upgradeSettings.drainTimeoutInMinutes
    }
    Write-Information "[$Pass] Azure reports the pool as $($pool.provisioningState) at $($pool.currentOrchestratorVersion)"

    # Pods evicted from the last drained node may still be warming up when the
    # apply returns. Keep watching, or their failures fall outside the window.
    Start-Sleep -Seconds $TailSeconds
}
catch {
    $evidence.error = $_.Exception.Message
    Write-Warning "[$Pass] $($_.Exception.Message)"
}
finally {
    if ($probe) {
        New-Item -ItemType File -Force -Path $stop | Out-Null
        if (-not $probe.WaitForExit(30000)) { $probe.Kill() }
    }
}

try {
    $evidence.after = Get-PoolSnapshot
    $evidence.events = @((Get-Json -ArgumentList @('get', 'events', '-n', $Pass, '-o', 'json')).items | ForEach-Object {
            [pscustomobject]@{
                time    = if ($_.lastTimestamp) { $_.lastTimestamp } else { $_.eventTime }
                reason  = $_.reason
                object  = "$($_.involvedObject.kind)/$($_.involvedObject.name)"
                message = $_.message
            }
        })
}
catch {
    if (-not $evidence.error) { $evidence.error = "Collecting evidence after the upgrade failed: $($_.Exception.Message)" }
}

# Deleting the namespace releases the service's public IP before the next pass.
& kubectl delete namespace $Pass --wait=true --timeout=5m --ignore-not-found | Out-Host

$evidence | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $out "pass-$Pass.json") -Encoding utf8NoBOM
Write-Information "[$Pass] Evidence written to $(Join-Path $out "pass-$Pass.json")"
if ($evidence.error) { exit 1 }
