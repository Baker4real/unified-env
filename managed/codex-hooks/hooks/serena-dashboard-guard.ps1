$ErrorActionPreference = 'Stop'

$codexRoot = 'D:\Codex'
$codexConfigPath = Join-Path $codexRoot '.codex\config.toml'
$serenaConfigPath = Join-Path $codexRoot '.serena\serena_config.yml'
$pythonPath = Join-Path $codexRoot 'tools\python314-official\python.exe'
$configMutexName = 'Local\CodexConfigTomlGuard'
$configBackupRoot = Join-Path $codexRoot '.codex\backups_state\serena-dashboard-guard'
$tempRoot = Join-Path $codexRoot '.codex\tmp'

function Test-UnderCodexRoot {
    param([Parameter(Mandatory = $true)][string]$Path)

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $root = [System.IO.Path]::GetFullPath($codexRoot + '\')
    return $fullPath.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)
}

function Test-TomlSectionHeader {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Line,
        [Parameter(Mandatory = $true)][string]$Section
    )
    return $Line -match "^\s*\[$([regex]::Escape($Section))\]\s*(?:#.*)?$"
}

function Test-AnyTomlTableHeader {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Line)
    return $Line -match '^\s*\[\[?.+\]\]?\s*(?:#.*)?$'
}

function Get-TomlSectionRange {
    param(
        [Parameter(Mandatory = $true)]$Lines,
        [Parameter(Mandatory = $true)][string]$Section
    )

    $matches = @()
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if (Test-TomlSectionHeader -Line $Lines[$i] -Section $Section) {
            $matches += $i
        }
    }

    if ($matches.Count -gt 1) {
        throw "Duplicate TOML section [$Section] found."
    }
    if ($matches.Count -eq 0) {
        return [ordered]@{ found = $false; start = -1; end = $Lines.Count }
    }

    $start = $matches[0]
    $end = $Lines.Count
    for ($i = $start + 1; $i -lt $Lines.Count; $i++) {
        if (Test-AnyTomlTableHeader -Line $Lines[$i]) {
            $end = $i
            break
        }
    }

    return [ordered]@{ found = $true; start = $start; end = $end }
}

function Get-TomlArrayValueEndIndex {
    param(
        [Parameter(Mandatory = $true)]$Lines,
        [Parameter(Mandatory = $true)][int]$StartIndex
    )

    $depth = 0
    $started = $false
    for ($i = $StartIndex; $i -lt $Lines.Count; $i++) {
        $line = [string]$Lines[$i]
        $quote = $null
        $escaped = $false
        for ($j = 0; $j -lt $line.Length; $j++) {
            $char = $line[$j]
            if ($null -ne $quote) {
                if ($quote -eq '"' -and $escaped) {
                    $escaped = $false
                    continue
                }
                if ($quote -eq '"' -and $char -eq '\') {
                    $escaped = $true
                    continue
                }
                if ($char -eq $quote) {
                    $quote = $null
                }
                continue
            }

            if ($char -eq '#') {
                break
            }
            if ($char -eq '"' -or $char -eq "'") {
                if ($j + 2 -lt $line.Length -and $line.Substring($j, 3) -in @('"""', "'''")) {
                    throw 'Refusing to rewrite a TOML array containing a multiline string.'
                }
                $quote = $char
                continue
            }
            if ($char -eq '[') {
                $depth++
                $started = $true
                continue
            }
            if ($char -eq ']') {
                $depth--
                if ($started -and $depth -eq 0) {
                    return $i
                }
            }
        }

        if ($null -ne $quote) {
            throw 'Refusing to rewrite an unterminated single-line TOML string.'
        }
    }

    throw 'TOML array value did not terminate before end of file.'
}

