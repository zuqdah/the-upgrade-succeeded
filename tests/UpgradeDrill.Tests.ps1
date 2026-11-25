BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../module/UpgradeDrill/UpgradeDrill.psm1') -Force
    Import-Module powershell-yaml -ErrorAction Stop

    function New-Sample {
        # 'ok' and 'x' characters, one sample per 200 ms from t=0.
        param([string]$Pattern, [long]$StartMs = 0, [int]$StepMs = 200)
        $i = 0
        foreach ($c in $Pattern.ToCharArray()) {
            [pscustomobject]@{ t = $StartMs + ($i * $StepMs); ok = ($c -eq '.') }
            $i++
        }
    }

    function ConvertFrom-Manifest {
        param([string]$Yaml)
        @(ConvertFrom-Yaml -Yaml $Yaml -AllDocuments)
    }

    $script:deployment = @'
apiVersion: apps/v1
kind: Deployment
metadata: {name: web, namespace: shop}
spec:
  replicas: 2
  selector: {matchLabels: {app: web}}
  template:
    metadata: {labels: {app: web, tier: front}}
    spec:
      topologySpreadConstraints:
        - {maxSkew: 1, topologyKey: kubernetes.io/hostname, whenUnsatisfiable: ScheduleAnyway, labelSelector: {matchLabels: {app: web}}}
      containers:
        - name: web
          image: example
          readinessProbe: {httpGet: {path: /, port: 8080}}
          lifecycle: {preStop: {exec: {command: [sleep, "5"]}}}
'@

    function New-Budget {
        param([string]$Field, [object]$Value, [string]$Namespace = 'shop', [string]$App = 'web')
        @"
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata: {name: web, namespace: $Namespace}
spec:
  ${Field}: $Value
  selector: {matchLabels: {app: $App}}
"@
    }
}

Describe 'Select-UpgradeVersion' {
    BeforeAll {
        $script:catalog = @'
{ "values": [
  { "version": "1.37", "isDefault": null, "isPreview": null,
    "patchVersions": { "1.37.0": { "upgrades": ["1.37.1"] }, "1.37.1": { "upgrades": [] } } },
  { "version": "1.36", "isDefault": true, "isPreview": null,
    "patchVersions": {
      "1.36.4": { "upgrades": ["1.36.10", "1.36.5", "1.37.0"] },
      "1.36.10": { "upgrades": ["1.37.0", "1.37.1"] },
      "1.36.5": { "upgrades": ["1.36.10", "1.37.0"] } } },
  { "version": "1.38", "isDefault": null, "isPreview": true,
    "patchVersions": { "1.38.0": { "upgrades": [] } } }
] }
'@ | ConvertFrom-Json
    }

    It 'upgrades to the newest patch of the default minor, from the patch before it' {
        $pick = Select-UpgradeVersion -Catalog $catalog
        $pick.From | Should -Be '1.36.5'
        $pick.To | Should -Be '1.36.10'
    }

    It 'sorts patches as versions, not strings, so 1.36.10 is newer than 1.36.5' {
        (Select-UpgradeVersion -Catalog $catalog).To | Should -Not -Be '1.36.5'
    }

    It 'falls back to the previous minor when the default has one patch' {
        $one = @'
{ "values": [
  { "version": "1.35", "isDefault": null, "patchVersions": { "1.35.2": { "upgrades": ["1.36.0"] }, "1.35.1": { "upgrades": ["1.35.2"] } } },
  { "version": "1.36", "isDefault": true, "patchVersions": { "1.36.0": { "upgrades": [] } } }
] }
'@ | ConvertFrom-Json
        $pick = Select-UpgradeVersion -Catalog $one
        $pick.From | Should -Be '1.35.2'
        $pick.To | Should -Be '1.36.0'
    }

    It 'refuses a pair the catalogue does not list as an upgrade path' {
        $broken = @'
{ "values": [ { "version": "1.36", "isDefault": true,
  "patchVersions": { "1.36.1": { "upgrades": [] }, "1.36.2": { "upgrades": [] } } } ] }
'@ | ConvertFrom-Json
        { Select-UpgradeVersion -Catalog $broken } | Should -Throw '*does not list an upgrade*'
    }

    It 'refuses a catalogue with no default rather than guessing' {
        $none = '{ "values": [ { "version": "1.36", "isDefault": null, "patchVersions": { "1.36.1": { "upgrades": [] } } } ] }' | ConvertFrom-Json
        { Select-UpgradeVersion -Catalog $none } | Should -Throw '*exactly one default*'
    }
}

