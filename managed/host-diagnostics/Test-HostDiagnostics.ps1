#Requires -Version 7.5
<#
.SYNOPSIS
Validate host diagnostic tools. Explorer recovery uses isolated owned test processes.
#>
[CmdletBinding()]
param(
    [string]$EvidenceRoot = 'D:/agents/run-evidence/host-diagnostics-checks',
    [switch]$SkipLiveSnapshot
)
$ErrorActionPreference = 'Stop'
$utf8 = [Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = $utf8
$fullRoot = [IO.Path]::GetFullPath($EvidenceRoot)
if (-not $fullRoot.StartsWith('D:\',[StringComparison]::OrdinalIgnoreCase)) { throw 'EvidenceRoot must resolve to D drive.' }
$runRoot = Join-Path $fullRoot ([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ') + '-' + [guid]::NewGuid().ToString('N').Substring(0,8))
[void][IO.Directory]::CreateDirectory($runRoot)
$files = @(
    'Read-BoundedProjection.ps1','Test-BoundedProjection.ps1',
    'Invoke-CheckedPowerShell.ps1','Test-CheckedPowerShell.ps1',
    'BrowserPrivacyProbe.py','Test-BrowserPrivacyProbe.py',
    'Get-NvidiaDownloadStatus.ps1','Test-NvidiaDownloadStatus.ps1',
    'Get-TaskbarSnapshot.ps1','Restart-ExplorerShell.ps1',
    'lib/ExplorerShellRecovery.ps1','Test-ExplorerShellRecovery.ps1',
    'Invoke-ManagedRecycle.ps1','Test-ManagedRecycle.ps1',
    'Test-HostDiagnostics.ps1'
)
$python = (Get-Command python.exe -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
$syntax = foreach ($file in $files) {
    $path = Join-Path $PSScriptRoot $file
    $tokens = $null; $parseErrors = $null
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        [pscustomobject]@{file=$file;status='missing';errors=@();sha256=$null}; continue
    }
    if ([IO.Path]::GetExtension($file) -eq '.py') {
        & $python -B -c 'import ast, pathlib, sys; ast.parse(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))' $path
        $parseErrors = if ($LASTEXITCODE -eq 0) { @() } else { @([pscustomobject]@{ErrorId='PythonSyntax';Extent=@{StartLineNumber=0}}) }
    }
    else { [void][Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$parseErrors) }
    [pscustomobject]@{
        file=$file
        status=$(if ($parseErrors.Count -eq 0) { 'passed' } else { 'failed' })
        errors=@($parseErrors | ForEach-Object { @{id=$_.ErrorId;line=$_.Extent.StartLineNumber} })
        sha256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
    }
}
$suiteDefinitions = @(
    @{name='projection';file='Test-BoundedProjection.ps1';args=@('-EvidenceRoot',(Join-Path $runRoot 'projection'))},
    @{name='powershell';file='Test-CheckedPowerShell.ps1';args=@('-EvidenceRoot',(Join-Path $runRoot 'powershell'))},
    @{name='nvidia';file='Test-NvidiaDownloadStatus.ps1';args=@('-EvidenceRoot',(Join-Path $runRoot 'nvidia'))},
    @{name='explorer';file='Test-ExplorerShellRecovery.ps1';args=@('-EvidenceDirectory',(Join-Path $runRoot 'explorer'))},
    @{name='browser';file='Test-BrowserPrivacyProbe.py';args=@()},
    @{name='recycle';file='Test-ManagedRecycle.ps1';args=@('-EvidenceRoot',(Join-Path $runRoot 'recycle'))}
)
if ($SkipLiveSnapshot) {
    $suiteDefinitions[3].args += '-SkipLiveSnapshot'
    $suiteDefinitions[5].args += '-SkipLiveRecycle'
}
$suites = [Collections.Generic.List[object]]::new()
if (@($syntax | Where-Object status -NE 'passed').Count -eq 0) {
    foreach ($suite in $suiteDefinitions) {
        $isPython = [IO.Path]::GetExtension($suite.file) -eq '.py'
        $runtime = if ($isPython) { $python } else { Join-Path $PSHOME 'pwsh.exe' }
        $psi = [Diagnostics.ProcessStartInfo]::new($runtime)
        $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
        $psi.StandardOutputEncoding = $utf8; $psi.StandardErrorEncoding = $utf8
        $entryArguments = if ($isPython) { @('-B',(Join-Path $PSScriptRoot $suite.file)) } else { @('-NoProfile','-NonInteractive','-File',(Join-Path $PSScriptRoot $suite.file)) }
        if ($isPython) { $psi.Environment['BROWSER_PROBE_TEST_ROOT'] = Join-Path $runRoot 'browser' }
        foreach ($argument in ($entryArguments + $suite.args)) {
            $psi.ArgumentList.Add([string]$argument)
        }
        $child = [Diagnostics.Process]::Start($psi)
        $stdoutTask = $child.StandardOutput.ReadToEndAsync()
        $stderrTask = $child.StandardError.ReadToEndAsync()
        $child.WaitForExit()
        $output = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        $exitCode = $child.ExitCode; $child.Dispose()
        $reportPath = Join-Path $runRoot ($suite.name + '-result.json')
        $parsed = $null; $jsonValid = $false
        try {
            if ([Text.Encoding]::UTF8.GetByteCount($output) -gt 65536) { throw 'suite-output-too-large' }
            $parsed = $output | ConvertFrom-Json -AsHashtable -ErrorAction Stop
            $jsonValid = ($parsed -is [Collections.IDictionary])
        } catch { $jsonValid = $false }
        if ($jsonValid) { [IO.File]::WriteAllText($reportPath,($parsed | ConvertTo-Json -Depth 20),$utf8) }
        $contractPassed = $false
        $passedChecks = 0; $skippedChecks = 0
        if ($jsonValid) {
            switch ($suite.name) {
                'projection' {
                    $passedChecks = @($parsed.checks | Where-Object status -EQ 'pass').Count
                    $contractPassed = $parsed.status -eq 'pass' -and $parsed.sourcesUnchanged -eq $true -and
                        $passedChecks -gt 0 -and $passedChecks -eq @($parsed.checks).Count
                }
                'powershell' {
                    $passedChecks = @($parsed.results | Where-Object status -EQ 'passed').Count
                    $contractPassed = $parsed.status -eq 'passed' -and $parsed.failures -eq 0 -and
                        $passedChecks -gt 0 -and $passedChecks -eq $parsed.cases
                }
                'nvidia' {
                    $passedChecks = @($parsed.cases | Where-Object passed -EQ $true).Count
                    $contractPassed = $parsed.passed -eq $true -and $passedChecks -gt 0 -and $passedChecks -eq @($parsed.cases).Count
                }
                'browser' {
                    $passedChecks = if ($parsed.status -eq 'passed') { $parsed.cases } else { 0 }
                    $contractPassed = $parsed.status -eq 'passed' -and $parsed.cases -gt 0 -and
                        $parsed.failures -eq 0 -and $parsed.errors -eq 0 -and $parsed.browserTouched -eq $false
                }
                'recycle' {
                    $passedChecks = @($parsed.results | Where-Object status -EQ 'passed').Count
                    $skippedChecks = @($parsed.results | Where-Object status -EQ 'skipped').Count
                    $live = @($parsed.results | Where-Object name -Like 'live recycle*')
                    $expectedStatus = if ($SkipLiveSnapshot) { 'passed-with-skips' } else { 'passed' }
                    $livePassed = $live.Count -eq 1 -and $(
                        if ($SkipLiveSnapshot) { $live[0].status -eq 'skipped' -and $live[0].reason -eq 'SkipLiveRecycle' -and $skippedChecks -eq 1 }
                        else { $live[0].status -eq 'passed' -and $skippedChecks -eq 0 }
                    )
                    $contractPassed = $parsed.status -eq $expectedStatus -and $parsed.failures -eq 0 -and $livePassed -and
                        $passedChecks -gt 0 -and $passedChecks + $skippedChecks -eq $parsed.cases
                }
                'explorer' {
                    $passedChecks = @($parsed.Results | Where-Object Status -EQ 'passed').Count
                    $skippedChecks = @($parsed.Results | Where-Object Status -EQ 'skipped').Count
                    $liveSnapshot = @($parsed.Results | Where-Object Case -EQ 'RealReadOnlySnapshot')
                    $isolated = @($parsed.Results | Where-Object Case -NE 'RealReadOnlySnapshot')
                    $expectedStatus = if ($SkipLiveSnapshot) { 'passed-with-skips' } else { 'passed' }
                    $snapshotPassed = $liveSnapshot.Count -eq 1 -and $(
                        if ($SkipLiveSnapshot) { $liveSnapshot[0].Status -eq 'skipped' -and $liveSnapshot[0].Reason -eq 'SkipLiveSnapshot' -and $skippedChecks -eq 1 }
                        else { $liveSnapshot[0].Status -eq 'passed' -and $skippedChecks -eq 0 }
                    )
                    $contractPassed = $parsed.Status -eq $expectedStatus -and $parsed.RealExplorerStopped -eq $false -and
                        $snapshotPassed -and $isolated.Count -eq 11 -and @($isolated | Where-Object Status -NE 'passed').Count -eq 0 -and
                        $parsed.PassedChecks -eq $passedChecks -and $parsed.SkippedChecks -eq $skippedChecks -and @($parsed.Children).Count -gt 0 -and
                        @($parsed.Children | Where-Object { $_.ProcessState -ne 'exited' -or $_.ExitCode -ne 0 }).Count -eq 0
                }
            }
        }
        $passed = $exitCode -eq 0 -and $jsonValid -and $contractPassed -and [string]::IsNullOrWhiteSpace($stderr)
        $suites.Add([pscustomobject]@{
            name=$suite.name;status=$(if (-not $passed) { 'failed' } elseif ($skippedChecks -gt 0) { 'passed-with-skips' } else { 'passed' });exitCode=$exitCode
            passedChecks=$passedChecks;skippedChecks=$skippedChecks
            validJson=$jsonValid;contractPassed=$contractPassed;stderrBytes=[Text.Encoding]::UTF8.GetByteCount($stderr)
            evidence=$(if ($jsonValid) { $reportPath } else { $null })
        })
    }
}
$sourceStability = foreach ($item in $syntax) {
    $path = Join-Path $PSScriptRoot $item.file
    [pscustomobject]@{file=$item.file;unchanged=((Test-Path -LiteralPath $path -PathType Leaf) -and $item.sha256 -eq (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash)}
}
$passed = @($syntax | Where-Object status -NE 'passed').Count -eq 0 -and
    @($sourceStability | Where-Object unchanged -NE $true).Count -eq 0 -and
    $suites.Count -eq $suiteDefinitions.Count -and @($suites | Where-Object { $_.status -notin @('passed','passed-with-skips') }).Count -eq 0
$totalPassed = [int]($suites | Measure-Object passedChecks -Sum).Sum
$totalSkipped = [int]($suites | Measure-Object skippedChecks -Sum).Sum
$report = [pscustomobject]@{
    status=$(if (-not $passed) { 'failed' } elseif ($totalSkipped -gt 0) { 'passed-with-skips' } else { 'passed' })
    passedChecks=$totalPassed;skippedChecks=$totalSkipped
    observedAtUtc=[DateTime]::UtcNow.ToString('o');runtime=$PSVersionTable.PSVersion.ToString()
    syntax=@($syntax);suites=@($suites);sourceStability=@($sourceStability);evidenceDirectory=$runRoot
}
$report | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $runRoot 'result.json') -Encoding utf8
[pscustomobject]@{status=$report.status;syntaxChecks=$syntax.Count;passedChecks=$totalPassed;skippedChecks=$totalSkipped;suites=@($suites);evidenceDirectory=$runRoot} | ConvertTo-Json -Depth 6 -Compress
if (-not $passed) { exit 1 }