function Set-TomlSectionKey {
    param(
        [Parameter(Mandatory = $true)]$Lines,
        [Parameter(Mandatory = $true)][string]$Section,
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][string]$DesiredLine,
        [ValidateSet('scalar', 'array')][string]$ValueKind = 'scalar'
    )

    $range = Get-TomlSectionRange -Lines $Lines -Section $Section
    if (-not $range['found']) {
        if ($Lines.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($Lines[$Lines.Count - 1])) {
            [void]$Lines.Add('')
        }
        [void]$Lines.Add("[$Section]")
        [void]$Lines.Add($DesiredLine)
        return $true
    }

    $keyIndexes = @()
    for ($i = $range['start'] + 1; $i -lt $range['end']; $i++) {
        if ($Lines[$i] -match "^\s*$([regex]::Escape($Key))\s*=") {
            $keyIndexes += $i
        }
    }
    if ($keyIndexes.Count -gt 1) {
        throw "Duplicate TOML key $Section.$Key found."
    }

    if ($keyIndexes.Count -eq 0) {
        $insertIndex = $range['end']
        while ($insertIndex -gt ($range['start'] + 1) -and [string]::IsNullOrWhiteSpace($Lines[$insertIndex - 1])) {
            $insertIndex--
        }
        $Lines.Insert($insertIndex, $DesiredLine)
        return $true
    }

    $startIndex = $keyIndexes[0]
    $endIndex = $startIndex
    if ($ValueKind -eq 'array') {
        $endIndex = Get-TomlArrayValueEndIndex -Lines $Lines -StartIndex $startIndex
    }
    elseif ($Lines[$startIndex] -match '"""|''{3}') {
        throw "Refusing to rewrite multiline TOML scalar $Section.$Key."
    }

    if ($endIndex -eq $startIndex -and $Lines[$startIndex] -eq $DesiredLine) {
        return $false
    }
    for ($i = $endIndex; $i -gt $startIndex; $i--) {
        $Lines.RemoveAt($i)
    }
    $Lines[$startIndex] = $DesiredLine
    return $true
}

function Assert-TomlFileValid {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $pythonPath -PathType Leaf)) {
        throw "Python TOML validator not found: $pythonPath"
    }
    $code = 'import pathlib, sys, tomllib; tomllib.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))'
    $output = @(& $pythonPath -c $code $Path 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "TOML validation failed for ${Path}: $($output -join ' ')"
    }
}