Describe 'Test-DrainReadiness' {
    It 'finds nothing wrong with a probed, budgeted, spread, gracefully stopping deployment' {
        $docs = ConvertFrom-Manifest ($deployment + (New-Budget 'minAvailable' 1))
        @(Test-DrainReadiness -Document $docs) | Should -BeNullOrEmpty
    }

    It 'flags a missing readiness probe as an error' {
        $docs = ConvertFrom-Manifest (($deployment -replace '(?m)^\s+readinessProbe:.*$\r?\n', '') + (New-Budget 'minAvailable' 1))
        $f = @(Test-DrainReadiness -Document $docs)
        $f.Rule | Should -Be @('NoReadinessProbe')
        $f[0].Severity | Should -Be 'Error'
    }

    It 'flags a deployment no budget selects' {
        (@(Test-DrainReadiness -Document (ConvertFrom-Manifest $deployment))).Rule | Should -Contain 'NoDisruptionBudget'
    }

    It 'does not count a budget in another namespace' {
        $docs = ConvertFrom-Manifest ($deployment + (New-Budget 'minAvailable' 1 -Namespace 'other'))
        (@(Test-DrainReadiness -Document $docs)).Rule | Should -Contain 'NoDisruptionBudget'
    }

    It 'does not count a budget whose selector matches other pods' {
        $docs = ConvertFrom-Manifest ($deployment + (New-Budget 'minAvailable' 1 -App 'api'))
        (@(Test-DrainReadiness -Document $docs)).Rule | Should -Contain 'NoDisruptionBudget'
    }

    It 'flags a budget no eviction can satisfy: <field> <value>' -ForEach @(
        @{ field = 'minAvailable'; value = 2 }
        @{ field = 'minAvailable'; value = '"100%"' }
        @{ field = 'maxUnavailable'; value = 0 }
        @{ field = 'maxUnavailable'; value = '"0%"' }
    ) {
        $docs = ConvertFrom-Manifest ($deployment + (New-Budget $field $value))
        (@(Test-DrainReadiness -Document $docs)).Rule | Should -Be @('DrainBlocked')
    }

    It 'accepts a budget that allows one eviction: <field> <value>' -ForEach @(
        @{ field = 'minAvailable'; value = 1 }
        @{ field = 'minAvailable'; value = '"50%"' }
        @{ field = 'maxUnavailable'; value = 1 }
        @{ field = 'maxUnavailable'; value = '"10%"' }
    ) {
        $docs = ConvertFrom-Manifest ($deployment + (New-Budget $field $value))
        @(Test-DrainReadiness -Document $docs) | Should -BeNullOrEmpty
    }

    It 'treats a missing replica count as one replica' {
        $docs = ConvertFrom-Manifest (($deployment -replace '(?m)^  replicas: 2\r?\n', '') + (New-Budget 'maxUnavailable' 1))
        (@(Test-DrainReadiness -Document $docs)).Rule | Should -Contain 'SingleReplica'
    }

    It 'warns, but does not error, on no preStop and no spread' {
        $bare = $deployment -replace '(?m)^\s+lifecycle:.*$\r?\n', '' -replace '(?ms)^      topologySpreadConstraints:.*?\}\}\}\r?\n', ''
        $f = @(Test-DrainReadiness -Document (ConvertFrom-Manifest ($bare + (New-Budget 'minAvailable' 1))))
        ($f.Rule | Sort-Object) | Should -Be @('NoGracefulStop', 'NoHostSpread')
        $f.Severity | Should -Not -Contain 'Error'
    }

    It 'accepts hostname anti-affinity in place of a spread constraint' {
        $affinity = $deployment -replace '(?ms)^      topologySpreadConstraints:.*?\}\}\}\r?\n', @'
      affinity:
        podAntiAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
            - weight: 100
              podAffinityTerm: {topologyKey: kubernetes.io/hostname, labelSelector: {matchLabels: {app: web}}}

'@
        @(Test-DrainReadiness -Document (ConvertFrom-Manifest ($affinity + (New-Budget 'minAvailable' 1)))) | Should -BeNullOrEmpty
    }

    Context 'the lab''s own manifests' {
        BeforeAll {
            $script:read = { param($p) ConvertFrom-Manifest ([System.IO.File]::ReadAllText((Join-Path $PSScriptRoot "../manifests/$p/app.yaml"))) }
        }

        It 'predicts the unprotected manifest will hurt traffic' {
            $errors = @(Test-DrainReadiness -Document (& $read 'unprotected') | Where-Object Severity -EQ 'Error').Rule | Sort-Object
            $errors | Should -Be @('NoDisruptionBudget', 'NoReadinessProbe')
        }

        It 'finds nothing at all in the protected manifest' {
            @(Test-DrainReadiness -Document (& $read 'protected')) | Should -BeNullOrEmpty
        }

        It 'keeps both passes identical apart from the protections' {
            # Same image, same warm-up, same replica count, same resources. If
            # these drift apart, the comparison stops being a comparison.
            $u = @(& $read 'unprotected' | Where-Object { $_.kind -eq 'Deployment' })[0].spec
            $p = @(& $read 'protected' | Where-Object { $_.kind -eq 'Deployment' })[0].spec
            $p.replicas | Should -Be $u.replicas
            $uc = $u.template.spec.containers[0]
            $pc = $p.template.spec.containers[0]
            $pc.image | Should -Be $uc.image
            $pc.command | Should -Be $uc.command
            ($pc.env | ConvertTo-Json -Depth 5) | Should -Be ($uc.env | ConvertTo-Json -Depth 5)
            ($pc.resources | ConvertTo-Json -Depth 5) | Should -Be ($uc.resources | ConvertTo-Json -Depth 5)
        }
    }
}

