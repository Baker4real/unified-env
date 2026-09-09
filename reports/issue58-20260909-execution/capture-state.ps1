param([Parameter(Mandatory)][string]$Label)
$ErrorActionPreference = 'Stop'
$repo = 'D:\agents\projects\统一环境'
$paths = @('scripts/lib/CodexSafeTreeDelete.ps1','scripts/lib/CodexSafeTreeDeleteStatusScan.cs','tests/Test-CodexSafeTreeDeleteStatus.ps1','scripts/Invoke-CodexSafeTreeDelete.ps1','managed/safe-tree-delete/policy.json')
$rows = foreach ($path in $paths) {
    $full = Join-Path $repo $path
    $item = Get-Item -LiteralPath $full
    if ($Label -eq 'before') {
        $backup = Join-Path $PSScriptRoot ('before-' + [IO.Path]::GetFileName($path) + '.bin')
        if (Test-Path -LiteralPath $backup) { throw "已有前态备份: $backup" }
        [IO.File]::Copy($full, $backup, $false)
    }
    @{path=$path;sha256=(Get-FileHash -LiteralPath $full).Hash.ToLowerInvariant();length=$item.Length;mtimeUtc=$item.LastWriteTimeUtc.ToString('o')}
}
$old = Join-Path $repo 'reports/issue58-20260908/live-rerun-20260909'
$oldRows = @(Get-ChildItem -LiteralPath $old -File | Sort-Object Name | ForEach-Object { @{name=$_.Name;sha256=(Get-FileHash -LiteralPath $_.FullName).Hash;length=$_.Length} })
$head = & git --no-optional-locks -C $repo rev-parse HEAD
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
$state = @{head=[string]$head;capturedAtUtc=[datetimeoffset]::UtcNow.ToString('o');files=@($rows);oldEvidenceFiles=$oldRows;shimSha256=(Get-FileHash -LiteralPath 'D:/Codex/.codex/scripts/invoke-safe-tree-delete.ps1').Hash;maintenancePresent=(Test-Path -LiteralPath 'D:/Codex/.codex/state/safe-tree-delete-deployment/maintenance.json')}
$output = Join-Path $PSScriptRoot "$Label-state.json"
if (Test-Path -LiteralPath $output) { throw "已有状态证据: $output" }
[IO.File]::WriteAllText($output, ($state | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
Write-Output "状态已保存: $Label; 旧证据文件=$($oldRows.Count)"
