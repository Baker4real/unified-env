Set-StrictMode -Version Latest

# #56 §7.2（G1）/§9：source closure 计算。闭包 = 固定 closurePaths + runner 可发现的全部
# 测试文件；每项 {repoRelativePath,length,sha256}，ordinal path 排序后折叠 closureSha256。
# 只对闭包本身记账，不因无关脏文件阻塞；历史快照不作激活凭证。

function Get-CodexSafeTreeDeleteClosureFixedPaths {
    return @(
        'modules/manifest.json',
        'scripts/Validate-ModuleBoundaries.cjs',
        'tests/Test-ModuleBoundaries.cjs',
        'scripts/Run-PowerShellTests.cjs',
        'scripts/Invoke-CodexSafeTreeDelete.ps1',
        'scripts/invoke-codex-safe-tree-delete-host.ps1',
        'scripts/invoke-codex-safe-tree-delete.cmd',
        'scripts/lib/CodexHostSafety.ps1',
        'scripts/lib/CodexSafeTreeDelete.ps1',
        'scripts/lib/CodexHostSafetyNativeLoader.ps1',
        'scripts/lib/CodexHookHandleBoundIO.cs',
        'scripts/lib/CodexSafeTreeDeleteFileIdentity.cs',
        'scripts/lib/CodexSafeTreeDeleteHashCache.cs',
        'scripts/lib/CodexSafeTreeDeleteApplySnapshot.cs',
        'scripts/lib/CodexSafeTreeDeleteHostSafetyPurgeAdapter.cs',
        'scripts/lib/CodexSafeTreeDeletePlanSnapshot.cs',
        'scripts/lib/CodexSafeTreeDeleteThreadJournal.cs',
        'scripts/lib/CodexSafeTreeDeleteParallelPurge.cs',
        'scripts/lib/CodexSafeTreeDeleteClosure.ps1',
        'scripts/lib/CodexSafeTreeDeleteStatusScan.cs',
        'managed/safe-tree-delete/policy.json',
        'scripts/Deploy-CodexSafeTreeDelete.ps1',
        'scripts/invoke-codex-safe-tree-delete-gate-shim.ps1'
    )
}

function Get-CodexSafeTreeDeleteClosure {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [AllowNull()][string[]]$ExtraPaths = @()
    )

    $rows = [Collections.Generic.List[object]]::new()
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $paths = [Collections.Generic.List[string]]::new()
    foreach ($fixed in (Get-CodexSafeTreeDeleteClosureFixedPaths)) {
        $paths.Add($fixed)
    }
    if ($null -ne $ExtraPaths) {
        foreach ($extra in $ExtraPaths) {
            if (-not [string]::IsNullOrWhiteSpace($extra)) { $paths.Add($extra) }
        }
    }
    # runner 可发现的测试文件（fixture/host-live 共享 tests/ 目录扫描）。
    $testsRoot = Join-Path $ProjectRoot 'tests'
    foreach ($pattern in @('Test-*.ps1', 'Test-*.cjs', 'Invoke-*.ps1')) {
        foreach ($found in [IO.Directory]::GetFiles($testsRoot, $pattern)) {
            $paths.Add(('tests/' + [IO.Path]::GetFileName($found)))
        }
    }

    foreach ($relative in ($paths | Sort-Object -Unique)) {
        $normalized = [string]$relative -replace '\\', '/'
        if (-not $seen.Add($normalized)) { continue }
        $full = Join-Path $ProjectRoot ($normalized -replace '/', '\')
        if (-not [IO.File]::Exists($full)) { continue }
        $bytes = [IO.File]::ReadAllBytes($full)
        $rows.Add([pscustomobject][ordered]@{
            repoRelativePath = $normalized
            length = [long]$bytes.Length
            sha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
        })
    }
    $sorted = @($rows | Sort-Object { [string]$_.repoRelativePath })
    $foldInput = [Text.StringBuilder]::new()
    foreach ($row in $sorted) {
        [void]$foldInput.AppendFormat(
            '{0}|{1}|{2}' + "`n",
            [string]$row.repoRelativePath,
            [long]$row.length,
            [string]$row.sha256)
    }
    $closureSha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData(
        [Text.UTF8Encoding]::new($false).GetBytes($foldInput.ToString()))).ToLowerInvariant()
    return [pscustomobject][ordered]@{
        closureSha256 = $closureSha256
        files = $sorted
    }
}
