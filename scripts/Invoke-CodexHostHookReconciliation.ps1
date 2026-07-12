[CmdletBinding()]
param(
    [ValidateSet("Check", "Repair")]
    [string]$Mode = "Check",
    [string]$CodexHome = $env:CODEX_HOME,
    [switch]$Json
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
$script:CurrentEvidencePath = $null
$script:FixtureConcurrentReplacePath = $null
$script:FixtureConcurrentReplaceKind = "content"
$script:FixtureConcurrentReplaceRemaining = 0
$script:FixtureCasFailureMode = $null
$script:FixturePostCommitFailurePhase = $null

$script:LegacyHookNames = @(
    "codex-mobile-permission-guard.py",
    "codex-projectless-root-d.cmd",
    "codex-projectless-root-d.js",
    "codex-provider-stability-guard.cmd",
    "codex-provider-stability-guard.ps1",
    "serena-activate-guarded.cmd",
    "serena-activate-guarded.ps1",
    "serena-dashboard-guard.cmd",
    "serena-dashboard-guard.ps1",
    "__pycache__\codex-mobile-permission-guard.cpython-313.pyc"
)
$script:LegacyHookDirectoryNames = @("__pycache__")
$script:TomlKeyPattern = '(?:[A-Za-z0-9_-]+|"(?:\\.|[^"\\])*"|''[^'']*'')'

function Get-Sha256 {
    param([string]$Path)

    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

function Get-TextSha256 {
    param([string]$Content)

    $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($Content)
    [System.Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($bytes))
}

function Test-IsLegacyHookRelativePath {
    param([string]$RelativePath)

    $normalized = $RelativePath.Replace('/', '\')
    if (@($script:LegacyHookNames | Where-Object { $_.Equals($normalized, [System.StringComparison]::OrdinalIgnoreCase) }).Count -gt 0) {
        return $true
    }
    foreach ($directoryName in $script:LegacyHookDirectoryNames) {
        if ($normalized.Equals($directoryName, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }
    $false
}

function Get-PreservedHookTreeInventory {
    param(
        [string]$HookDirectory,
        [object[]]$HookTree
    )

    @($HookTree | ForEach-Object {
        $relativePath = [System.IO.Path]::GetRelativePath($HookDirectory, $_.FullName).Replace('/', '\')
        if (Test-IsLegacyHookRelativePath -RelativePath $relativePath) {
            return
        }
        [pscustomobject]@{
            path = $relativePath
            kind = if ($_.PSIsContainer) { "directory" } else { "file" }
            sha256 = if ($_.PSIsContainer) { $null } else { Get-Sha256 -Path $_.FullName }
        }
    } | Sort-Object path)
}

function Get-RepairMutexName {
    param([string]$ResolvedCodexHome)

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($ResolvedCodexHome.ToLowerInvariant())
    $hash = [System.Security.Cryptography.SHA256]::HashData($bytes)
    $suffix = ([System.Convert]::ToHexString($hash)).Substring(0, 24)
    "Local\CodexHostHookReconciliation-$suffix"
}

function Assert-NoReparsePath {
    param(
        [string]$Path,
        [switch]$RequireLeaf
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $root = [System.IO.Path]::GetPathRoot($fullPath)
    if (-not $root.Equals("D:\", [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "路径必须位于 D 盘：$fullPath"
    }

    $current = $root
    $relative = $fullPath.Substring($root.Length)
    foreach ($segment in @($relative -split '[\\/]' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
        $current = Join-Path $current $segment
        if (-not (Test-Path -LiteralPath $current)) {
            continue
        }

        $item = Get-Item -LiteralPath $current -Force
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "路径不得穿过 reparse point：$current"
        }
        if (-not $item.PSIsContainer -and $item.LinkType -eq "HardLink") {
            throw "文件不得是 hard link：$current"
        }
    }

    if ($RequireLeaf -and -not (Test-Path -LiteralPath $fullPath)) {
        throw "路径不存在：$fullPath"
    }

    $fullPath
}

function Resolve-CodexHome {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        $Value = "D:\Codex\.codex"
    }
    if (-not [System.IO.Path]::IsPathFullyQualified($Value)) {
        throw "CodexHome 必须是绝对路径：$Value"
    }

    $fullPath = Assert-NoReparsePath -Path $Value -RequireLeaf
    if (-not (Test-Path -LiteralPath $fullPath -PathType Container)) {
        throw "CodexHome 必须是目录：$fullPath"
    }

    foreach ($relative in @("config.toml", "hooks.json", "hooks")) {
        $requiredPath = Join-Path $fullPath $relative
        if (-not (Test-Path -LiteralPath $requiredPath)) {
            throw "CodexHome 缺少必要路径：$requiredPath"
        }
        Assert-NoReparsePath -Path $requiredPath -RequireLeaf | Out-Null
    }

    $fullPath.TrimEnd("\", "/")
}

function Assert-RepairHomeAuthorized {
    param([string]$ResolvedCodexHome)

    $liveHome = [System.IO.Path]::GetFullPath("D:\Codex\.codex").TrimEnd("\", "/")
    if ($ResolvedCodexHome.Equals($liveHome, [System.StringComparison]::OrdinalIgnoreCase)) {
        return
    }

    $markerPath = Join-Path $ResolvedCodexHome ".codex-host-hook-reconciliation-fixture"
    if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf)) {
        throw "非默认 CodexHome 只允许带受控 fixture marker 的 Repair"
    }
    Assert-NoReparsePath -Path $markerPath -RequireLeaf | Out-Null
    if ((Read-Text -Path $markerPath).Trim() -cne "codex-host-hook-reconciliation-fixture-v1") {
        throw "fixture marker 内容不匹配，拒绝 Repair"
    }
}

function Initialize-FixtureTestSeams {
    param([string]$ResolvedCodexHome)

    $requestedPath = $env:CODEX_HOST_HOOK_TEST_CONCURRENT_REPLACE
    $postCommitFailurePhase = $env:CODEX_HOST_HOOK_TEST_POST_COMMIT_FAILURE
    if (
        [string]::IsNullOrWhiteSpace($requestedPath) -and
        [string]::IsNullOrWhiteSpace($postCommitFailurePhase)
    ) {
        return
    }

    $liveHome = [System.IO.Path]::GetFullPath("D:\Codex\.codex").TrimEnd("\", "/")
    if ($ResolvedCodexHome.Equals($liveHome, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "fixture-only test seam 不得用于 live CodexHome"
    }

    if (-not [string]::IsNullOrWhiteSpace($postCommitFailurePhase)) {
        if ($postCommitFailurePhase -notin @("acl", "legacy")) {
            throw "fixture-only post-commit failure phase 无效"
        }
        $script:FixturePostCommitFailurePhase = $postCommitFailurePhase
    }

    if ([string]::IsNullOrWhiteSpace($requestedPath)) {
        return
    }

    $fullPath = Assert-NoReparsePath -Path $requestedPath -RequireLeaf
    if (-not $fullPath.StartsWith("$ResolvedCodexHome\", [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "fixture-only test seam 必须位于当前 CodexHome 内"
    }
    $script:FixtureConcurrentReplacePath = $fullPath
    $replaceKind = $env:CODEX_HOST_HOOK_TEST_CONCURRENT_KIND
    if (-not [string]::IsNullOrWhiteSpace($replaceKind)) {
        if ($replaceKind -notin @("content", "acl")) {
            throw "fixture-only concurrent replacement kind 无效"
        }
        $script:FixtureConcurrentReplaceKind = $replaceKind
    }
    $occurrenceText = $env:CODEX_HOST_HOOK_TEST_CONCURRENT_OCCURRENCE
    $occurrence = 1
    if (
        -not [string]::IsNullOrWhiteSpace($occurrenceText) -and
        (-not [int]::TryParse($occurrenceText, [ref]$occurrence) -or $occurrence -lt 1 -or $occurrence -gt 10)
    ) {
        throw "fixture-only concurrent replacement occurrence 无效"
    }
    $script:FixtureConcurrentReplaceRemaining = $occurrence
    $failureMode = $env:CODEX_HOST_HOOK_TEST_CAS_FAILURE_MODE
    if (-not [string]::IsNullOrWhiteSpace($failureMode)) {
        if ($failureMode -notin @("replace", "hash")) {
            throw "fixture-only CAS failure mode 无效"
        }
        $script:FixtureCasFailureMode = $failureMode
    }
}

function Get-ExceptionDataValue {
    param(
        [System.Exception]$Exception,
        [string]$Key
    )

    $cursor = $Exception
    while ($null -ne $cursor) {
        if ($cursor.Data.Contains($Key)) {
            return $cursor.Data[$Key]
        }
        $cursor = $cursor.InnerException
    }
    $null
}

function Get-ConcurrentReplaceRecord {
    param([System.Exception]$Exception)

    $path = [string](Get-ExceptionDataValue -Exception $Exception -Key "CodexConcurrentReplacePath")
    if ([string]::IsNullOrWhiteSpace($path)) {
        return $null
    }

    $backupPath = [string](Get-ExceptionDataValue -Exception $Exception -Key "CodexConcurrentBackupPath")
    [pscustomobject]@{
        path = $path
        backupRestored = [bool](Get-ExceptionDataValue -Exception $Exception -Key "CodexConcurrentBackupRestored")
        backupPath = if ([string]::IsNullOrWhiteSpace($backupPath)) { $null } else { $backupPath }
    }
}

function Read-Text {
    param([string]$Path)

    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if (
        $bytes.Length -ge 3 -and
        $bytes[0] -eq 0xEF -and
        $bytes[1] -eq 0xBB -and
        $bytes[2] -eq 0xBF
    ) {
        throw "受管文本文件不得包含 UTF-8 BOM：$Path"
    }
    try {
        [System.Text.UTF8Encoding]::new($false, $true).GetString($bytes)
    } catch [System.Text.DecoderFallbackException] {
        throw "受管文本文件不是严格 UTF-8：$Path"
    }
}

function Write-AtomicText {
    param(
        [string]$Path,
        [string]$Content,
        [string]$ExpectedCurrentSha256,
        [string]$ExpectedCurrentSddl
    )

    $directory = [System.IO.Path]::GetDirectoryName($Path)
    $fileName = [System.IO.Path]::GetFileName($Path)
    $tempPath = Join-Path $directory (".$fileName.tmp." + [guid]::NewGuid().ToString("N"))
    $replaceBackupPath = Join-Path $directory (".$fileName.replace-backup." + [guid]::NewGuid().ToString("N"))
    $preserveBackup = $false
    try {
        [System.IO.File]::WriteAllText($tempPath, $Content, [System.Text.UTF8Encoding]::new($false))
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            if (
                $null -ne $script:FixtureConcurrentReplacePath -and
                $Path.Equals($script:FixtureConcurrentReplacePath, [System.StringComparison]::OrdinalIgnoreCase)
            ) {
                $script:FixtureConcurrentReplaceRemaining--
                if ($script:FixtureConcurrentReplaceRemaining -le 0) {
                    if ($script:FixtureConcurrentReplaceKind -eq "acl") {
                        Set-ProtectedAcl -Path $Path
                    } else {
                        [System.IO.File]::WriteAllText(
                            $Path,
                            "# fixture concurrent replacement`n",
                            [System.Text.UTF8Encoding]::new($false)
                        )
                    }
                    $script:FixtureConcurrentReplacePath = $null
                }
            }
            $preserveBackup = $true
            try {
                [System.IO.File]::Replace($tempPath, $Path, $replaceBackupPath, $false)
                if (
                    $script:FixtureCasFailureMode -eq "replace" -and
                    $null -eq $script:FixtureConcurrentReplacePath
                ) {
                    $script:FixtureCasFailureMode = $null
                    throw "fixture File.Replace partial failure"
                }
            } catch {
                if (Test-Path -LiteralPath $replaceBackupPath -PathType Leaf) {
                    $exception = [System.InvalidOperationException]::new("File.Replace 失败且已产生 backup", $_.Exception)
                    $exception.Data["CodexConcurrentReplacePath"] = $Path
                    $exception.Data["CodexConcurrentBackupPath"] = $replaceBackupPath
                    throw $exception
                }
                $preserveBackup = $false
                throw
            }
            if (-not [string]::IsNullOrWhiteSpace($ExpectedCurrentSha256)) {
                $backupHash = $null
                $backupSddl = $null
                $validationError = $null
                try {
                    if (
                        $script:FixtureCasFailureMode -eq "hash" -and
                        $null -eq $script:FixtureConcurrentReplacePath
                    ) {
                        $script:FixtureCasFailureMode = $null
                        throw "fixture CAS backup hash failure"
                    }
                    $backupHash = Get-Sha256 -Path $replaceBackupPath
                    $backupSddl = (Get-Acl -LiteralPath $replaceBackupPath).Sddl
                } catch {
                    $validationError = "无法验证原子替换 backup：$($_.Exception.Message)"
                }
                $metadataMismatch = (
                    -not [string]::IsNullOrWhiteSpace($ExpectedCurrentSddl) -and
                    $backupSddl -cne $ExpectedCurrentSddl
                )
                if ($null -ne $validationError -or $backupHash -ne $ExpectedCurrentSha256 -or $metadataMismatch) {
                    $message = if ($null -ne $validationError) { $validationError } else { "目标文件在原子替换提交窗口发生内容或 ACL 并发变化" }
                    $exception = [System.InvalidOperationException]::new($message)
                    $exception.Data["CodexConcurrentReplacePath"] = $Path
                    $exception.Data["CodexConcurrentBackupPath"] = $replaceBackupPath
                    throw $exception
                }
            }
            $preserveBackup = $false
        } else {
            [System.IO.File]::Move($tempPath, $Path)
        }
    } finally {
        if (Test-Path -LiteralPath $tempPath -PathType Leaf) {
            Remove-Item -LiteralPath $tempPath -Force
        }
        if (-not $preserveBackup -and (Test-Path -LiteralPath $replaceBackupPath -PathType Leaf)) {
            Remove-Item -LiteralPath $replaceBackupPath -Force
        }
    }
}

function ConvertFrom-TomlDottedKeyName {
    param([string]$Name)

    $match = [regex]::Match(
        $Name,
        '^\s*(?<key>' + $script:TomlKeyPattern + ')\s*(?:\.\s*(?<key>' + $script:TomlKeyPattern + ')\s*)*$'
    )
    if (-not $match.Success) {
        throw "当前安全 parser 无法解析 TOML dotted key：$Name"
    }

    $segments = [System.Collections.Generic.List[string]]::new()
    foreach ($capture in $match.Groups['key'].Captures) {
        $token = $capture.Value
        if ($token.StartsWith('"', [System.StringComparison]::Ordinal)) {
            try {
                $decoded = ConvertFrom-Json -InputObject $token -NoEnumerate
            } catch {
                throw "当前安全 parser 无法解析 TOML quoted key：$token"
            }
            if ($decoded -isnot [string]) {
                throw "TOML quoted key 必须解析为字符串：$token"
            }
            $segments.Add($decoded)
        } elseif ($token.StartsWith("'", [System.StringComparison]::Ordinal)) {
            $segments.Add($token.Substring(1, $token.Length - 2))
        } else {
            $segments.Add($token)
        }
    }
    $segments.ToArray()
}

function Test-TomlKeySegmentsEqual {
    param(
        [string[]]$Left,
        [string[]]$Right
    )

    if ($Left.Count -ne $Right.Count) {
        return $false
    }
    for ($index = 0; $index -lt $Left.Count; $index++) {
        if ($Left[$index] -cne $Right[$index]) {
            return $false
        }
    }
    $true
}

function Get-TomlAssignmentKeySegments {
    param([string]$Line)

    $match = [regex]::Match(
        $Line,
        '^\s*(?<name>' + $script:TomlKeyPattern + '(?:\s*\.\s*' + $script:TomlKeyPattern + ')*)\s*='
    )
    if (-not $match.Success) {
        return
    }
    ConvertFrom-TomlDottedKeyName -Name $match.Groups['name'].Value
}

function Resolve-TomlParserPython {
    $runtimeRoot = Assert-NoReparsePath -Path "D:\Codex\tools\python314-official" -RequireLeaf
    foreach ($relativePath in @("Lib", "Lib\tomllib")) {
        $directoryPath = Assert-NoReparsePath -Path (Join-Path $runtimeRoot $relativePath) -RequireLeaf
        if (-not (Test-Path -LiteralPath $directoryPath -PathType Container)) {
            throw "TOML parser Python runtime 目录缺失"
        }
    }
    foreach ($relativePath in @(
        "python.exe",
        "python3.dll",
        "python314.dll",
        "Lib\tomllib\__init__.py",
        "Lib\tomllib\_parser.py",
        "Lib\tomllib\_re.py",
        "Lib\tomllib\_types.py"
    )) {
        $filePath = Assert-NoReparsePath -Path (Join-Path $runtimeRoot $relativePath) -RequireLeaf
        if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
            throw "TOML parser Python runtime 文件缺失"
        }
    }

    $pythonPath = Join-Path $runtimeRoot "python.exe"
    $python = Get-Item -LiteralPath $pythonPath -Force
    if ($python.VersionInfo.ProductVersion -notmatch '^3\.14\.') {
        throw "TOML parser Python 版本不符合固定的 3.14 runtime 边界"
    }
    $signature = Get-AuthenticodeSignature -LiteralPath $pythonPath
    if (
        $signature.Status -ne [System.Management.Automation.SignatureStatus]::Valid -or
        $null -eq $signature.SignerCertificate -or
        $signature.SignerCertificate.Subject -notmatch '(^|,\s*)CN=Python Software Foundation(,|$)'
    ) {
        throw "TOML parser Python 未通过 Python Software Foundation 签名验证"
    }
    $pythonPath
}

function Wait-TomlParserTask {
    param(
        [System.Threading.Tasks.Task]$Task,
        [System.Diagnostics.Stopwatch]$Clock,
        [int]$TimeoutMilliseconds
    )

    while (-not $Task.IsCompleted) {
        $remaining = $TimeoutMilliseconds - [int]$Clock.ElapsedMilliseconds
        if ($remaining -le 0) {
            throw "TOML parser Python 超时"
        }
        Start-Sleep -Milliseconds ([Math]::Min(10, $remaining))
    }
    $Task.GetAwaiter().GetResult()
}

function Assert-ValidToml {
    param([string]$Content)

    $pythonPath = Resolve-TomlParserPython
    $pycacheRoot = Assert-NoReparsePath -Path "D:\Codex\.codex\run-evidence" -RequireLeaf
    if (-not (Test-Path -LiteralPath $pycacheRoot -PathType Container)) {
        throw "TOML parser pycache 隔离根不存在"
    }
    $pycachePrefix = Assert-NoReparsePath -Path (Join-Path $pycacheRoot (".toml-parser-pycache-{0}" -f ([guid]::NewGuid().ToString("N"))))
    if (Test-Path -LiteralPath $pycachePrefix) {
        throw "TOML parser pycache 隔离路径必须不存在"
    }

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $pythonPath
    foreach ($argument in @(
        "-B",
        "-I",
        "-S",
        "-X",
        "utf8",
        "-X",
        "pycache_prefix=$pycachePrefix",
        "-c",
        'import sys, tomllib; tomllib.loads(sys.stdin.read())'
    )) {
        $startInfo.ArgumentList.Add($argument)
    }
    $startInfo.WorkingDirectory = "D:\Codex"
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $utf8 = [System.Text.UTF8Encoding]::new($false, $true)
    $startInfo.StandardInputEncoding = $utf8
    $startInfo.StandardOutputEncoding = $utf8
    $startInfo.StandardErrorEncoding = $utf8

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    $started = $false
    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    $timeoutMilliseconds = 5000
    try {
        $started = $process.Start()
        if (-not $started) {
            throw "TOML parser Python 未启动"
        }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $writeTask = $process.StandardInput.WriteAsync($Content)
        Wait-TomlParserTask -Task $writeTask -Clock $clock -TimeoutMilliseconds $timeoutMilliseconds | Out-Null
        $flushTask = $process.StandardInput.FlushAsync()
        Wait-TomlParserTask -Task $flushTask -Clock $clock -TimeoutMilliseconds $timeoutMilliseconds | Out-Null
        $process.StandardInput.Close()
        $remaining = $timeoutMilliseconds - [int]$clock.ElapsedMilliseconds
        if ($remaining -le 0 -or -not $process.WaitForExit($remaining)) {
            throw "TOML parser Python 超时"
        }
        Wait-TomlParserTask -Task $stdoutTask -Clock $clock -TimeoutMilliseconds $timeoutMilliseconds | Out-Null
        Wait-TomlParserTask -Task $stderrTask -Clock $clock -TimeoutMilliseconds $timeoutMilliseconds | Out-Null
        if ($process.ExitCode -ne 0) {
            throw "config.toml 未通过完整 TOML 语法验证"
        }
    } catch {
        throw "完整 TOML 语法验证失败"
    } finally {
        if ($started -and -not $process.HasExited) {
            try {
                $process.StandardInput.BaseStream.Dispose()
            } catch {
            }
            try {
                $process.Kill($true)
            } catch {
            }
            $process.WaitForExit(1000) | Out-Null
        }
        $process.Dispose()
    }
}

function Invoke-FixturePostCommitFailure {
    param([ValidateSet("acl", "legacy")][string]$Phase)

    if ($script:FixturePostCommitFailurePhase -ceq $Phase) {
        $script:FixturePostCommitFailurePhase = $null
        throw "fixture-only post-commit $Phase failure"
    }
}

function Get-TomlDocument {
    param([string]$Content)

    Assert-ValidToml -Content $Content
    if ($Content.Contains("'''") -or $Content.Contains('"""')) {
        throw "当前安全 parser 不处理 TOML 多行字符串；为避免把正文误判为 section，拒绝写入"
    }

    $newLine = if ($Content.Contains("`r`n")) { "`r`n" } else { "`n" }
    $lines = [regex]::Split($Content, "\r?\n")
    $headers = [System.Collections.Generic.List[object]]::new()
    for ($index = 0; $index -lt $lines.Count; $index++) {
        $match = [regex]::Match($lines[$index], '^\s*\[(?<name>[^\[\]]+)\]\s*(?:#.*)?$')
        if ($match.Success) {
            $segments = @(ConvertFrom-TomlDottedKeyName -Name $match.Groups['name'].Value)
            $headers.Add([pscustomobject]@{
                index = $index
                name = $match.Groups['name'].Value
                segments = $segments
                kind = "table"
            })
            continue
        }
        $arrayMatch = [regex]::Match($lines[$index], '^\s*\[\[(?<name>[^\[\]]+)\]\]\s*(?:#.*)?$')
        if ($arrayMatch.Success) {
            $segments = @(ConvertFrom-TomlDottedKeyName -Name $arrayMatch.Groups['name'].Value)
            $headers.Add([pscustomobject]@{
                index = $index
                name = $arrayMatch.Groups['name'].Value
                segments = $segments
                kind = "array-table"
            })
        }
    }

    [pscustomobject]@{
        lines = $lines
        newLine = $newLine
        headers = $headers.ToArray()
    }
}

function Get-UniqueSectionRange {
    param(
        [object]$Document,
        [string]$Name
    )

    $expectedSegments = @($Name.Split('.'))
    $matches = @($Document.headers | Where-Object {
        $_.kind -ceq "table" -and (Test-TomlKeySegmentsEqual -Left @($_.segments) -Right $expectedSegments)
    })
    if ($matches.Count -ne 1) {
        throw "TOML section 必须恰好出现一次：[$Name]；实际 $($matches.Count)"
    }

    $header = $matches[0]
    $next = @($Document.headers | Where-Object { $_.index -gt $header.index } | Sort-Object index | Select-Object -First 1)
    [pscustomobject]@{
        start = $header.index + 1
        end = if ($next.Count -eq 1) { $next[0].index } else { $Document.lines.Count }
    }
}

function Get-UniqueKeyIndex {
    param(
        [object]$Document,
        [string]$Key,
        [int]$Start,
        [int]$End
    )

    $expectedSegments = @($Key)
    $keyIndices = [System.Collections.Generic.List[int]]::new()
    for ($index = $Start; $index -lt $End; $index++) {
        $segments = @(Get-TomlAssignmentKeySegments -Line $Document.lines[$index])
        if (Test-TomlKeySegmentsEqual -Left $segments -Right $expectedSegments) {
            $keyIndices.Add($index)
        }
    }
    if ($keyIndices.Count -ne 1) {
        throw "TOML key 必须在目标作用域恰好出现一次：$Key；实际 $($keyIndices.Count)"
    }

    $keyIndices[0]
}

function Set-TomlKeyLiteral {
    param(
        [object]$Document,
        [int]$Index,
        [string]$Key,
        [string]$Literal
    )

    $match = [regex]::Match($Document.lines[$Index], '^(?<indent>\s*)')
    if (-not $match.Success) {
        throw "无法定位 TOML key：$Key"
    }
    $Document.lines[$Index] = "$($match.Groups['indent'].Value)$Key = $Literal"
}

function Convert-SerenaArgs {
    param(
        [string]$RightHandSide,
        [string]$ExpectedContextPath
    )

    try {
        $parsed = ConvertFrom-Json -InputObject $RightHandSide -NoEnumerate
    } catch {
        throw "Serena args 必须是单行、JSON 兼容的 TOML 字符串数组：$($_.Exception.Message)"
    }
    if ($parsed -isnot [System.Collections.IList]) {
        throw "Serena args 必须是字符串数组"
    }

    $tokens = @($parsed)
    if ($tokens.Count -eq 0 -or $tokens[0] -cne "start-mcp-server") {
        throw "Serena args 必须以 start-mcp-server 开头"
    }
    foreach ($token in $tokens) {
        if ($token -isnot [string]) {
            throw "Serena args 只能包含字符串"
        }
    }

    $result = [System.Collections.Generic.List[string]]::new()
    $contextValues = [System.Collections.Generic.List[string]]::new()
    for ($index = 0; $index -lt $tokens.Count; $index++) {
        $token = [string]$tokens[$index]
        if ($token -ceq "--project-from-cwd") {
            continue
        }
        if ($token.StartsWith("--project-from-cwd=", [System.StringComparison]::Ordinal)) {
            throw "--project-from-cwd 不接受值"
        }
        if ($token -ceq "--context") {
            if ($index + 1 -ge $tokens.Count -or
                [string]::IsNullOrWhiteSpace([string]$tokens[$index + 1]) -or
                ([string]$tokens[$index + 1]).StartsWith("--", [System.StringComparison]::Ordinal)) {
                throw "--context 缺少参数值"
            }
            $contextValues.Add([string]$tokens[$index + 1])
        }
        if ($token.StartsWith("--context=", [System.StringComparison]::Ordinal)) {
            $contextValue = $token.Substring("--context=".Length)
            if ([string]::IsNullOrWhiteSpace($contextValue)) {
                throw "--context 缺少参数值"
            }
            $contextValues.Add($contextValue)
        }
        if ($token -ceq "--project" -or $token -ceq "--project-file") {
            if ($index + 1 -ge $tokens.Count -or
                [string]::IsNullOrWhiteSpace([string]$tokens[$index + 1]) -or
                ([string]$tokens[$index + 1]).StartsWith("--", [System.StringComparison]::Ordinal)) {
                throw "$token 缺少参数值"
            }
            $index++
            continue
        }
        if ($token.StartsWith("--project=", [System.StringComparison]::Ordinal) -or $token.StartsWith("--project-file=", [System.StringComparison]::Ordinal)) {
            if ([string]::IsNullOrWhiteSpace($token.Substring($token.IndexOf('=') + 1))) {
                throw "$($token.Substring(0, $token.IndexOf('='))) 缺少参数值"
            }
            continue
        }

        $result.Add($token)
    }

    if ($contextValues.Count -ne 1) {
        throw "Serena args 必须恰好包含一个 --context；实际 $($contextValues.Count)"
    }
    if (-not [System.IO.Path]::IsPathFullyQualified($contextValues[0])) {
        throw "Serena --context 必须是绝对路径：$($contextValues[0])"
    }
    $resolvedContext = [System.IO.Path]::GetFullPath($contextValues[0]).TrimEnd('\', '/')
    $resolvedExpected = [System.IO.Path]::GetFullPath($ExpectedContextPath).TrimEnd('\', '/')
    if (-not $resolvedContext.Equals($resolvedExpected, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Serena --context 未指向受保护的 codex-file-tools.yml"
    }

    ConvertTo-Json -InputObject $result.ToArray() -Compress
}

function Get-DesiredConfig {
    param(
        [string]$Content,
        [string]$ExpectedSerenaContextPath
    )

    $document = Get-TomlDocument -Content $Content
    $firstSectionIndex = if ($document.headers.Count -gt 0) { ($document.headers | Sort-Object index | Select-Object -First 1).index } else { $document.lines.Count }
    for ($index = 0; $index -lt $firstSectionIndex; $index++) {
        $segments = @(Get-TomlAssignmentKeySegments -Line $document.lines[$index])
        if ($segments.Count -gt 0 -and $segments[0] -ceq "hooks") {
            throw "根级 TOML dotted hook key 不受支持，拒绝写入"
        }
    }

    $approvalIndex = Get-UniqueKeyIndex -Document $document -Key "approval_policy" -Start 0 -End $firstSectionIndex
    $sandboxIndex = Get-UniqueKeyIndex -Document $document -Key "sandbox_mode" -Start 0 -End $firstSectionIndex
    Set-TomlKeyLiteral -Document $document -Index $approvalIndex -Key "approval_policy" -Literal '"never"'
    Set-TomlKeyLiteral -Document $document -Index $sandboxIndex -Key "sandbox_mode" -Literal '"danger-full-access"'

    $features = Get-UniqueSectionRange -Document $document -Name "features"
    $featuresHooksIndex = Get-UniqueKeyIndex -Document $document -Key "hooks" -Start $features.start -End $features.end
    $unifiedExecIndex = Get-UniqueKeyIndex -Document $document -Key "unified_exec" -Start $features.start -End $features.end
    Set-TomlKeyLiteral -Document $document -Index $featuresHooksIndex -Key "hooks" -Literal "true"
    Set-TomlKeyLiteral -Document $document -Index $unifiedExecIndex -Key "unified_exec" -Literal "true"

    $serena = Get-UniqueSectionRange -Document $document -Name "mcp_servers.serena"
    $argsIndex = Get-UniqueKeyIndex -Document $document -Key "args" -Start $serena.start -End $serena.end
    $argsLine = $document.lines[$argsIndex]
    $equalsIndex = $argsLine.IndexOf('=')
    if ($equalsIndex -lt 0) {
        throw "无法解析 Serena args"
    }
    $argsLiteral = Convert-SerenaArgs -RightHandSide $argsLine.Substring($equalsIndex + 1).Trim() -ExpectedContextPath $ExpectedSerenaContextPath
    Set-TomlKeyLiteral -Document $document -Index $argsIndex -Key "args" -Literal $argsLiteral

    $keep = [bool[]]::new($document.lines.Count)
    [array]::Fill($keep, $true)
    $headers = @($document.headers | Sort-Object index)
    $seenHookSections = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    for ($headerIndex = 0; $headerIndex -lt $headers.Count; $headerIndex++) {
        $header = $headers[$headerIndex]
        if (@($header.segments).Count -eq 0 -or $header.segments[0] -cne "hooks") {
            continue
        }
        $semanticName = ConvertTo-Json -InputObject ([object[]]@($header.segments)) -Compress
        if (-not $seenHookSections.Add($semanticName)) {
            throw "重复的 TOML hook section：$semanticName"
        }
        $end = if ($headerIndex + 1 -lt $headers.Count) { $headers[$headerIndex + 1].index } else { $document.lines.Count }
        for ($lineIndex = $header.index; $lineIndex -lt $end; $lineIndex++) {
            $keep[$lineIndex] = $false
        }
    }

    $keptLines = [System.Collections.Generic.List[string]]::new()
    for ($index = 0; $index -lt $document.lines.Count; $index++) {
        if ($keep[$index]) {
            $keptLines.Add($document.lines[$index])
        }
    }
    $desired = [string]::Join($document.newLine, $keptLines)
    Assert-ValidToml -Content $desired

    [pscustomobject]@{
        content = $desired
        changed = -not $Content.Equals($desired, [System.StringComparison]::Ordinal)
    }
}

function Get-DesiredHooksJson {
    param([string]$Content)

    try {
        $document = [System.Text.Json.JsonDocument]::Parse($Content)
    } catch {
        throw "hooks.json 无法解析：$($_.Exception.Message)"
    }

    $desired = $null
    try {
        if ($document.RootElement.ValueKind -ne [System.Text.Json.JsonValueKind]::Object) {
            throw "hooks.json 顶层必须是 JSON 对象"
        }
        $properties = @($document.RootElement.EnumerateObject())
        $propertyNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
        foreach ($property in $properties) {
            if (-not $propertyNames.Add($property.Name)) {
                throw "hooks.json 顶层属性不得重复：$($property.Name)"
            }
        }
        $hookProperties = @($properties | Where-Object { $_.Name -ceq "hooks" })
        if ($hookProperties.Count -ne 1) {
            throw "hooks.json 必须恰好包含一个 hooks 属性"
        }
        if ($hookProperties[0].Value.ValueKind -ne [System.Text.Json.JsonValueKind]::Object) {
            throw "hooks.json 的 hooks 必须是 JSON 对象"
        }
        $alreadyEmpty = -not $hookProperties[0].Value.EnumerateObject().MoveNext()
        if (-not $alreadyEmpty) {
            $stream = [System.IO.MemoryStream]::new()
            $options = [System.Text.Json.JsonWriterOptions]::new()
            $options.Indented = $true
            $writer = [System.Text.Json.Utf8JsonWriter]::new($stream, $options)
            try {
                $writer.WriteStartObject()
                foreach ($property in $properties) {
                    $writer.WritePropertyName($property.Name)
                    if ($property.Name -ceq "hooks") {
                        $writer.WriteStartObject()
                        $writer.WriteEndObject()
                    } else {
                        $writer.WriteRawValue($property.Value.GetRawText(), $true)
                    }
                }
                $writer.WriteEndObject()
                $writer.Flush()
                $desired = [System.Text.UTF8Encoding]::new($false).GetString($stream.ToArray()) + "`n"
            } finally {
                $writer.Dispose()
                $stream.Dispose()
            }
        }
    } finally {
        $document.Dispose()
    }

    if ($alreadyEmpty) {
        return [pscustomobject]@{
            content = $Content
            changed = $false
        }
    }

    [pscustomobject]@{
        content = $desired
        changed = -not $Content.Equals($desired, [System.StringComparison]::Ordinal)
    }
}

function Get-AllowedWriterSids {
    @(
        [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value,
        "S-1-5-18",
        "S-1-5-32-544"
    )
}

function Test-ProtectedAcl {
    param([string]$Path)

    $allowed = @(Get-AllowedWriterSids)
    $acl = Get-Acl -LiteralPath $Path
    $ownerSid = $acl.GetOwner([System.Security.Principal.SecurityIdentifier]).Value
    $ownerAllowed = $allowed -contains $ownerSid
    $writeMask = [System.Security.AccessControl.FileSystemRights]::WriteData -bor
        [System.Security.AccessControl.FileSystemRights]::CreateFiles -bor
        [System.Security.AccessControl.FileSystemRights]::AppendData -bor
        [System.Security.AccessControl.FileSystemRights]::CreateDirectories -bor
        [System.Security.AccessControl.FileSystemRights]::WriteExtendedAttributes -bor
        [System.Security.AccessControl.FileSystemRights]::WriteAttributes -bor
        [System.Security.AccessControl.FileSystemRights]::Delete -bor
        [System.Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles -bor
        [System.Security.AccessControl.FileSystemRights]::ChangePermissions -bor
        [System.Security.AccessControl.FileSystemRights]::TakeOwnership
    $writers = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $unexpected = [System.Collections.Generic.List[string]]::new()
    $missingInheritance = [System.Collections.Generic.List[string]]::new()
    $denyCount = 0
    $isDirectory = (Get-Item -LiteralPath $Path -Force).PSIsContainer
    foreach ($rule in $acl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier])) {
        if ($rule.AccessControlType -eq [System.Security.AccessControl.AccessControlType]::Deny) {
            $denyCount++
            continue
        }
        if (($rule.FileSystemRights -band $writeMask) -eq 0) {
            continue
        }
        $sid = $rule.IdentityReference.Value
        $writers.Add($sid) | Out-Null
        if ($allowed -notcontains $sid) {
            $unexpected.Add($sid)
        } elseif ($isDirectory) {
            $requiredInheritance = [System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [System.Security.AccessControl.InheritanceFlags]::ObjectInherit
            if (($rule.InheritanceFlags -band $requiredInheritance) -ne $requiredInheritance) {
                $missingInheritance.Add($sid)
            }
        }
    }
    $missing = @($allowed | Where-Object { -not $writers.Contains($_) })

    [pscustomobject]@{
        ok = $ownerAllowed -and $acl.AreAccessRulesProtected -and $unexpected.Count -eq 0 -and $missing.Count -eq 0 -and $missingInheritance.Count -eq 0 -and $denyCount -eq 0
        ownerAllowed = $ownerAllowed
        protected = $acl.AreAccessRulesProtected
        unexpectedWriterCount = $unexpected.Count
        missingRequiredWriterCount = $missing.Count
        missingInheritanceCount = $missingInheritance.Count
        denyRuleCount = $denyCount
    }
}

function Set-ProtectedAcl {
    param([string]$Path)

    if ((Test-ProtectedAcl -Path $Path).ok) {
        return
    }

    $item = Get-Item -LiteralPath $Path -Force
    $currentSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
    $security = if ($item.PSIsContainer) {
        [System.Security.AccessControl.DirectorySecurity]::new()
    } else {
        [System.Security.AccessControl.FileSecurity]::new()
    }
    $security.SetOwner($currentSid)
    $security.SetAccessRuleProtection($true, $false)

    $allowed = @(Get-AllowedWriterSids)
    $readMask = [System.Security.AccessControl.FileSystemRights]::ReadAndExecute -bor
        [System.Security.AccessControl.FileSystemRights]::Read -bor
        [System.Security.AccessControl.FileSystemRights]::Synchronize
    $existingAcl = Get-Acl -LiteralPath $Path
    foreach ($existingRule in $existingAcl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier])) {
        $sidValue = $existingRule.IdentityReference.Value
        if ($existingRule.AccessControlType -ne [System.Security.AccessControl.AccessControlType]::Allow -or $allowed -contains $sidValue) {
            continue
        }
        $readRights = $existingRule.FileSystemRights -band $readMask
        if ($readRights -eq 0) {
            continue
        }
        $readRule = [System.Security.AccessControl.FileSystemAccessRule]::new(
            [System.Security.Principal.SecurityIdentifier]::new($sidValue),
            $readRights,
            $existingRule.InheritanceFlags,
            $existingRule.PropagationFlags,
            [System.Security.AccessControl.AccessControlType]::Allow
        )
        $security.AddAccessRule($readRule) | Out-Null
    }

    foreach ($sidValue in $allowed) {
        $sid = [System.Security.Principal.SecurityIdentifier]::new($sidValue)
        if ($item.PSIsContainer) {
            $rule = [System.Security.AccessControl.FileSystemAccessRule]::new(
                $sid,
                [System.Security.AccessControl.FileSystemRights]::FullControl,
                [System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [System.Security.AccessControl.InheritanceFlags]::ObjectInherit,
                [System.Security.AccessControl.PropagationFlags]::None,
                [System.Security.AccessControl.AccessControlType]::Allow
            )
        } else {
            $rule = [System.Security.AccessControl.FileSystemAccessRule]::new(
                $sid,
                [System.Security.AccessControl.FileSystemRights]::FullControl,
                [System.Security.AccessControl.AccessControlType]::Allow
            )
        }
        $security.AddAccessRule($rule) | Out-Null
    }

    Set-Acl -LiteralPath $Path -AclObject $security
}

function Test-SerenaContextPolicy {
    param([string]$Content)

    $lines = [regex]::Split($Content, "\r?\n")
    $promptKeys = @(
        for ($index = 0; $index -lt $lines.Count; $index++) {
            if ($lines[$index] -match '^(?:prompt|"prompt"|''prompt'')\s*:') {
                $index
            }
        }
    )
    $promptHeaders = @(
        for ($index = 0; $index -lt $lines.Count; $index++) {
            if ($lines[$index] -match '^prompt\s*:\s*\|\s*(?:#.*)?$') {
                $index
            }
        }
    )
    if ($promptKeys.Count -ne 1 -or $promptHeaders.Count -ne 1 -or $promptKeys[0] -ne $promptHeaders[0]) {
        return $false
    }

    $promptLines = [System.Collections.Generic.List[string]]::new()
    for ($index = $promptHeaders[0] + 1; $index -lt $lines.Count; $index++) {
        $line = $lines[$index]
        if (-not [string]::IsNullOrWhiteSpace($line) -and -not $line.StartsWith("  ", [System.StringComparison]::Ordinal)) {
            break
        }
        if ($line.StartsWith("  ", [System.StringComparison]::Ordinal)) {
            $promptLines.Add($line.Substring(2))
        } else {
            $promptLines.Add("")
        }
    }

    $normalizedPrompt = [regex]::Replace(($promptLines -join "`n"), '\s+', ' ').Trim()
    $requiredPolicy = "Before using any project-scoped Serena tool in a repository task, explicitly call activate_project with the absolute current workspace or repository root from Codex's environment_context, then verify the result with get_current_config. Never infer the task project from Serena's initial active project or from the Serena process working directory."
    $normalizedPrompt.Contains($requiredPolicy, [System.StringComparison]::Ordinal)
}

function Get-ReconciliationState {
    param([string]$ResolvedCodexHome)

    $configPath = Join-Path $ResolvedCodexHome "config.toml"
    $hooksPath = Join-Path $ResolvedCodexHome "hooks.json"
    $hookDirectory = Join-Path $ResolvedCodexHome "hooks"
    $hostRoot = [System.IO.Directory]::GetParent($ResolvedCodexHome).FullName
    $serenaContextDirectory = Join-Path $hostRoot ".serena\contexts"
    $serenaContextPath = Join-Path $serenaContextDirectory "codex-file-tools.yml"
    foreach ($path in @($configPath, $hooksPath, $hookDirectory, $serenaContextDirectory, $serenaContextPath)) {
        Assert-NoReparsePath -Path $path -RequireLeaf | Out-Null
    }
    $configContent = Read-Text -Path $configPath
    $hooksContent = Read-Text -Path $hooksPath
    $serenaContextContent = Read-Text -Path $serenaContextPath
    if (-not (Test-SerenaContextPolicy -Content $serenaContextContent)) {
        throw "Serena context 缺少受控的显式项目激活与复验契约"
    }
    $desiredConfig = Get-DesiredConfig -Content $configContent -ExpectedSerenaContextPath $serenaContextPath
    $desiredHooks = Get-DesiredHooksJson -Content $hooksContent
    $legacyPresent = @($script:LegacyHookNames | Where-Object {
        $candidate = Join-Path $hookDirectory $_
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            return $false
        }
        Assert-NoReparsePath -Path $candidate -RequireLeaf | Out-Null
        $true
    })
    $legacyDirectoriesPresent = @($script:LegacyHookDirectoryNames | Where-Object {
        $candidate = Join-Path $hookDirectory $_
        if (-not (Test-Path -LiteralPath $candidate -PathType Container)) {
            return $false
        }
        Assert-NoReparsePath -Path $candidate -RequireLeaf | Out-Null
        $true
    })
    $hookTree = @(Get-Item -LiteralPath $hookDirectory -Force) + @(Get-ChildItem -LiteralPath $hookDirectory -Recurse -Force)
    foreach ($item in $hookTree) {
        Assert-NoReparsePath -Path $item.FullName -RequireLeaf | Out-Null
    }
    $preservedHookTree = @(Get-PreservedHookTreeInventory -HookDirectory $hookDirectory -HookTree $hookTree)
    # config.toml is a vendor-owned volatile artifact: Codex Desktop may replace
    # the file atomically, so its leaf ACL is not a durable policy boundary.
    # Keep its contents under semantic reconciliation, and reserve ACL health
    # for the stable hook and Serena surfaces owned by this reconciler.
    $aclStates = @(
        Test-ProtectedAcl -Path $hooksPath
        Test-ProtectedAcl -Path $serenaContextPath
        $hookTree | ForEach-Object { Test-ProtectedAcl -Path $_.FullName }
    )

    $checks = @(
        [pscustomobject]@{ name = "config"; ok = -not $desiredConfig.changed },
        [pscustomobject]@{ name = "registrations"; ok = -not $desiredHooks.changed },
        [pscustomobject]@{ name = "legacyImplementations"; ok = $legacyPresent.Count -eq 0 -and $legacyDirectoriesPresent.Count -eq 0; presentCount = $legacyPresent.Count + $legacyDirectoriesPresent.Count },
        [pscustomobject]@{ name = "acl"; ok = @($aclStates | Where-Object { -not $_.ok }).Count -eq 0; driftedTargetCount = @($aclStates | Where-Object { -not $_.ok }).Count }
    )
    $driftCount = @($checks | Where-Object { -not $_.ok }).Count

    [pscustomobject]@{
        configPath = $configPath
        hooksPath = $hooksPath
        hookDirectory = $hookDirectory
        serenaContextDirectory = $serenaContextDirectory
        serenaContextPath = $serenaContextPath
        serenaContextContent = $serenaContextContent
        hookTreePaths = @($hookTree | ForEach-Object { $_.FullName })
        preservedHookTree = $preservedHookTree
        configContent = $configContent
        hooksContent = $hooksContent
        desiredConfig = $desiredConfig
        desiredHooks = $desiredHooks
        legacyPresent = $legacyPresent
        legacyDirectoriesPresent = $legacyDirectoriesPresent
        checks = $checks
        driftCount = $driftCount
        ok = $driftCount -eq 0
    }
}

function New-Result {
    param(
        [string]$ResultMode,
        [object]$State,
        [bool]$Changed,
        [AllowNull()][object]$EvidencePath
    )

    [pscustomobject]@{
        schemaVersion = 1
        mode = $ResultMode
        ok = [bool]$State.ok
        changed = $Changed
        driftCount = [int]$State.driftCount
        checks = @($State.checks)
        evidencePath = $EvidencePath
    }
}

function Write-Manifest {
    param(
        [string]$Path,
        [System.Collections.IDictionary]$Manifest
    )

    $content = (ConvertTo-Json -InputObject $Manifest -Depth 12) + "`n"
    Write-AtomicText -Path $Path -Content $content
    Set-ProtectedAcl -Path $Path
}

function New-EvidenceSnapshot {
    param(
        [string]$ResolvedCodexHome,
        [object]$State
    )

    $runEvidenceRoot = Join-Path $ResolvedCodexHome "run-evidence"
    Assert-NoReparsePath -Path $runEvidenceRoot | Out-Null
    New-Item -ItemType Directory -Force -Path $runEvidenceRoot | Out-Null
    Assert-NoReparsePath -Path $runEvidenceRoot -RequireLeaf | Out-Null

    $evidenceRoot = Join-Path $runEvidenceRoot "host-hook-remediation"
    Assert-NoReparsePath -Path $evidenceRoot | Out-Null
    New-Item -ItemType Directory -Force -Path $evidenceRoot | Out-Null
    Assert-NoReparsePath -Path $evidenceRoot -RequireLeaf | Out-Null
    Set-ProtectedAcl -Path $evidenceRoot

    $runId = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmss.fffZ") + "-" + [guid]::NewGuid().ToString("N").Substring(0, 8)
    $evidencePath = Join-Path $evidenceRoot $runId
    New-Item -ItemType Directory -Path $evidencePath | Out-Null
    $script:CurrentEvidencePath = $evidencePath
    Set-ProtectedAcl -Path $evidencePath
    $configEvidencePath = Join-Path $evidencePath "config.toml"
    $hooksEvidencePath = Join-Path $evidencePath "hooks.json"
    $serenaContextEvidencePath = Join-Path $evidencePath "codex-file-tools.yml"
    [System.IO.File]::WriteAllText($configEvidencePath, $State.configContent, [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::WriteAllText($hooksEvidencePath, $State.hooksContent, [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::WriteAllText($serenaContextEvidencePath, $State.serenaContextContent, [System.Text.UTF8Encoding]::new($false))
    Set-ProtectedAcl -Path $configEvidencePath
    Set-ProtectedAcl -Path $hooksEvidencePath
    Set-ProtectedAcl -Path $serenaContextEvidencePath

    $legacyEvidence = Join-Path $evidencePath "legacy-hooks"
    New-Item -ItemType Directory -Path $legacyEvidence | Out-Null
    Set-ProtectedAcl -Path $legacyEvidence
    $legacyHashes = [ordered]@{}
    foreach ($name in $State.legacyPresent) {
        $source = Join-Path $State.hookDirectory $name
        Assert-NoReparsePath -Path $source -RequireLeaf | Out-Null
        $destination = Join-Path $legacyEvidence $name
        $destinationParent = [System.IO.Path]::GetDirectoryName($destination)
        New-Item -ItemType Directory -Force -Path $destinationParent | Out-Null
        Set-ProtectedAcl -Path $destinationParent
        [System.IO.File]::Copy($source, $destination, $false)
        Set-ProtectedAcl -Path $destination
        $legacyHashes[$name] = Get-Sha256 -Path $destination
    }

    $aclBefore = [ordered]@{}
    foreach ($path in @($State.configPath, $State.hooksPath, $State.serenaContextPath) + @($State.hookTreePaths)) {
        $aclBefore[$path] = (Get-Acl -LiteralPath $path).Sddl
    }
    $aclBeforePath = Join-Path $evidencePath "acl-before.json"
    $aclBefore | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $aclBeforePath -Encoding UTF8
    Set-ProtectedAcl -Path $aclBeforePath

    $manifest = [ordered]@{
        schemaVersion = 1
        runId = $runId
        createdAtUtc = (Get-Date).ToUniversalTime().ToString("o")
        codexHome = $ResolvedCodexHome
        status = "prepared"
        originalHashes = [ordered]@{
            "config.toml" = Get-Sha256 -Path $configEvidencePath
            "hooks.json" = Get-Sha256 -Path $hooksEvidencePath
            "codex-file-tools.yml" = Get-Sha256 -Path $serenaContextEvidencePath
            legacyHooks = $legacyHashes
        }
        preservedHookTree = @($State.preservedHookTree)
        intendedResources = [ordered]@{
            "config.toml" = if ($State.desiredConfig.changed) { Get-TextSha256 -Content $State.desiredConfig.content } else { $null }
            "hooks.json" = if ($State.desiredHooks.changed) { Get-TextSha256 -Content $State.desiredHooks.content } else { $null }
        }
        attemptedResources = @()
        committedResources = @()
        retiredResources = @()
        aclTargets = @()
        concurrentReplace = $null
        rollbackConcurrentReplaces = @()
        error = $null
    }
    $manifestPath = Join-Path $evidencePath "manifest.json"
    Write-Manifest -Path $manifestPath -Manifest $manifest

    [pscustomobject]@{
        path = $evidencePath
        manifestPath = $manifestPath
        manifest = $manifest
    }
}

function Invoke-Repair {
    param(
        [string]$ResolvedCodexHome,
        [object]$InitialState
    )

    if ($InitialState.ok) {
        return New-Result -ResultMode "Repair" -State $InitialState -Changed $false -EvidencePath $null
    }

    $originalConfigAcl = Get-Acl -LiteralPath $InitialState.configPath
    $originalHooksAcl = Get-Acl -LiteralPath $InitialState.hooksPath
    $snapshot = New-EvidenceSnapshot -ResolvedCodexHome $ResolvedCodexHome -State $InitialState
    $manifest = $snapshot.manifest
    $committed = [System.Collections.Generic.List[string]]::new()
    $attempted = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    try {
        $manifest.status = "applying"
        Write-Manifest -Path $snapshot.manifestPath -Manifest $manifest
        if ($InitialState.desiredConfig.changed) {
            if ((Get-Sha256 -Path $InitialState.configPath) -ne $manifest.originalHashes["config.toml"]) {
                throw "config.toml 在修复前置校验后发生并发变化"
            }
            $attempted.Add("config.toml") | Out-Null
            $manifest.attemptedResources = @($attempted)
            Write-Manifest -Path $snapshot.manifestPath -Manifest $manifest
            Write-AtomicText `
                -Path $InitialState.configPath `
                -Content $InitialState.desiredConfig.content `
                -ExpectedCurrentSha256 $manifest.originalHashes["config.toml"] `
                -ExpectedCurrentSddl $originalConfigAcl.Sddl
            $validatedConfig = Get-DesiredConfig -Content (Read-Text -Path $InitialState.configPath) -ExpectedSerenaContextPath $InitialState.serenaContextPath
            if ($validatedConfig.changed) {
                throw "config.toml 原子替换后未通过自验证"
            }
            # The reconciler owns selected config semantics, not the vendor
            # file's long-term ACL policy. Preserve the metadata observed at
            # transaction start instead of silently widening or hardening it.
            $committed.Add("config.toml")
            $manifest.committedResources = $committed.ToArray()
            Write-Manifest -Path $snapshot.manifestPath -Manifest $manifest
        }

        if ($InitialState.desiredHooks.changed) {
            if ((Get-Sha256 -Path $InitialState.hooksPath) -ne $manifest.originalHashes["hooks.json"]) {
                throw "hooks.json 在修复前置校验后发生并发变化"
            }
            $attempted.Add("hooks.json") | Out-Null
            $manifest.attemptedResources = @($attempted)
            Write-Manifest -Path $snapshot.manifestPath -Manifest $manifest
            Write-AtomicText `
                -Path $InitialState.hooksPath `
                -Content $InitialState.desiredHooks.content `
                -ExpectedCurrentSha256 $manifest.originalHashes["hooks.json"] `
                -ExpectedCurrentSddl $originalHooksAcl.Sddl
            $validatedHooks = Get-DesiredHooksJson -Content (Read-Text -Path $InitialState.hooksPath)
            if ($validatedHooks.changed) {
                throw "hooks.json 原子替换后未通过自验证"
            }
            $committed.Add("hooks.json")
            $manifest.committedResources = $committed.ToArray()
            Write-Manifest -Path $snapshot.manifestPath -Manifest $manifest
        }
    } catch {
        $failure = $_
        $rollbackErrors = [System.Collections.Generic.List[string]]::new()
        $concurrentReplace = Get-ConcurrentReplaceRecord -Exception $failure.Exception
        $concurrentReplacePath = if ($null -eq $concurrentReplace) { "" } else { $concurrentReplace.path }
        $manifest.concurrentReplace = $concurrentReplace
        if ($attempted.Contains("config.toml") -and -not $concurrentReplacePath.Equals($InitialState.configPath, [System.StringComparison]::OrdinalIgnoreCase)) {
            try {
                $currentConfig = Read-Text -Path $InitialState.configPath
                if ($currentConfig.Equals($InitialState.desiredConfig.content, [System.StringComparison]::Ordinal)) {
                    Write-AtomicText `
                        -Path $InitialState.configPath `
                        -Content $InitialState.configContent `
                        -ExpectedCurrentSha256 $manifest.intendedResources["config.toml"] `
                        -ExpectedCurrentSddl $originalConfigAcl.Sddl
                } elseif (-not $currentConfig.Equals($InitialState.configContent, [System.StringComparison]::Ordinal)) {
                    throw "检测到非本次 Repair 写入的并发内容，拒绝覆盖"
                }
            } catch {
                $rollbackConcurrent = Get-ConcurrentReplaceRecord -Exception $_.Exception
                if ($null -ne $rollbackConcurrent) {
                    $manifest.rollbackConcurrentReplaces = @($manifest.rollbackConcurrentReplaces) + @($rollbackConcurrent)
                }
                $rollbackErrors.Add("config.toml: $($_.Exception.Message)")
            }
        } elseif ($attempted.Contains("config.toml")) {
            $rollbackErrors.Add("config.toml: 并发版本已保留，拒绝用旧快照覆盖")
        }
        if ($attempted.Contains("hooks.json") -and -not $concurrentReplacePath.Equals($InitialState.hooksPath, [System.StringComparison]::OrdinalIgnoreCase)) {
            try {
                $currentHooks = Read-Text -Path $InitialState.hooksPath
                if ($currentHooks.Equals($InitialState.desiredHooks.content, [System.StringComparison]::Ordinal)) {
                    Write-AtomicText `
                        -Path $InitialState.hooksPath `
                        -Content $InitialState.hooksContent `
                        -ExpectedCurrentSha256 $manifest.intendedResources["hooks.json"] `
                        -ExpectedCurrentSddl $originalHooksAcl.Sddl
                } elseif (-not $currentHooks.Equals($InitialState.hooksContent, [System.StringComparison]::Ordinal)) {
                    throw "检测到非本次 Repair 写入的并发内容，拒绝覆盖"
                }
            } catch {
                $rollbackConcurrent = Get-ConcurrentReplaceRecord -Exception $_.Exception
                if ($null -ne $rollbackConcurrent) {
                    $manifest.rollbackConcurrentReplaces = @($manifest.rollbackConcurrentReplaces) + @($rollbackConcurrent)
                }
                $rollbackErrors.Add("hooks.json: $($_.Exception.Message)")
            }
        } elseif ($attempted.Contains("hooks.json")) {
            $rollbackErrors.Add("hooks.json: 并发版本已保留，拒绝用旧快照覆盖")
        }

        $manifest.status = if ($rollbackErrors.Count -eq 0) { "rolled-back" } else { "unsafe-partial" }
        $manifest.error = $failure.Exception.Message
        if ($rollbackErrors.Count -gt 0) {
            $manifest.rollbackErrors = $rollbackErrors.ToArray()
        }
        Write-Manifest -Path $snapshot.manifestPath -Manifest $manifest
        if ($rollbackErrors.Count -gt 0) {
            throw "修复失败且回滚不完整：$($rollbackErrors -join '; ')"
        }
        throw $failure
    }

    try {
        $postCommitConfig = Get-DesiredConfig -Content (Read-Text -Path $InitialState.configPath) -ExpectedSerenaContextPath $InitialState.serenaContextPath
        $postCommitHooks = Get-DesiredHooksJson -Content (Read-Text -Path $InitialState.hooksPath)
        if ($postCommitConfig.changed -or $postCommitHooks.changed) {
            throw "两文件提交完成后目标状态被并发改写"
        }

        $aclTargets = @(
            $InitialState.hooksPath,
            $InitialState.serenaContextPath,
            $InitialState.hookDirectory
        ) + @(
            Get-ChildItem -LiteralPath $InitialState.hookDirectory -Recurse -Force | ForEach-Object { $_.FullName }
        )
        $aclApplied = [System.Collections.Generic.List[string]]::new()
        foreach ($path in $aclTargets) {
            Assert-NoReparsePath -Path $path -RequireLeaf | Out-Null
            Set-ProtectedAcl -Path $path
            $aclApplied.Add($path)
            $manifest.aclTargets = $aclApplied.ToArray()
            Write-Manifest -Path $snapshot.manifestPath -Manifest $manifest
            Invoke-FixturePostCommitFailure -Phase "acl"
        }

        $retired = [System.Collections.Generic.List[string]]::new()
        foreach ($name in $InitialState.legacyPresent) {
            $livePath = Join-Path $InitialState.hookDirectory $name
            $evidencePath = Join-Path $snapshot.path "legacy-hooks\$name"
            Assert-NoReparsePath -Path $livePath -RequireLeaf | Out-Null
            if (-not (Test-Path -LiteralPath $evidencePath -PathType Leaf)) {
                throw "退役前缺少 legacy evidence：$name"
            }
            if ((Get-Sha256 -Path $livePath) -ne (Get-Sha256 -Path $evidencePath)) {
                throw "退役前 legacy evidence 哈希不一致：$name"
            }
            Remove-Item -LiteralPath $livePath -Force
            $retired.Add($name)
            $manifest.retiredResources = $retired.ToArray()
            Write-Manifest -Path $snapshot.manifestPath -Manifest $manifest
            Invoke-FixturePostCommitFailure -Phase "legacy"
        }
        foreach ($directoryName in $InitialState.legacyDirectoriesPresent) {
            $legacyDirectoryPath = Join-Path $InitialState.hookDirectory $directoryName
            Assert-NoReparsePath -Path $legacyDirectoryPath -RequireLeaf | Out-Null
            if (@(Get-ChildItem -LiteralPath $legacyDirectoryPath -Force).Count -ne 0) {
                throw "legacy 目录包含非 allowlist 内容，拒绝删除：$directoryName"
            }
            Remove-Item -LiteralPath $legacyDirectoryPath -Force
            $retired.Add("$directoryName\")
            $manifest.retiredResources = $retired.ToArray()
            Write-Manifest -Path $snapshot.manifestPath -Manifest $manifest
            Invoke-FixturePostCommitFailure -Phase "legacy"
        }
        $manifest.retiredResources = $retired.ToArray()

        $finalState = Get-ReconciliationState -ResolvedCodexHome $ResolvedCodexHome
        if (-not $finalState.ok) {
            throw "Repair 完成后仍有 $($finalState.driftCount) 类 drift"
        }
        $initialPreservedTree = @($InitialState.preservedHookTree) | ConvertTo-Json -Depth 4 -Compress
        $finalPreservedTree = @($finalState.preservedHookTree) | ConvertTo-Json -Depth 4 -Compress
        if ($initialPreservedTree -cne $finalPreservedTree) {
            throw "未知 hooks tree 的路径或内容在 Repair 期间发生变化"
        }

        $manifest.status = "completed"
        $manifest.completedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
        Write-Manifest -Path $snapshot.manifestPath -Manifest $manifest
        New-Result -ResultMode "Repair" -State $finalState -Changed $true -EvidencePath $snapshot.path
    } catch {
        $manifest.status = "unsafe-partial"
        $manifest.error = $_.Exception.Message
        Write-Manifest -Path $snapshot.manifestPath -Manifest $manifest
        throw
    }
}

try {
    $resolvedHome = Resolve-CodexHome -Value $CodexHome
    if ($Mode -eq "Check") {
        $state = Get-ReconciliationState -ResolvedCodexHome $resolvedHome
        $result = New-Result -ResultMode "Check" -State $state -Changed $false -EvidencePath $null
    } else {
        Assert-RepairHomeAuthorized -ResolvedCodexHome $resolvedHome
        Initialize-FixtureTestSeams -ResolvedCodexHome $resolvedHome
        $mutex = [System.Threading.Mutex]::new($false, (Get-RepairMutexName -ResolvedCodexHome $resolvedHome))
        $lockTaken = $false
        try {
            try {
                $lockTaken = $mutex.WaitOne(5000)
            } catch [System.Threading.AbandonedMutexException] {
                $lockTaken = $true
            }
            if (-not $lockTaken) {
                throw "另一个 Repair 正在处理同一 CodexHome"
            }

            $state = Get-ReconciliationState -ResolvedCodexHome $resolvedHome
            $result = Invoke-Repair -ResolvedCodexHome $resolvedHome -InitialState $state
        } finally {
            if ($lockTaken) {
                $mutex.ReleaseMutex()
            }
            $mutex.Dispose()
        }
    }

    if ($Json) {
        ConvertTo-Json -InputObject $result -Depth 10 -Compress
    } else {
        $result
    }
} catch {
    if ($Json) {
        [pscustomobject]@{
            schemaVersion = 1
            mode = $Mode
            ok = $false
            changed = $null
            driftCount = $null
            checks = @()
            evidencePath = $script:CurrentEvidencePath
            error = [pscustomobject]@{
                code = "reconciliation-failed"
                message = "检查或修复失败；JSON 输出已脱敏，请在受保护 evidence 中查看详细诊断（如有）"
            }
        } | ConvertTo-Json -Depth 6 -Compress | Write-Output
        throw "reconciliation-failed"
    }
    throw
}
