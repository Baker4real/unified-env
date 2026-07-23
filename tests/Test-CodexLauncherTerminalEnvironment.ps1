$ErrorActionPreference = 'Stop'

$launcherRoot = 'D:\Codex\tools\codex-launcher'
$projectPath = Join-Path $launcherRoot 'CodexLauncher.csproj'
$assemblyPath = Join-Path $launcherRoot 'bin\Release\net6.0\codex-launcher.dll'
$dotnet = (Get-Command dotnet -CommandType Application -ErrorAction Stop).Source

function Invoke-HiddenProcess {
    param([Parameter(Mandatory)][string]$FilePath,[Parameter()][string[]]$Arguments=@())

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $FilePath
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($argument in $Arguments) { [void]$startInfo.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    $started = $false
    try {
        if (-not $process.Start()) { throw "hidden process did not start: $FilePath" }
        $started = $true
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        $text = $stdout
        if (-not [string]::IsNullOrEmpty($stderr)) {
            if (-not [string]::IsNullOrEmpty($text) -and -not $text.EndsWith("`n")) { $text += [Environment]::NewLine }
            $text += $stderr
        }
        [pscustomobject]@{ExitCode=$process.ExitCode;StdOut=$stdout;StdErr=$stderr;Text=$text}
    } finally {
        if ($started -and -not $process.HasExited) { try { $process.Kill($true); $process.WaitForExit() } catch {} }
        $process.Dispose()
    }
}

$testSource = Get-Content -Raw -LiteralPath $PSCommandPath
$helperStart = $testSource.IndexOf('function Invoke-HiddenProcess')
$helperEnd = $testSource.IndexOf('$testSource =', $helperStart)
if ($helperStart -lt 0 -or $helperEnd -le $helperStart) { throw 'hidden dotnet helper is unavailable' }
$helperSource = $testSource.Substring($helperStart, $helperEnd - $helperStart)
if ($helperSource -cnotmatch 'UseShellExecute\s*=\s*\$false' -or $helperSource -cnotmatch 'CreateNoWindow\s*=\s*\$true') { throw 'dotnet build process must be hidden' }
$directDotnetPattern = '&\s*\$' + 'dotnet\b'
if ($testSource -cmatch $directDotnetPattern) { throw 'launcher test must not directly invoke dotnet' }

$buildRun = Invoke-HiddenProcess -FilePath $dotnet -Arguments @('build', $projectPath, '-c', 'Release', '--nologo')
if ($buildRun.ExitCode -ne 0) {
    throw "Codex launcher build failed with exit code $($buildRun.ExitCode): $($buildRun.Text)"
}
if (-not (Test-Path -LiteralPath $assemblyPath -PathType Leaf)) {
    throw "Codex launcher assembly was not produced: $assemblyPath"
}

$assembly = [Reflection.Assembly]::LoadFrom($assemblyPath)
$programType = $assembly.GetType('CodexLauncher.Program', $true)
$bindingFlags = [Reflection.BindingFlags]::NonPublic -bor [Reflection.BindingFlags]::Static
$method = $programType.GetMethod('ConfigureTerminalEnvironment', $bindingFlags)
if ($null -eq $method) {
    throw 'ConfigureTerminalEnvironment is missing'
}

function Assert-TermCase {
    param(
        [AllowNull()]
        [string] $InitialTerm,
        [bool] $Interactive,
        [AllowNull()]
        [string] $ExpectedTerm,
        [string] $Name
    )

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.UseShellExecute = $false
    if ($null -eq $InitialTerm) {
        [void] $startInfo.Environment.Remove('TERM')
    }
    else {
        $startInfo.Environment['TERM'] = $InitialTerm
    }

    [void] $method.Invoke($null, @($startInfo, $Interactive))
    $actual = if ($startInfo.Environment.ContainsKey('TERM')) {
        [string] $startInfo.Environment['TERM']
    }
    else {
        $null
    }
    if ($actual -cne $ExpectedTerm) {
        throw "$Name failed: expected TERM='$ExpectedTerm', actual TERM='$actual'"
    }
}

Assert-TermCase -InitialTerm 'dumb' -Interactive $true -ExpectedTerm 'xterm-256color' -Name 'interactive dumb'
Assert-TermCase -InitialTerm $null -Interactive $true -ExpectedTerm 'xterm-256color' -Name 'interactive missing'
Assert-TermCase -InitialTerm 'vt100' -Interactive $true -ExpectedTerm 'vt100' -Name 'interactive real term'
Assert-TermCase -InitialTerm 'dumb' -Interactive $false -ExpectedTerm 'dumb' -Name 'redirected dumb'
Assert-TermCase -InitialTerm $null -Interactive $false -ExpectedTerm $null -Name 'redirected missing'

[pscustomobject]@{
    ok = $true
    cases = 5
    assembly = $assemblyPath
}
