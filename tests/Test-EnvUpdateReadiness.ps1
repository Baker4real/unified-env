param(
    [string]$ProjectRoot = "D:\Codex\projects\统一环境",
    [switch]$KeepOutputs
)

$ErrorActionPreference = "Stop"

function Assert-True { param([bool]$Condition, [string]$Message) if (-not $Condition) { throw $Message } }
function Assert-Property { param([object]$Object, [string]$Name) Assert-True ($Object.PSObject.Properties.Name -contains $Name) "缺少属性：$Name" }

function Copy-JsonObject {
    param([object]$Value)
    return ($Value | ConvertTo-Json -Depth 100) | ConvertFrom-Json -DateKind String
}

function Publish-InventoryFixture {
    param([object]$Document, [string]$OutputDir)
    Publish-JsonMarkdownArtifactPair -Document $Document -OutputDir $OutputDir -JsonFileName "inventory.json" -MarkdownFileName "REPORT.md" -RenderMarkdown {
        param($PublishedDocument, $JsonSha256)
        "# Inventory fixture`n`nschema=$($PublishedDocument.schemaVersion)"
    }
}

$inventoryScript = Join-Path $ProjectRoot "scripts\Invoke-EnvInventory.ps1"
$readinessScript = Join-Path $ProjectRoot "scripts\New-EnvUpdateReadinessReport.ps1"
$publisherPath = Join-Path $ProjectRoot "scripts\lib\ReportArtifactPublisher.ps1"
$testRoot = Join-Path $ProjectRoot "reports\env-update-readiness-test"
$inventoryOutput = Join-Path $testRoot "inventory"
$readinessOutput = Join-Path $testRoot "readiness"
$junctionTarget = Join-Path $testRoot "junction-target"
$junctionPath = Join-Path $testRoot "junction-link"

. $publisherPath
Assert-True (Test-Path -LiteralPath $inventoryScript -PathType Leaf) "找不到 inventory 脚本"
Assert-True (Test-Path -LiteralPath $readinessScript -PathType Leaf) "找不到更新准备报告脚本"