Describe 'Measure-ProbeResult' {
    It 'counts a clean window as clean' {
        $m = Measure-ProbeResult -Sample @(New-Sample '..........')
        $m.Total | Should -Be 10
        $m.Failed | Should -Be 0
        $m.LongestOutageMs | Should -Be 0
        $m.Spans | Should -BeNullOrEmpty
    }

    It 'measures a full outage from the first failure to the next success' {
        $m = Measure-ProbeResult -Sample @(New-Sample '...xxxxx..')
        $m.Failed | Should -Be 5
        $m.LongestOutageMs | Should -Be 1000
    }

    It 'does not call interleaved failures an outage' {
        $m = Measure-ProbeResult -Sample @(New-Sample '.x.x.x.x.x')
        $m.Failed | Should -Be 5
        $m.LongestOutageMs | Should -Be 200
    }

    It 'groups failures into spans separated by quiet gaps' {
        $samples = @(New-Sample '.x.x.x') + @(New-Sample '.....' -StartMs 1200) + @(New-Sample 'xx.' -StartMs 30000)
        $m = Measure-ProbeResult -Sample $samples -SpanGapMs 5000
        $m.Spans.Count | Should -Be 2
        $m.Spans[0].Failed | Should -Be 3
        $m.Spans[1].Failed | Should -Be 2
    }

    It 'sorts samples by time before measuring' {
        $samples = @(New-Sample '...xx...')
        [array]::Reverse($samples)
        (Measure-ProbeResult -Sample $samples).LongestOutageMs | Should -Be 400
    }

    It 'says so when the window ends mid-outage instead of inventing an end' {
        $m = Measure-ProbeResult -Sample @(New-Sample '...xxx')
        $m.OutageOpenAtEnd | Should -BeTrue
        $m.LongestOutageMs | Should -Be 400
    }

    It 'returns zero samples for an empty window rather than throwing' {
        $m = Measure-ProbeResult -Sample @()
        $m.Total | Should -Be 0
        $m.FailureRate | Should -BeNullOrEmpty
    }
}