function Write-ValidatedToml {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Lines
    )

    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    $unique = "{0}-{1}-{2}" -f (Get-Date -Format 'yyyyMMdd-HHmmss-fff'), $PID, ([guid]::NewGuid().ToString('N').Substring(0, 8))
    $tempPath = Join-Path $tempRoot "config-serena-$unique.toml"
    try {
        [System.IO.File]::WriteAllLines($tempPath, [string[]]$Lines.ToArray([string]), [System.Text.UTF8Encoding]::new($false))
        Assert-TomlFileValid -Path $tempPath
        $backupDirectory = Join-Path $configBackupRoot $unique
        New-Item -ItemType Directory -Path $backupDirectory -Force | Out-Null
        Copy-Item -LiteralPath $Path -Destination (Join-Path $backupDirectory 'config.toml')
        [System.IO.File]::Move($tempPath, $Path, $true)
        $tempPath = $null
    }
    finally {
        if ($null -ne $tempPath -and (Test-Path -LiteralPath $tempPath)) {
            Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Set-SerenaCodexConfig {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $false
    }
    if (-not (Test-UnderCodexRoot -Path $Path)) {
        throw "Refusing to edit non-D:\Codex path: $Path"
    }

    $mutex = [Threading.Mutex]::new($false, $configMutexName)
    $acquired = $false
    try {
        try {
            $acquired = $mutex.WaitOne(10000)
        }
        catch [Threading.AbandonedMutexException] {
            $acquired = $true
        }
        if (-not $acquired) {
            throw 'Timed out waiting for the shared Codex TOML mutex.'
        }

        Assert-TomlFileValid -Path $Path
        $lines = [System.Collections.ArrayList]::new()
        [void]$lines.AddRange([string[]][System.IO.File]::ReadAllLines($Path))

        $changed = $false
        $changed = (Set-TomlSectionKey -Lines $lines -Section 'mcp_servers.serena' -Key 'type' -DesiredLine 'type = "stdio"') -or $changed
        $changed = (Set-TomlSectionKey -Lines $lines -Section 'mcp_servers.serena' -Key 'command' -DesiredLine 'command = "D:\\Codex\\.codex\\scripts\\start-serena-mcp.cmd"') -or $changed
        $changed = (Set-TomlSectionKey -Lines $lines -Section 'mcp_servers.serena' -Key 'args' -DesiredLine 'args = [ "start-mcp-server", "--context=D:\\Codex\\.serena\\contexts\\codex-file-tools.yml", "--project-from-cwd", "--enable-web-dashboard=true", "--open-web-dashboard=false" ]' -ValueKind 'array') -or $changed
        $changed = (Set-TomlSectionKey -Lines $lines -Section 'mcp_servers.serena.env' -Key 'UV_TOOL_DIR' -DesiredLine 'UV_TOOL_DIR = "D:\\Codex\\tools\\uv\\tools"') -or $changed
        $changed = (Set-TomlSectionKey -Lines $lines -Section 'mcp_servers.serena.env' -Key 'UV_TOOL_BIN_DIR' -DesiredLine 'UV_TOOL_BIN_DIR = "D:\\Codex\\tools\\uv\\bin"') -or $changed
        $changed = (Set-TomlSectionKey -Lines $lines -Section 'mcp_servers.serena.env' -Key 'UV_PYTHON' -DesiredLine 'UV_PYTHON = "D:\\Codex\\tools\\python314-official\\python.exe"') -or $changed
        $changed = (Set-TomlSectionKey -Lines $lines -Section 'mcp_servers.serena.env' -Key 'PYTHON314_HOME' -DesiredLine 'PYTHON314_HOME = "D:\\Codex\\tools\\python314-official"') -or $changed
        $changed = (Set-TomlSectionKey -Lines $lines -Section 'mcp_servers.serena.env' -Key 'PYTHON314_EXE' -DesiredLine 'PYTHON314_EXE = "D:\\Codex\\tools\\python314-official\\python.exe"') -or $changed

    if ($changed) {
            Write-ValidatedToml -Path $Path -Lines $lines
        }
        return $changed
    }
    finally {
        if ($acquired) {
            $mutex.ReleaseMutex()
        }
        $mutex.Dispose()
    }
}

function Set-YamlTopLevelScalar {
    param(
        [Parameter(Mandatory = $true)]$Lines,
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][string]$Value
    )

    $desired = "${Key}: ${Value}"
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -match "^\s*$([regex]::Escape($Key))\s*:") {
            if ($Lines[$i] -ne $desired) {
                $Lines[$i] = $desired
                return $true
            }
            return $false
        }
    }
    $Lines.Add($desired)
    return $true
}

function Set-SerenaDashboardConfig {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $false
    }
    if (-not (Test-UnderCodexRoot -Path $Path)) {
        throw "Refusing to edit non-D:\Codex path: $Path"
    }

    $lines = [System.Collections.ArrayList]::new()
    [void]$lines.AddRange([string[]][System.IO.File]::ReadAllLines($Path))

    $changed = $false
    $changed = (Set-YamlTopLevelScalar -Lines $lines -Key 'gui_log_window' -Value 'false') -or $changed
    $changed = (Set-YamlTopLevelScalar -Lines $lines -Key 'web_dashboard' -Value 'true') -or $changed
    $changed = (Set-YamlTopLevelScalar -Lines $lines -Key 'web_dashboard_open_on_launch' -Value 'false') -or $changed
    $changed = (Set-YamlTopLevelScalar -Lines $lines -Key 'web_dashboard_interface' -Value 'tray_manager') -or $changed

    if ($changed) {
        [System.IO.File]::WriteAllLines($Path, [string[]]$lines.ToArray([string]), [System.Text.UTF8Encoding]::new($false))
    }
    return $changed
}

$changedCodex = Set-SerenaCodexConfig -Path $codexConfigPath
$changedSerena = Set-SerenaDashboardConfig -Path $serenaConfigPath

if ($changedCodex -or $changedSerena) {
    Write-Output 'Serena dashboard settings normalized for Codex.'
}
