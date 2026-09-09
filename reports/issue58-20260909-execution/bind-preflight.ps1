param([string]$Name='preflight-bindings-v2.json')
$ErrorActionPreference='Stop'
$names=@('invoke-bounded.ps1','child-gate.ps1','ProcessObservation.cs','prepare-runtime.ps1','diagnostic-payload.ps1','fingerprint-payload.ps1','run-n1.ps1')
$rows=@($names|ForEach-Object{ $item=Get-Item -LiteralPath (Join-Path $PSScriptRoot $_); @{name=$_;length=$item.Length;sha256=(Get-FileHash -LiteralPath $item.FullName).Hash.ToLowerInvariant()} })
$state=@{capturedAtUtc=[datetimeoffset]::UtcNow.ToString('o');phase='before 指纹进行中；真实 Status 尚未启动';files=$rows;syntheticChecksSha256=(Get-FileHash -LiteralPath (Join-Path $PSScriptRoot 'synthetic-checks-v2.json')).Hash.ToLowerInvariant()}
$stream=[IO.File]::Open((Join-Path $PSScriptRoot $Name),[IO.FileMode]::CreateNew)
try{$stream.Write([Text.Encoding]::UTF8.GetBytes(($state|ConvertTo-Json -Depth 6)))}finally{$stream.Dispose()}
Write-Output "诊断执行绑定已保存: $($rows.Count) 文件原字节 SHA-256"
