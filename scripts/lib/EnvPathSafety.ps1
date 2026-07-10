function Test-EnvSafeAbsolutePathSyntax {
    [CmdletBinding()]
    param([AllowNull()][object]$Path)

    if ($Path -isnot [string] -or [string]::IsNullOrWhiteSpace($Path) -or $Path -cne $Path.Trim()) {
        return $false
    }

    if ($Path -match '^[A-Za-z]:[\\/]') {
        return $true
    }

    $normalized = $Path.Replace('/', '\')
    if (-not $normalized.StartsWith('\\', [StringComparison]::Ordinal)) {
        return $false
    }
    $segments = @($normalized.Substring(2) -split '\\')
    if ($segments.Count -lt 2 -or
        [string]::IsNullOrWhiteSpace($segments[0]) -or
        [string]::IsNullOrWhiteSpace($segments[1]) -or
        $segments[0] -notmatch '^[^\\/:*?"<>|]+$' -or
        $segments[1] -notmatch '^[^\\/:*?"<>|]+$' -or
        $segments[0] -in @('.', '..', '?') -or
        $segments[1] -in @('.', '..')) {
        return $false
    }
    return $true
}

function Assert-EnvSafeAbsolutePath {
    [CmdletBinding()]
    param(
        [AllowNull()][object]$Path,
        [Parameter(Mandatory)][string]$FactName
    )

    if (-not (Test-EnvSafeAbsolutePathSyntax -Path $Path)) {
        throw "$FactName 必须是普通 DOS drive absolute path 或合法 UNC path，且不得使用 device、NT object manager、root-relative 或未知 namespace：$Path"
    }
}

function Assert-EnvSafeReparseTarget {
    [CmdletBinding()]
    param(
        [AllowNull()][object]$Path,
        [Parameter(Mandatory)][string]$FactName
    )

    Assert-EnvSafeAbsolutePath -Path $Path -FactName $FactName
}
