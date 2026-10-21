[CmdletBinding()]
param([string]$FixtureRoot = 'D:/agents/run-evidence/quiet-window-fixtures')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

# scripts\Get-CodexSafeTreeDeleteQuietWindow.ps1 逐条判定安静窗口的四个条件。检查一律带测试 seam，
# 不读生产状态根与生产 mutex。夹具 state root 与 git 仓库建一次后复用，各场景只增删单个文件，
# 不递归删除。
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$checkScript = Join-Path $projectRoot 'scripts\Get-CodexSafeTreeDeleteQuietWindow.ps1'
$pwsh = Join-Path $PSHOME 'pwsh.exe'
$utf8 = [Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = $utf8
. (Join-Path $projectRoot 'scripts\lib\CodexSafeTreeDeleteGateHolder.ps1')

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Remove-FileIfPresent([string]$Path) {
    if ([IO.File]::Exists($Path)) { [IO.File]::Delete($Path) }
}

$FixtureRoot = [IO.Path]::GetFullPath($FixtureRoot)
$stateRoot = Join-Path $FixtureRoot 'state'
$repo = Join-Path $FixtureRoot 'repo'
$mutexName = 'Local\CodexQuietWindowTest-{0}' -f [guid]::NewGuid().ToString('N')
[void][IO.Directory]::CreateDirectory($stateRoot)
if (-not (Test-Path -LiteralPath (Join-Path $repo '.git'))) {
    [void][IO.Directory]::CreateDirectory($repo)
    git -C $repo init -q -b main
    git -C $repo config core.autocrlf false
    [IO.File]::WriteAllText((Join-Path $repo 'tracked.txt'), "base`n", $utf8)
    git -C $repo add -- tracked.txt
    git -C $repo -c user.name=probe -c user.email=1+probe@users.noreply.github.com commit -q -m init
    Assert-True ($LASTEXITCODE -eq 0) '夹具仓库初始提交失败。'
}
$gitDirectory = @(git -C $repo rev-parse --absolute-git-dir)
Assert-True ($LASTEXITCODE -eq 0 -and $gitDirectory.Count -eq 1) '读不到夹具仓库的 git 目录。'
$markerPath = Join-Path $stateRoot 'maintenance.json'
$holderPath = Get-CodexSafeTreeDeleteGateHolderPath -StateRoot $stateRoot
$trackedPath = Join-Path $repo 'tracked.txt'
$untrackedPath = Join-Path $repo 'untracked.txt'
$indexLockPath = Join-Path ([string]$gitDirectory[0]) 'index.lock'
$seamArguments = @('-RepositoryRoot', $repo, '-StateRootForTest', $stateRoot, '-MutexNameForTest', $mutexName)

function Reset-Fixture {
    foreach ($path in @($markerPath, $holderPath, $untrackedPath, $indexLockPath)) { Remove-FileIfPresent $path }
    git -C $repo checkout -q -- tracked.txt
    Assert-True ($LASTEXITCODE -eq 0) '夹具仓库还原失败。'
}

function Invoke-Check([string[]]$Arguments = $seamArguments, [string]$Command) {
    # 给了 Command 时，由一个 pwsh -Command 父进程去运行检查。
    if ([string]::IsNullOrEmpty($Command)) {
        $output = @(& $pwsh -NoProfile -NonInteractive -File $checkScript @Arguments 2>&1)
    } else {
        $output = @(& $pwsh -NoProfile -NonInteractive -Command $Command 2>&1)
    }
    $exitCode = $LASTEXITCODE
    $lines = @($output | Where-Object { $_ -isnot [Management.Automation.ErrorRecord] } | ForEach-Object { [string]$_ })
    Assert-True ($lines.Count -eq 1) ('检查应只输出一行 JSON：{0}' -f ($output -join ' | '))
    return [pscustomobject]@{ exitCode = $exitCode; result = ($lines[0] | ConvertFrom-Json -AsHashtable); text = $lines[0] }
}

function Get-ConditionOk($Check, [string]$Name) {
    $condition = @($Check.result['conditions'] | Where-Object { $_['name'] -eq $Name })
    Assert-True ($condition.Count -eq 1) ('缺少条件 {0}：{1}' -f $Name, $Check.text)
    return $condition[0]['ok']
}

function Assert-Quiet($Check, [string]$Scenario) {
    Assert-True ($Check.exitCode -eq 0 -and $Check.result['quiet'] -eq $true) ('{0}：应判定安静（exit {1}）：{2}' -f $Scenario, $Check.exitCode, $Check.text)
    Assert-True (@($Check.result['conditions']).Count -eq 4) ('{0}：应报告四个条件：{1}' -f $Scenario, $Check.text)
}

function Assert-OnlyFailing($Check, [string]$Name, [string]$Scenario) {
    Assert-True ($Check.exitCode -eq 1 -and $Check.result['quiet'] -eq $false) ('{0}：应判定不安静并以 1 退出（exit {1}）：{2}' -f $Scenario, $Check.exitCode, $Check.text)
    Assert-True ((Get-ConditionOk $Check $Name) -eq $false) ('{0}：{1} 应为 false：{2}' -f $Scenario, $Name, $Check.text)
    $others = @($Check.result['conditions'] | Where-Object { $_['name'] -ne $Name -and $_['ok'] -ne $true })
    Assert-True ($others.Count -eq 0) ('{0}：只有 {1} 应失败：{2}' -f $Scenario, $Name, $Check.text)
}

function Start-MarkerProcess([string]$CommentText) {
    # 命令行带标记文本但只是 sleep；pwsh 把 # 之后当注释。
    $startInfo = [Diagnostics.ProcessStartInfo]::new($pwsh)
    foreach ($argument in @('-NoProfile', '-NonInteractive', '-Command', ('Start-Sleep -Seconds 120 # ' + $CommentText))) {
        $startInfo.ArgumentList.Add($argument)
    }
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    return [Diagnostics.Process]::Start($startInfo)
}

function Stop-MarkerProcess($Process) {
    if ($null -ne $Process -and -not $Process.HasExited) {
        $Process.Kill()
        [void]$Process.WaitForExit(10000)
    }
}

function Get-AncestorFunctionText([string]$Path) {
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    Assert-True ($errors.Count -eq 0) ('{0} 解析失败。' -f $Path)
    $function = $ast.Find({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Get-ProcessAncestorIds'
    }, $true)
    Assert-True ($null -ne $function) ('{0} 缺少 Get-ProcessAncestorIds。' -f $Path)
    return ($function.Extent.Text -replace "`r`n", "`n")
}

# 祖先链上溯与部署工具的 legacy drain 是同一份逻辑：这里只核对两份逐字一致，
# PID 复用与父链成环的行为由 Test-CodexSafeTreeDeleteDeployment.ps1 的 S12 覆盖。
$deployTool = Join-Path $projectRoot 'scripts\Deploy-CodexSafeTreeDelete.ps1'
Assert-True ((Get-AncestorFunctionText $checkScript) -ceq (Get-AncestorFunctionText $deployTool)) '安静窗口检查与部署工具的 Get-ProcessAncestorIds 不一致。'

$blocker = $null
$outsider = $null
Reset-Fixture
try {
    Assert-Quiet (Invoke-Check) '基线'

    $mutex = [Threading.Mutex]::new($false, $mutexName)
    try {
        Assert-OnlyFailing (Invoke-Check) 'gate-idle' 'deployment mutex 存在'
    } finally {
        $mutex.Dispose()
    }
    Assert-Quiet (Invoke-Check) 'mutex 关闭后'

    Assert-True (Write-CodexSafeTreeDeleteGateHolder -StateRoot $stateRoot -Mode 'Apply') '写面包屑失败。'
    Assert-OnlyFailing (Invoke-Check) 'gate-idle' '面包屑描述存活进程'
    # 同一 PID、启动时间不符：stale，不阻止。
    $staleHolder = '{"pid":' + $PID + ',"processStartUtc":"2000-01-01T00:00:00.0000000Z","mode":"Apply","acquiredAtUtc":"2000-01-01T00:00:00.0000000Z"}'
    [IO.File]::WriteAllText($holderPath, $staleHolder, [Text.Encoding]::ASCII)
    Assert-Quiet (Invoke-Check) 'stale 面包屑'
    Remove-FileIfPresent $holderPath

    [IO.File]::WriteAllText($markerPath, '{}', [Text.Encoding]::ASCII)
    Assert-OnlyFailing (Invoke-Check) 'no-maintenance-marker' 'maintenance marker 在场'
    Remove-FileIfPresent $markerPath

    $blocker = Start-MarkerProcess ('Run-PowerShellTests.cjs ' + $stateRoot)
    $check = Invoke-Check
    Assert-OnlyFailing $check 'no-managed-delete-or-test-runner-process' '测试 runner 进程'
    $processes = @(@($check.result['conditions'] | Where-Object { $_['name'] -eq 'no-managed-delete-or-test-runner-process' })[0]['detail']['processes'])
    Assert-True ($processes.Count -eq 1 -and $processes[0]['processId'] -eq $blocker.Id -and $processes[0]['marker'] -eq 'Run-PowerShellTests.cjs') ('应只报出这个 runner 进程：{0}' -f $check.text)
    Assert-True (-not $check.text.Contains('Start-Sleep')) '输出不应回显命令行。'
    Stop-MarkerProcess $blocker
    Assert-Quiet (Invoke-Check) 'runner 进程退出后'

    # 测试 seam 生效时，命令行不含 fixture state root 的入口进程不计（同部署工具 #93 的 drain 范围）。
    $outsider = Start-MarkerProcess 'Invoke-CodexSafeTreeDelete.ps1 -Mode Status'
    Assert-Quiet (Invoke-Check) '范围外的入口进程'
    Stop-MarkerProcess $outsider

    # 检查进程自身及祖先链不计：父进程命令行带标记与 fixture state root，检查仍应判定安静。
    $nested = '& ''{0}'' -NoProfile -NonInteractive -File ''{1}'' -RepositoryRoot ''{2}'' -StateRootForTest ''{3}'' -MutexNameForTest ''{4}''; exit $LASTEXITCODE # Run-PowerShellTests.cjs {3}' -f @(
        $pwsh, $checkScript, $repo, $stateRoot, $mutexName)
    Assert-Quiet (Invoke-Check -Command $nested) '祖先链里带标记的父进程'

    [IO.File]::WriteAllText($trackedPath, "changed`n", $utf8)
    Assert-OnlyFailing (Invoke-Check) 'main-tree-clean' '已跟踪文件被修改'
    Reset-Fixture
    [IO.File]::WriteAllText($untrackedPath, "probe`n", $utf8)
    Assert-OnlyFailing (Invoke-Check) 'main-tree-clean' '未跟踪文件'
    Reset-Fixture
    [IO.File]::WriteAllText($indexLockPath, '', [Text.Encoding]::ASCII)
    Assert-OnlyFailing (Invoke-Check) 'main-tree-clean' 'index.lock 在场'
    Reset-Fixture
    Assert-Quiet (Invoke-Check) '工作树还原后'

    # 被检查的目录不在任何 git 仓库里：条件无法判定，退出 2。
    $previousCeiling = $env:GIT_CEILING_DIRECTORIES
    $env:GIT_CEILING_DIRECTORIES = $FixtureRoot
    try {
        $check = Invoke-Check @('-RepositoryRoot', $stateRoot, '-StateRootForTest', $stateRoot, '-MutexNameForTest', $mutexName)
    } finally {
        $env:GIT_CEILING_DIRECTORIES = $previousCeiling
    }
    Assert-True ($check.exitCode -eq 2 -and $check.result['quiet'] -eq $false) ('非 git 目录应以 2 退出：{0}' -f $check.text)
    Assert-True ($null -eq (Get-ConditionOk $check 'main-tree-clean')) ('非 git 目录时 main-tree-clean 应为 null：{0}' -f $check.text)

    $check = Invoke-Check @('-RepositoryRoot', $repo, '-StateRootForTest', $stateRoot)
    Assert-True ($check.exitCode -eq 2 -and $check.result['quiet'] -eq $false) ('测试 seam 只给一半时应以 2 退出：{0}' -f $check.text)
} finally {
    Stop-MarkerProcess $blocker
    Stop-MarkerProcess $outsider
    Reset-Fixture
}

'quiet window check: all checks passed'
