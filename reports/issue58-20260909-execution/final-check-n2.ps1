$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$repo='D:/agents/projects/统一环境';$root=$PSScriptRoot
$psPaths=@((Join-Path $repo 'scripts/lib/CodexSafeTreeDelete.ps1'),(Join-Path $repo 'scripts/lib/CodexSafeTreeDeleteStatusScan.cs'))
$psPaths+=@(Get-ChildItem -LiteralPath $root -Filter '*.ps1' -File -Recurse|ForEach-Object{$_.FullName})
$parseErrors=@()
foreach($path in $psPaths|Where-Object{$_.EndsWith('.ps1',[StringComparison]::OrdinalIgnoreCase)}){$tokens=$null;$errors=$null;[void][Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors);$parseErrors+=@($errors|ForEach-Object{$_.Message})}
$moduleLog=Join-Path $root 'final-module-boundaries.txt';& node (Join-Path $repo 'scripts/Validate-ModuleBoundaries.cjs') *> $moduleLog;$moduleExit=$LASTEXITCODE
$diffLog=Join-Path $root 'final-git-diff-check.txt';& git --no-optional-locks -C $repo diff --check *> $diffLog;$diffExit=$LASTEXITCODE
$source=[IO.File]::ReadAllBytes((Join-Path $repo 'scripts/lib/CodexSafeTreeDeleteStatusScan.cs'));$sourceSha=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($source)).ToLowerInvariant()
$result=[ordered]@{capturedAtUtc=[datetimeoffset]::UtcNow.ToString('o');psParse=@{exitCode=$(if($parseErrors.Count){1}else{0});files=$psPaths.Count;errors=$parseErrors};moduleBoundaries=@{exitCode=$moduleExit;log='final-module-boundaries.txt'};gitDiffCheck=@{exitCode=$diffExit;log='final-git-diff-check.txt'};pooledSource=@{path='scripts/lib/CodexSafeTreeDeleteStatusScan.cs';sha256=$sourceSha;strategy='ArrayPool<byte>.Shared; Return(buffer,true) in nested finally; no pooled experiment switch; no diagnostic counters'};pooledEvidence='pooled-buffer-check-final.json';formalColdRunsStarted=$false;deployStarted=$false}
[IO.File]::WriteAllText((Join-Path $root 'final-check-n2.json'),($result|ConvertTo-Json -Depth 8))
Write-Output "final checks: ps=$($result.psParse.exitCode) module=$moduleExit diff=$diffExit pooledSha=$sourceSha"
if($parseErrors.Count -or $moduleExit -ne 0 -or $diffExit -ne 0){exit 1};exit 0
