$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repo = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repo 'scripts\Invoke-PowerShellParameterCaseLint.ps1'
$testRoot = Join-Path $repo 'reports\powershell-parameter-case-lint-test'
$utf8 = [System.Text.UTF8Encoding]::new($false)
# The lint prints UTF-8 and the repo path is Chinese; decode child stdout the same way.
[Console]::OutputEncoding = $utf8

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

$overwrites = Join-Path $testRoot 'overwrites.ps1'
$clean = Join-Path $testRoot 'clean.ps1'
$broken = Join-Path $testRoot 'broken.ps1'
try {
    Assert-True (Test-Path -LiteralPath $scriptPath -PathType Leaf) "Missing lint script: $scriptPath"
    New-Item -ItemType Directory -Force -Path $testRoot | Out-Null
    [System.IO.File]::WriteAllText($overwrites, @'
function Find-Record([string]$Root, [string]$Original) {
    foreach ($index in [IO.Directory]::EnumerateFiles($Root)) {
        $original = $null
        if ($index.EndsWith('.txt')) { $original = [IO.File]::ReadAllText($index) }
        if ($original -and $original.Equals($Original)) { return $index }
    }
}
function Get-Total {
    param([int[]]$Values, [int]$Value, [int]$Count, [string]$Label, $First, $Second)
    foreach ($value in $Values) { $count++ }
    [string]$label = 'total'
    $first, $second = $Values
    $count += 1
}
function Get-Outer {
    function Get-Inner([string]$Name) { $name = 'inner' }
}
class Counter {
    [int] Add([int]$Step) { $step = 2; return $Step }
}
'@, $utf8)
    [System.IO.File]::WriteAllText($clean, @'
function Resolve-Target([string]$Path, [string]$Original) {
    $Path = [IO.Path]::GetFullPath($Path)
    $recorded = $original
    Write-Output $path $recorded
}
function Get-Outer([string]$Name) {
    function Get-Inner { $name = 'a local of Get-Inner' }
    Get-Inner
    $Name
}
function Get-Nothing {
    param()
    $result = 1
    $result
}
'@, $utf8)
    [System.IO.File]::WriteAllText($broken, "function Get-Broken {`n", $utf8)

    # Every rebinding form is listed against the function or method that declares the parameter. Find-Record has
    # the shape that made managed recycle read back the wrong bin record before 5ac0f50.
    $result = Invoke-Lint @($overwrites, $clean)
    Assert-True ($result.exitCode -eq 1 -and $result.report.status -eq 'error') "Overwrites must exit 1 with status error, got $($result.exitCode)"
    $expected = @(
        '3 Find-Record assigns $original, which is the parameter $Original'
        '4 Find-Record assigns $original, which is the parameter $Original'
        '10 Get-Total assigns $value, which is the parameter $Value'
        '10 Get-Total assigns $count, which is the parameter $Count'
        '11 Get-Total assigns $label, which is the parameter $Label'
        '12 Get-Total assigns $first, which is the parameter $First'
        '12 Get-Total assigns $second, which is the parameter $Second'
        '13 Get-Total assigns $count, which is the parameter $Count'
        '16 Get-Inner assigns $name, which is the parameter $Name'
        '19 Add assigns $step, which is the parameter $Step'
    ) | ForEach-Object { '{0}:{1}' -f $overwrites, $_ }
    $actual = Get-Listing $result.report
    Assert-True ((($actual | Sort-Object) -join "`n") -ceq (($expected | Sort-Object) -join "`n")) ("Unexpected findings:`n" + ($actual -join "`n"))
    Assert-True ($result.report.files -eq 2 -and $result.report.errors -eq $expected.Count) "Counts: files $($result.report.files), errors $($result.report.errors)"

    # Same-spelling overwrites, reads through another spelling, a nested function's own locals and an empty
    # param() block are clean.
    $result = Invoke-Lint @($clean)
    Assert-True ($result.exitCode -eq 0 -and $result.report.status -eq 'ok' -and @($result.report.findings).Count -eq 0) ("Clean file must pass:`n" + ((Get-Listing $result.report) -join "`n"))

    # A file that does not parse fails instead of passing unchecked.
    $result = Invoke-Lint @($broken)
    $codes = @($result.report.findings | ForEach-Object { '{0}:{1}' -f $_.code, $_.path })
    Assert-True ($result.exitCode -eq 1 -and ($codes -join ',') -ceq "parse-error:$broken") "A parse error must be reported, got: $($codes -join ',')"

    # The repository's tracked PowerShell is clean.
    $result = Invoke-Lint
    Assert-True ($result.report.files -gt 0) 'The lint must check the tracked PowerShell files'
    Assert-True ($result.exitCode -eq 0) ("Tracked PowerShell overwrites parameters through another spelling:`n" + ((Get-Listing $result.report) -join "`n"))
} finally {
    foreach ($file in $overwrites, $clean, $broken) { if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file } }
    if (Test-Path -LiteralPath $testRoot) { [System.IO.Directory]::Delete($testRoot) }
}

[pscustomobject]@{
    ok = $true
    test = 'Test-PowerShellParameterCaseLint'
} | ConvertTo-Json -Compress
