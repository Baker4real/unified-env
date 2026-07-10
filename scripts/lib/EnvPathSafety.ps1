function Test-EnvSafeWin32PathSegments {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][AllowEmptyString()][string[]]$Segments)

    for ($index = 0; $index -lt $Segments.Count; $index++) {
        $segment = $Segments[$index]
        if ($segment.Length -eq 0) {
            if ($index -eq $Segments.Count - 1) {
                continue
            }
            return $false
        }
        if ($segment.EndsWith(' ', [StringComparison]::Ordinal) -or
            $segment.EndsWith('.', [StringComparison]::Ordinal) -or
            $segment -match '[<>:"|?*]') {
            return $false
        }
        foreach ($character in $segment.ToCharArray()) {
            if ([int]$character -lt 32) {
                return $false
            }
        }

        $deviceStem = ($segment -split '\.', 2)[0].TrimEnd(' ', '.')
        if ($deviceStem -imatch '^(?:CON|PRN|AUX|NUL|CLOCK\$|COM[1-9]|LPT[1-9])$') {
            return $false
        }
    }
    return $true
}

function Test-EnvSafeAbsolutePathSyntax {
    [CmdletBinding()]
    param([AllowNull()][object]$Path)

    if ($Path -isnot [string] -or [string]::IsNullOrWhiteSpace($Path) -or $Path -cne $Path.Trim()) {
        return $false
    }

    $normalized = $Path.Replace('/', '\')
    if ($normalized -match '^[A-Za-z]:\\') {
        $remainder = $normalized.Substring(3)
        if ($remainder.Length -eq 0) {
            return $true
        }
        return Test-EnvSafeWin32PathSegments -Segments ([string[]]$remainder.Split([char]'\'))
    }

    if (-not $normalized.StartsWith('\\', [StringComparison]::Ordinal)) {
        return $false
    }
    $segments = [string[]]$normalized.Substring(2).Split([char]'\')
    if ($segments.Count -lt 2 -or
        [string]::IsNullOrWhiteSpace($segments[0]) -or
        [string]::IsNullOrWhiteSpace($segments[1]) -or
        -not (Test-EnvSafeWin32PathSegments -Segments $segments)) {
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
