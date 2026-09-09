[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Payload,
    [string[]]$PayloadArguments=@(),
    [Parameter(Mandatory)][ValidatePattern('^[a-z0-9-]+$')][string]$Name,
    [ValidateRange(500,600000)][int]$DeadlineMs=180000,
    [ValidateSet('Status','Fingerprint')][string]$Contract='Status',
    [switch]$SimulateMissingOsObservation
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
if (-not ('Issue58N1.TaskJob' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'ProcessObservation.cs') }
$pwsh='D:\Codex\tools\PowerShell\7.6.5\pwsh.exe'
$runRoot=Join-Path $PSScriptRoot $Name
if (Test-Path -LiteralPath $runRoot) { throw '运行输出目录已存在，拒绝覆盖。' }
[void][IO.Directory]::CreateDirectory($runRoot)
$receipts=Join-Path $runRoot 'identity'
[void][IO.Directory]::CreateDirectory($receipts)
$token=[Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(32))
$tokenHash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($token))).ToLowerInvariant()
$psi=[Diagnostics.ProcessStartInfo]::new()
$psi.FileName=$pwsh
$psi.WorkingDirectory='D:\agents\projects\统一环境'
$psi.UseShellExecute=$false
$psi.CreateNoWindow=$true
$psi.RedirectStandardInput=$true
$psi.RedirectStandardOutput=$true
$psi.RedirectStandardError=$true
$psi.Environment['ISSUE58_OWNER_TOKEN']=$token
$psi.Environment['ISSUE58_PARENT_PID']=[string]$PID
$psi.Environment['ISSUE58_RECEIPT_ROOT']=$receipts
$psi.Environment['ISSUE58_RUN_ROOT']=$runRoot
foreach($arg in @('-NoLogo','-NoProfile','-File',(Join-Path $PSScriptRoot 'child-gate.ps1'),'-Payload',$Payload)+$(if($PayloadArguments.Count){@('-PayloadArguments')+$PayloadArguments}else{@()})) { [void]$psi.ArgumentList.Add($arg) }
$record=[ordered]@{
    artifactType='issue58.n1-bounded-process';ownerTokenSha256=$tokenHash;tokenIssuedAtUtc=[datetimeoffset]::UtcNow.ToString('o')
    lifetime='task-scoped';tokenChannel='child-process-environment';status='running';processState='not-started'
    launchIntent=@{executable=$pwsh;arguments=@($psi.ArgumentList);cwd=$psi.WorkingDirectory;readiness='token/PID/starttime/exe/hash/parent receipt';readinessTimeoutMs=10000;expectedExitCode=0;deadlineMs=$DeadlineMs}
    processId=$null;osStartTimeUtc=$null;osExecutable=$null;osParentProcessId=$null;osObservation='unverified';identityVerified=$false
    childReceipt=$null;exitCode=$null;timedOut=$false;elapsedMs=$null;completedBeforeDeadline=$false;completionObservedMs=$null;cleanupMs=$null;jobEmpty=$false;residualPids=@()
    parseSucceeded=$false;complete=$null;operationCount=$null;error=$null;stdout='stdout.json';stderr='stderr.txt';cleanupIdentities=@();unverifiedMembers=@()
}
[IO.File]::WriteAllText((Join-Path $runRoot 'launch.json'),($record|ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false))
$process=[Diagnostics.Process]::new();$process.StartInfo=$psi
$job=[Issue58N1.TaskJob]::new()
$watch=[Diagnostics.Stopwatch]::StartNew()
$started=$false;$assigned=$false;$outTask=$null;$errTask=$null;$outFile=$null;$errFile=$null
$cancel=[Threading.CancellationTokenSource]::new()
function Test-OwnedProcess([Diagnostics.Process]$p) {
    $Id=$p.Id
    $receiptPath=Join-Path $receipts "$Id.json"
    if(-not [IO.File]::Exists($receiptPath)){return $false}
    $r=ConvertFrom-Json ([IO.File]::ReadAllText($receiptPath)) -AsHashtable -DateKind String
    return ($r.tokenSha256 -ceq $tokenHash -and $r.processId -eq $Id -and
        $r.parentProcessId -eq [Issue58N1.TaskJob]::Parent($p) -and
        [datetimeoffset]::Parse($r.startTimeUtc).UtcDateTime -eq $p.StartTime.ToUniversalTime() -and
        $r.executable -ieq [Issue58N1.TaskJob]::Image($p) -and
        $r.executableSha256 -ceq (Get-FileHash -LiteralPath $r.executable).Hash.ToLowerInvariant())
}
try {
    $started=$process.Start()
    if(-not $started){throw '子进程未启动。'}
    $record.processId=$process.Id
    $record.osStartTimeUtc=$process.StartTime.ToUniversalTime().ToString('o')
    $outFile=[IO.File]::Open((Join-Path $runRoot 'stdout.json'),[IO.FileMode]::CreateNew)
    $errFile=[IO.File]::Open((Join-Path $runRoot 'stderr.txt'),[IO.FileMode]::CreateNew)
    $outTask=$process.StandardOutput.BaseStream.CopyToAsync($outFile,$cancel.Token)
    $errTask=$process.StandardError.BaseStream.CopyToAsync($errFile,$cancel.Token)
    $ready=Join-Path $receipts "$($process.Id).json"
    while(-not [IO.File]::Exists($ready) -and -not $process.HasExited -and $watch.ElapsedMilliseconds -lt [Math]::Min(10000,$DeadlineMs)){Start-Sleep -Milliseconds 20}
    if(-not [IO.File]::Exists($ready)){throw '子进程 readiness 回报缺失。'}
    $record.childReceipt=ConvertFrom-Json ([IO.File]::ReadAllText($ready)) -AsHashtable -DateKind String
    $record.identityVerified=(Test-OwnedProcess $process) -and $record.childReceipt.parentProcessId -eq $PID
    if(-not $record.identityVerified){throw '子进程 owner token 或身份绑定不匹配。'}
    if(-not $SimulateMissingOsObservation){$record.osExecutable=[Issue58N1.TaskJob]::Image($process);$record.osParentProcessId=[Issue58N1.TaskJob]::Parent($process);$record.osObservation='verified'}
    $job.Assign($process);$assigned=$true
    $process.StandardInput.WriteLine('GO');$process.StandardInput.Flush()
    $record.processState='running'
    while($watch.ElapsedMilliseconds -lt $DeadlineMs){
        if($process.HasExited -and $outTask.IsCompleted -and $errTask.IsCompleted -and $job.Pids().Length -eq 0){
            $record.completionObservedMs=$watch.ElapsedMilliseconds
            $record.completedBeforeDeadline=$record.completionObservedMs -lt $DeadlineMs
            break
        }
        if($watch.ElapsedMilliseconds -ge $DeadlineMs-100 -and -not $process.HasExited){$process.StandardInput.Close()}
        Start-Sleep -Milliseconds 20
    }
    $record.timedOut=-not $record.completedBeforeDeadline
    if(-not $record.timedOut){[void]$outTask.GetAwaiter().GetResult();[void]$errTask.GetAwaiter().GetResult()}
} catch {$record.error=$_.Exception.Message} finally {
    $record.elapsedMs=$watch.ElapsedMilliseconds
    if($record.elapsedMs -ge $DeadlineMs){$record.timedOut=$true}
    $cancel.Cancel()
    $cleanup=[Diagnostics.Stopwatch]::StartNew()
    try {
        if($started){
            try{$process.StandardInput.Close()}catch{}
            if($assigned){
                $ids=@($job.Pids())
                foreach($id in $ids){
                    $member=Get-Process -Id $id -ErrorAction SilentlyContinue
                    if($null -eq $member){continue}
                    try {
                        $owned=Test-OwnedProcess $member
                        $record.cleanupIdentities+=@{processId=$id;startTimeUtc=$member.StartTime.ToUniversalTime().ToString('o');verified=$owned}
                        if(-not $owned){$record.unverifiedMembers+=@{processId=$id;startTimeUtc=$member.StartTime.ToUniversalTime().ToString('o');action='未控制；需人工复核'}}
                        if($owned -and -not $member.HasExited){$member.Kill()}
                    } catch {if(-not $member.HasExited){throw}} finally {$member.Dispose()}
                }
                while($job.Pids().Length -gt 0 -and $cleanup.ElapsedMilliseconds -lt 3000){Start-Sleep -Milliseconds 20}
                $record.residualPids=@($job.Pids());$record.jobEmpty=$record.residualPids.Count -eq 0
            }else{
                [void]$process.WaitForExit(11000)
                $record.jobEmpty=$process.HasExited
            }
            if($process.HasExited){$record.exitCode=[int]$process.ExitCode;$record.processState='exited'}
            if($null -ne $outTask -and $null -ne $errTask){
                try{[void][Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]@($outTask,$errTask),1000)}catch{if(-not $record.timedOut -and $null -eq $record.error){throw}}
            }
        }
    }catch{$record.error=([string]$record.error+'; 收口: '+$_.Exception.Message)}
    $record.cleanupMs=$cleanup.ElapsedMilliseconds
    if($null -ne $outFile){$outFile.Dispose()};if($null -ne $errFile){$errFile.Dispose()}
    $job.Dispose();$process.Dispose();$cancel.Dispose()
}
try {
    if(-not $record.timedOut -and $record.exitCode -eq 0 -and $null -eq $record.error){
        $parsed=ConvertFrom-Json ([IO.File]::ReadAllText((Join-Path $runRoot 'stdout.json'))) -AsHashtable -Depth 128 -DateKind String
        if($Contract -eq 'Fingerprint'){
            $record.parseSucceeded=$parsed.artifactType -ceq 'issue58.n1-evidence-fingerprint' -and $null -ne $parsed.evidence -and $null -ne $parsed.policy
        }else{
            $record.parseSucceeded=($parsed.artifactType -ceq 'env-governance.codex-safe-tree-delete-status' -and $parsed.schemaVersion -eq 1 -and $parsed.operations -is [array] -and $parsed.complete -is [bool])
            if($record.parseSucceeded){$record.complete=$parsed.complete;$record.operationCount=$parsed.operations.Count}
        }
    }
}catch{$record.error='JSON: '+$_.Exception.Message}
$pass=$record.identityVerified -and $record.osObservation -ceq 'verified' -and $record.jobEmpty -and $record.unverifiedMembers.Count -eq 0 -and -not $record.timedOut -and $record.exitCode -eq 0 -and $record.parseSucceeded -and $null -eq $record.error
$record.status=if($pass){'complete'}elseif(-not $record.jobEmpty -or -not $record.identityVerified -or $record.osObservation -cne 'verified' -or $record.unverifiedMembers.Count -gt 0){'manual-review'}else{'failed'}
$record.wrapperExitCode=if($pass){0}else{1}
[IO.File]::WriteAllText((Join-Path $runRoot 'result.json'),($record|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
Write-Output "$Name wrapperExit=$($record.wrapperExitCode) childExit=$($record.exitCode) timedOut=$($record.timedOut) jobEmpty=$($record.jobEmpty) parse=$($record.parseSucceeded)"
exit $record.wrapperExitCode
