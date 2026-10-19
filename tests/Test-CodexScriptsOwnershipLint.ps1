param(
    [switch]$KeepOutputs
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repo 'scripts\Invoke-CodexScriptsOwnershipLint.ps1'
$registryPath = Join-Path $repo 'managed\codex-scripts\ownership.json'
$testRoot = Join-Path $repo 'reports\codex-scripts-ownership-lint-test'
$utf8 = [System.Text.UTF8Encoding]::new($false)
# The lint prints UTF-8 and the repo path is Chinese; decode child stdout the same way.
[Console]::OutputEncoding = $utf8

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Assert-CanRemoveTestRoot([string]$Path) {
    $reports = [System.IO.Path]::GetFullPath((Join-Path $repo 'reports')).TrimEnd('\', '/')
    $full = [System.IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    Assert-True $full.StartsWith("$reports\", [System.StringComparison]::OrdinalIgnoreCase) "Test root must sit under reports: $Path"
    $current = $full
    while ($current.Length -gt $reports.Length) {
        if (Test-Path -LiteralPath $current) {
            $isReparse = ((Get-Item -LiteralPath $current -Force).Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0
            Assert-True (-not $isReparse) "Test root must not cross a reparse point: $current"
        }
        $current = [System.IO.Directory]::GetParent($current).FullName.TrimEnd('\', '/')
    }
}

function Write-Text([string]$Path, [string]$Text) {
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path) | Out-Null
    [System.IO.File]::WriteAllText($Path, $Text, $utf8)
}

function Write-Registry([string]$Path, [object[]]$Entries) {
    Write-Text $Path (([ordered]@{
                artifactType = 'env-governance.codex-scripts-ownership'
                schemaVersion = 1
                entries = @($Entries)
            }) | ConvertTo-Json -Depth 5)
}

function Invoke-Lint([string]$Root, [string]$Registry, [string]$Project) {
    # Out of process, so the exit code and the single-JSON stdout contract are what callers see.
    $stdout = & pwsh -NoProfile -NonInteractive -File $scriptPath -Root $Root -RegistryPath $Registry -ProjectRoot $Project 2>&1
    $exitCode = $LASTEXITCODE
    $lines = @($stdout | ForEach-Object { [string]$_ } | Where-Object { $_ -ne '' })
    [pscustomobject]@{ exitCode = $exitCode; lines = $lines }
}

function Get-Report($Result) {
    Assert-True ($Result.lines.Count -eq 1) "Lint must print exactly one JSON line, got: $($Result.lines -join ' | ')"
    $Result.lines[0] | ConvertFrom-Json
}

function Get-Codes($Report) {
    @($Report.findings | ForEach-Object { '{0}:{1}:{2}' -f $_.level, $_.code, $_.path } | Sort-Object)
}

function Get-TreeState([string]$Path) {
    # Enumeration returns timestamps cached in the parent directory's index, which NTFS refreshes once a child
    # is opened, so compare names and file hashes instead.
    @(Get-ChildItem -LiteralPath $Path -Recurse -Force | Sort-Object FullName | ForEach-Object {
            if ($_.PSIsContainer) { '{0}|d' -f $_.FullName }
            else { '{0}|{1}' -f $_.FullName, (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash }
        }) -join "`n"
}

$project = Join-Path $testRoot 'project'
$scripts = Join-Path $testRoot 'scripts'
$registry = Join-Path $testRoot 'ownership.json'
$junction = Join-Path $scripts 'linked'
$cleanEntries = @(
    [ordered]@{ path = 'tool.ps1'; owner = 'scripts/Deploy-Fixture.ps1'; source = 'src/tool.ps1' },
    [ordered]@{ path = 'lib/helper.ps1'; owner = 'scripts/Deploy-Fixture.ps1'; source = 'src/lib/helper.ps1' },
    [ordered]@{ path = 'native.cmd'; owner = 'D:/fixture/docs/native.md' },
    [ordered]@{ path = 'cache/'; owner = 'generated cache' }
)
try {
    Assert-True (Test-Path -LiteralPath $scriptPath -PathType Leaf) "Missing lint script: $scriptPath"
    Assert-CanRemoveTestRoot $testRoot
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }

    Write-Text (Join-Path $project 'scripts\Deploy-Fixture.ps1') "`$sourceFiles = @('tool.ps1', 'lib/helper.ps1')"
    Write-Text (Join-Path $project 'src\tool.ps1') 'tool'
    Write-Text (Join-Path $project 'src\lib\helper.ps1') 'helper'
    Write-Text (Join-Path $scripts 'tool.ps1') 'tool'
    Write-Text (Join-Path $scripts 'lib\helper.ps1') 'helper'
    Write-Text (Join-Path $scripts 'native.cmd') 'native'
    Write-Text (Join-Path $scripts 'cache\nested\a.pyc') 'cache'
    Write-Registry $registry $cleanEntries

    # 1. Every file covered, sources equal, owners name their files: ok, exit 0.
    $result = Invoke-Lint $scripts $registry $project
    $report = Get-Report $result
    Assert-True ($result.exitCode -eq 0 -and $report.status -eq 'ok' -and $report.files -eq 4 -and $report.entries -eq 4) (
        "A fully registered root must pass: exit $($result.exitCode) $($result.lines -join ' ')")

    # 2. Strays at the top level and inside a directory that only has file entries are unowned errors; a directory
    #    entry covers its whole subtree; a junction is an error and is not followed.
    Write-Text (Join-Path $scripts 'stray.cjs') 'stray'
    Write-Text (Join-Path $scripts 'lib\stray.cjs') 'stray'
    Write-Text (Join-Path $scripts 'cache\b.pyc') 'cache'
    New-Item -ItemType Junction -Path $junction -Target (Join-Path $project 'src') | Out-Null
    $before = Get-TreeState $testRoot
    $result = Invoke-Lint $scripts $registry $project
    $report = Get-Report $result
    $expected = @('error:reparse-point:linked', 'error:unowned:lib/stray.cjs', 'error:unowned:stray.cjs')
    Assert-True ($result.exitCode -eq 1 -and ((Get-Codes $report) -join ',') -eq ($expected -join ',')) (
        "Strays and junctions must be errors: exit $($result.exitCode) $((Get-Codes $report) -join ',')")
    Assert-True ((Get-TreeState $testRoot) -eq $before) 'The lint must not modify the scripts root or the project'
    (Get-Item -LiteralPath $junction -Force).Delete()
    Remove-Item -LiteralPath (Join-Path $scripts 'stray.cjs'), (Join-Path $scripts 'lib\stray.cjs')

    # 3. Warnings alone keep exit 0: a deployed copy that differs from its source, and an entry absent on this host.
    Write-Text (Join-Path $scripts 'tool.ps1') 'tool, edited in place'
    Write-Registry $registry (@($cleanEntries) + @([ordered]@{ path = 'gone.ps1'; owner = 'D:/fixture/docs/gone.md' }))
    $result = Invoke-Lint $scripts $registry $project
    $report = Get-Report $result
    $expected = @('warning:missing:gone.ps1', 'warning:source-drift:tool.ps1')
    Assert-True ($result.exitCode -eq 0 -and $report.status -eq 'warning' -and ((Get-Codes $report) -join ',') -eq ($expected -join ',')) (
        "Drift and absence must be warnings: exit $($result.exitCode) $((Get-Codes $report) -join ',')")
    Write-Text (Join-Path $scripts 'tool.ps1') 'tool'

    # 4. A source that is not in the repository, a deploy owner that never names the file and an absent deploy owner
    #    are errors.
    Write-Text (Join-Path $scripts 'orphaned.ps1') 'orphaned'
    Write-Text (Join-Path $scripts 'unnamed.ps1') 'unnamed'
    Write-Text (Join-Path $scripts 'ghost.ps1') 'ghost'
    Write-Registry $registry (@($cleanEntries) + @(
            [ordered]@{ path = 'orphaned.ps1'; owner = 'D:/fixture/docs/orphaned.md'; source = 'src/orphaned.ps1' },
            [ordered]@{ path = 'unnamed.ps1'; owner = 'scripts/Deploy-Fixture.ps1' },
            [ordered]@{ path = 'ghost.ps1'; owner = 'scripts/Deploy-Absent.ps1' }
        ))
    $result = Invoke-Lint $scripts $registry $project
    $report = Get-Report $result
    $expected = @('error:owner-mismatch:ghost.ps1', 'error:owner-mismatch:unnamed.ps1', 'error:source-missing:orphaned.ps1')
    Assert-True ($result.exitCode -eq 1 -and ((Get-Codes $report) -join ',') -eq ($expected -join ',')) (
        "Broken sources and owners must be errors: exit $($result.exitCode) $((Get-Codes $report) -join ',')")
    Remove-Item -LiteralPath (Join-Path $scripts 'orphaned.ps1'), (Join-Path $scripts 'unnamed.ps1'), (Join-Path $scripts 'ghost.ps1')

    # 5. A missing root is an error, not a silent pass.
    $result = Invoke-Lint (Join-Path $testRoot 'absent') $registry $project
    $report = Get-Report $result
    Assert-True ($result.exitCode -eq 1 -and ((Get-Codes $report) -join ',') -eq 'error:root-missing:.') 'A missing root must be an error'

    # 6. An invalid registry stops the lint with a non-zero exit before any report.
    $invalidCases = @(
        @{ label = 'duplicate path'; entries = @(@{ path = 'tool.ps1'; owner = 'a' }, @{ path = 'TOOL.ps1'; owner = 'b' }); text = 'listed twice' },
        @{ label = 'parent segment'; entries = @(@{ path = '../tool.ps1'; owner = 'a' }); text = 'relative with forward slashes' },
        @{ label = 'directory with source'; entries = @(@{ path = 'cache/'; owner = 'a'; source = 'src/tool.ps1' }); text = 'cannot name a source' },
        @{ label = 'entry under a directory entry'; entries = @(@{ path = 'lib/'; owner = 'a' }, @{ path = 'lib/helper.ps1'; owner = 'b' }); text = 'already covered' },
        @{ label = 'missing owner'; entries = @(@{ path = 'tool.ps1' }); text = 'needs a path and an owner' }
    )
    foreach ($case in $invalidCases) {
        Write-Registry $registry $case.entries
        $result = Invoke-Lint $scripts $registry $project
        Assert-True ($result.exitCode -ne 0 -and ($result.lines -join "`n").Contains($case.text)) (
            "Invalid registry ($($case.label)) must stop the lint: exit $($result.exitCode) $($result.lines -join ' ')")
    }

    # 7. The repository registry is consistent on its own: on a root rebuilt from it (sources copied, other entries
    #    as placeholders) every source exists and every deploy-script owner names its files.
    $rebuilt = Join-Path $testRoot 'rebuilt'
    foreach ($entry in @((Get-Content -Raw -LiteralPath $registryPath | ConvertFrom-Json).entries)) {
        $path = [string]$entry.path
        $target = Join-Path $rebuilt $path.TrimEnd('/').Replace('/', '\')
        if ($path.EndsWith('/')) {
            Write-Text (Join-Path $target 'placeholder') 'placeholder'
        } elseif ($entry.PSObject.Properties.Name -contains 'source') {
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
            Copy-Item -LiteralPath (Join-Path $repo ([string]$entry.source).Replace('/', '\')) -Destination $target
        } else {
            Write-Text $target 'placeholder'
        }
    }
    $result = Invoke-Lint $rebuilt $registryPath $repo
    $report = Get-Report $result
    Assert-True ($result.exitCode -eq 0 -and $report.status -eq 'ok') (
        "The repository registry must be self-consistent: exit $($result.exitCode) $((Get-Codes $report) -join ',')")
} finally {
    if (Test-Path -LiteralPath $junction) {
        $item = Get-Item -LiteralPath $junction -Force
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { $item.Delete() }
    }
    if (-not $KeepOutputs -and (Test-Path -LiteralPath $testRoot)) {
        Assert-CanRemoveTestRoot $testRoot
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}

[pscustomobject]@{
    ok = $true
    test = 'Test-CodexScriptsOwnershipLint'
} | ConvertTo-Json -Compress
