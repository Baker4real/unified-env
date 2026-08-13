[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$hostSafetyLibraryPath = Join-Path $projectRoot 'scripts\lib\CodexHostSafety.ps1'
$libraryPath = Join-Path $projectRoot 'scripts\lib\CodexSafeTreeDelete.ps1'
$fixtureRoot = Join-Path $projectRoot ("reports\safe-tree-delete-test-{0}" -f ([guid]::NewGuid().ToString('N')))
$targetPath = Join-Path $fixtureRoot 'candidate'
$nestedPath = Join-Path $targetPath 'nested'
$evidenceRoot = Join-Path $fixtureRoot 'evidence'
$policyPath = Join-Path $fixtureRoot 'policy.json'
$payloadPath = Join-Path $targetPath 'payload.txt'
$childPath = Join-Path $nestedPath 'child.bin'
$payloadBytes = [Text.Encoding]::UTF8.GetBytes('plan-identity-v2-payload')
$childBytes = [Text.Encoding]::UTF8.GetBytes('plan-identity-v2-child')

function Assert-True {
    param([Parameter(Mandatory)][bool]$Condition, [Parameter(Mandatory)][string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-Throws {
    param(
        [Parameter(Mandatory)][scriptblock]$Action,
        [Parameter(Mandatory)][string]$Message
    )

    try {
        & $Action
    } catch {
        return $_.Exception.Message
    }
    throw $Message
}

function Test-FileId128Equal {
    param(
        [Parameter(Mandatory)][byte[]]$Left,
        [Parameter(Mandatory)][byte[]]$Right
    )
    return [Linq.Enumerable]::SequenceEqual($Left, $Right)
}

function ConvertTo-ExpectedUInt64 {
    param([Parameter(Mandatory)]$Value)

    if ($Value -is [UInt64]) { return [UInt64]$Value }
    if ($Value -is [long]) {
        Assert-True ([long]$Value -ge 0L) 'volumeSerialNumber JSON integer 不得为负'
        return [UInt64][long]$Value
    }
    if ($Value -is [int]) {
        Assert-True ([int]$Value -ge 0) 'volumeSerialNumber JSON integer 不得为负'
        return [UInt64][int]$Value
    }
    if ($Value -is [decimal]) {
        Assert-True (
            [decimal]$Value -ge 0 -and
            [decimal]$Value -eq [Math]::Truncate([decimal]$Value) -and
            [decimal]$Value -le [decimal][UInt64]::MaxValue
        ) 'volumeSerialNumber 必须落在 uint64 整数域'
        return [UInt64][decimal]$Value
    }
    if ($Value -is [Numerics.BigInteger]) {
        Assert-True (
            $Value -ge [Numerics.BigInteger]::Zero -and
            $Value -le [Numerics.BigInteger][UInt64]::MaxValue
        ) 'volumeSerialNumber 必须落在 uint64 整数域'
        return [UInt64]$Value
    }
    throw "volumeSerialNumber JSON 类型非法：$($Value.GetType().FullName)"
}

function Remove-TestTree {
    param([Parameter(Mandatory)][string]$Path)

    if (-not [IO.Directory]::Exists($Path)) { return }
    $parent = Split-Path -Parent $Path
    $snapshot = Get-CodexHookCapabilityDirectoryTreeSnapshot `
        -Path $Path `
        -CapabilityRoot $parent `
        -AllowedExactPaths @($Path) `
        -Name 'safe-delete plan identity v2 test cleanup snapshot'
    Remove-CodexHookCapabilityDirectoryTree `
        -Path $Path `
        -CapabilityRoot $parent `
        -AllowedExactPaths @($Path) `
        -ExpectedRootIdentity @($snapshot.rootIdentity) `
        -ExpectedTreeManifest $snapshot `
        -Scope 'safe-delete plan identity v2 test cleanup'
}

$runtimeEdition = [string]$PSVersionTable.PSEdition
$runtimeMajor = [int]$PSVersionTable.PSVersion.Major
$runtimeMinor = [int]$PSVersionTable.PSVersion.Minor
Assert-True ($runtimeEdition -ceq 'Core') "本测试要求 PowerShell Core，实际为 $runtimeEdition"
Assert-True (
    $runtimeMajor -gt 7 -or
    ($runtimeMajor -eq 7 -and $runtimeMinor -ge 6)
) "本测试要求 PowerShell 7.6+，实际为 $($PSVersionTable.PSVersion)"

$drive = [IO.DriveInfo]::new([IO.Path]::GetPathRoot($projectRoot))
Assert-True (
    $drive.DriveFormat -ceq 'NTFS' -or
    $drive.DriveFormat -ceq 'ReFS'
) "本测试要求 NTFS/ReFS，实际为 $($drive.DriveFormat)"

. $hostSafetyLibraryPath
. $libraryPath
Assert-True (
    $null -ne (Get-Command -Name New-CodexSafeTreeDeletePlan -ErrorAction SilentlyContinue)
) 'New-CodexSafeTreeDeletePlan 必须存在'
Assert-True (
    $null -ne (Get-Command -Name Get-CodexSafeTreeDeleteFileIdentityV2 -ErrorAction SilentlyContinue)
) 'Get-CodexSafeTreeDeleteFileIdentityV2 必须存在'
Assert-True (
    $null -ne (Get-Command -Name Read-CodexSafeTreeDeleteFileIdentityV2FromPlan -ErrorAction SilentlyContinue)
) 'RED: Read-CodexSafeTreeDeleteFileIdentityV2FromPlan 尚不存在'

try {
    [void][IO.Directory]::CreateDirectory($nestedPath)
    [void][IO.Directory]::CreateDirectory($evidenceRoot)
    [IO.File]::WriteAllBytes($payloadPath, $payloadBytes)
    [IO.File]::WriteAllBytes($childPath, $childBytes)

    $policy = [pscustomobject][ordered]@{
        artifactType = 'env-governance.codex-safe-tree-delete-policy'
        schemaVersion = 3
        entries = @(
            [pscustomobject][ordered]@{
                id = 'plan-identity-v2-fixture'
                capabilityRoot = $fixtureRoot
                minimumDescendantDepth = 1
                rootDeletionPurpose = 'none'
                deniedExactPaths = @($evidenceRoot)
            }
        )
    }
    [IO.File]::WriteAllText(
        $policyPath,
        ($policy | ConvertTo-Json -Depth 10),
        [Text.UTF8Encoding]::new($false))

    $planResult = New-CodexSafeTreeDeletePlan `
        -TargetPath $targetPath `
        -CapabilityRoot $fixtureRoot `
        -PolicyPath $policyPath `
        -EvidenceRoot $evidenceRoot
    Assert-True ([IO.File]::Exists([string]$planResult.planPath)) 'Plan 必须写出 plan.json'
    Assert-True ($planResult.fileCount -eq 2) 'Plan 必须包含两个普通文件'

    $planText = [IO.File]::ReadAllText([string]$planResult.planPath, [Text.UTF8Encoding]::new($false))
    $plan = $planText | ConvertFrom-Json -Depth 128 -DateKind String -ErrorAction Stop
    Assert-True (
        $plan.artifactType -ceq 'env-governance.codex-safe-tree-delete-plan' -and
        [long]$plan.schemaVersion -eq 1L
    ) 'plan artifact/schema 必须保持现役 schemaVersion=1'
    Assert-True (
        @($plan.PSObject.Properties.Name) -contains 'fileIdentitiesV2'
    ) 'RED: 新 plan 必须并列写出 fileIdentitiesV2，不得改写 treeManifest.identity'
    Assert-True ($plan.fileIdentitiesV2 -is [Array]) 'fileIdentitiesV2 必须是 JSON array'
    Assert-True (@($plan.fileIdentitiesV2).Count -eq 2) 'fileIdentitiesV2 必须覆盖每个 file'

    $root = [Text.Json.JsonDocument]::Parse($planText)
    try {
        $rawIdentities = $root.RootElement.GetProperty('fileIdentitiesV2')
        Assert-True (
            $rawIdentities.ValueKind -eq [Text.Json.JsonValueKind]::Array
        ) 'fileIdentitiesV2 词法上必须是 JSON array'
        for ($index = 0; $index -lt $rawIdentities.GetArrayLength(); $index++) {
            $rawRecord = $rawIdentities[$index]
            Assert-True (
                $rawRecord.GetProperty('volumeSerialNumber').ValueKind -eq [Text.Json.JsonValueKind]::Number
            ) 'volumeSerialNumber 必须是 JSON number'
            Assert-True (
                $rawRecord.GetProperty('fileId128').ValueKind -eq [Text.Json.JsonValueKind]::String
            ) 'fileId128 必须是 JSON string（Base64）'
        }
    } finally {
        $root.Dispose()
    }

    $plannedFiles = @($plan.treeManifest.entries | Where-Object kind -ceq 'file')
    Assert-True ($plannedFiles.Count -eq 2) 'treeManifest 必须仍包含两个 file'
    foreach ($entry in $plannedFiles) {
        Assert-True (@($entry.identity).Count -eq 2) 'treeManifest.identity 必须仍是现役 64-bit FileIndex 合同'
    }

    $expectedPaths = @(
        [pscustomobject]@{ relativePath = 'payload.txt'; absolutePath = $payloadPath },
        [pscustomobject]@{ relativePath = 'nested/child.bin'; absolutePath = $childPath }
    )
    foreach ($expected in $expectedPaths) {
        $record = @($plan.fileIdentitiesV2 | Where-Object relativePath -ceq $expected.relativePath)
        Assert-True ($record.Count -eq 1) "fileIdentitiesV2 必须包含 $($expected.relativePath)"
        $item = $record[0]
        Assert-True (
            ((@($item.PSObject.Properties.Name) | Sort-Object -CaseSensitive) -join '|') -ceq
            'capturedAtUtc|fileId128|fileSize|lastWriteTimeUtc|relativePath|volumeSerialNumber'
        ) "fileIdentitiesV2 记录属性必须稳定：$($expected.relativePath)"

        $fileId128 = [Convert]::FromBase64String([string]$item.fileId128)
        Assert-True ($fileId128.Length -eq 16) "$($expected.relativePath) fileId128 解码后必须是 16 字节"
        $live = Get-CodexSafeTreeDeleteFileIdentityV2 -LiteralPath $expected.absolutePath
        Assert-True (
            (Test-FileId128Equal -Left $fileId128 -Right $live.FileId128)
        ) "$($expected.relativePath) 写入的 FileId128 必须与当场再取一致"
        Assert-True (
            (ConvertTo-ExpectedUInt64 -Value $item.volumeSerialNumber) -eq $live.VolumeSerialNumber
        ) "$($expected.relativePath) 写入的 VolumeSerialNumber 必须与当场再取一致"
        Assert-True ([long]$item.fileSize -eq $live.FileSize) "$($expected.relativePath) fileSize 必须与当场再取一致"
    }

    $approved = Read-CodexSafeTreeDeleteApprovedPlan `
        -PlanPath ([string]$planResult.planPath) `
        -ApprovedPlanSha256 ([string]$planResult.planSha256) `
        -PolicyPath $policyPath `
        -EvidenceRoot $evidenceRoot
    Assert-True (
        $approved.document.artifactType -ceq 'env-governance.codex-safe-tree-delete-plan'
    ) '现役 approved plan 读取不得因并列 fileIdentitiesV2 失败'

    $readBack = @(Read-CodexSafeTreeDeleteFileIdentityV2FromPlan -Plan $plan)
    Assert-True ($readBack.Count -eq 2) '读回函数必须返回每个 file 的 FileIdentityV2'
    foreach ($expected in $expectedPaths) {
        $row = @($readBack | Where-Object relativePath -ceq $expected.relativePath)
        Assert-True ($row.Count -eq 1) "读回结果必须包含 $($expected.relativePath)"
        $identity = $row[0].identity
        Assert-True ($identity -is [CodexSafeTreeDelete.FileIdentityV2]) `
            "$($expected.relativePath) 读回对象必须是 FileIdentityV2"
        $live = Get-CodexSafeTreeDeleteFileIdentityV2 -LiteralPath $expected.absolutePath
        Assert-True ($identity.VolumeSerialNumber -eq $live.VolumeSerialNumber) `
            "$($expected.relativePath) 读回 VolumeSerialNumber 必须与当场再取一致"
        Assert-True ($identity.FileId128.Length -eq 16) "$($expected.relativePath) 读回 FileId128 长度必须是 16"
        Assert-True (
            (Test-FileId128Equal -Left $identity.FileId128 -Right $live.FileId128)
        ) "$($expected.relativePath) 读回 FileId128 必须与当场再取一致"
        Assert-True ($identity.FileSize -eq $live.FileSize) `
            "$($expected.relativePath) 读回 FileSize 必须与当场再取一致"
    }

    $legacyPlan = $planText | ConvertFrom-Json -Depth 128 -DateKind String -ErrorAction Stop
    $null = $legacyPlan.PSObject.Properties.Remove('fileIdentitiesV2')
    $legacyError = Assert-Throws `
        -Message '缺少 fileIdentitiesV2 的旧 plan 必须被拒绝' `
        -Action { [void](Read-CodexSafeTreeDeleteFileIdentityV2FromPlan -Plan $legacyPlan) }
    Assert-True (
        $legacyError -match 'fileIdentitiesV2'
    ) '旧 plan 拒绝原因必须明确指向缺失 V2 字段'
    Assert-True (
        $legacyError -match '拒绝' -or
        $legacyError -match '缺少'
    ) '旧 plan 必须 fail-closed，不得降级成 64-bit FileIndex'

    [pscustomobject][ordered]@{
        ok = $true
        suite = 'CodexSafeTreeDeletePlanIdentityV2'
        slices = 3
    }
} finally {
    if ([IO.Directory]::Exists($fixtureRoot)) {
        Remove-TestTree -Path $fixtureRoot
    }
}
