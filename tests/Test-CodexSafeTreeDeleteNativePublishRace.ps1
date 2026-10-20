[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# #87：native loader 并发首次发布同一 generation 与破损 generation 自愈的回归。
# 旧实现用固定临时文件名（CodexHostSafetyNative.dll.tmp / generation-manifest.json.tmp）发布，
# 两个进程同时首发同一 generation 时会互相覆盖/误删/拼出不匹配的 DLL+manifest，且不匹配的
# generation 无法自愈，之后每次加载都重编译再失败。本套件只在 fixture native 根
# （.scratch/safe-tree-delete-tests-* 下的 native-fixture-cache-*）验证，绝不触碰生产根：
# 1. 多进程 barrier 同步后同时首发同一 generation：全部成功，DLL 与 manifest 匹配；
# 2. 已存在 DLL 与 manifest 不匹配（dllSha256 对不上）的 generation：自愈后成功发布；
# 3. 已存在不完整 generation（只剩 DLL、manifest 缺失；旧实现的典型残留）：自愈后成功；
# 4. generation 目录混入非 loader 产物：失败闭锁并给出可操作错误，不替用户删文件。
# 每个场景都在独立 pwsh 子进程中经 fixture compile seam 执行。

$projectRoot = Split-Path -Parent $PSScriptRoot
$libDirectory = Join-Path $projectRoot 'scripts\lib'
$hostSafetyLibraryPath = Join-Path $libDirectory 'CodexHostSafety.ps1'
$loaderPath = Join-Path $libDirectory 'CodexHostSafetyNativeLoader.ps1'
$pwshPath = [Environment]::ProcessPath

. $hostSafetyLibraryPath
. (Join-Path $PSScriptRoot 'New-CodexSafeTreeDeleteTestScratchRoot.ps1')

function Assert-True {
    param([Parameter(Mandatory)][bool]$Condition, [Parameter(Mandatory)][string]$Message)
    if (-not $Condition) { throw $Message }
}

function Remove-TestTree {
    param([Parameter(Mandatory)][string]$Path)

    if (-not [IO.Directory]::Exists($Path)) { return }
    $snapshot = Get-CodexHookCapabilityDirectoryTreeSnapshot `
        -Path $Path `
        -CapabilityRoot (Split-Path -Parent $Path) `
        -AllowedExactPaths @($Path) `
        -Name 'safe-delete native publish race test cleanup snapshot'
    Remove-CodexHookCapabilityDirectoryTree `
        -Path $Path `
        -CapabilityRoot (Split-Path -Parent $Path) `
        -AllowedExactPaths @($Path) `
        -ExpectedRootIdentity @($snapshot.rootIdentity) `
        -ExpectedTreeManifest $snapshot `
        -Scope 'safe-delete native publish race test cleanup'
}

function Get-FileSha256Hex {
    param([Parameter(Mandatory)][string]$Path)
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData(
        [IO.File]::ReadAllBytes($Path))).ToLowerInvariant()
}

function Assert-GenerationIntact {
    # 发布产物形状与一致性：恰好 DLL+manifest 两个文件，无子目录；manifest 自指本
    # generation（variant 与 compileCompositeSha256=目录名），dllSha256 与实际 DLL 匹配。
    param(
        [Parameter(Mandatory)][string]$GenerationDirectory,
        [Parameter(Mandatory)][ValidateSet('base', 'default')][string]$Variant
    )

    $files = @([IO.Directory]::GetFiles($GenerationDirectory) | ForEach-Object { [IO.Path]::GetFileName($_) } | Sort-Object)
    Assert-True (($files -join ',') -ceq 'CodexHostSafetyNative.dll,generation-manifest.json') (
        "generation 必须恰好包含 DLL 与 manifest 两个文件，实际：$($files -join ',')（$GenerationDirectory）")
    Assert-True (@([IO.Directory]::GetDirectories($GenerationDirectory)).Count -eq 0) (
        "generation 不得包含子目录：$GenerationDirectory")
    $manifest = [IO.File]::ReadAllText(
        (Join-Path $GenerationDirectory 'generation-manifest.json'),
        [Text.UTF8Encoding]::new($false)) | ConvertFrom-Json -Depth 16
    $actualDllSha = Get-FileSha256Hex -Path (Join-Path $GenerationDirectory 'CodexHostSafetyNative.dll')
    Assert-True ([string]$manifest.dllSha256 -ceq $actualDllSha) (
        "发布的 DLL 与 manifest.dllSha256 不匹配：$GenerationDirectory")
    Assert-True ([string]$manifest.variant -ceq $Variant) (
        "manifest.variant 必须是 $Variant：$GenerationDirectory")
    Assert-True ([string]$manifest.compileCompositeSha256 -ceq [IO.Path]::GetFileName($GenerationDirectory)) (
        "manifest.compileCompositeSha256 必须与 generation 目录名一致：$GenerationDirectory")
}

