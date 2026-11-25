#Requires -Version 7.2
<#
.SYNOPSIS
Grades the manifests, and the drill's evidence if there is any, against expectations.json.

.DESCRIPTION
With -StaticOnly (CI), checks that the manifest analysis predicts exactly what
expectations.json declares for each pass. Without it, also grades each pass's
live evidence and writes drill-report.json.

Exits non-zero on any mismatch, any Contradicted pass, and any Unknown pass.
Unknown means a precondition for measuring failed, and a drill that could not
measure must not report a pass.
#>
[CmdletBinding()]
param(
    [string]$EvidenceDirectory = 'out',
    [string]$ReportPath = 'drill-report.json',
    [switch]$StaticOnly
)

$ErrorActionPreference = 'Stop'
$InformationPreference = 'Continue'

$root = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'module/UpgradeDrill/UpgradeDrill.psm1') -Force
Import-Module powershell-yaml -ErrorAction Stop

$expectations = [System.IO.File]::ReadAllText((Join-Path $root 'expectations.json')) | ConvertFrom-Json
$failures = [System.Collections.Generic.List[string]]::new()
$summary = [System.Collections.Generic.List[string]]::new()
$report = [ordered]@{ generatedAt = [DateTimeOffset]::UtcNow.ToString('o'); static = [ordered]@{}; passes = [ordered]@{} }

$summary.Add('### Manifest analysis')
$summary.Add('')
$summary.Add('| Pass | Predicted (errors) | Declared | Warnings |')
$summary.Add('|---|---|---|---|')

foreach ($pass in $expectations.passes.PSObject.Properties.Name) {
    $declared = @($expectations.passes.$pass.staticErrors | Sort-Object)
    $documents = @(ConvertFrom-Yaml -Yaml ([System.IO.File]::ReadAllText((Join-Path $root "manifests/$pass/app.yaml"))) -AllDocuments)
    $findings = @(Test-DrainReadiness -Document $documents)
    $errors = @($findings | Where-Object Severity -EQ 'Error' | ForEach-Object Rule | Sort-Object -Unique)
    $warnings = @($findings | Where-Object Severity -EQ 'Warning' | ForEach-Object Rule | Sort-Object -Unique)

    $report.static[$pass] = [ordered]@{ declared = $declared; predicted = $errors; findings = $findings }
    $summary.Add("| $pass | $(if ($errors) { $errors -join ', ' } else { 'none' }) | $(if ($declared) { $declared -join ', ' } else { 'none' }) | $(if ($warnings) { $warnings -join ', ' } else { 'none' }) |")

    # Compared as joined strings: Compare-Object refuses an empty reference,
    # and "no errors predicted" is exactly the case that matters most.
    if (($declared -join ',') -ne ($errors -join ',')) {
        $failures.Add("Manifest analysis for '$pass' predicted [$($errors -join ', ')] but expectations.json declares [$($declared -join ', ')].")
    }
    foreach ($f in $findings) { Write-Information "  [$pass] $($f.Severity) $($f.Rule): $($f.Detail)" }
}

if (-not $StaticOnly) {
    $summary.Add('')
    $summary.Add('### Live upgrade')
    $summary.Add('')
    $summary.Add('| Pass | Upgrade | Azure reported | Requests failed | Longest full outage | Result |')
    $summary.Add('|---|---|---|---|---|---|')

    foreach ($pass in $expectations.passes.PSObject.Properties.Name) {
        $expectation = $expectations.passes.$pass
        $evidencePath = Join-Path $EvidenceDirectory "pass-$pass.json"

        if (-not (Test-Path -LiteralPath $evidencePath)) {
            $failures.Add("Pass '$pass' left no evidence; it did not run.")
            $report.passes[$pass] = [ordered]@{ Result = 'Unknown'; Reasons = @('The pass left no evidence file.') }
            $summary.Add("| $pass | - | - | - | - | **Unknown** (did not run) |")
            continue
        }

        $evidence = [System.IO.File]::ReadAllText($evidencePath) | ConvertFrom-Json
        $samplesPath = Join-Path $EvidenceDirectory $evidence.samplesFile
        $samples = @()
        if (Test-Path -LiteralPath $samplesPath) {
            $samples = @([System.IO.File]::ReadAllLines($samplesPath) | Where-Object { $_ } | ConvertFrom-Json)
        }

        $start = if ($null -ne $evidence.upgradeStartMs) { [long]$evidence.upgradeStartMs } else { [long]::MaxValue }
        $baseline = Measure-ProbeResult -Sample @($samples | Where-Object { [long]$_.t -lt $start })
        $during = Measure-ProbeResult -Sample @($samples | Where-Object { [long]$_.t -ge $start })
        $happened = Test-UpgradeHappened -Before $evidence.before -After $evidence.after `
            -FromVersion $evidence.fromVersion -ToVersion $evidence.toVersion

        $verdict = Get-PassVerdict -Pass $pass -Expectation $expectation -Baseline $baseline -Upgrade $during `
            -Happened $happened -TerraformExit $evidence.terraformExit `
            -ProvisioningState ([string](Get-Field $evidence 'nodePool', 'provisioningState')) `
            -MinimumBaselineSamples $expectations.probe.minimumBaselineSamples `
            -MinimumSamples $expectations.probe.minimumSamples

        if ($evidence.error) {
            $verdict.Reasons = @($verdict.Reasons) + "The pass reported an error: $($evidence.error)"
        }

        $report.passes[$pass] = [ordered]@{
            Result            = $verdict.Result
            Reasons           = $verdict.Reasons
            ReportedSucceeded = $verdict.ReportedSucceeded
            TerraformExit     = $evidence.terraformExit
            NodePool          = $evidence.nodePool
            UpgradeSeconds    = if ($evidence.upgradeEndMs) { [math]::Round(($evidence.upgradeEndMs - $evidence.upgradeStartMs) / 1000) } else { $null }
            Upgrade           = $happened
            Baseline          = $baseline
            During            = $during
        }

        $state = Get-Field $evidence 'nodePool', 'provisioningState'
        $summary.Add(("| $pass | $($evidence.fromVersion) -> $($evidence.toVersion) | " +
                "$(if ($state) { $state } else { '-' }) (terraform exit $($evidence.terraformExit)) | " +
                "$($during.Failed) of $($during.Total) | $([math]::Round($during.LongestOutageMs / 1000, 1))s | **$($verdict.Result)** |"))

        foreach ($reason in $verdict.Reasons) { Write-Information "  [$pass] $($verdict.Result): $reason" }
        if ($verdict.Result -ne 'Confirmed') {
            $failures.Add("Pass '$pass' is $($verdict.Result): $($verdict.Reasons -join ' ')")
        }
    }

    $report | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $ReportPath -Encoding utf8NoBOM
}

if ($env:GITHUB_STEP_SUMMARY) { $summary | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append -Encoding utf8 }
$summary | ForEach-Object { Write-Information $_ }

if ($failures.Count) {
    $failures | ForEach-Object { Write-Warning $_ }
    throw "$($failures.Count) check(s) did not hold."
}
Write-Information 'Every check held.'
