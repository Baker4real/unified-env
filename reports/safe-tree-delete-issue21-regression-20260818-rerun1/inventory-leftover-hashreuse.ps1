Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$issue32 = 'D:\Codex\projects\统一环境\reports\safe-tree-delete-issue32-20260817'
$txs = @(Get-ChildItem -LiteralPath $issue32 -Recurse -Filter 'transaction.json' -File)
foreach ($file in $txs) {
    $tx = Get-Content -Raw -LiteralPath $file.FullName | ConvertFrom-Json -Depth 16 -DateKind String
    $sha = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    Write-Output ('TX status={0} sha={1} path={2}' -f [string]$tx.status, $sha, $file.FullName)
    Write-Output ('  target={0}' -f [string]$tx.targetPath)
    Write-Output ('  quarantine={0}' -f [string]$tx.quarantinePath)
    Write-Output ('  quarantineExists={0}' -f [IO.Directory]::Exists([string]$tx.quarantinePath))
}
Write-Output '--- dirs ---'
foreach ($name in @(
        'fixtures-7f708262197f4e698d6179aa248d7fae',
        'scale-1000',
        'scale-10000')) {
    $path = Join-Path $issue32 $name
    Write-Output ('DIR exists={0} path={1}' -f [IO.Directory]::Exists($path), $path)
}
