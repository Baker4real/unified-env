[CmdletBinding()]
param([string]$FixtureRoot = 'D:/agents/run-evidence/powershell-array-unwrap-lint-fixtures')

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repo = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repo 'scripts\Invoke-PowerShellArrayUnwrapLint.ps1'
$utf8 = [System.Text.UTF8Encoding]::new($false)
# The lint prints UTF-8 and the repo path is Chinese; decode child stdout the same way.
[Console]::OutputEncoding = $utf8
# The fixture files are rewritten on every run and kept, so nothing here deletes a directory.
$FixtureRoot = [System.IO.Path]::GetFullPath($FixtureRoot)
[void][System.IO.Directory]::CreateDirectory($FixtureRoot)

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Invoke-Lint([string[]]$File) {
    # Out of process, so the exit code and the single-JSON stdout contract are what callers see.
    $command = "& '{0}'" -f ($scriptPath -replace "'", "''")
    if ($File) { $command += ' -Path @({0})' -f (($File | ForEach-Object { "'" + ($_ -replace "'", "''") + "'" }) -join ',') }
    $stdout = & pwsh -NoProfile -NonInteractive -Command $command
    $exitCode = $LASTEXITCODE
    $lines = @($stdout | Where-Object { $_ -ne '' })
    Assert-True ($lines.Count -eq 1) "Lint must print exactly one JSON line, got $($lines.Count)"
    [pscustomobject]@{ exitCode = $exitCode; report = ($lines[0] | ConvertFrom-Json) }
}

function Get-Listing($Report) {
    @($Report.findings | ForEach-Object { '{0}:{1} {2}' -f $_.path, $_.line, $_.detail })
}

$unwraps = Join-Path $FixtureRoot 'unwraps.ps1'
$clean = Join-Path $FixtureRoot 'clean.ps1'
$broken = Join-Path $FixtureRoot 'broken.ps1'
Assert-True (Test-Path -LiteralPath $scriptPath -PathType Leaf) "Missing lint script: $scriptPath"
[System.IO.File]::WriteAllText($unwraps, @'
param([string[]]$CommandForTest)
$command = $(if ($CommandForTest) { $CommandForTest } else { @('gh') })
$labels = $(if ($CommandForTest) { @() } else { 'a', 'b' })
$mode = $(switch ($CommandForTest.Count) { 0 { @('none') } default { 'some' } })
$nested = $(if ($CommandForTest) { if ($CommandForTest.Count -gt 1) { @($CommandForTest[1]) } })
$row = @{ items = $(try { @(Get-Item -LiteralPath $PSCommandPath) } catch { $null }) }
$all = $(foreach ($name in $CommandForTest) { @($name) })
$pair = $(if ($CommandForTest) { 'a', 'b' } else { 'c' })
'@, $utf8)
[System.IO.File]::WriteAllText($clean, @'
param([string[]]$CommandForTest)
$command = @(if ($CommandForTest) { $CommandForTest } else { 'gh' })
[string[]]$typed = $(if ($CommandForTest) { $CommandForTest } else { @('gh') })
$first = $(if ($CommandForTest) { [string]$CommandForTest[0] } else { $null })
$count = $(if (@($CommandForTest).Count -gt 0) { 1 } else { 0 })
$kept = $(if ($CommandForTest) { ,@($CommandForTest) } else { ,@() })
$bare = if ($CommandForTest) { @('a') } else { @() }
$typed += $(if ($CommandForTest) { @('x') })
$row = @{ first = $(if ($CommandForTest) { 'u' } else { $null }) }
exit $(if ($CommandForTest) { 1 } else { 0 })
'@, $utf8)
[System.IO.File]::WriteAllText($broken, "function Get-Broken {`n", $utf8)

# Each value is listed once, in line order. Line 2 has the shape that made Publish-GitHubIssueComment.ps1 call
# 'g' instead of 'gh' before 272fd4c.
$result = Invoke-Lint @($unwraps, $clean)
Assert-True ($result.exitCode -eq 1 -and $result.report.status -eq 'error') "Unwrapping values must exit 1 with status error, got $($result.exitCode)"
$expected = @(
    '2 $command = $(...) unwraps the array it outputs; use @(...)'
    '3 $labels = $(...) unwraps the array it outputs; use @(...)'
    '4 $mode = $(...) unwraps the array it outputs; use @(...)'
    '5 $nested = $(...) unwraps the array it outputs; use @(...)'
    '6 items = $(...) unwraps the array it outputs; use @(...)'
    '7 $all = $(...) unwraps the array it outputs; use @(...)'
    '8 $pair = $(...) unwraps the array it outputs; use @(...)'
) | ForEach-Object { '{0}:{1}' -f $unwraps, $_ }
$actual = Get-Listing $result.report
Assert-True (($actual -join "`n") -ceq ($expected -join "`n")) ("Unexpected findings:`n" + ($actual -join "`n"))
Assert-True ($result.report.files -eq 2 -and $result.report.errors -eq $expected.Count) "Counts: files $($result.report.files), errors $($result.report.errors)"
Assert-True (@($result.report.findings | Where-Object { $_.code -cne 'subexpression-array-unwrap' }).Count -eq 0) 'Every finding must carry the subexpression-array-unwrap code'

# @(...), an array-typed target, scalar output, @() inside a condition, ,@(...), the bare if form, +=, exit and a
# scalar hashtable value are clean.
$result = Invoke-Lint @($clean)
Assert-True ($result.exitCode -eq 0 -and $result.report.status -eq 'ok' -and @($result.report.findings).Count -eq 0) ("Clean file must pass:`n" + ((Get-Listing $result.report) -join "`n"))

# A file that does not parse fails instead of passing unchecked.
$result = Invoke-Lint @($broken)
$codes = @($result.report.findings | ForEach-Object { '{0}:{1}' -f $_.code, $_.path })
Assert-True ($result.exitCode -eq 1 -and ($codes -join ',') -ceq "parse-error:$broken") "A parse error must be reported, got: $($codes -join ',')"

# The repository's tracked PowerShell is clean.
$result = Invoke-Lint
Assert-True ($result.report.files -gt 0) 'The lint must check the tracked PowerShell files'
Assert-True ($result.exitCode -eq 0) ("Tracked PowerShell assigns `$(...) that unwraps an array:`n" + ((Get-Listing $result.report) -join "`n"))

[pscustomobject]@{
    ok = $true
    test = 'Test-PowerShellArrayUnwrapLint'
} | ConvertTo-Json -Compress
