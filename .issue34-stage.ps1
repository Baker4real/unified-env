$ErrorActionPreference = 'Stop'
$repo = 'D:\Codex\projects\统一环境'
$relativePath = 'scripts/lib/CodexSafeTreeDelete.ps1'
$patchPath = Join-Path $repo '.issue34-stage.patch'

$diffText = (& git -C $repo diff --no-ext-diff --unified=0 --no-color HEAD -- $relativePath | Out-String)
if ($LASTEXITCODE -ne 0) { throw 'git diff HEAD failed' }
$diffText = $diffText -replace "`r", ''
$diffLines = $diffText -split "`n"
$firstHunk = [Array]::IndexOf($diffLines, ($diffLines | Where-Object { $_ -like '@@*' } | Select-Object -First 1))
if ($firstHunk -lt 4) { throw 'no diff hunks found' }
$prefix = @($diffLines[0..($firstHunk - 1)])
$wantedOldStarts = [Collections.Generic.HashSet[int]]::new()
foreach ($oldStartToKeep in @(1564, 1602, 1802, 1840, 2068, 3342, 3839, 4140)) {
    [void]$wantedOldStarts.Add($oldStartToKeep)
}
$blocks = [Collections.Generic.List[object]]::new()
$current = $null
foreach ($line in $diffLines[$firstHunk..($diffLines.Count - 1)]) {
    if ($line -like '@@*') {
        if ($null -ne $current -and $current.selected) { $blocks.Add($current) }
        $match = [regex]::Match($line, '^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@(.*)$')
        if (-not $match.Success) { throw "unexpected hunk header: $line" }
        $oldStart = [int]$match.Groups[1].Value
        $oldCount = if ($match.Groups[2].Success) { [int]$match.Groups[2].Value } else { 1 }
        $newStart = [int]$match.Groups[3].Value
        $newCount = if ($match.Groups[4].Success) { [int]$match.Groups[4].Value } else { 1 }
        $current = [pscustomobject]@{
            oldStart = $oldStart
            oldCount = $oldCount
            newStart = $newStart
            newCount = $newCount
            suffix = $match.Groups[5].Value
            lines = [Collections.Generic.List[string]]::new()
            selected = $wantedOldStarts.Contains($oldStart)
        }
        continue
    }
    if ($null -ne $current) { $current.lines.Add($line) }
}
if ($null -ne $current -and $current.selected) { $blocks.Add($current) }

$sortedBlocks = @($blocks | Sort-Object oldStart)

$output = [Collections.Generic.List[string]]::new()
foreach ($line in $prefix) { $output.Add($line) }
$cumulativeDelta = 0
foreach ($block in $sortedBlocks) {
    $added = @($block.lines | Where-Object { $_.StartsWith('+') }).Count
    $removed = @($block.lines | Where-Object { $_.StartsWith('-') }).Count
    $adjustedNewStart = $block.oldStart + $cumulativeDelta
    $adjustedNewCount = $block.oldCount + $added - $removed
    $suffix = $block.suffix
    $output.Add(('@@ -{0},{1} +{2},{3} @@{4}' -f $block.oldStart, $block.oldCount, $adjustedNewStart, $adjustedNewCount, $suffix))
    foreach ($line in $block.lines) { $output.Add($line) }
    $cumulativeDelta += ($added - $removed)
}
[IO.File]::WriteAllText($patchPath, (($output -join "`n") + "`n"), [Text.UTF8Encoding]::new($false))
& git -C $repo apply --cached --whitespace=nowarn $patchPath
if ($LASTEXITCODE -ne 0) { throw 'git apply --cached failed' }