function Assert-VariantRootClean {
    # 发布/自愈结束后 variant 根只允许留下唯一 generation 目录（无 staging/quarantine 残留）。
    param([Parameter(Mandatory)][string]$GenerationDirectory)

    $variantRoot = Split-Path -Parent $GenerationDirectory
    $siblings = @([IO.Directory]::GetDirectories($variantRoot))
    Assert-True ($siblings.Count -eq 1 -and [string]$siblings[0] -ceq $GenerationDirectory) (
        "variant 根必须只剩唯一 generation 目录（无 staging/quarantine 残留）：$variantRoot，实际：$($siblings -join ';')")
}

function Start-ProbeChild {
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [Parameter(Mandatory)][string[]]$Arguments
    )

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $pwshPath
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $utf8 = [Text.UTF8Encoding]::new($false)
    $startInfo.StandardOutputEncoding = $utf8
    $startInfo.StandardErrorEncoding = $utf8
    foreach ($argument in @('-NoProfile', '-NonInteractive', '-File', $ScriptPath) + $Arguments) {
        [void]$startInfo.ArgumentList.Add($argument)
    }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    Assert-True $process.Start() "探针子进程启动失败：$ScriptPath"
    return [pscustomobject]@{
        Process = $process
        StdoutTask = $process.StandardOutput.ReadToEndAsync()
        StderrTask = $process.StandardError.ReadToEndAsync()
    }
}

function Wait-ProbeChild {
    param(
        [Parameter(Mandatory)][object]$Child,
        [Parameter(Mandatory)][int]$TimeoutSeconds
    )

    $exited = $Child.Process.WaitForExit($TimeoutSeconds * 1000)
    if (-not $exited) {
        try { $Child.Process.Kill() } catch {}
        throw "探针子进程超时（${TimeoutSeconds}s，PID=$($Child.Process.Id)）"
    }
    $Child.Process.WaitForExit()
    return [pscustomobject]@{
        ExitCode = $Child.Process.ExitCode
        Stdout = $Child.StdoutTask.Result
        Stderr = $Child.StderrTask.Result
    }
}

function ConvertTo-ProbeResult {
    param(
        [Parameter(Mandatory)][object]$Outcome,
        [Parameter(Mandatory)][string]$Label
    )

    if ($Outcome.ExitCode -ne 0) {
        throw ("{0} 探针子进程失败（exit={1}）：`n{2}`n{3}" -f $Label, $Outcome.ExitCode, $Outcome.Stdout, $Outcome.Stderr)
    }
    $jsonLines = @($Outcome.Stdout -split "`r?`n" | Where-Object { $_.StartsWith('{') })
    Assert-True ($jsonLines.Count -ge 1) ("{0} 探针子进程没有输出 JSON：{1}" -f $Label, $Outcome.Stdout)
    return ($jsonLines[-1] | ConvertFrom-Json -Depth 16)
}

function Invoke-FixtureCompileProbe {
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [Parameter(Mandatory)][string]$TestParent,
        [Parameter(Mandatory)][string]$Nonce,
        [Parameter(Mandatory)][ValidateSet('base', 'default')][string]$Variant,
        [switch]$AllowFailure
    )

    $child = Start-ProbeChild -ScriptPath $ScriptPath -Arguments @(
        '-LoaderPath', $loaderPath,
        '-TestParent', $TestParent,
        '-Nonce', $Nonce,
        '-Variant', $Variant)
    $outcome = Wait-ProbeChild -Child $child -TimeoutSeconds 600
    if ($AllowFailure) { return $outcome }
    return (ConvertTo-ProbeResult -Outcome $outcome -Label 'fixture compile')
}

