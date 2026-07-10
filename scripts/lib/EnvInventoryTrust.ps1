function Get-InventorySha256 {
    param([AllowNull()][string]$Value)

    $text = if ($null -eq $Value) { "" } else { $Value }
    $bytes = [Text.Encoding]::UTF8.GetBytes($text)
    $hash = [Security.Cryptography.SHA256]::HashData($bytes)
    return [Convert]::ToHexString($hash).ToLowerInvariant()
}

function Get-InventoryPathRoot {
    param([AllowNull()][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $null
    }

    try {
        return [IO.Path]::GetPathRoot($Path)
    } catch {
        return $null
    }
}

function Get-InventoryPathComparisonKey {
    param([Parameter(Mandatory)][string]$Path)

    try {
        if ([IO.Path]::IsPathFullyQualified($Path)) {
            $fullPath = [IO.Path]::GetFullPath($Path)
            $root = [IO.Path]::GetPathRoot($fullPath)
            if ($fullPath.Equals($root, [StringComparison]::OrdinalIgnoreCase)) {
                return $root
            }
            return $fullPath.TrimEnd("\", "/")
        }
    } catch {
        # 异常或相对路径只使用字面比较键。
    }

    return $Path.TrimEnd("\", "/")
}

function New-PathScopeRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet("process", "user", "machine")][string]$Source,
        [AllowNull()][string]$RawValue,
        [AllowNull()][string]$DotNetValue,
        [object[]]$ReadErrors = @(),
        [Parameter(Mandatory)][scriptblock]$MetadataResolver
    )

    $entries = [Collections.Generic.List[object]]::new()
    $duplicates = [Collections.Generic.List[object]]::new()
    $metadataErrors = [Collections.Generic.List[string]]::new()
    $seen = [Collections.Generic.Dictionary[string, int]]::new([StringComparer]::OrdinalIgnoreCase)
    $complete = (@($ReadErrors).Count -eq 0) -and ($RawValue -ceq $DotNetValue)
    $rawEntries = @(if ([string]::IsNullOrWhiteSpace($RawValue)) {
        @()
    } else {
        @($RawValue -split ";" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    })

    for ($index = 0; $index -lt $rawEntries.Count; $index++) {
        $rawPath = $rawEntries[$index].Trim()
        $expandedPath = [Environment]::ExpandEnvironmentVariables($rawPath)
        $containsUnexpandedVariable = [regex]::IsMatch($expandedPath, "%[^%]+%")
        $expansionStatus = if ($containsUnexpandedVariable) {
            "failed"
        } elseif ($expandedPath -ceq $rawPath) {
            "not-required"
        } else {
            "expanded"
        }

        $exists = $null
        $isReparsePoint = $null
        $reparseTarget = $null
        if ($containsUnexpandedVariable) {
            $complete = $false
        } else {
            try {
                $metadata = & $MetadataResolver $expandedPath
                $exists = [bool]$metadata.exists
                $isReparsePoint = [bool]$metadata.isReparsePoint
                $reparseTarget = $metadata.reparseTarget
            } catch {
                $complete = $false
                $metadataErrors.Add("[$index] $($_.Exception.Message)")
            }
        }

        $entries.Add([pscustomobject][ordered]@{
            index = $index
            rawPath = $rawPath
            expandedPath = $expandedPath
            expansionStatus = $expansionStatus
            exists = $exists
            drive = if ($containsUnexpandedVariable) { $null } else { Get-InventoryPathRoot -Path $expandedPath }
            isReparsePoint = $isReparsePoint
            reparseTarget = $reparseTarget
        })

        if (-not $containsUnexpandedVariable) {
            $comparisonPath = Get-InventoryPathComparisonKey -Path $expandedPath
            if ($seen.ContainsKey($comparisonPath)) {
                $duplicates.Add([pscustomobject]@{
                    firstIndex = $seen[$comparisonPath]
                    duplicateIndex = $index
                    expandedPath = $expandedPath
                })
            } else {
                $seen.Add($comparisonPath, $index)
            }
        }
    }

    $missingPathCleanupCandidates = if ($complete) {
        @($entries | Where-Object { $_.exists -eq $false })
    } else {
        @()
    }
    $errors = [Collections.Generic.List[string]]::new()
    foreach ($readError in @($ReadErrors)) {
        $errors.Add("Read: $readError")
    }
    if ($RawValue -cne $DotNetValue) {
        $errors.Add("Registry/.NET PATH values differ")
    }
    foreach ($entry in @($entries | Where-Object { $_.expansionStatus -eq "failed" })) {
        $errors.Add("Expansion [$($entry.index)]: unresolved environment variable")
    }
    foreach ($metadataError in @($metadataErrors)) {
        $errors.Add("Metadata $metadataError")
    }

    return [pscustomobject][ordered]@{
        source = $Source
        readStatus = if (@($ReadErrors).Count -eq 0) { "ok" } else { "error" }
        complete = $complete
        errors = @($errors)
        rawValueSha256 = Get-InventorySha256 -Value $RawValue
        dotNetValueSha256 = Get-InventorySha256 -Value $DotNetValue
        valuesMatch = ($RawValue -ceq $DotNetValue)
        readErrors = @($ReadErrors | ForEach-Object { "$_" })
        metadataErrors = @($metadataErrors)
        entries = @($entries)
        duplicates = @($duplicates)
        missingPathCleanupCandidates = @($missingPathCleanupCandidates)
    }
}

function Test-InventorySubPath {
    param(
        [AllowNull()][string]$Path,
        [AllowNull()][string]$Root
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or [string]::IsNullOrWhiteSpace($Root)) {
        return $false
    }

    try {
        $fullPath = [IO.Path]::GetFullPath($Path).TrimEnd("\", "/")
        $fullRoot = [IO.Path]::GetFullPath($Root).TrimEnd("\", "/")
        return $fullPath.Equals($fullRoot, [StringComparison]::OrdinalIgnoreCase) -or
            $fullPath.StartsWith("$fullRoot\", [StringComparison]::OrdinalIgnoreCase)
    } catch {
        return $false
    }
}

function Get-InventoryPathOrigin {
    param(
        [AllowNull()][string]$Path,
        [string[]]$ProjectRoots,
        [string[]]$SharedRoots,
        [string[]]$VendorRoots,
        [string[]]$WindowsSystemRoots,
        [string[]]$SystemInstallerRoots,
        [string[]]$UserProfileRoots,
        [Parameter(Mandatory)][scriptblock]$MetadataResolver,
        [switch]$ProbeSucceeded,
        [switch]$ProjectEnvironmentEvidence
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or -not [IO.Path]::IsPathFullyQualified($Path)) {
        return [pscustomobject]@{
            path = $Path
            originClass = "unknown"
            matchedRule = "no-absolute-path"
            matchedRoot = $null
            isReparsePoint = $null
            reparseTarget = $null
        }
    }

    $metadata = $null
    try {
        $metadata = & $MetadataResolver $Path
    } catch {
        return [pscustomobject]@{
            path = $Path
            originClass = "unknown"
            matchedRule = "metadata-read-failed"
            matchedRoot = $null
            isReparsePoint = $null
            reparseTarget = $null
        }
    }

    $pathHasEnvironmentMarker = [regex]::IsMatch(
        $Path,
        '(?i)(?:^|[\\/])(?:\.venv|venv(?:-[^\\/]+)?|\.conda|node_modules)(?:[\\/]|$)'
    )
    foreach ($root in @($ProjectRoots)) {
        if (($ProjectEnvironmentEvidence -or $pathHasEnvironmentMarker) -and (Test-InventorySubPath -Path $Path -Root $root)) {
            return [pscustomobject]@{
                path = $Path
                originClass = "project-local-env"
                matchedRule = "explicit-project-root"
                matchedRoot = $root
                isReparsePoint = [bool]$metadata.isReparsePoint
                reparseTarget = $metadata.reparseTarget
            }
        }
    }

    $rootClasses = @(
        [pscustomobject]@{ roots = @($VendorRoots); originClass = "vendor-runtime"; matchedRule = "explicit-vendor-root" }
        [pscustomobject]@{ roots = @($WindowsSystemRoots); originClass = "windows-system"; matchedRule = "windows-system-root" }
        [pscustomobject]@{ roots = @($SystemInstallerRoots); originClass = "system-installer"; matchedRule = "system-installer-root" }
        [pscustomobject]@{ roots = @($UserProfileRoots); originClass = "user-profile"; matchedRule = "user-profile-root" }
        [pscustomobject]@{ roots = @($SharedRoots); originClass = "shared-tool"; matchedRule = "explicit-shared-root" }
    )
    foreach ($rootClass in $rootClasses) {
        foreach ($root in $rootClass.roots) {
            if (Test-InventorySubPath -Path $Path -Root $root) {
                $originClass = $rootClass.originClass
                $matchedRule = $rootClass.matchedRule
                if ($originClass -eq "shared-tool" -and -not $ProbeSucceeded) {
                    $originClass = "unknown"
                    $matchedRule = "shared-root-probe-not-succeeded"
                }
                return [pscustomobject]@{
                    path = $Path
                    originClass = $originClass
                    matchedRule = $matchedRule
                    matchedRoot = $root
                    isReparsePoint = [bool]$metadata.isReparsePoint
                    reparseTarget = $metadata.reparseTarget
                }
            }
        }
    }

    return [pscustomobject]@{
        path = $Path
        originClass = "unknown"
        matchedRule = "no-origin-rule-matched"
        matchedRoot = $null
        isReparsePoint = [bool]$metadata.isReparsePoint
        reparseTarget = $metadata.reparseTarget
    }
}

function Get-ToolOriginDecision {
    [CmdletBinding()]
    param(
        [AllowNull()][string]$LauncherPath,
        [AllowNull()][string]$RuntimePath,
        [AllowNull()][string]$RuntimePrefix,
        [AllowNull()][string]$RuntimeBasePrefix,
        [string[]]$ProjectRoots = @(),
        [string[]]$SharedRoots = @(),
        [string[]]$VendorRoots = @(),
        [string[]]$WindowsSystemRoots = @(),
        [string[]]$SystemInstallerRoots = @(),
        [string[]]$UserProfileRoots = @(),
        [Parameter(Mandatory)][scriptblock]$MetadataResolver,
        [switch]$LauncherProbeSucceeded,
        [switch]$RuntimeProbeSucceeded,
        [switch]$RuntimeProbeFailed
    )

    $launcher = Get-InventoryPathOrigin -Path $LauncherPath -ProjectRoots $ProjectRoots -SharedRoots $SharedRoots -VendorRoots $VendorRoots -WindowsSystemRoots $WindowsSystemRoots -SystemInstallerRoots $SystemInstallerRoots -UserProfileRoots $UserProfileRoots -MetadataResolver $MetadataResolver -ProbeSucceeded:$LauncherProbeSucceeded
    $runtimeHasEnvironmentEvidence = $false
    if (-not [string]::IsNullOrWhiteSpace($RuntimePath) -and
        -not [string]::IsNullOrWhiteSpace($RuntimePrefix) -and
        -not [string]::IsNullOrWhiteSpace($RuntimeBasePrefix) -and
        $RuntimePrefix -ine $RuntimeBasePrefix -and
        (Test-InventorySubPath -Path $RuntimePath -Root $RuntimePrefix)) {
        $runtimeHasEnvironmentEvidence = @($ProjectRoots | Where-Object { Test-InventorySubPath -Path $RuntimePrefix -Root $_ }).Count -gt 0
    }
    $runtime = if ($RuntimeProbeFailed) {
        [pscustomobject]@{
            path = $null
            originClass = "unknown"
            matchedRule = "runtime-probe-failed"
            matchedRoot = $null
            isReparsePoint = $null
            reparseTarget = $null
        }
    } elseif (-not [string]::IsNullOrWhiteSpace($RuntimePath)) {
        Get-InventoryPathOrigin -Path $RuntimePath -ProjectRoots $ProjectRoots -SharedRoots $SharedRoots -VendorRoots $VendorRoots -WindowsSystemRoots $WindowsSystemRoots -SystemInstallerRoots $SystemInstallerRoots -UserProfileRoots $UserProfileRoots -MetadataResolver $MetadataResolver -ProbeSucceeded:$RuntimeProbeSucceeded -ProjectEnvironmentEvidence:$runtimeHasEnvironmentEvidence
    } else {
        $null
    }

    $finalOrigin = if ($RuntimeProbeFailed) {
        "unknown"
    } elseif ($null -ne $runtime) {
        $runtime.originClass
    } else {
        $launcher.originClass
    }
    $hasReparseEvidence = [bool]$launcher.isReparsePoint -or ($null -ne $runtime -and [bool]$runtime.isReparsePoint)
    $riskOriginClasses = @("project-local-env", "vendor-runtime", "system-installer", "windows-system", "user-profile", "unknown")
    $roleOriginClasses = @($launcher.originClass)
    if ($null -ne $runtime) {
        $roleOriginClasses += $runtime.originClass
    }
    $hasRiskOrigin = @($roleOriginClasses | Where-Object { $riskOriginClasses -contains $_ }).Count -gt 0
    $requiresManualReview = $hasReparseEvidence -or $hasRiskOrigin

    return [pscustomobject][ordered]@{
        launcher = $launcher
        runtime = $runtime
        originClass = $finalOrigin
        originEvidence = @(
            [pscustomobject]@{ role = "launcher"; evidence = $launcher }
            if ($null -ne $runtime) {
                [pscustomobject]@{ role = "runtime"; evidence = $runtime }
            }
        )
        resolutionScope = "process"
        requiresManualReview = $requiresManualReview
    }
}

function ConvertFrom-PythonRuntimeProbe {
    [CmdletBinding()]
    param(
        [AllowNull()][string]$Json,
        [switch]$TimedOut,
        [AllowNull()][string]$ErrorMessage
    )

    if ($TimedOut) {
        return [pscustomobject]@{
            succeeded = $false
            executable = $null
            prefix = $null
            basePrefix = $null
            error = "Python runtime probe timed out"
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($ErrorMessage)) {
        return [pscustomobject]@{
            succeeded = $false
            executable = $null
            prefix = $null
            basePrefix = $null
            error = $ErrorMessage
        }
    }

    try {
        if ([string]::IsNullOrWhiteSpace($Json)) {
            throw "Python runtime probe returned no JSON"
        }

        $probe = $Json | ConvertFrom-Json -ErrorAction Stop
        if ($probe -is [Array]) {
            throw "Python runtime probe must return one JSON object"
        }

        $actualProperties = @($probe.PSObject.Properties.Name | Sort-Object)
        $expectedProperties = @("basePrefix", "executable", "prefix")
        if (($actualProperties -join ",") -cne ($expectedProperties -join ",")) {
            throw "Python runtime probe JSON fields are invalid"
        }

        foreach ($property in $expectedProperties) {
            $value = $probe.$property
            if ($value -isnot [string] -or -not [IO.Path]::IsPathFullyQualified($value)) {
                throw "Python runtime probe field '$property' must be an absolute path"
            }
        }

        return [pscustomobject]@{
            succeeded = $true
            executable = [string]$probe.executable
            prefix = [string]$probe.prefix
            basePrefix = [string]$probe.basePrefix
            error = $null
        }
    } catch {
        return [pscustomobject]@{
            succeeded = $false
            executable = $null
            prefix = $null
            basePrefix = $null
            error = $_.Exception.Message
        }
    }
}

function New-InventoryV3Document {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][Collections.IDictionary]$Facts
    )

    $requiredFacts = @(
        "generatedAt",
        "host",
        "outputDir",
        "projectRoots",
        "toolOwnerRoots",
        "excludedRoots",
        "versionProbeTimeoutSeconds",
        "includeSizes",
        "skipVersionProbe",
        "tools",
        "selectedEnvironmentVariables",
        "pathScopes",
        "directories",
        "projectEnvironmentMarkers",
        "localEnvironmentFindings",
        "migrationCandidates",
        "manualReviewItems"
    )
    foreach ($name in $requiredFacts) {
        if (-not $Facts.Contains($name)) {
            throw "Inventory v3 fact is missing: $name"
        }
    }

    foreach ($scopeName in @("process", "user", "machine")) {
        if (-not ($Facts.pathScopes.PSObject.Properties.Name -contains $scopeName)) {
            throw "Inventory v3 PATH scope is missing: $scopeName"
        }
    }

    $pathEntries = @(
        foreach ($entry in @($Facts.pathScopes.process.entries)) {
            [pscustomobject][ordered]@{
                index = $entry.index
                path = $entry.expandedPath
                exists = $entry.exists
                drive = $entry.drive
            }
        }
    )

    return [pscustomobject][ordered]@{
        artifactType = "env-governance.inventory"
        schemaVersion = 3
        executionAllowed = $false
        generatedAt = $Facts.generatedAt
        readOnly = $true
        host = $Facts.host
        outputDir = $Facts.outputDir
        projectRoots = @($Facts.projectRoots)
        toolOwnerRoots = @($Facts.toolOwnerRoots)
        excludedRoots = @($Facts.excludedRoots)
        versionProbeTimeoutSeconds = $Facts.versionProbeTimeoutSeconds
        includeSizes = [bool]$Facts.includeSizes
        skipVersionProbe = [bool]$Facts.skipVersionProbe
        tools = @($Facts.tools)
        selectedEnvironmentVariables = @($Facts.selectedEnvironmentVariables)
        pathScopes = $Facts.pathScopes
        pathEntries = $pathEntries
        directories = @($Facts.directories)
        projectEnvironmentMarkers = @($Facts.projectEnvironmentMarkers)
        localEnvironmentFindings = @($Facts.localEnvironmentFindings)
        migrationCandidates = @($Facts.migrationCandidates)
        manualReviewItems = @($Facts.manualReviewItems)
    }
}