try {
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $inventoryOutput | Out-Null

    & $inventoryScript -OutputDir $inventoryOutput -SkipVersionProbe | Out-Null
    $inventoryPath = Join-Path $inventoryOutput "inventory.json"
    $inventory = Get-Content -LiteralPath $inventoryPath -Raw | ConvertFrom-Json -DateKind String
    Assert-True (Test-Path -LiteralPath $inventoryPath -PathType Leaf) "测试 inventory 未生成"

    $result = & $readinessScript -InventoryPath $inventoryPath -OutputDir $readinessOutput
    Assert-True ([bool]$result.readOnly) "更新准备报告脚本没有返回 readOnly=true"
    $jsonPath = Join-Path $readinessOutput "readiness.json"
    $markdownPath = Join-Path $readinessOutput "REPORT.md"
    $readiness = Get-Content -LiteralPath $jsonPath -Raw | ConvertFrom-Json
    foreach ($property in @("artifactType", "schemaVersion", "generationId", "readOnly", "inventoryPath", "inventorySchemaVersion", "toolReadiness", "pathSummary", "highRiskItems", "policy")) {
        Assert-Property $readiness $property
    }
    Assert-True ($readiness.artifactType -ceq "env-governance.update-readiness") "readiness artifactType 错误"
    Assert-True ($readiness.schemaVersion -eq 3) "readiness schemaVersion 必须为 3"
    Assert-True ($readiness.inventorySchemaVersion -eq 3) "readiness 必须记录 inventory schema 3"
    Assert-True ($readiness.pathSummary.sourceScope -ceq "process") "PATH 摘要必须来自 process scope"
    Assert-True ($readiness.pathSummary.complete -is [bool]) "PATH 摘要 complete 必须是 Boolean"
    foreach ($arrayProperty in @("errors", "missingEntries", "staleLocalEnvironmentEntries", "duplicates", "recommendations")) {
        Assert-True ($readiness.pathSummary.$arrayProperty -is [array]) "PATH 摘要 $arrayProperty 必须是数组"
    }
    Assert-True ($readiness.toolReadiness.Count -gt 0) "没有生成工具更新准备项"
    foreach ($entry in $readiness.toolReadiness) {
        foreach ($property in @("name", "path", "pathDisplay", "pathStatus", "locationClass", "originClass", "decisionInputs", "recommendedUpdateEntry", "recommendedAction", "requiresManualReview", "autoUpdateAllowed", "riskLevel")) {
            Assert-Property $entry $property
        }
        foreach ($input in @("locationClass", "originClass", "probeSucceeded", "requiresManualReview", "resolutionScope")) { Assert-Property $entry.decisionInputs $input }
        Assert-True (-not [bool]$entry.autoUpdateAllowed) "$($entry.name) 不应允许自动更新"
    }
    $pair = Test-JsonMarkdownArtifactPair -JsonPath $jsonPath -MarkdownPath $markdownPath
    Assert-True ([bool]$pair.ok) "readiness JSON/Markdown pair 校验失败：$($pair.error)"
    $markdown = Get-Content -LiteralPath $markdownPath -Raw
    foreach ($expected in @("只读", "工具更新准备", "process", "归属", "人工审查", "不自动更新")) {
        Assert-True $markdown.Contains($expected) "REPORT.md 缺少预期文本：$expected"
    }

    # 不完整 process scope 可以生成事实报告，但不得生成 missing/stale cleanup advice。
    $incompleteInventory = Copy-JsonObject $inventory
    $incompleteInventory.pathScopes.process.complete = $false
    $incompleteInventory.pathScopes.process.errors = @("fixture incomplete")
    $incompleteInventory.pathScopes.process.missingPathCleanupCandidates = @()
    $incompletePair = Publish-InventoryFixture -Document $incompleteInventory -OutputDir (Join-Path $testRoot "input-incomplete")
    $incompletePath = $incompletePair.jsonPath
    $incompleteOutput = Join-Path $testRoot "readiness-incomplete"
    & $readinessScript -InventoryPath $incompletePath -OutputDir $incompleteOutput | Out-Null
    $incomplete = Get-Content -LiteralPath (Join-Path $incompleteOutput "readiness.json") -Raw | ConvertFrom-Json
    Assert-True (-not [bool]$incomplete.pathSummary.complete) "不完整 process scope 必须保持 complete=false"
    Assert-True (-not [bool]$incomplete.pathSummary.cleanupAdviceAllowed) "不完整 process scope 不得允许 cleanup advice"
    Assert-True (@($incomplete.pathSummary.missingEntries).Count -eq 0) "不完整 process scope 不得生成 missing 建议"
    Assert-True (@($incomplete.pathSummary.staleLocalEnvironmentEntries).Count -eq 0) "不完整 process scope 不得生成 stale 建议"

    # 所有 inventory contract 错误必须在创建 OutputDir 之前失败。
    $invalidCases = @(
        @{ name = "schema2"; mutate = { param($d) $d.schemaVersion = 2 } },
        @{ name = "future-schema"; mutate = { param($d) $d.schemaVersion = 4 } },
        @{ name = "artifact"; mutate = { param($d) $d.artifactType = "wrong" } },
        @{ name = "missing-scopes"; mutate = { param($d) $d.PSObject.Properties.Remove("pathScopes") } },
        @{ name = "missing-origin"; mutate = { param($d) $d.tools[0].PSObject.Properties.Remove("originClass") } },
        @{ name = "string-exists"; mutate = { param($d) if (@($d.pathScopes.process.entries).Count -gt 0) { $d.pathScopes.process.entries[0].exists = "false" } else { $d.pathScopes.process.complete = "false" } } },
        @{ name = "manual-bypass"; mutate = { param($d) $d.tools[0].requiresManualReview = $false } },
        @{ name = "forged-duplicate"; mutate = { param($d) $entry = $d.pathScopes.process.entries[0]; $d.pathScopes.process.duplicates = @([pscustomobject]@{ firstIndex = 0; duplicateIndex = 0; expandedPath = $entry.expandedPath }) } },
        @{ name = "origin-evidence-mismatch"; mutate = { param($d) $d.tools[0].originEvidence[0].evidence.matchedRule = "tampered" } },
        @{ name = "shared-self-report"; mutate = {
            param($d)
            $tool = $d.tools[0]
            $spoofPath = "D:\projects\app\.venv\Scripts\python.exe"
            $launcher = [pscustomobject]@{ path=$spoofPath; originClass="shared-tool"; matchedRule="explicit-shared-root"; matchedRoot="D:\Codex\tools"; metadataStatus="ok"; metadataError=$null; isReparsePoint=$false; reparseAncestor=$null; reparseTarget=$null }
            $tool.path=$spoofPath; $tool.found=$true; $tool.probeSucceeded=$true; $tool.error=$null; $tool.launcher=$launcher; $tool.runtime=$null; $tool.originClass="shared-tool"; $tool.originEvidence=@([pscustomobject]@{role="launcher";evidence=$launcher}); $tool.requiresManualReview=$false
        } }
    )
    foreach ($case in $invalidCases) {
        $document = Copy-JsonObject $inventory
        & $case.mutate $document
        $publishedInput = Publish-InventoryFixture -Document $document -OutputDir (Join-Path $testRoot "input-$($case.name)")
        $input = $publishedInput.jsonPath
        $output = Join-Path $testRoot "reject-$($case.name)"
        $blocked = $false
        try { & $readinessScript -InventoryPath $input -InventoryMarkdownPath $publishedInput.markdownPath -OutputDir $output | Out-Null } catch { $blocked = $true }
        Assert-True $blocked "readiness 未拒绝 invalid inventory：$($case.name)"
        Assert-True (-not (Test-Path -LiteralPath $output)) "invalid inventory 不得创建 OutputDir：$($case.name)"
    }

    $pairFixture = Publish-InventoryFixture -Document (Copy-JsonObject $inventory) -OutputDir (Join-Path $testRoot "input-pair-tampered")
    $tamperedInventoryMarkdown = (Get-Content -LiteralPath $pairFixture.markdownPath -Raw) -replace '(?m)^sourceJsonSha256:\s*[0-9a-f]{64}$', ('sourceJsonSha256: ' + ('f' * 64))
    Set-Content -LiteralPath $pairFixture.markdownPath -Value $tamperedInventoryMarkdown -NoNewline
    $pairRejectOutput = Join-Path $testRoot "reject-pair-tampered"
    New-Item -ItemType Directory -Force -Path $pairRejectOutput | Out-Null
    Set-Content -LiteralPath (Join-Path $pairRejectOutput "readiness.json") -Value "old-json" -NoNewline
    Set-Content -LiteralPath (Join-Path $pairRejectOutput "REPORT.md") -Value "old-markdown" -NoNewline
    $pairBlocked = $false
    try { & $readinessScript -InventoryPath $pairFixture.jsonPath -InventoryMarkdownPath $pairFixture.markdownPath -OutputDir $pairRejectOutput | Out-Null } catch { $pairBlocked = $true }
    Assert-True $pairBlocked "readiness 必须拒绝篡改的 inventory pair"
    Assert-True ((Get-Content -LiteralPath (Join-Path $pairRejectOutput "readiness.json") -Raw) -ceq "old-json") "pair 失败不得覆盖旧 readiness.json"
    Assert-True ((Get-Content -LiteralPath (Join-Path $pairRejectOutput "REPORT.md") -Raw) -ceq "old-markdown") "pair 失败不得覆盖旧 REPORT.md"

    $missingPairOutput = Join-Path $testRoot "reject-pair-missing"
    $missingPairBlocked = $false
    try { & $readinessScript -InventoryPath $inventoryPath -InventoryMarkdownPath (Join-Path $testRoot "missing-REPORT.md") -OutputDir $missingPairOutput | Out-Null } catch { $missingPairBlocked = $true }
    Assert-True $missingPairBlocked "readiness 必须拒绝缺失的 inventory Markdown"
    Assert-True (-not (Test-Path -LiteralPath $missingPairOutput)) "缺失 pair 不得创建输出"

    $mismatchA = Publish-InventoryFixture -Document (Copy-JsonObject $inventory) -OutputDir (Join-Path $testRoot "input-mismatch-a")
    $mismatchB = Publish-InventoryFixture -Document (Copy-JsonObject $inventory) -OutputDir (Join-Path $testRoot "input-mismatch-b")
    $mismatchOutput = Join-Path $testRoot "reject-pair-mismatch"
    $mismatchBlocked = $false
    try { & $readinessScript -InventoryPath $mismatchA.jsonPath -InventoryMarkdownPath $mismatchB.markdownPath -OutputDir $mismatchOutput | Out-Null } catch { $mismatchBlocked = $true }
    Assert-True $mismatchBlocked "readiness 必须拒绝跨 generation 的 inventory pair"
    Assert-True (-not (Test-Path -LiteralPath $mismatchOutput)) "错配 pair 不得创建输出"

    $blockedOutput = "C:\Codex-should-not-be-created"
    $blocked = $false
    try { & $readinessScript -InventoryPath $inventoryPath -OutputDir $blockedOutput | Out-Null } catch { $blocked = $true }
    Assert-True $blocked "更新准备报告脚本没有阻止 C 盘 OutputDir"
    Assert-True (-not (Test-Path -LiteralPath $blockedOutput)) "测试不应在 C 盘创建输出目录"

    New-Item -ItemType Directory -Force -Path $junctionTarget | Out-Null
    New-Item -ItemType Junction -Path $junctionPath -Target $junctionTarget | Out-Null
    $junctionBlocked = $false
    try { & $readinessScript -InventoryPath $inventoryPath -OutputDir (Join-Path $junctionPath "readiness") | Out-Null } catch { $junctionBlocked = $true }
    Assert-True $junctionBlocked "更新准备报告脚本没有阻止穿过 junction 的 OutputDir"
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $junctionTarget "readiness\readiness.json"))) "测试不应通过 junction 写入目标目录"
} finally {
    if (Test-Path -LiteralPath $junctionPath) {
        $item = Get-Item -LiteralPath $junctionPath -Force
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { $item.Delete() }
    }
    if (-not $KeepOutputs -and (Test-Path -LiteralPath $testRoot)) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}

[pscustomobject]@{ ok = $true; readinessJson = $jsonPath; readinessMarkdown = $markdownPath }