$fixtureCompileProbe = @'
param(
    [Parameter(Mandatory)][string]$LoaderPath,
    [Parameter(Mandatory)][string]$TestParent,
    [Parameter(Mandatory)][string]$Nonce,
    [Parameter(Mandatory)][ValidateSet('base', 'default')][string]$Variant,
    [string]$BarrierPath = ''
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# 子进程的 Console.Out/Error 默认按系统 ANSI 代码页写；父进程按 UTF-8 解码重定向流。
# 固定为 UTF-8，否则仓库路径含非 ASCII 字符时错误文本中的路径会被误读（评审 finding）。
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
. $LoaderPath
if (-not [string]::IsNullOrEmpty($BarrierPath)) {
    $deadline = [DateTime]::UtcNow.AddMinutes(5)
    while (-not [IO.File]::Exists($BarrierPath)) {
        if ([DateTime]::UtcNow -gt $deadline) { throw 'barrier wait timeout' }
        Start-Sleep -Milliseconds 25
    }
}
$capability = New-CodexHostSafetyNativeFixtureCapability -TestParent $TestParent -Nonce $Nonce
$generation = Invoke-CodexHostSafetyNativeFixtureCompile -Capability $capability -Variant $Variant
[pscustomobject][ordered]@{
    pid = $PID
    root = [string]$capability.Root
    generationDirectory = [string]$generation.GenerationDirectory
    compiledHere = [bool]$generation.CompiledHere
} | ConvertTo-Json -Compress -EscapeHandling EscapeNonAscii
'@

$scratchRoot = New-CodexSafeTreeDeleteTestScratchRoot -ProjectRoot $projectRoot -SuiteName 'nativepublishrace'
$raceChildren = @()
try {
    [void][IO.Directory]::CreateDirectory($scratchRoot)
    $probePath = Join-Path $scratchRoot 'probe-fixture-compile.ps1'
    [IO.File]::WriteAllText($probePath, $fixtureCompileProbe, [Text.UTF8Encoding]::new($true))

    # 1. 多进程 barrier 同步后同时首发同一 generation：全部成功且收敛到同一 generation，
    #    发布出的 DLL 与 manifest 匹配，variant 根无 staging/quarantine 残留。
    $raceNonce = [guid]::NewGuid().ToString('N').Substring(0, 16)
    $barrierPath = Join-Path $scratchRoot 'race-barrier.go'
    $childCount = 6
    for ($i = 0; $i -lt $childCount; $i++) {
        $raceChildren += Start-ProbeChild -ScriptPath $probePath -Arguments @(
            '-LoaderPath', $loaderPath,
            '-TestParent', $scratchRoot,
            '-Nonce', $raceNonce,
            '-Variant', 'default',
            '-BarrierPath', $barrierPath)
    }
    [IO.File]::WriteAllText($barrierPath, 'go', [Text.UTF8Encoding]::new($false))
    $raceResults = @()
    foreach ($child in $raceChildren) {
        $raceResults += (ConvertTo-ProbeResult -Outcome (Wait-ProbeChild -Child $child -TimeoutSeconds 600) -Label 'concurrent publish')
    }
    $distinctGenerations = @($raceResults | ForEach-Object { [string]$_.generationDirectory } | Sort-Object -Unique)
    Assert-True ($distinctGenerations.Count -eq 1) (
        "全部并发首发必须收敛到同一 generation，实际：$($distinctGenerations -join ';')")
    $raceGeneration = $distinctGenerations[0]
    Assert-True ($raceGeneration.StartsWith($scratchRoot, [StringComparison]::OrdinalIgnoreCase)) (
        "并发首发只允许写 fixture native 根：$raceGeneration")
    Assert-GenerationIntact -GenerationDirectory $raceGeneration -Variant 'default'
    Assert-VariantRootClean -GenerationDirectory $raceGeneration
    $compiledHereCount = @($raceResults | Where-Object { [bool]$_.compiledHere }).Count
    Assert-True ($compiledHereCount -ge 1) '并发首发至少一个进程实际编译'

    # 2. 已存在 DLL 与 manifest 不匹配（dllSha256 对不上）的 generation：自愈后成功发布，
    #    不得复用破损产物，也不得每次重编译再失败。
    $mismatchNonce = [guid]::NewGuid().ToString('N').Substring(0, 16)
    $mismatchFirst = Invoke-FixtureCompileProbe -ScriptPath $probePath -TestParent $scratchRoot -Nonce $mismatchNonce -Variant 'default'
    Assert-True ([bool]$mismatchFirst.compiledHere) '首次 fixture 编译必须实际编译'
    $mismatchGeneration = [string]$mismatchFirst.generationDirectory
    [IO.File]::WriteAllBytes((Join-Path $mismatchGeneration 'CodexHostSafetyNative.dll'), [byte[]](1..64))
    $mismatchHealed = Invoke-FixtureCompileProbe -ScriptPath $probePath -TestParent $scratchRoot -Nonce $mismatchNonce -Variant 'default'
    Assert-True ([bool]$mismatchHealed.compiledHere) '不匹配 generation 必须重新编译发布，不得复用破损产物'
    Assert-True ([string]$mismatchHealed.generationDirectory -ceq $mismatchGeneration) (
        '自愈必须发布回同一内容寻址 generation 路径')
    Assert-GenerationIntact -GenerationDirectory $mismatchGeneration -Variant 'default'
    Assert-VariantRootClean -GenerationDirectory $mismatchGeneration

    # 3. 已存在不完整 generation（只剩 DLL、manifest 缺失；旧实现并发事故的典型残留）：
    #    自愈后成功发布。
    $incompleteNonce = [guid]::NewGuid().ToString('N').Substring(0, 16)
    $incompleteFirst = Invoke-FixtureCompileProbe -ScriptPath $probePath -TestParent $scratchRoot -Nonce $incompleteNonce -Variant 'default'
    $incompleteGeneration = [string]$incompleteFirst.generationDirectory
    [IO.File]::Delete((Join-Path $incompleteGeneration 'generation-manifest.json'))
    $incompleteHealed = Invoke-FixtureCompileProbe -ScriptPath $probePath -TestParent $scratchRoot -Nonce $incompleteNonce -Variant 'default'
    Assert-True ([bool]$incompleteHealed.compiledHere) '不完整 generation 必须重新编译发布'
    Assert-True ([string]$incompleteHealed.generationDirectory -ceq $incompleteGeneration) (
        '自愈必须发布回同一内容寻址 generation 路径')
    Assert-GenerationIntact -GenerationDirectory $incompleteGeneration -Variant 'default'
    Assert-VariantRootClean -GenerationDirectory $incompleteGeneration

    # 4. generation 目录混入非 loader 产物：失败闭锁并给出可操作错误，不替用户删文件。
    $foreignNonce = [guid]::NewGuid().ToString('N').Substring(0, 16)
    $foreignFirst = Invoke-FixtureCompileProbe -ScriptPath $probePath -TestParent $scratchRoot -Nonce $foreignNonce -Variant 'default'
    $foreignGeneration = [string]$foreignFirst.generationDirectory
    $corruptedBytes = [byte[]](1..64)
    $foreignDllPath = Join-Path $foreignGeneration 'CodexHostSafetyNative.dll'
    [IO.File]::WriteAllBytes($foreignDllPath, $corruptedBytes)
    $foreignPath = Join-Path $foreignGeneration 'unexpected.txt'
    [IO.File]::WriteAllText($foreignPath, 'not a loader artifact', [Text.UTF8Encoding]::new($false))
    $refused = Invoke-FixtureCompileProbe -ScriptPath $probePath -TestParent $scratchRoot -Nonce $foreignNonce -Variant 'default' -AllowFailure
    Assert-True ($refused.ExitCode -ne 0) '混入非 loader 产物的破损 generation 必须失败闭锁，不得静默自愈'
    $refusedOutput = @($refused.Stdout, $refused.Stderr) -join "`n"
    Assert-True ($refusedOutput.Contains($foreignGeneration)) (
        "闭锁错误必须给出可操作的 generation 路径：$foreignGeneration；实际输出：$refusedOutput")
    Assert-True ($refusedOutput.Contains('unexpected.txt')) (
        "闭锁错误必须列出意外条目 unexpected.txt；实际输出：$refusedOutput")
    Assert-True ([IO.File]::Exists($foreignPath)) '失败闭锁不得删除非 loader 产物'
    $foreignCorruptedSha = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($corruptedBytes)).ToLowerInvariant()
    Assert-True ((Get-FileSha256Hex -Path $foreignDllPath) -ceq $foreignCorruptedSha) '失败闭锁不得改写破损 DLL'
    Assert-True ([IO.Directory]::Exists($foreignGeneration)) '失败闭锁必须保留现场供人工核查'

    [pscustomobject][ordered]@{
        ok = $true
        suite = 'CodexSafeTreeDeleteNativePublishRace'
        slices = 4
        concurrentPublishers = $childCount
        concurrentCompiledHere = $compiledHereCount
    }
} finally {
    foreach ($child in $raceChildren) {
        if (-not $child.Process.HasExited) {
            try { $child.Process.Kill() } catch {}
        }
        $child.Process.Dispose()
    }
    Remove-TestTree -Path $scratchRoot
}