Describe 'Test-UpgradeHappened' {
    BeforeAll {
        function New-Snapshot {
            param([string]$Version, [string[]]$PodUid)
            [pscustomobject]@{
                nodes = @(
                    [pscustomobject]@{ name = 'aks-pool-0'; kubeletVersion = "v$Version" }
                    [pscustomobject]@{ name = 'aks-pool-1'; kubeletVersion = "v$Version" }
                )
                pods  = @($PodUid | ForEach-Object { [pscustomobject]@{ name = "web-$_"; uid = $_ } })
            }
        }
    }

    It 'confirms an upgrade that moved every node and replaced every pod' {
        $r = Test-UpgradeHappened -Before (New-Snapshot '1.36.4' 'a', 'b') -After (New-Snapshot '1.36.5' 'c', 'd') -FromVersion '1.36.4' -ToVersion '1.36.5'
        $r.Happened | Should -BeTrue
    }

    It 'rejects an upgrade that left a node behind' {
        $after = New-Snapshot '1.36.5' 'c', 'd'
        $after.nodes[1].kubeletVersion = 'v1.36.4'
        (Test-UpgradeHappened -Before (New-Snapshot '1.36.4' 'a', 'b') -After $after -FromVersion '1.36.4' -ToVersion '1.36.5').Happened | Should -BeFalse
    }

    It 'rejects an upgrade a pod survived, because then nothing was drained' {
        $r = Test-UpgradeHappened -Before (New-Snapshot '1.36.4' 'a', 'b') -After (New-Snapshot '1.36.5' 'a', 'd') -FromVersion '1.36.4' -ToVersion '1.36.5'
        $r.Happened | Should -BeFalse
        $r.Detail | Should -Match 'web-a'
    }

    It 'is unknown, not true, when the pool did not start at the declared version' {
        $r = Test-UpgradeHappened -Before (New-Snapshot '1.36.5' 'a') -After (New-Snapshot '1.36.5' 'b') -FromVersion '1.36.4' -ToVersion '1.36.5'
        $r.Happened | Should -BeNullOrEmpty
    }

    It 'is unknown, not true, when there is no evidence: <case>' -ForEach @(
        @{ case = 'no snapshot before'; before = $null }
        @{ case = 'no nodes before'; before = [pscustomobject]@{ nodes = @(); pods = @([pscustomobject]@{ uid = 'a' }) } }
        @{ case = 'no pods before'; before = [pscustomobject]@{ nodes = @([pscustomobject]@{ name = 'n'; kubeletVersion = 'v1.36.4' }); pods = @() } }
    ) {
        $r = Test-UpgradeHappened -Before $before -After (New-Snapshot '1.36.5' 'c') -FromVersion '1.36.4' -ToVersion '1.36.5'
        $r.Happened | Should -BeNullOrEmpty
    }
}

