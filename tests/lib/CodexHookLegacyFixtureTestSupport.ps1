Set-StrictMode -Version Latest

function Get-CodexHookRemovedLegacyCmdRelativePaths {
    [CmdletBinding()]
    param()

    return [string[]]@(
        'retired/codex-mobile-permission-guard.cmd',
        'hooks/codex-projectless-root-d.cmd',
        'hooks/codex-provider-stability-guard.cmd',
        'hooks/serena-activate-guarded.cmd',
        'hooks/serena-dashboard-guard.cmd',
        'hooks/codex-state-preflight.cmd',
        'hooks/codex-github-cli-guard.cmd',
        'hooks/serena-activation-reminder.cmd',
        'hooks/serena-cleanup-guarded.cmd',
        'hooks/serena-reminder-guarded.cmd'
    )
}

function Get-CodexHookActiveCmdRelativePaths {
    [CmdletBinding()]
    param()

    return [string[]]@()
}

function Get-CodexHookRemovedLegacyCmdSamples {
    [CmdletBinding()]
    param()

    return [ordered]@{
        'retired/codex-mobile-permission-guard.cmd' = (
            @(
                '@echo off'
                'set "PYTHON_EXE=D:\Codex\tools\python313-official\python.exe"'
                'if not exist "%PYTHON_EXE%" set "PYTHON_EXE=D:\hermes-data\.npm-global\python.exe"'
                'if exist "%PYTHON_EXE%" ('
                '  "%PYTHON_EXE%" "D:\Codex\.codex\hooks\codex-mobile-permission-guard.py" %*'
                ') else ('
                '  python "D:\Codex\.codex\hooks\codex-mobile-permission-guard.py" %*'
                ')'
                ''
            ) -join "`r`n"
        )
        'hooks/codex-projectless-root-d.cmd' = (
            @(
                '@echo off'
                '"D:\Codex\tools\python314-official\python.exe" "D:\Codex\.codex\hooks\codex-state-policy-guard.py" %*'
                'exit /b %ERRORLEVEL%'
                ''
            ) -join "`r`n"
        )
        'hooks/codex-provider-stability-guard.cmd' = (
            @(
                '@echo off'
                '"D:\Codex\tools\PowerShell\7.6.5\pwsh.exe" -NoProfile -ExecutionPolicy Bypass -File "D:\Codex\.codex\hooks\codex-provider-stability-guard.ps1" %*'
                'exit /b %ERRORLEVEL%'
                ''
            ) -join "`r`n"
        )
        'hooks/serena-activate-guarded.cmd' = (
            @(
                '@echo off'
                '"D:\Codex\tools\PowerShell\7.6.5\pwsh.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "D:\Codex\.codex\hooks\serena-activate-guarded.ps1" %*'
                'exit /b %ERRORLEVEL%'
                ''
            ) -join "`r`n"
        )
        'hooks/serena-dashboard-guard.cmd' = (
            @(
                '@echo off'
                '"D:\Codex\tools\PowerShell\7.6.5\pwsh.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "D:\Codex\.codex\hooks\serena-dashboard-guard.ps1" %*'
                'exit /b %ERRORLEVEL%'
                ''
            ) -join "`r`n"
        )
        'hooks/codex-state-preflight.cmd' = (
            @(
                '@echo off'
                '"D:\Codex\tools\python315-official\pythonw.exe" -I -S -B -X utf8 "%~dp0lib\hidden-console-launcher.py" "D:\Codex\tools\python315-official\python.exe" -I -S -B -X utf8 "%~dp0codex-state-preflight.py" %*'
                'exit /b %ERRORLEVEL%'
                ''
            ) -join "`r`n"
        )
        'hooks/codex-github-cli-guard.cmd' = (
            @(
                '@echo off'
                '"D:\Codex\tools\PowerShell\7.6.5\pwsh.exe" -NoProfile -ExecutionPolicy Bypass -File "D:\Codex\.codex\hooks\codex-github-cli-guard.ps1" %*'
                'exit /b %ERRORLEVEL%'
                ''
            ) -join "`r`n"
        )
        'hooks/serena-activation-reminder.cmd' = (
            @(
                '@echo off'
                'setlocal'
                'set "SERENA_HOME=D:\Codex\.serena"'
                '"D:\Codex\tools\python315-official\pythonw.exe" -I -S -B -X utf8 "%~dp0lib\hidden-console-launcher.py" "D:\Codex\tools\PowerShell\7.6.5\pwsh.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0serena-behavior-guard.ps1" -Mode Activation'
                'exit /b %ERRORLEVEL%'
                ''
            ) -join "`r`n"
        )
        'hooks/serena-cleanup-guarded.cmd' = (
            @(
                '@echo off'
                'setlocal'
                'set "SERENA_HOME=D:\Codex\.serena"'
                '"D:\Codex\tools\python315-official\pythonw.exe" -I -S -B -X utf8 "%~dp0lib\hidden-console-launcher.py" "D:\Codex\tools\PowerShell\7.6.5\pwsh.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0serena-behavior-guard.ps1" -Mode Cleanup'
                'exit /b %ERRORLEVEL%'
                ''
            ) -join "`r`n"
        )
        'hooks/serena-reminder-guarded.cmd' = (
            @(
                '@echo off'
                'setlocal'
                'set "SERENA_HOME=D:\Codex\.serena"'
                '"D:\Codex\tools\python315-official\pythonw.exe" -I -S -B -X utf8 "%~dp0lib\hidden-console-launcher.py" "D:\Codex\tools\PowerShell\7.6.5\pwsh.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0serena-behavior-guard.ps1" -Mode Reminder'
                'exit /b %ERRORLEVEL%'
                ''
            ) -join "`r`n"
        )
    }
}

