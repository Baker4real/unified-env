# gh 调用的共用实现，供 scripts\Publish-GitHubIssueComment.ps1、scripts\Invoke-GhRead.ps1 和
# scripts\Get-CiFailureSummary.ps1 点源。gh 偶发 EOF 时的处理规则见 docs/agents/issue-tracker.md「gh 报 EOF 时」。
# 调用方先把 [Console]::OutputEncoding 设成 UTF-8，gh 输出里的中文才能正确解码。

# 运行一次 gh，不重试。$GhCommand 是可执行文件加前置参数，生产调用是 @('gh')。
function Invoke-Gh([string[]]$GhCommand, [string[]]$Arguments) {
    # 退出码由调用方判断，非零退出不能变成异常。
    $PSNativeCommandUseErrorActionPreference = $false
    $prefix = @($GhCommand | Select-Object -Skip 1)
    $output = @(& $GhCommand[0] @prefix @Arguments 2>&1)
    $exitCode = $LASTEXITCODE
    return [pscustomobject]@{
        exitCode = $exitCode
        stdout = @($output | Where-Object { $_ -isnot [Management.Automation.ErrorRecord] } | ForEach-Object { [string]$_ })
        stderr = (@($output | Where-Object { $_ -is [Management.Automation.ErrorRecord] } | ForEach-Object { $_.ToString() }) -join ' ')
    }
}

# 只用于读取和幂等写入（如加标签）：非零退出就等 2、4、6 秒再试，共 $AttemptLimit 次。
# 用完仍失败就抛出，不拿空结果做判断。
function Invoke-GhWithRetry([string[]]$GhCommand, [string[]]$Arguments, [int]$AttemptLimit = 4, [switch]$NoRetryDelay) {
    for ($attempt = 1; ; $attempt++) {
        $result = Invoke-Gh -GhCommand $GhCommand -Arguments $Arguments
        if ($result.exitCode -eq 0) { return $result.stdout }
        if ($attempt -ge $AttemptLimit) {
            throw ('gh {0} failed after {1} attempts (exit {2}): {3}' -f ($Arguments -join ' '), $attempt, $result.exitCode, $result.stderr)
        }
        if (-not $NoRetryDelay) { Start-Sleep -Seconds (2 * $attempt) }
    }
}
