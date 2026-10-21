#requires -Version 7.4
<#
.SYNOPSIS
Exercise Invoke-ManagedRecycle through its public process interface on D: fixtures.
.DESCRIPTION
Check, refusal and plan cases never touch the Recycle Bin. The live case recycles two fixture trees into the D: bin,
the second while the first one's $I index record is held open the way Explorer or a scanner briefly holds a new
record and a decoy $I record for another path sits in the bin, then restores both the way Explorer does, without
deleting anything: each $R content moves back to its path and each $I record, the decoy included, moves into this
run's evidence. -SkipLiveRecycle reports that case as skipped.
#>
[CmdletBinding()]
param(
    [string]$EvidenceRoot = 'D:/agents/run-evidence/managed-recycle-tests',
    [switch]$SkipLiveRecycle
)

$ErrorActionPreference = 'Stop'
$utf8 = [Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = $utf8
$OutputEncoding = $utf8
$fullEvidenceRoot = [IO.Path]::GetFullPath($EvidenceRoot)
if (-not $fullEvidenceRoot.StartsWith('D:\', [StringComparison]::OrdinalIgnoreCase)) { throw 'EvidenceRoot must resolve to D drive.' }
$runRoot = Join-Path $fullEvidenceRoot ('ManagedRecycle-' + [guid]::NewGuid().ToString('N'))
$fixtures = Join-Path $runRoot 'fixtures'
$entryEvidence = Join-Path $runRoot 'entry'
[void][IO.Directory]::CreateDirectory($fixtures)
[void][IO.Directory]::CreateDirectory($entryEvidence)
$entry = Join-Path $PSScriptRoot 'Invoke-ManagedRecycle.ps1'
$cases = [Collections.Generic.List[object]]::new()
$junctions = [Collections.Generic.List[string]]::new()
$expectedManifest = @("D`tempty", "D`tsub", "F`ta.txt`t5", "F`tsub\b.bin`t1024")
$liveCase = 'live recycle finds each tree''s own bin record past a locked record and a newer decoy, and the test restores them'
# Whether the fixture volume has bin settings; a fresh profile (a CI runner) has none until the volume's bin is first used.
$fixtureVolume = try { [string](Get-CimInstance Win32_Volume -Filter "DriveLetter='$([IO.Path]::GetPathRoot($fullEvidenceRoot).TrimEnd('\'))'").DeviceID } catch { '' }
$binSettingsKey = if ($fixtureVolume) {
    'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\BitBucket\Volume\' + ($fixtureVolume -replace '^\\\\\?\\Volume|\\$', '')
}
function Test-BinSettings {
    if (-not $binSettingsKey) { return $null }
    $settings = Get-ItemProperty -LiteralPath $binSettingsKey -ErrorAction SilentlyContinue
    $null -ne $settings -and $null -ne $settings.PSObject.Properties['MaxCapacity'] -and $null -ne $settings.PSObject.Properties['NukeOnDelete']
}
$binSettingsAtStart = Test-BinSettings
# Earlier suites can create the settings first. Only on a disposable GitHub-hosted runner, the Check case removes them right
# before it calls the entry, so a pass always proves that the entry's query-first order recreates them.
$resetBinSettings = $env:GITHUB_ACTIONS -eq 'true' -and $env:RUNNER_ENVIRONMENT -eq 'github-hosted' -and [bool]$binSettingsKey
$binSettingsCheck = [ordered]@{ reset = $false; removed = $null; beforeCheck = $null; afterCheck = $null }

function Invoke-Entry {
    param([string[]]$EntryArguments)
    $psi = [Diagnostics.ProcessStartInfo]::new((Join-Path $PSHOME 'pwsh.exe'))
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = $utf8
    $psi.StandardErrorEncoding = $utf8
    foreach ($argument in @('-NoProfile', '-NonInteractive', '-File', $entry) + $EntryArguments + @('-EvidenceRoot', $entryEvidence)) {
        $psi.ArgumentList.Add([string]$argument)
    }
    $process = [Diagnostics.Process]::Start($psi)
    try {
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(60000)) {
            $process.Kill($true)
            throw 'Entry exceeded its 60-second test timeout.'
        }
        $out = $stdout.GetAwaiter().GetResult()
        $json = try { $out | ConvertFrom-Json -AsHashtable -ErrorAction Stop } catch { $null }
        [pscustomobject]@{ exitCode = $process.ExitCode; json = $json; stdout = $out; stderr = $stderr.GetAwaiter().GetResult() }
    }
    finally {
        if (-not $process.HasExited) { $process.Kill($true) }
        $process.Dispose()
    }
}

function Invoke-Plan([string]$Target) {
    Invoke-Entry @('-Mode', 'Plan', '-TargetPath', $Target, '-Purpose', 'managed recycle test', '-Authorization', 'test fixture created by this run')
}

function Assert-Refused($Response, [string]$Reason) {
    if ($null -eq $Response.json) { throw "Entry output was not JSON (exit $($Response.exitCode))." }
    if ($Response.exitCode -ne 1 -or $Response.json.status -ne 'refused' -or $Response.json.reason -ne $Reason) {
        throw "Expected refusal '$Reason'; received exit $($Response.exitCode) status '$($Response.json.status)' reason '$($Response.json.reason)'."
    }
    if ($Response.stderr) { throw 'Entry wrote to stderr.' }
}

function Assert-Case {
    param([string]$Name, [scriptblock]$Test)
    try {
        & $Test
        $cases.Add([pscustomobject]@{ name = $Name; status = 'passed' })
    } catch {
        $cases.Add([pscustomobject]@{ name = $Name; status = 'failed'; reason = $_.Exception.Message })
    }
}

function New-Tree([string]$Name) {
    $root = Join-Path $fixtures $Name
    [void][IO.Directory]::CreateDirectory((Join-Path $root 'sub'))
    [void][IO.Directory]::CreateDirectory((Join-Path $root 'empty'))
    [IO.File]::WriteAllText((Join-Path $root 'a.txt'), 'hello', $utf8)
    [IO.File]::WriteAllBytes((Join-Path $root 'sub\b.bin'), [byte[]]::new(1024))
    $root
}

function New-Junction([string]$Path, [string]$Target) {
    $null = New-Item -ItemType Junction -Path $Path -Target $Target
    $junctions.Add($Path)
}

# A version 2 $I record for a path that was never recycled, dated a day ahead so that it is the newest in the bin.
function New-BinDecoy([string]$BinDirectory, [string]$Original) {
    $path = Join-Path $BinDirectory ('$I' + [guid]::NewGuid().ToString('N').Substring(0, 6).ToUpperInvariant())
    $name = [Text.Encoding]::Unicode.GetBytes($Original + [char]0)
    $bytes = [byte[]]([BitConverter]::GetBytes([long]2) + [BitConverter]::GetBytes([long]1029) +
        [BitConverter]::GetBytes([DateTime]::UtcNow.AddDays(1).ToFileTimeUtc()) + [BitConverter]::GetBytes([int]($name.Length / 2)) + $name)
    $stream = [IO.File]::Open($path, 'CreateNew', 'Write', 'None')
    try { $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Dispose() }
    $path
}

# Explorer and scanners briefly open new $I records; retry a step on one for up to 10 seconds.
function Invoke-BinStep([scriptblock]$Step) {
    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    while ($true) {
        try { return & $Step }
        catch [IO.IOException] {
            if ([DateTime]::UtcNow -ge $deadline) { throw }
            Start-Sleep -Milliseconds 200
        }
    }
}

$realTarget = Join-Path $fixtures 'junction-target'
[void][IO.Directory]::CreateDirectory((Join-Path $realTarget 'child'))
$longTree = Join-Path $fixtures 'tree-long'
$longFile = $null

try {
    Assert-Case 'plan refuses relative and missing targets' {
        Assert-Refused (Invoke-Plan 'relative\target') 'target-not-fully-qualified'
        Assert-Refused (Invoke-Plan (Join-Path $fixtures 'missing')) 'target-missing'
    }

    Assert-Case 'plan refuses volume roots, protected roots and their ancestors' {
        foreach ($target in @('D:\', 'D:\agents\projects', 'C:\Users', $entryEvidence, (Split-Path -Parent $entryEvidence))) {
            $response = Invoke-Plan $target
            Assert-Refused $response 'protected-location'
            if ($response.json.protection -notin @('volume-root', 'protected-root')) { throw "Unexpected protection for $target." }
        }
    }

    Assert-Case 'plan refuses system subtrees, the bin and the evidence root' {
        $windowsTemp = Join-Path ([Environment]::GetFolderPath('Windows')) 'Temp'
        foreach ($target in @($windowsTemp, 'D:\$Recycle.Bin', (Join-Path $entryEvidence 'inside'))) {
            $response = Invoke-Plan $target
            Assert-Refused $response 'protected-location'
            if ($response.json.protection -ne 'protected-subtree') { throw "Unexpected protection for $target." }
        }
    }

    Assert-Case 'plan refuses a junction on the target path' {
        $link = Join-Path $fixtures 'junction-on-path'
        New-Junction $link $realTarget
        $response = Invoke-Plan (Join-Path $link 'child')
        Assert-Refused $response 'reparse-point-on-path'
        if ($response.json.reparsePoint -ne $link) { throw 'The reported reparse point is not the junction.' }
    }

    Assert-Case 'plan refuses a junction inside the tree' {
        $tree = New-Tree 'tree-junction'
        New-Junction (Join-Path $tree 'inner') $realTarget
        $response = Invoke-Plan $tree
        Assert-Refused $response 'tree-not-recyclable'
        if (@($response.json.problems) -notcontains 'reparse-point: inner') { throw 'The junction was not reported.' }
    }

    Assert-Case 'plan refuses hard-linked files' {
        $tree = New-Tree 'tree-hardlink'
        $null = New-Item -ItemType HardLink -Path (Join-Path $fixtures 'hardlink-twin.txt') -Target (Join-Path $tree 'a.txt')
        $response = Invoke-Plan $tree
        Assert-Refused $response 'tree-not-recyclable'
        if (@($response.json.problems) -notcontains 'hard-link: a.txt (2 links)') { throw 'The hard link was not reported.' }
    }

    Assert-Case 'plan refuses paths the shell cannot move' {
        [void][IO.Directory]::CreateDirectory($longTree)
        $name = 'x' * (262 - $longTree.Length - 1)
        $script:longFile = Join-Path $longTree $name
        [IO.File]::WriteAllText($script:longFile, 'long', $utf8)
        $response = Invoke-Plan $longTree
        Assert-Refused $response 'path-too-long'
        if ($response.json.longestPath -le 259) { throw 'The longest path was not measured.' }
        $binDirectory = 'D:\$Recycle.Bin\' + [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        if ($response.json.inPlaceLongestPath -ne 262 -or $response.json.inBinLongestPath -ne $binDirectory.Length + 10 + $name.Length) {
            throw 'The in-place and in-bin lengths were not reported.'
        }
        if ($response.json.tooLongCount -ne 1 -or [string]::Join('|', $response.json.tooLong) -cne $name) { throw 'The entry over the limit was not named.' }
    }

    Assert-Case 'plan requires purpose and authorization' {
        $tree = New-Tree 'tree-unauthorized'
        Assert-Refused (Invoke-Entry @('-Mode', 'Plan', '-TargetPath', $tree, '-Purpose', 'managed recycle test')) 'purpose-and-authorization-required'
        if (@(Get-ChildItem -LiteralPath $entryEvidence -Filter 'plan.json' -Recurse).Count -ne 0) { throw 'A refused plan wrote plan.json.' }
    }

    Assert-Case 'check shares the preflight without purpose or authorization' {
        Assert-Refused (Invoke-Entry @('-Mode', 'Check', '-TargetPath', (Join-Path $fixtures 'missing'))) 'target-missing'
        Assert-Refused (Invoke-Entry @('-Mode', 'Check', '-TargetPath', 'D:\agents\projects')) 'protected-location'
    }

    Assert-Case 'check reports a recyclable tree and writes no evidence' {
        $tree = New-Tree 'tree-check'
        $before = @(Get-ChildItem -LiteralPath $entryEvidence -Recurse).Count
        if ($resetBinSettings -and (Test-BinSettings)) {
            $settings = Get-ItemProperty -LiteralPath $binSettingsKey
            $binSettingsCheck.removed = [ordered]@{ MaxCapacity = $settings.MaxCapacity; NukeOnDelete = $settings.NukeOnDelete }
            Remove-Item -LiteralPath $binSettingsKey -Recurse
            $binSettingsCheck.reset = $true
        }
        $binSettingsCheck.beforeCheck = Test-BinSettings
        $response = Invoke-Entry @('-Mode', 'Check', '-TargetPath', $tree)
        $binSettingsCheck.afterCheck = Test-BinSettings
        if ($response.exitCode -ne 0 -or $response.json.status -ne 'checked' -or $response.stderr) { throw "Check failed: $($response.stdout)" }
        if ($response.json.fileCount -ne 2 -or $response.json.directoryCount -ne 2 -or $response.json.totalBytes -ne 1029) { throw 'Check totals changed.' }
        if (@($response.json.topLevel).Count -ne 3 -or $response.json.ContainsKey('planPath')) { throw 'Check did not report the top level, or reported a plan.' }
        if (@(Get-ChildItem -LiteralPath $entryEvidence -Recurse).Count -ne $before) { throw 'Check wrote evidence.' }
    }

    Assert-Case 'plan writes the exact manifest pinned by the plan hash' {
        $tree = New-Tree 'tree-plan'
        $response = Invoke-Plan $tree
        if ($response.exitCode -ne 0 -or $response.json.status -ne 'planned' -or $response.stderr) { throw "Plan failed: $($response.stdout)" }
        $planPath = $response.json.planPath
        if ((Split-Path -Parent (Split-Path -Parent $planPath)) -ne $entryEvidence) { throw 'plan.json is not directly under a run directory.' }
        if ((Get-FileHash -LiteralPath $planPath -Algorithm SHA256).Hash -ne $response.json.planSha256) { throw 'planSha256 is not the plan file hash.' }
        $plan = [IO.File]::ReadAllText($planPath) | ConvertFrom-Json -AsHashtable
        if ([string]::Join('|', $plan.manifest) -cne [string]::Join('|', $expectedManifest)) { throw 'The manifest is not exact.' }
        if ($plan.target -ne $tree -or $plan.fileCount -ne 2 -or $plan.directoryCount -ne 2 -or $plan.totalBytes -ne 1029) { throw 'Plan totals changed.' }
        if ($plan.authorization -cne 'test fixture created by this run' -or $plan.purpose -cne 'managed recycle test') { throw 'Plan lost its authorization.' }
        $single = Invoke-Plan (Join-Path $tree 'a.txt')
        $singlePlan = [IO.File]::ReadAllText($single.json.planPath) | ConvertFrom-Json -AsHashtable
        if ($single.json.kind -ne 'file' -or [string]::Join('|', $singlePlan.manifest) -cne "F`t`t5") { throw 'A single-file plan is not exact.' }
        $script:planned = $response.json
    }

    Assert-Case 'apply requires confirmation, the approved hash and a plan inside its evidence root' {
        if (-not $script:planned) { throw 'No plan from the previous case.' }
        $plan = $script:planned
        Assert-Refused (Invoke-Entry @('-Mode', 'Apply', '-PlanPath', $plan.planPath, '-ApprovedPlanSha256', $plan.planSha256)) 'confirm-recycle-required'
        Assert-Refused (Invoke-Entry @('-Mode', 'Apply', '-PlanPath', $plan.planPath, '-ApprovedPlanSha256', ('0' * 64), '-ConfirmRecycle')) 'plan-sha256-mismatch'
        $outside = Join-Path $fixtures 'plan.json'
        [IO.File]::Copy($plan.planPath, $outside)
        Assert-Refused (Invoke-Entry @('-Mode', 'Apply', '-PlanPath', $outside, '-ApprovedPlanSha256', $plan.planSha256, '-ConfirmRecycle')) 'plan-outside-evidence-root'
        if (-not [IO.Directory]::Exists($plan.target)) { throw 'A refused apply touched the target.' }
    }

    Assert-Case 'apply refuses an expired plan' {
        $plan = [IO.File]::ReadAllText($script:planned.planPath) | ConvertFrom-Json -AsHashtable
        $plan.createdUnixMs = [DateTimeOffset]::UtcNow.AddMinutes(-31).ToUnixTimeMilliseconds()
        $runDir = Join-Path $entryEvidence 'expired-plan'
        [void][IO.Directory]::CreateDirectory($runDir)
        $bytes = $utf8.GetBytes(($plan | ConvertTo-Json -Depth 6))
        [IO.File]::WriteAllBytes((Join-Path $runDir 'plan.json'), $bytes)
        $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))
        Assert-Refused (Invoke-Entry @('-Mode', 'Apply', '-PlanPath', (Join-Path $runDir 'plan.json'), '-ApprovedPlanSha256', $hash, '-ConfirmRecycle')) 'plan-expired'
    }

    Assert-Case 'apply records a changed tree once and refuses to replay the plan' {
        $tree = New-Tree 'tree-drift'
        $planned = Invoke-Plan $tree
        if ($planned.exitCode -ne 0) { throw "Plan failed: $($planned.stdout)" }
        [IO.File]::WriteAllText((Join-Path $tree 'extra.txt'), 'drift', $utf8)
        $apply = @('-Mode', 'Apply', '-PlanPath', $planned.json.planPath, '-ApprovedPlanSha256', $planned.json.planSha256, '-ConfirmRecycle')
        Assert-Refused (Invoke-Entry $apply) 'manifest-changed'
        $recorded = [IO.File]::ReadAllText((Join-Path (Split-Path -Parent $planned.json.planPath) 'result.json')) | ConvertFrom-Json -AsHashtable
        if ($recorded.reason -ne 'manifest-changed' -or -not [IO.File]::Exists((Join-Path $tree 'extra.txt'))) { throw 'The drift refusal was not recorded or touched the tree.' }
        Assert-Refused (Invoke-Entry $apply) 'plan-already-applied'
    }

    if ($SkipLiveRecycle) { $cases.Add([pscustomobject]@{ name = $liveCase; status = 'skipped'; reason = 'SkipLiveRecycle' }) }
    else {
        Assert-Case $liveCase {
            $tree = New-Tree 'tree-live'
            $planned = Invoke-Plan $tree
            if ($planned.exitCode -ne 0) { throw "Plan failed: $($planned.stdout)" }
            $applied = Invoke-Entry @('-Mode', 'Apply', '-PlanPath', $planned.json.planPath, '-ApprovedPlanSha256', $planned.json.planSha256, '-ConfirmRecycle')
            if ($applied.exitCode -ne 0 -or $applied.json.status -ne 'recycled' -or $applied.stderr) { throw "Recycle failed: $($applied.stdout)" }
            $record = $applied.json.binRecord
            $binDir = 'D:\$Recycle.Bin\' + [Security.Principal.WindowsIdentity]::GetCurrent().User.Value + '\'
            if ([IO.Directory]::Exists($tree) -or -not [IO.Directory]::Exists($record.contentPath) -or -not [IO.File]::Exists($record.indexPath) -or
                -not $record.indexPath.StartsWith($binDir, [StringComparison]::OrdinalIgnoreCase)) { throw 'The bin record does not match the recycled tree.' }
            $saved = [IO.File]::ReadAllText($applied.json.resultPath) | ConvertFrom-Json -AsHashtable
            if ($saved.status -ne 'recycled' -or $saved.binManifestSha256 -ne $planned.json.manifestSha256) { throw 'result.json does not prove the bin copy.' }
            # The second tree's readback walks every $I record: the first tree's, held here without sharing, and a decoy
            # for another path dated after every real record, which only the original-path match rules out.
            $second = New-Tree 'tree-live-second'
            $secondPlanned = Invoke-Plan $second
            if ($secondPlanned.exitCode -ne 0) { throw "Plan failed: $($secondPlanned.stdout)" }
            $lock = Invoke-BinStep { [IO.File]::Open($record.indexPath, 'Open', 'Read', 'None') }
            $decoy = $null
            try {
                $decoy = New-BinDecoy $binDir (Join-Path $fixtures 'decoy')
                $secondApplied = Invoke-Entry @('-Mode', 'Apply', '-PlanPath', $secondPlanned.json.planPath, '-ApprovedPlanSha256', $secondPlanned.json.planSha256, '-ConfirmRecycle')
            }
            finally {
                $lock.Dispose()
                if ($decoy) { Invoke-BinStep { [IO.File]::Move($decoy, (Join-Path $runRoot 'restored-bin-decoy.bin')) } }
            }
            [IO.Directory]::Move($record.contentPath, $tree)
            Invoke-BinStep { [IO.File]::Move($record.indexPath, (Join-Path $runRoot 'restored-bin-index.bin')) }
            if ($secondApplied.exitCode -ne 0 -or $secondApplied.json.status -ne 'recycled' -or $secondApplied.stderr) { throw "Recycle past a locked record failed: $($secondApplied.stdout)" }
            if (@($secondApplied.json.unreadableBinRecords) -notcontains $record.indexPath) { throw 'The locked record was not reported as skipped.' }
            $secondRecord = $secondApplied.json.binRecord
            if ($secondRecord.indexPath -eq $decoy) { throw 'The readback took the decoy record for another path.' }
            [IO.Directory]::Move($secondRecord.contentPath, $second)
            Invoke-BinStep { [IO.File]::Move($secondRecord.indexPath, (Join-Path $runRoot 'restored-bin-index-second.bin')) }
            $replanned = Invoke-Plan $tree
            if ($replanned.exitCode -ne 0 -or $replanned.json.manifestSha256 -ne $planned.json.manifestSha256) { throw 'The restored tree differs from the plan.' }
            $replanned = Invoke-Plan $second
            if ($replanned.exitCode -ne 0 -or $replanned.json.manifestSha256 -ne $secondPlanned.json.manifestSha256) { throw 'The restored second tree differs from its plan.' }
        }
    }
}
finally {
    # Leave fixtures as evidence, minus the two shapes later tools trip on: junction links and a path over MAX_PATH.
    foreach ($link in $junctions) { if ([IO.Directory]::Exists($link)) { [IO.Directory]::Delete($link) } }
    if ($longFile -and [IO.File]::Exists($longFile)) { [IO.File]::Move($longFile, (Join-Path $longTree 'long-name-renamed.txt')) }
}

$failed = @($cases | Where-Object status -eq 'failed')
$skipped = @($cases | Where-Object status -eq 'skipped')
$report = [ordered]@{
    status = if ($failed.Count) { 'failed' } elseif ($skipped.Count) { 'passed-with-skips' } else { 'passed' }
    cases = $cases.Count
    failures = $failed.Count
    skipped = $skipped.Count
    fixture = $runRoot
    binSettingsAtStart = $binSettingsAtStart
    binSettingsCheck = $binSettingsCheck
    runtime = $PSVersionTable.PSVersion.ToString()
    entrySha256 = (Get-FileHash -LiteralPath $entry -Algorithm SHA256).Hash
    testSha256 = (Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash
    results = $cases.ToArray()
}
$json = $report | ConvertTo-Json -Depth 6
[IO.File]::WriteAllText((Join-Path $runRoot 'ManagedRecycle-results.json'), $json, $utf8)
$json
if ($failed.Count) { exit 1 }
exit 0