Describe 'Get-PassVerdict' {
    BeforeAll {
        $script:clean = Measure-ProbeResult -Sample @(New-Sample ('.' * 150))
        $script:outage = Measure-ProbeResult -Sample @(New-Sample (('.' * 1000) + ('x' * 50) + ('.' * 500)) -StartMs 100000)
        $script:quiet = Measure-ProbeResult -Sample @(New-Sample ('.' * 1500) -StartMs 100000)
        $script:yes = [pscustomobject]@{ Happened = $true; Detail = 'ok' }
        $script:outageExpected = [pscustomobject]@{ expect = 'outage'; reportedSucceeded = $true }
        $script:cleanExpected = [pscustomobject]@{ expect = 'noFailures'; maxFailed = 0; reportedSucceeded = $true }

        function Invoke-Verdict {
            param($Expectation, $Baseline = $clean, $Upgrade, $Happened = $yes, $Exit = 0, $State = 'Succeeded')
            Get-PassVerdict -Pass 'p' -Expectation $Expectation -Baseline $Baseline -Upgrade $Upgrade -Happened $Happened `
                -TerraformExit $Exit -ProvisioningState $State -MinimumBaselineSamples 100 -MinimumSamples 1000
        }
    }

    It 'confirms an outage behind a reported success' {
        $v = Invoke-Verdict -Expectation $outageExpected -Upgrade $outage
        $v.Result | Should -Be 'Confirmed'
        $v.ReportedSucceeded | Should -BeTrue
        $v.Failed | Should -Be 50
    }

    It 'contradicts an expected outage that did not happen' {
        (Invoke-Verdict -Expectation $outageExpected -Upgrade $quiet).Result | Should -Be 'Contradicted'
    }

    It 'confirms a clean upgrade when nothing failed' {
        (Invoke-Verdict -Expectation $cleanExpected -Upgrade $quiet).Result | Should -Be 'Confirmed'
    }

    It 'contradicts a protected pass that dropped any request' {
        (Invoke-Verdict -Expectation $cleanExpected -Upgrade $outage).Result | Should -Be 'Contradicted'
    }

    It 'contradicts when the upgrade was not reported as succeeded: exit <exit>, state <state>' -ForEach @(
        @{ exit = 1; state = 'Succeeded' }
        @{ exit = 0; state = 'Failed' }
        @{ exit = $null; state = '' }
    ) {
        $v = Invoke-Verdict -Expectation $cleanExpected -Upgrade $quiet -Exit $exit -State $state
        $v.Result | Should -Be 'Contradicted'
        $v.ReportedSucceeded | Should -BeFalse
    }

    It 'is unknown when the app was failing before the upgrade began' {
        $sick = Measure-ProbeResult -Sample @(New-Sample (('.' * 140) + 'x' * 10))
        $v = Invoke-Verdict -Expectation $outageExpected -Upgrade $outage -Baseline $sick
        $v.Result | Should -Be 'Unknown'
        $v.Reasons -join ' ' | Should -Match 'BEFORE the upgrade'
    }

    It 'is unknown, never confirmed, when the probe barely ran: <case>' -ForEach @(
        @{ case = 'short baseline'; baseline = 'short' }
        @{ case = 'short upgrade window'; baseline = 'clean' }
    ) {
        $b = if ($baseline -eq 'short') { Measure-ProbeResult -Sample @(New-Sample ('.' * 20)) } else { $clean }
        $u = if ($baseline -eq 'short') { $quiet } else { Measure-ProbeResult -Sample @(New-Sample ('.' * 200)) }
        (Invoke-Verdict -Expectation $cleanExpected -Baseline $b -Upgrade $u).Result | Should -Be 'Unknown'
    }

    It 'is unknown when nothing proves the upgrade drained anything, however clean the traffic' {
        $v = Invoke-Verdict -Expectation $cleanExpected -Upgrade $quiet -Happened ([pscustomobject]@{ Happened = $null; Detail = 'no nodes' })
        $v.Result | Should -Be 'Unknown'
    }

    It 'refuses an expectation it does not understand' {
        { Invoke-Verdict -Expectation ([pscustomobject]@{ expect = 'vibes'; reportedSucceeded = $true }) -Upgrade $quiet } | Should -Throw '*unknown expectation*'
    }
}
