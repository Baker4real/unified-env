#Requires -Version 7.5
[CmdletBinding()]
param([string]$EvidenceRoot = 'D:/agents/run-evidence/host-diagnostics-fixtures')

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$utf8 = [Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = $utf8
$projectRoot = Split-Path -Parent $PSScriptRoot
$entry = Join-Path $projectRoot 'managed/host-diagnostics/Test-HostDiagnostics.ps1'

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Invoke-PublicScript([string]$Path, [string[]]$Arguments) {
    $psi = [Diagnostics.ProcessStartInfo]::new((Join-Path $PSHOME 'pwsh.exe'))
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = $utf8
    $psi.StandardErrorEncoding = $utf8
    foreach ($argument in (@('-NoProfile','-NonInteractive','-File',$Path) + $Arguments)) {
        $psi.ArgumentList.Add($argument)
    }
    $child = [Diagnostics.Process]::Start($psi)
    try {
        $stdout = $child.StandardOutput.ReadToEndAsync()
        $stderr = $child.StandardError.ReadToEndAsync()
        if (-not $child.WaitForExit(180000)) {
            $child.Kill($true)
            [void]$child.WaitForExit(5000)
            throw 'Host diagnostics public entry exceeded its test timeout.'
        }
        [pscustomobject]@{
            exitCode = $child.ExitCode
            stdout = $stdout.GetAwaiter().GetResult()
            stderr = $stderr.GetAwaiter().GetResult()
        }
    }
    finally { $child.Dispose() }
}

function Get-Excerpt([string]$Text, [int]$MaxChars = 4000) {
    if ($Text.Length -le $MaxChars) { return $Text }
    $Text.Substring(0,$MaxChars) + '...[' + ($Text.Length - $MaxChars) + ' more chars]'
}

# CI discards the evidence directory, so the message carries the stdout suite report and each failed suite's evidence.
function Format-DiagnosticsFailure($Result) {
    $lines = [Collections.Generic.List[string]]::new()
    $lines.Add('Managed host diagnostics failed: exit=' + $Result.exitCode)
    $lines.Add('report: ' + (Get-Excerpt $Result.stdout))
    try {
        $report = $Result.stdout | ConvertFrom-Json -ErrorAction Stop
        foreach ($suite in @($report.suites | Where-Object status -eq 'failed')) {
            $detail = if ($suite.evidence) { Get-Content -LiteralPath $suite.evidence -Raw | ConvertFrom-Json -ErrorAction Stop | ConvertTo-Json -Depth 20 -Compress } else { 'no JSON evidence' }
            $lines.Add('failed suite ' + $suite.name + ': ' + (Get-Excerpt $detail))
        }
    }
    catch { $lines.Add('suite evidence unavailable: ' + $_.Exception.Message) }
    if (-not [string]::IsNullOrWhiteSpace($Result.stderr)) { $lines.Add('stderr: ' + (Get-Excerpt $Result.stderr)) }
    $lines -join "`n"
}

Assert-True (Test-Path -LiteralPath $entry -PathType Leaf) 'The managed host diagnostics entry must exist.'
$deployEntry = Join-Path $projectRoot 'scripts/Deploy-HostDiagnostics.ps1'
Assert-True (Test-Path -LiteralPath $deployEntry -PathType Leaf) 'The host diagnostics deployment entry must exist.'
$deployRoot = Join-Path $EvidenceRoot ('deployment-fixture-' + [guid]::NewGuid().ToString('N'))
$targetRoot = Join-Path $deployRoot 'target'
$deployEvidence = Join-Path $deployRoot 'evidence'
[void][IO.Directory]::CreateDirectory($targetRoot)
$sentinel = Join-Path $targetRoot 'unrelated.keep'
$previousFile = Join-Path $targetRoot 'Read-BoundedProjection.ps1'
[IO.File]::WriteAllText($sentinel,'unrelated fixture must remain unchanged',$utf8)
[IO.File]::WriteAllText($previousFile,'# previous managed fixture',$utf8)
$sentinelHash = (Get-FileHash -LiteralPath $sentinel -Algorithm SHA256).Hash
$previousHash = (Get-FileHash -LiteralPath $previousFile -Algorithm SHA256).Hash
$sourceRoot = Split-Path -Parent $entry
$check = Invoke-PublicScript $deployEntry @('-SourceRoot',$sourceRoot,'-TargetRoot',$targetRoot,'-EvidenceRoot',$deployEvidence)
$checkReport = $check.stdout | ConvertFrom-Json -ErrorAction Stop
Assert-True ($check.exitCode -eq 1 -and $checkReport.mode -eq 'Check' -and $checkReport.status -eq 'drift') 'Default Check must expose drift without applying it.'
Assert-True ($checkReport.files.Count -eq 15 -and $checkReport.changedFiles -eq 15) 'Check must compare every allowlisted file.'
Assert-True (-not (Test-Path -LiteralPath $deployEvidence)) 'Check must not create an evidence directory.'
Assert-True ((Get-FileHash -LiteralPath $previousFile -Algorithm SHA256).Hash -eq $previousHash -and (Get-ChildItem -LiteralPath $targetRoot -Recurse -File).Count -eq 2) 'Check must leave the target tree unchanged.'

$apply = Invoke-PublicScript $deployEntry @('-Mode','Apply','-SourceRoot',$sourceRoot,'-TargetRoot',$targetRoot,'-EvidenceRoot',$deployEvidence)
$applyReport = $apply.stdout | ConvertFrom-Json -ErrorAction Stop
Assert-True ($apply.exitCode -eq 0 -and $applyReport.status -eq 'deployed' -and $applyReport.writtenFiles -eq 15) 'Apply must publish the complete allowlist.'
$replaced = @($applyReport.files | Where-Object relative -eq 'Read-BoundedProjection.ps1')[0]
Assert-True ((Get-FileHash -LiteralPath $replaced.backupPath -Algorithm SHA256).Hash -eq $previousHash) 'Apply must retain the original file as a verified backup.'
Assert-True ((Get-FileHash -LiteralPath $sentinel -Algorithm SHA256).Hash -eq $sentinelHash) 'Apply must not modify files outside the allowlist.'
Assert-True ((Get-ChildItem -LiteralPath $targetRoot -Recurse -File).Count -eq 16) 'Apply must not publish undeclared files.'
Assert-True (Test-Path -LiteralPath (Join-Path $applyReport.evidenceDirectory 'manifest.json') -PathType Leaf) 'Apply must save its deployment evidence.'
$after = Invoke-PublicScript $deployEntry @('-SourceRoot',$sourceRoot,'-TargetRoot',$targetRoot)
$afterReport = $after.stdout | ConvertFrom-Json -ErrorAction Stop
Assert-True ($after.exitCode -eq 0 -and $afterReport.status -eq 'in-sync' -and $afterReport.changedFiles -eq 0) 'An independent Check must confirm every deployed source hash.'

$incompleteSource = Join-Path $deployRoot 'incomplete-source'
[void][IO.Directory]::CreateDirectory($incompleteSource)
$linkedTarget = Join-Path $deployRoot 'target-link'
New-Item -ItemType Junction -Path $linkedTarget -Target $targetRoot | Out-Null
$refusalCases = @(
    @{name='same-path';source=$sourceRoot;target=$sourceRoot;reason='must not be the same path or overlap'},
    @{name='missing-source';source=$incompleteSource;target=$targetRoot;reason='Missing allowlisted source'},
    @{name='reparse-ancestor';source=$sourceRoot;target=$linkedTarget;reason='Reparse point is not an allowed deployment path'}
)
foreach ($case in $refusalCases) {
    $refusedEvidence = Join-Path $deployRoot ($case.name + '-evidence')
    $refused = Invoke-PublicScript $deployEntry @('-Mode','Apply','-SourceRoot',$case.source,'-TargetRoot',$case.target,'-EvidenceRoot',$refusedEvidence)
    $refusedReport = $refused.stdout | ConvertFrom-Json -ErrorAction Stop
    Assert-True ($refused.exitCode -eq 1 -and $refusedReport.status -eq 'failed' -and $refusedReport.writtenFiles -eq 0 -and $refusedReport.error.Contains($case.reason)) ('Deployment must refuse ' + $case.name + ' before any replacement.')
    Assert-True (-not (Test-Path -LiteralPath $refusedEvidence)) ('Refused deployment must not create evidence for ' + $case.name + '.')
}
$unchanged = Invoke-PublicScript $deployEntry @('-SourceRoot',$sourceRoot,'-TargetRoot',$targetRoot)
$unchangedReport = $unchanged.stdout | ConvertFrom-Json -ErrorAction Stop
Assert-True ($unchanged.exitCode -eq 0 -and $unchangedReport.status -eq 'in-sync') 'Refused deployments must leave the existing bundle unchanged.'
Assert-True ((Get-FileHash -LiteralPath $sentinel -Algorithm SHA256).Hash -eq $sentinelHash) 'Refused deployments must not modify unrelated files.'
$deploymentReport = [ordered]@{
    status = 'passed'
    cases = @('default-check-is-read-only','apply-allowlist-backup-readback') + @($refusalCases.name)
    deploymentManifest = Join-Path $applyReport.evidenceDirectory 'manifest.json'
    sourceRoot = $sourceRoot
    targetRoot = $targetRoot
}
$deploymentResultPath = Join-Path $deployRoot 'deployment-result.json'
[IO.File]::WriteAllText($deploymentResultPath,($deploymentReport | ConvertTo-Json -Depth 4),$utf8)

$result = Invoke-PublicScript $entry @('-EvidenceRoot',$EvidenceRoot,'-SkipLiveSnapshot')
if ($result.exitCode -ne 0) { throw (Format-DiagnosticsFailure $result) }
Assert-True ([string]::IsNullOrWhiteSpace($result.stderr)) 'Managed host diagnostics wrote unexpected stderr.'
$report = $result.stdout | ConvertFrom-Json -ErrorAction Stop
Assert-True ($report.status -eq 'passed-with-skips') 'CI must report its live snapshot omission explicitly.'
Assert-True ($report.syntaxChecks -eq 15) 'The complete 15-file bundle must pass syntax checks.'
Assert-True ($report.suites.Count -eq 6) 'All six managed diagnostic suites must run.'
Assert-True (@($report.suites | Where-Object { $_.status -notin @('passed','passed-with-skips') }).Count -eq 0) 'A diagnostic suite failed.'
$explorerSuite = @($report.suites | Where-Object name -eq 'explorer')[0]
$explorer = Get-Content -LiteralPath $explorerSuite.evidence -Raw | ConvertFrom-Json -ErrorAction Stop
$skipped = @($explorer.Results | Where-Object Status -eq 'skipped')
Assert-True ($skipped.Count -eq 1 -and $skipped[0].Case -eq 'RealReadOnlySnapshot' -and $skipped[0].Reason -eq 'SkipLiveSnapshot') 'Only the explicitly requested real snapshot may be skipped.'
Assert-True (@($explorer.Results | Where-Object Status -eq 'passed').Count -eq 11) 'All isolated Explorer recovery cases must still pass.'
$recycleSuite = @($report.suites | Where-Object name -eq 'recycle')[0]
$recycle = Get-Content -LiteralPath $recycleSuite.evidence -Raw | ConvertFrom-Json -ErrorAction Stop
$recycleSkipped = @($recycle.results | Where-Object status -eq 'skipped')
Assert-True ($recycleSkipped.Count -eq 1 -and $recycleSkipped[0].name -like 'live recycle*' -and $recycleSkipped[0].reason -eq 'SkipLiveRecycle') 'CI must not touch the real Recycle Bin.'
Assert-True ($recycle.failures -eq 0 -and @($recycle.results | Where-Object status -eq 'passed').Count -eq $recycle.cases - 1) 'All isolated managed recycle cases must still pass.'
if ($env:GITHUB_ACTIONS -eq 'true' -and $env:RUNNER_ENVIRONMENT -eq 'github-hosted') {
    Assert-True ($recycle.binSettingsCheck.beforeCheck -eq $false -and $recycle.binSettingsCheck.afterCheck -eq $true) 'On a GitHub-hosted runner the passing Check case must start without bin settings and leave them created.'
}
Assert-True ($explorerSuite.skippedChecks -eq 1 -and $recycleSuite.skippedChecks -eq 1 -and $report.skippedChecks -eq 2) 'Skipped checks must be counted separately from passes.'
Assert-True (-not (Test-Path -LiteralPath (Join-Path $explorer.EvidenceDirectory 'real-before.json'))) 'CI must not capture the real Explorer snapshot.'
$powershellSuite = @($report.suites | Where-Object name -eq 'powershell')[0]
$powershell = Get-Content -LiteralPath $powershellSuite.evidence -Raw | ConvertFrom-Json -ErrorAction Stop
$runRootPrefix = [IO.Path]::GetFullPath($report.evidenceDirectory).TrimEnd('\') + '\'
Assert-True ([IO.Path]::GetFullPath($powershell.fixture).StartsWith($runRootPrefix,[StringComparison]::OrdinalIgnoreCase)) 'PowerShell regression evidence must remain under the caller-supplied evidence root.'

[pscustomobject]@{
    status = 'passed-with-skips'
    suites = $report.suites.Count
    passedChecks = $report.passedChecks
    skippedChecks = $report.skippedChecks
    # False on a fresh runner means the passing Check/Plan cases created the bin settings themselves.
    recycleBinSettingsAtStart = $recycle.binSettingsAtStart
    # On a GitHub-hosted runner beforeCheck=false and afterCheck=true prove the query-first order; reset says the test removed them.
    recycleBinSettingsCheck = $recycle.binSettingsCheck
    deploymentChecks = $deploymentReport.cases.Count
    deploymentEvidence = $deploymentResultPath
    evidenceDirectory = $report.evidenceDirectory
} | ConvertTo-Json -Compress
