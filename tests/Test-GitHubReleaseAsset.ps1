#requires -Version 7.4
$ErrorActionPreference = 'Stop'
$utf8 = [Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = $utf8
$repo = Split-Path -Parent $PSScriptRoot
$entry = Join-Path $repo 'managed/host-diagnostics/Get-GitHubReleaseAsset.ps1'
$evidence = 'D:/agents/run-evidence/github-release-asset-tests/' + [guid]::NewGuid().ToString('N')
$null = New-Item -ItemType Directory -Path $evidence -Force
$fakeGh = Join-Path $evidence 'Fake-Gh.ps1'
@'
$args | Set-Content -LiteralPath (Join-Path $PSScriptRoot 'gh-arguments.txt') -Encoding utf8
$payload = @{
    tag_name = 'v2.5.8'
    padding = 'x' * 50000
    assets = @(
        @{ name = 'other.zip'; size = 1; digest = 'sha256:other'; browser_download_url = 'https://example.com/other' },
        @{ name = 'Clash.Verge_2.5.8_x64-setup.exe'; size = 60230483; digest = 'sha256:821c0f5957f84c8f7d14532044840e8280d708af24a6a143db360b49bd1e7302'; browser_download_url = 'https://example.com/setup.exe' }
    )
} | ConvertTo-Json -Depth 5 -Compress
$payload
'@ | Set-Content -LiteralPath $fakeGh -Encoding utf8
$psi = [Diagnostics.ProcessStartInfo]::new((Join-Path $PSHOME 'pwsh.exe'))
$arguments = @('-NoProfile', '-NonInteractive', '-File', $entry, '-Repository', 'clash-verge-rev/clash-verge-rev', '-AssetName', 'Clash.Verge_2.5.8_x64-setup.exe', '-GhCommand', $fakeGh)
foreach ($argument in $arguments) { $psi.ArgumentList.Add($argument) }
$psi.UseShellExecute = $false
$psi.CreateNoWindow = $true
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
$psi.StandardOutputEncoding = $utf8
$psi.StandardErrorEncoding = $utf8
$process = [Diagnostics.Process]::Start($psi)
$stdout = $process.StandardOutput.ReadToEndAsync()
$stderr = $process.StandardError.ReadToEndAsync()
if (-not $process.WaitForExit(15000)) { $process.Kill($true); throw 'Release asset test timed out' }
if ($process.ExitCode -ne 0) { throw "Asset projection failed: $($stderr.GetAwaiter().GetResult())" }
$text = $stdout.GetAwaiter().GetResult()
if ($text.Length -gt 1200) { throw "Projection remained too large: $($text.Length)" }
$report = $text | ConvertFrom-Json
if ($report.tag -ne 'v2.5.8' -or $report.asset.size -ne 60230483 -or $report.asset.digest -ne 'sha256:821c0f5957f84c8f7d14532044840e8280d708af24a6a143db360b49bd1e7302') { throw 'Selected asset fields are incorrect' }
$ghArguments = Get-Content -LiteralPath (Join-Path $evidence 'gh-arguments.txt') -Raw -Encoding utf8
if ($ghArguments -notmatch '--jq' -or $ghArguments -notmatch 'select\(.name') { throw 'API-side asset projection was not requested' }

# 生产路径：不传 GhCommand，按 PATH 解析 gh。PATH 最前面放替身 gh.ps1 并先确认解析到它，免得真 gh 发请求。
$pathRoot = Join-Path $evidence 'path-gh'
$null = New-Item -ItemType Directory -Path $pathRoot -Force
$shim = Join-Path $pathRoot 'gh.ps1'
Copy-Item -LiteralPath $fakeGh -Destination $shim
$searchPath = $pathRoot + [IO.Path]::PathSeparator + $env:PATH
$previousPath = $env:PATH
$env:PATH = $searchPath
try { $resolved = Get-Command -Name gh | Select-Object -First 1 } finally { $env:PATH = $previousPath }
if ($resolved.Source -ne $shim) { throw "gh resolved to $($resolved.Source) instead of the fixture" }
$psi = [Diagnostics.ProcessStartInfo]::new((Join-Path $PSHOME 'pwsh.exe'))
foreach ($argument in @('-NoProfile', '-NonInteractive', '-File', $entry, '-Repository', 'clash-verge-rev/clash-verge-rev', '-AssetName', 'Clash.Verge_2.5.8_x64-setup.exe')) { $psi.ArgumentList.Add($argument) }
$psi.UseShellExecute = $false
$psi.CreateNoWindow = $true
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
$psi.StandardOutputEncoding = $utf8
$psi.StandardErrorEncoding = $utf8
$psi.Environment['PATH'] = $searchPath
$process = [Diagnostics.Process]::Start($psi)
$stdout = $process.StandardOutput.ReadToEndAsync()
$stderr = $process.StandardError.ReadToEndAsync()
if (-not $process.WaitForExit(15000)) { $process.Kill($true); throw 'PATH-resolved release asset test timed out' }
if ($process.ExitCode -ne 0) { throw "PATH-resolved gh failed: $($stderr.GetAwaiter().GetResult())" }
if (($stdout.GetAwaiter().GetResult() | ConvertFrom-Json).asset.size -ne 60230483) { throw 'PATH-resolved gh returned the wrong asset' }
if (-not (Test-Path -LiteralPath (Join-Path $pathRoot 'gh-arguments.txt'))) { throw 'The PATH fixture was not the gh that ran' }
[ordered]@{ status = 'passed'; evidence = $evidence; cases = 3 } | ConvertTo-Json -Compress
