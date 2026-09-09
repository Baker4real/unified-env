$repo='D:/agents/projects/统一环境'
# Refuse an implicit production cache compile. The edited scanner is loaded only in memory.
. (Join-Path $repo 'scripts/lib/CodexHostSafetyNativeLoader.ps1')
$variant=Get-CodexHostSafetyNativeRequestedVariant
$sources=Get-CodexHostSafetyNativeSourceSet -Variant $variant
$composite=Get-CodexHostSafetyNativeCompileCompositeSha256 -Sources $sources -Variant $variant
$generation=Join-Path (Join-Path (Get-CodexHostSafetyNativeProductionRoot) $variant) $composite
if(-not (Test-CodexHostSafetyNativeGenerationValid -GenerationDirectory $generation -ExpectedCompositeSha256 $composite -ExpectedVariant $variant)){
    throw '现有 native generation 无效；本次拒绝写入生产缓存。'
}
Add-Type -Path (Join-Path $repo 'scripts/lib/CodexSafeTreeDeleteStatusScan.cs')
