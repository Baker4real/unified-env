#requires -Version 7.4
<#
.SYNOPSIS
只读确认同目录 invoke-safe-tree-delete.ps1 支持的 Mode，并由它自己的 Check 判定目标。
.DESCRIPTION
Mode 集合、Plan 是否要求 CapabilityRoot 和结果格式从脚本 AST 读出（shim 委托时读被委托的实现）。
支持 Check 时，放行与否、CapabilityRoot 和拒绝原因原样取自 Check，本脚本不另行解释 policy。
没有 Check 的旧版本只列出 root 包含目标的 policy 条目，作为它自己 Plan 的 -CapabilityRoot 候选；
那时放行与否仍由旧版 Plan 判定，这里报 check-unavailable。不执行 Plan/Apply/Purge。
#>
[CmdletBinding()]
param([Parameter(Mandatory)][string]$TargetPath)
$ErrorActionPreference = 'Stop'
$utf8 = [Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = $utf8
$deleteFull = Join-Path $PSScriptRoot 'invoke-safe-tree-delete.ps1'
$target = [IO.Path]::GetFullPath($TargetPath)
$report = [ordered]@{
    status = 'safe-delete-missing'
    supportedModes = @()
    capabilityRootRequiredByPlan = $null
    resultFormat = $null
    managedRecycleAvailable = Test-Path -LiteralPath (Join-Path $PSScriptRoot 'Invoke-ManagedRecycle.ps1') -PathType Leaf
    decisionSource = $null
    allowedByPolicy = $null
    capabilityRoot = $null
    policyEntryId = $null
    refusalReason = $null
    refusalMessage = $null
    targetPath = $target
}
if (-not (Test-Path -LiteralPath $deleteFull -PathType Leaf)) {
    $report | ConvertTo-Json -Depth 6 -Compress
    exit 1
}
$text = [IO.File]::ReadAllText($deleteFull)
$delegateMatch = [regex]::Match($text, '[A-Za-z]:[\\/][^''\"]*Invoke-CodexSafeTreeDelete\.ps1')
$capabilityFull = $deleteFull
if ($delegateMatch.Success -and (Test-Path -LiteralPath $delegateMatch.Value -PathType Leaf)) { $capabilityFull = $delegateMatch.Value }
$capabilityText = [IO.File]::ReadAllText($capabilityFull)
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($capabilityFull, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) { throw 'Safe-delete script has parse errors' }
$modeParameter = @($ast.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.ParameterAst] -and $node.Name.VariablePath.UserPath -eq 'Mode'
}, $true)) | Select-Object -First 1
if ($modeParameter.Count -eq 1) {
    $validate = @($modeParameter[0].Attributes | Where-Object { $_ -is [System.Management.Automation.Language.AttributeAst] -and $_.TypeName.Name -eq 'ValidateSet' } | Select-Object -First 1)
    if ($validate.Count -eq 1) {
        $report.supportedModes = @($validate[0].PositionalArguments | ForEach-Object {
            if ($_ -is [System.Management.Automation.Language.StringConstantExpressionAst]) { $_.Value } else { $_.Extent.Text.Trim([char[]]@([char]39, [char]34)) }
        })
    }
}
$contractText=$capabilityText
# The production entry delegates validation to the shared dispatcher; inspect that
# adjacent source instead of assuming its parameter declarations are the contract.
$dispatchSource=Join-Path (Split-Path -Parent $capabilityFull) 'lib/CodexSafeTreeDelete.ps1'
if($capabilityText -match '\bInvoke-CodexSafeTreeDeleteMode\b' -and (Test-Path -LiteralPath $dispatchSource -PathType Leaf)){
 $contractText=[IO.File]::ReadAllText($dispatchSource)
}
$report.capabilityRootRequiredByPlan = [regex]::IsMatch($contractText, 'Plan[^\r\n]*TargetPath[^\r\n]*CapabilityRoot')
$report.resultFormat = if ($text -match 'ConvertTo-Json') { 'json' } else { 'powershell-object' }
# These are caller recipes for the discovered supported modes. They grant no deletion authority;
# policy/root decisions still come exclusively from the gate's Check.
$contracts=[ordered]@{}
$knownContracts=@{
 Check=@{requiredParameters=@('TargetPath');confirms=@();writesPayload=$false}
 Plan=@{requiredParameters=@('TargetPath');confirms=@();writesPayload=$false}
 BatchPurge=@{requiredParameters=@('TargetPaths');confirms=@('ConfirmApply','ConfirmPurge');writesPayload=$true}
 Apply=@{requiredParameters=@('PlanPath','ApprovedPlanSha256');confirms=@('ConfirmApply');writesPayload=$true}
 Purge=@{requiredParameters=@('TransactionPath','ApprovedTransactionSha256');confirms=@('ConfirmPurge');writesPayload=$true}
 Archive=@{requiredParameters=@('TransactionPath','ApprovedTransactionSha256');confirms=@('ConfirmArchive');writesPayload=$false}
 Restore=@{requiredParameters=@('TransactionPath','ApprovedTransactionSha256');confirms=@('ConfirmRestore');writesPayload=$true}
 Status=@{requiredParameters=@();confirms=@();writesPayload=$false}
 Lint=@{requiredParameters=@();confirms=@();writesPayload=$false}
}
if($report.capabilityRootRequiredByPlan){$knownContracts.Plan.requiredParameters+=@('CapabilityRoot')}
foreach($mode in $report.supportedModes){if($knownContracts.ContainsKey($mode)){$contracts[$mode]=$knownContracts[$mode]}}
$report.modeContracts=$contracts
$report.batchGroupingKey='policyEntryId'
$report.listArgumentSeparator='::'
$report.hashText='lowercase-hex-sha256'

