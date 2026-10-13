param(
    [switch]$KeepOutputs
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repo 'scripts\Invoke-StagingManifestLint.ps1'
$testRoot = Join-Path $repo 'reports\staging-manifest-lint-test'
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

function Write-Manifest([string]$Directory, [hashtable]$Override = @{}, [string[]]$Drop = @()) {
    $manifest = [ordered]@{
        createdBy   = [ordered]@{ host = 'claude-code'; session = 'fixture-session' }
        createdAt   = '2026-10-13T12:00:00+08:00'
        purpose     = 'fixture'
        sources     = @([ordered]@{ path = 'payload'; from = 'D:/fixture/payload' })
        sensitive   = [ordered]@{ present = $false; items = @() }
        expires     = '2099-01-01'
        disposition = 'report to the user'
    }
    foreach ($key in $Override.Keys) { $manifest[$key] = $Override[$key] }
    foreach ($key in $Drop) { $manifest.Remove($key) }
    New-Item -ItemType Directory -Force -Path (Join-Path $Directory 'payload') | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $Directory 'manifest.json'), ($manifest | ConvertTo-Json -Depth 6), $utf8)
}

function Invoke-Lint([string[]]$Roots) {
    # Out of process, so the exit code and the single-JSON stdout contract are what callers see.
    $rootList = ($Roots | ForEach-Object { "'" + ($_ -replace "'", "''") + "'" }) -join ','
    $command = "& '{0}' -Root @({1}) -AsOf ([datetime]'2026-10-13T12:00:00')" -f ($scriptPath -replace "'", "''"), $rootList
    $stdout = & pwsh -NoProfile -NonInteractive -Command $command
    $exitCode = $LASTEXITCODE
    $lines = @($stdout | Where-Object { $_ -ne '' })
    Assert-True ($lines.Count -eq 1) "Lint must print exactly one JSON line, got $($lines.Count)"
    [pscustomobject]@{ exitCode = $exitCode; report = ($lines[0] | ConvertFrom-Json) }
}

function Get-Code($Report, [string]$Name) {
    $entry = @($Report.findings | Where-Object name -eq $Name)
    Assert-True ($entry.Count -eq 1) "Missing finding for $Name"
    @($entry[0].issues | ForEach-Object { '{0}:{1}' -f $_.level, $_.code })
}

function Get-TreeState([string]$Path) {
    # Enumeration returns timestamps cached in the parent directory's index, which NTFS refreshes once a child
    # is opened, so compare names and file hashes instead.
    @(Get-ChildItem -LiteralPath $Path -Recurse -Force | Sort-Object FullName | ForEach-Object {
        if ($_.PSIsContainer) { '{0}|d' -f $_.FullName }
        else { '{0}|{1}' -f $_.FullName, (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash }
    }) -join "`n"
}

$junction = Join-Path $testRoot 'mixed\linked'
try {
    Assert-True (Test-Path -LiteralPath $scriptPath -PathType Leaf) "Missing lint script: $scriptPath"
    Assert-CanRemoveTestRoot $testRoot
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }

    $clean = Join-Path $testRoot 'clean'
    $mixed = Join-Path $testRoot 'mixed'
    Write-Manifest (Join-Path $clean 'good')
    Write-Manifest (Join-Path $clean 'old') @{ expires = '2026-10-01' }
    Write-Manifest (Join-Path $mixed 'good')
    New-Item -ItemType Directory -Force -Path (Join-Path $mixed 'no-manifest') | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $mixed 'bad-json') | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $mixed 'bad-json\manifest.json'), '{', $utf8)
    Write-Manifest (Join-Path $mixed 'incomplete') @{
        sensitive = [ordered]@{ present = $true; items = @() }
        createdBy = [ordered]@{ host = 'claude-code' }
    } @('disposition')
    Write-Manifest (Join-Path $mixed 'unlisted')
    [System.IO.File]::WriteAllText((Join-Path $mixed 'unlisted\extra.txt'), 'x', $utf8)
    Write-Manifest (Join-Path $mixed 'secret') @{
        sensitive = [ordered]@{ present = $true; items = @([ordered]@{ path = 'payload/key.json'; type = 'credential file (not opened)' }) }
    }
    [System.IO.File]::WriteAllText((Join-Path $mixed 'loose.txt'), 'x', $utf8)
    New-Item -ItemType Junction -Path $junction -Target (Join-Path $mixed 'good') | Out-Null

    # Valid manifests pass; an expired one only warns and keeps exit 0.
    $result = Invoke-Lint @($clean)
    Assert-True ($result.exitCode -eq 0) "Warnings alone must exit 0, got $($result.exitCode)"
    Assert-True ($result.report.status -eq 'warning' -and $result.report.errors -eq 0 -and $result.report.warnings -eq 1) 'Clean root must report one warning'
    Assert-True (@(Get-Code $result.report 'good').Count -eq 0) 'A complete manifest must have no issues'
    Assert-True ((Get-Code $result.report 'old') -join ',' -eq 'warning:expired') 'A past expiry must warn'

    # Every broken shape is named, and the lint changes nothing on disk.
    $before = Get-TreeState $testRoot
    $result = Invoke-Lint @($mixed)
    Assert-True ($result.exitCode -eq 1) "Errors must exit 1, got $($result.exitCode)"
    Assert-True ($result.report.status -eq 'error') 'Mixed root must report status error'
    Assert-True (@(Get-Code $result.report 'good').Count -eq 0) 'The good entry must stay clean beside broken ones'
    Assert-True (@(Get-Code $result.report 'secret').Count -eq 0) 'A sensitive entry with named items is valid'
    Assert-True ((Get-Code $result.report 'no-manifest') -join ',' -eq 'error:missing-manifest') 'Missing manifest must be reported'
    Assert-True ((Get-Code $result.report 'bad-json') -join ',' -eq 'error:invalid-json') 'Unparseable manifest must be reported'
    $incomplete = Get-Code $result.report 'incomplete'
    Assert-True ($incomplete -contains 'error:missing-field' -and @($incomplete | Where-Object { $_ -eq 'error:invalid-field' }).Count -eq 2) "Incomplete manifest codes: $($incomplete -join ',')"
    Assert-True ((Get-Code $result.report 'unlisted') -join ',' -eq 'error:unlisted-item') 'An item missing from sources must be reported'
    Assert-True ((Get-Code $result.report 'loose.txt') -join ',' -eq 'error:loose-file') 'A loose file must be reported'
    Assert-True ((Get-Code $result.report 'linked') -join ',' -eq 'error:reparse-point') 'A junction entry must be reported'
    $after = Get-TreeState $testRoot
    $changed = @(Compare-Object ($before -split "`n") ($after -split "`n") | ForEach-Object { $_.SideIndicator + $_.InputObject })
    Assert-True ($changed.Count -eq 0) ("The lint must not modify the holding roots: " + ($changed -join '; '))

    # A missing root fails instead of passing silently.
    $result = Invoke-Lint @((Join-Path $testRoot 'absent'))
    Assert-True ($result.exitCode -eq 1 -and $result.report.findings[0].issues[0].code -eq 'root-missing') 'A missing root must be an error'
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
    test = 'Test-StagingManifestLint'
} | ConvertTo-Json -Compress
