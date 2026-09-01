Set-StrictMode -Version Latest

function New-CodexSafeTreeDeleteTestScratchRoot {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$SuiteName
    )

    if ([string]::IsNullOrWhiteSpace($SuiteName)) {
        throw 'SuiteName must not be empty'
    }

    $scratchBase = [IO.Path]::GetFullPath((Join-Path $ProjectRoot '.scratch')).TrimEnd('\')
    $runId = [guid]::NewGuid().ToString('N')
    $root = Join-Path $scratchBase ('safe-tree-delete-tests-{0}-{1}' -f $SuiteName, $runId)
    $full = [IO.Path]::GetFullPath($root)
    $prefix = $scratchBase + '\safe-tree-delete-tests-'
    if (-not $full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "scratch root must be under $prefix : $full"
    }
    if ([IO.Path]::GetPathRoot($full) -cne 'D:\') {
        throw "scratch root must be on D: $full"
    }
    return $full
}