if ($report.supportedModes -contains 'Check') {
    # 子进程没有控制台时按系统代码页输出；先切到 UTF-8 再调用。路径经环境变量传入，不拼进命令。
    $command = '[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false); & $env:CAPABILITY_SAFE_DELETE -Mode Check -TargetPath $env:CAPABILITY_TARGET; exit $LASTEXITCODE'
    $psi = [Diagnostics.ProcessStartInfo]::new((Join-Path $PSHOME 'pwsh.exe'))
    foreach ($argument in @('-NoProfile', '-NonInteractive', '-Command', $command)) { $psi.ArgumentList.Add($argument) }
    $psi.Environment['CAPABILITY_SAFE_DELETE'] = $deleteFull
    $psi.Environment['CAPABILITY_TARGET'] = $target
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = $utf8
    $psi.StandardErrorEncoding = $utf8
    $process = [Diagnostics.Process]::Start($psi)
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit(60000)) { $process.Kill($true); throw 'Safe-delete Check timed out' }
    $null = $stderr.GetAwaiter().GetResult()
    $line = @($stdout.GetAwaiter().GetResult() -split "`r?`n" | Where-Object { $_.Trim() }) | Select-Object -Last 1
    $check = $null
    try { $check = $line | ConvertFrom-Json -ErrorAction Stop } catch { $check = $null }
    if ($process.ExitCode -ne 0 -or $null -eq $check -or @($check.results).Count -ne 1) { throw "Safe-delete Check returned no usable result (exit $($process.ExitCode))" }
    $decision = @($check.results)[0]
    $report.decisionSource = 'safe-delete-check'
    $report.allowedByPolicy = [bool]$decision.allowed
    $report.capabilityRoot = $decision.capabilityRoot
    $report.policyEntryId = $decision.policyEntryId
    $report.refusalReason = $decision.refusalReason
    $report.refusalMessage = $decision.refusalMessage
    $report.status = if ($report.allowedByPolicy) { 'ok' } else { 'refused' }
} else {
    $report.status = 'check-unavailable'
    $report.decisionSource = 'policy-candidates-only'
    $report.capabilityRootCandidates = $null
    if ($delegateMatch.Success) {
        $policyPath = Join-Path (Split-Path -Parent (Split-Path -Parent $delegateMatch.Value)) 'managed/safe-tree-delete/policy.json'
        if (Test-Path -LiteralPath $policyPath -PathType Leaf) {
            $policy = Get-Content -LiteralPath $policyPath -Raw -Encoding utf8 | ConvertFrom-Json
            $report.capabilityRootCandidates = @(foreach ($policyEntry in @($policy.entries)) {
                $root = [IO.Path]::GetFullPath([string]$policyEntry.capabilityRoot).TrimEnd([char[]]@([char]92, [char]47))
                if ($target.Equals($root, [StringComparison]::OrdinalIgnoreCase) -or $target.StartsWith($root + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { $root }
            })
        }
    }
}
$report | ConvertTo-Json -Depth 6 -Compress
if ($report.status -ne 'ok') { exit 1 }