function Get-CodexHookRemovedLegacyCmdBytes {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RelativePath
    )

    $normalized = $RelativePath.Replace('\', '/')
    $samples = Get-CodexHookRemovedLegacyCmdSamples
    if (-not $samples.Contains($normalized)) {
        throw "未知历史退役 .cmd 夹具路径：$RelativePath"
    }
    return [Text.UTF8Encoding]::new($false).GetBytes([string]$samples[$normalized])
}

function Get-CodexHookRemovedLegacyCmdTextByLiveName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$LiveName
    )

    $normalizedLeaf = [IO.Path]::GetFileName($LiveName)
    $samples = Get-CodexHookRemovedLegacyCmdSamples
    foreach ($relativePath in $samples.Keys) {
        if ([IO.Path]::GetFileName([string]$relativePath) -ieq $normalizedLeaf) {
            return [string]$samples[$relativePath]
        }
    }
    return $null
}

function Assert-CodexHookRetiredCmdSourcesRemoved {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ManagedRoot
    )

    foreach ($removedRelativePath in (Get-CodexHookRemovedLegacyCmdRelativePaths)) {
        $fullPath = Join-Path $ManagedRoot ($removedRelativePath.Replace('/', '\'))
        if (Test-Path -LiteralPath $fullPath) {
            throw "退役或已脱离批处理包装器的 .cmd 不得继续留在受管源码树：$removedRelativePath"
        }
    }
    $remainingCmdFiles = @(Get-ChildItem -LiteralPath $ManagedRoot -Recurse -File -Filter '*.cmd' -ErrorAction Stop)
    if ($remainingCmdFiles.Count -ne 0) {
        $remainingPaths = @($remainingCmdFiles | ForEach-Object { [IO.Path]::GetRelativePath($ManagedRoot, $_.FullName).Replace('\', '/') }) -join ','
        throw "受管源码树不得残留任何 .cmd 文件：$remainingPaths"
    }
    return $true
}

function Write-CodexHookLegacyCmdFixtureFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$RelativePath
    )

    $parent = Split-Path -Parent $Path
    if (-not [IO.Directory]::Exists($parent)) {
        [void][IO.Directory]::CreateDirectory($parent)
    }
    [byte[]]$bytes = Get-CodexHookRemovedLegacyCmdBytes -RelativePath $RelativePath
    [IO.File]::WriteAllBytes($Path, $bytes)
    return $bytes
}

function New-CodexHookIsolatedLegacyManagedSourceTree {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SourceManagedRoot,
        [Parameter(Mandatory)][string]$DestinationRoot,
        [Parameter(Mandatory)][object]$Manifest,
        [switch]$IncludeAllRemovedLegacyCmds
    )

    $resolvedSource = [IO.Path]::GetFullPath($SourceManagedRoot).TrimEnd('\', '/')
    $resolvedDestination = [IO.Path]::GetFullPath($DestinationRoot).TrimEnd('\', '/')
    if (
        $resolvedDestination.Equals($resolvedSource, [StringComparison]::OrdinalIgnoreCase) -or
        $resolvedDestination.StartsWith("$resolvedSource\", [StringComparison]::OrdinalIgnoreCase)
    ) {
        throw "隔离历史夹具目录不得位于受管源码树内：$resolvedDestination"
    }

    if ([IO.Directory]::Exists($resolvedDestination)) {
        Remove-Item -LiteralPath $resolvedDestination -Recurse -Force
    }
    [void][IO.Directory]::CreateDirectory($resolvedDestination)

    $samples = Get-CodexHookRemovedLegacyCmdSamples
    $generated = [Collections.Generic.List[string]]::new()
    $copied = [Collections.Generic.List[string]]::new()
    $written = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

    foreach ($file in @($Manifest.files)) {
        $normalized = ([string]$file.relativePath).Replace('\', '/')
        $destPath = Join-Path $resolvedDestination ($normalized.Replace('/', '\'))
        $destParent = Split-Path -Parent $destPath
        if (-not [IO.Directory]::Exists($destParent)) {
            [void][IO.Directory]::CreateDirectory($destParent)
        }
        if ($samples.Contains($normalized)) {
            [byte[]]$bytes = [Text.UTF8Encoding]::new($false).GetBytes([string]$samples[$normalized])
            [IO.File]::WriteAllBytes($destPath, $bytes)
            $generated.Add($normalized)
        } else {
            $srcPath = Join-Path $resolvedSource ($normalized.Replace('/', '\'))
            if (-not (Test-Path -LiteralPath $srcPath -PathType Leaf)) {
                throw "非退役受管源文件缺失：$srcPath"
            }
            [IO.File]::WriteAllBytes($destPath, [IO.File]::ReadAllBytes($srcPath))
            $copied.Add($normalized)
        }
        [void]$written.Add($normalized)
    }

    if ($IncludeAllRemovedLegacyCmds) {
        foreach ($relativePath in $samples.Keys) {
            if ($written.Contains([string]$relativePath)) { continue }
            $destPath = Join-Path $resolvedDestination (([string]$relativePath).Replace('/', '\'))
            [void](Write-CodexHookLegacyCmdFixtureFile -Path $destPath -RelativePath ([string]$relativePath))
            $generated.Add([string]$relativePath)
            [void]$written.Add([string]$relativePath)
        }
    }

    return [pscustomobject][ordered]@{
        root = $resolvedDestination
        generatedRelativePaths = [string[]]$generated.ToArray()
        copiedRelativePaths = [string[]]$copied.ToArray()
    }
}
