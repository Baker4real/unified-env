$ErrorActionPreference = 'Stop'

$launcherRoot = 'D:\Codex\tools\codex-launcher'
$projectPath = Join-Path $launcherRoot 'CodexLauncher.csproj'
$assemblyPath = Join-Path $launcherRoot 'bin\Release\net6.0\codex-launcher.dll'
$dotnet = (Get-Command dotnet -CommandType Application -ErrorAction Stop).Source

& $dotnet build $projectPath -c Release --nologo | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "Codex launcher build failed with exit code $LASTEXITCODE"
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
