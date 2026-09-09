$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
$repo='D:/agents/projects/统一环境';Add-Type -Path (Join-Path $repo 'scripts/lib/CodexSafeTreeDeleteStatusScan.cs')
$root=Join-Path $repo ('.scratch/safe-tree-delete-tests-issue58-buffer-'+[guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($root)
$sizes=@(0,1,1048575,1048576,1048593,2097165);$expected=@{}
foreach($size in $sizes){$path=Join-Path $root ("{0}.bin" -f $size);$bytes=[byte[]]::new($size);for($i=0;$i -lt $size;$i++){$bytes[$i]=[byte](($i*31+7)%251)};[IO.File]::WriteAllBytes($path,$bytes);$expected[(Split-Path $path -Leaf)]=(Get-FileHash -LiteralPath $path).Hash.ToLowerInvariant()}
for($fileIndex=0;$fileIndex -lt 12;$fileIndex++){$path=Join-Path $root ("concurrent-{0}.bin" -f $fileIndex);$size=1048576+$fileIndex*17;$bytes=[byte[]]::new($size);for($i=0;$i -lt $size;$i++){$bytes[$i]=[byte](($i*13+$fileIndex*19)%251)};[IO.File]::WriteAllBytes($path,$bytes);$expected[(Split-Path $path -Leaf)]=(Get-FileHash -LiteralPath $path).Hash.ToLowerInvariant()}
$scan=[CodexSafeTreeDelete.StatusTreeSnapshotScanner]::Scan($root,$false,$false,$null)
$type=[CodexSafeTreeDelete.StatusTreeSnapshotScanner]
$pass=$scan.Entries.Count -eq 19
$rows=@(foreach($entry in $scan.Entries|Where-Object{$_.RelativePath -ne '.'}){$name=[IO.Path]::GetFileName($entry.RelativePath);@{name=$name;sha256=$entry.Sha256;matches=$entry.Sha256 -ceq $expected[$name]}})
$pass=$pass -and @($rows|Where-Object{-not $_.matches}).Count -eq 0
$validStream=[IO.File]::OpenRead((Join-Path $root '1.bin'));$invalid=$validStream.SafeFileHandle;$validStream.Dispose();$method=[CodexSafeTreeDelete.StatusTreeSnapshotScanner].GetMethod('HashHandleContents',[Reflection.BindingFlags]'NonPublic,Static');$threw=$false;try{[void]$method.Invoke($null,@($invalid))}catch{$threw=$true}finally{$invalid.Dispose()}
$source=Get-Content -LiteralPath (Join-Path $repo 'scripts/lib/CodexSafeTreeDeleteStatusScan.cs') -Raw;$clearSource=$source.Contains('ArrayPool<byte>.Shared.Return(buffer, true)')
$pass=$pass -and $threw -and $clearSource
[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'pooled-buffer-check-final.json'),(@{passed=$pass;sizes=$sizes;concurrentFiles=12;entries=$scan.Entries.Count;rows=$rows;exceptionThrown=$threw;returnedOnExceptionDynamicObserved=$false;clearArraySource=$clearSource;errorFinally='HashHandleContents has hasher creation and read in try; ArrayPool Return(buffer, clearArray:true) in nested finally.'}|ConvertTo-Json -Depth 8))
Write-Output "pooled buffer boundary check: passed=$pass"
if(-not $pass){exit 1};exit 0
