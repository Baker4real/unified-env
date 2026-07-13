param(
  [switch]$CheckOnly,
  [switch]$CheckAuth,
  [switch]$Strict,
  [switch]$Json
)

$ErrorActionPreference = "Stop"
. 'D:\Codex\.codex\hooks\lib\CodexHookRuntime.ps1'
. 'D:\Codex\.codex\hooks\lib\CodexGitHubCliGuardEntry.ps1'
$GuardStarted = [DateTime]::UtcNow
$GuardStopwatch = [Diagnostics.Stopwatch]::StartNew()
$script:ActiveGitHubGuardState = $null
$GhSourcePath = "D:\Codex\tools\gh\bin\gh.exe"
$ToolsBinPath = "D:\Codex\tools\bin"
$GhNativePath = Join-Path $ToolsBinPath "gh.exe"
$ExpectedGhConfigDir = "D:\Codex\.config\gh"
$ExpectedHostsPath = Join-Path $ExpectedGhConfigDir "hosts.yml"
$BackupRoot = "D:\Codex\.codex\backups_state\github-cli-native-entry"
$FsutilPath = Join-Path $env:SystemRoot "System32\fsutil.exe"
$WherePath = Join-Path $env:SystemRoot "System32\where.exe"
$RepairMutexName = "Local\CodexGitHubCliNativeEntryGuard"
$EnvironmentMutexName = "Local\CodexGitHubCliEnvironmentGuard"

function Normalize-PathEntry {
  param([AllowNull()] [string]$Value)

  if ([string]::IsNullOrWhiteSpace($Value)) {
    return $null
  }

  return $Value.Trim().Trim('"').Replace('/', '\').TrimEnd('\')
}

function Test-EnvironmentPathEntry {
  param(
    [AllowNull()] [string]$PathValue,
    [string]$Expected
  )

  $normalizedExpected = Normalize-PathEntry $Expected
  foreach ($entry in @($PathValue -split ';')) {
    $normalizedEntry = Normalize-PathEntry $entry
    if ($null -ne $normalizedEntry -and [string]::Equals($normalizedEntry, $normalizedExpected, [StringComparison]::OrdinalIgnoreCase)) {
      return $true
    }
  }

  return $false
}

function Protect-GhPersistentEnvironment {
  $mutex = [Threading.Mutex]::new($false, $EnvironmentMutexName)
  $acquired = $false

  try {
    try {
      $acquired = $mutex.WaitOne(1500)
    }
    catch [Threading.AbandonedMutexException] {
      $acquired = $true
    }

    if (-not $acquired) {
      throw "Timed out waiting for the GitHub CLI environment mutex."
    }

    $repairs = @()
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $persistentPathOk = (Test-EnvironmentPathEntry -PathValue $userPath -Expected $ToolsBinPath) -or (Test-EnvironmentPathEntry -PathValue $machinePath -Expected $ToolsBinPath)
    if (-not $persistentPathOk -and -not $CheckOnly) {
      $newUserPath = if ([string]::IsNullOrWhiteSpace($userPath)) { $ToolsBinPath } else { "$ToolsBinPath;$userPath" }
      [Environment]::SetEnvironmentVariable('Path', $newUserPath, 'User')
      $script:ActiveGitHubGuardState.changed = $true
      $repairs += 'userPath'
      $persistentPathOk = $true
    }

    $userConfig = [Environment]::GetEnvironmentVariable('GH_CONFIG_DIR', 'User')
    $persistentConfigOk = [string]::Equals((Normalize-PathEntry $userConfig), (Normalize-PathEntry $ExpectedGhConfigDir), [StringComparison]::OrdinalIgnoreCase)
    if (-not $persistentConfigOk -and -not $CheckOnly) {
      [Environment]::SetEnvironmentVariable('GH_CONFIG_DIR', $ExpectedGhConfigDir, 'User')
      $script:ActiveGitHubGuardState.changed = $true
      $repairs += 'userGhConfigDir'
      $persistentConfigOk = $true
    }

    return [ordered]@{
      pathOk = $persistentPathOk
      ghConfigDirOk = $persistentConfigOk
      repairs = @($repairs)
    }
  }
  finally {
    if ($acquired) {
      $mutex.ReleaseMutex()
    }
    $mutex.Dispose()
  }
}

function Get-HardLinkState {
  param(
    [string]$SourcePath,
    [string]$LinkPath
  )

  if (-not (Test-Path -LiteralPath $FsutilPath -PathType Leaf)) {
    return [ordered]@{ status = 'unverifiable'; reason = 'fsutil.exe is missing' }
  }

  if (-not (Test-Path -LiteralPath $SourcePath -PathType Leaf) -or -not (Test-Path -LiteralPath $LinkPath -PathType Leaf)) {
    return [ordered]@{ status = 'drift'; reason = 'source or link is missing' }
  }

  $sourceDrive = [IO.Path]::GetPathRoot($SourcePath).TrimEnd('\')
  $linkDrive = [IO.Path]::GetPathRoot($LinkPath).TrimEnd('\')
  if (-not [string]::Equals($sourceDrive, $linkDrive, [StringComparison]::OrdinalIgnoreCase)) {
    return [ordered]@{ status = 'drift'; reason = 'source and link are on different volumes' }
  }

  $expectedRelative = $LinkPath.Substring($sourceDrive.Length).Replace('/', '\')
  $links = @(& $FsutilPath hardlink list $SourcePath 2>$null)
  if ($LASTEXITCODE -ne 0) {
    return [ordered]@{ status = 'unverifiable'; reason = 'fsutil hardlink list failed' }
  }

  foreach ($link in $links) {
    if ([string]::Equals(([string]$link).Trim(), $expectedRelative, [StringComparison]::OrdinalIgnoreCase)) {
      return [ordered]@{ status = 'valid'; reason = $null }
    }
  }

  return [ordered]@{ status = 'drift'; reason = 'paths do not share the same file identity' }
}

function Test-GhHardLink {
  return (Get-HardLinkState -SourcePath $GhSourcePath -LinkPath $GhNativePath)['status'] -eq 'valid'
}

function Get-GhSignatureState {
  if (-not (Test-Path -LiteralPath $GhSourcePath -PathType Leaf)) {
    return [ordered]@{ checked = $true; valid = $false; status = 'NotFound'; signer = $null }
  }

  $signature = Get-AuthenticodeSignature -LiteralPath $GhSourcePath
  $signer = if ($signature.SignerCertificate) { $signature.SignerCertificate.Subject } else { $null }
  $publisherOk = $null -ne $signer -and $signer -match '(?i)(^|,\s*)CN="?GitHub, Inc\."?(,|$)'
  return [ordered]@{
    checked = $true
    valid = ($signature.Status -eq 'Valid' -and $publisherOk)
    status = $signature.Status.ToString()
    signer = $signer
  }
}

function Get-ResolvedGhExecutablePath {
  if (-not (Test-Path -LiteralPath $WherePath -PathType Leaf)) {
    return $null
  }

  $matches = @(& $WherePath gh.exe 2>$null)
  if ($LASTEXITCODE -ne 0) {
    return $null
  }

  foreach ($match in $matches) {
    $candidate = ([string]$match).Trim()
    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
      return [IO.Path]::GetFullPath($candidate)
    }
  }

  return $null
}

function Test-GhExecutableIsManaged {
  param([AllowNull()] [string]$Path)

  if ([string]::IsNullOrWhiteSpace($Path)) {
    return $false
  }

  return (Get-HardLinkState -SourcePath $GhSourcePath -LinkPath $Path)['status'] -eq 'valid'
}

function Repair-GhHardLink {
  $mutex = [Threading.Mutex]::new($false, $RepairMutexName)
  $acquired = $false
  $temporaryLinkPath = $null
  $restorePath = $null

  try {
    try {
      $acquired = $mutex.WaitOne(1500)
    }
    catch [Threading.AbandonedMutexException] {
      $acquired = $true
    }

    if (-not $acquired) {
      throw "Timed out waiting for the GitHub CLI repair mutex."
    }

    $state = Get-HardLinkState -SourcePath $GhSourcePath -LinkPath $GhNativePath
    if ($state['status'] -eq 'valid') {
      return [ordered]@{ changed = $false; backupPath = $null }
    }
    if ($state['status'] -eq 'unverifiable') {
      throw "Refusing to repair an unverifiable GitHub CLI entry: $($state['reason'])"
    }
    if ($CheckOnly) {
      return [ordered]@{ changed = $false; backupPath = $null }
    }
    if (-not (Test-Path -LiteralPath $GhSourcePath -PathType Leaf)) {
      throw "Official GitHub CLI binary not found: $GhSourcePath"
    }

    $verifierState = Get-HardLinkState -SourcePath $GhSourcePath -LinkPath $GhSourcePath
    if ($verifierState['status'] -ne 'valid') {
      throw "Refusing to repair because hard-link identity cannot be verified: $($verifierState['reason'])"
    }

    $signature = Get-GhSignatureState
    if (-not [bool]$signature['valid']) {
      throw "Refusing to link an unsigned or unexpected GitHub CLI binary: status=$($signature['status']); signer=$($signature['signer'])"
    }

    if (-not (Test-Path -LiteralPath $ToolsBinPath -PathType Container)) {
      New-Item -ItemType Directory -Path $ToolsBinPath -Force | Out-Null
    }
    if ((Test-Path -LiteralPath $GhNativePath) -and -not (Test-Path -LiteralPath $GhNativePath -PathType Leaf)) {
      throw "Refusing to replace a non-file GitHub CLI entry: $GhNativePath"
    }

    $unique = "{0}-{1}-{2}" -f (Get-Date -Format 'yyyyMMdd-HHmmss-fff'), $PID, ([guid]::NewGuid().ToString('N').Substring(0, 8))
    $temporaryLinkPath = Join-Path $ToolsBinPath ".gh-codex-guard-$unique.tmp"
    New-Item -ItemType HardLink -Path $temporaryLinkPath -Target $GhSourcePath | Out-Null
    $temporaryState = Get-HardLinkState -SourcePath $GhSourcePath -LinkPath $temporaryLinkPath
    if ($temporaryState['status'] -ne 'valid') {
      throw "Temporary GitHub CLI hard link could not be verified: $($temporaryState['reason'])"
    }

    $backupPath = $null
    if (Test-Path -LiteralPath $GhNativePath -PathType Leaf) {
      $backupDirectory = Join-Path $BackupRoot $unique
      New-Item -ItemType Directory -Path $backupDirectory -Force | Out-Null
      $backupPath = Join-Path $backupDirectory 'gh.exe'
      Copy-Item -LiteralPath $GhNativePath -Destination $backupPath
    }

    [IO.File]::Move($temporaryLinkPath, $GhNativePath, $true)
    $script:ActiveGitHubGuardState.changed = $true
    $temporaryLinkPath = $null
    $finalState = Get-HardLinkState -SourcePath $GhSourcePath -LinkPath $GhNativePath
    if ($finalState['status'] -ne 'valid') {
      if ($null -ne $backupPath -and (Test-Path -LiteralPath $backupPath -PathType Leaf)) {
        $restorePath = Join-Path $ToolsBinPath ".gh-codex-restore-$unique.tmp"
        Copy-Item -LiteralPath $backupPath -Destination $restorePath
        [IO.File]::Move($restorePath, $GhNativePath, $true)
        $restorePath = $null
      }
      elseif (Test-Path -LiteralPath $GhNativePath -PathType Leaf) {
        Remove-Item -LiteralPath $GhNativePath -Force
      }
      throw "Managed GitHub CLI hard link failed post-switch verification: $($finalState['reason'])"
    }

    return [ordered]@{ changed = $true; backupPath = $backupPath }
  }
  finally {
    if ($null -ne $temporaryLinkPath -and (Test-Path -LiteralPath $temporaryLinkPath)) {
      Remove-Item -LiteralPath $temporaryLinkPath -Force -ErrorAction SilentlyContinue
    }
    if ($null -ne $restorePath -and (Test-Path -LiteralPath $restorePath)) {
      Remove-Item -LiteralPath $restorePath -Force -ErrorAction SilentlyContinue
    }
    if ($acquired) {
      $mutex.ReleaseMutex()
    }
    $mutex.Dispose()
  }
}

function Invoke-NativeProbe {
  param(
    [string]$FileName,
    [string[]]$Arguments,
    [int]$TimeoutMs
  )

  $startInfo = [Diagnostics.ProcessStartInfo]::new()
  $startInfo.FileName = $FileName
  $startInfo.UseShellExecute = $false
  $startInfo.CreateNoWindow = $true
  $startInfo.RedirectStandardOutput = $true
  $startInfo.RedirectStandardError = $true
  $startInfo.Environment['GIT_TERMINAL_PROMPT'] = '0'
  $startInfo.Environment['GH_PROMPT_DISABLED'] = '1'
  foreach ($argument in $Arguments) {
    $startInfo.ArgumentList.Add($argument)
  }

  $process = [Diagnostics.Process]::new()
  $process.StartInfo = $startInfo
  $stopwatch = [Diagnostics.Stopwatch]::StartNew()

  try {
    $started = $process.Start()
    if (-not $started) {
      return [ordered]@{ success = $false; exitCode = $null; durationMs = $stopwatch.ElapsedMilliseconds; timedOut = $false; error = 'Process.Start returned false'; executablePath = $null }
    }

    $executablePath = try { $process.MainModule.FileName } catch { $null }
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()

    if (-not $process.WaitForExit($TimeoutMs)) {
      try { $process.Kill($true) } catch {}
      try { [void]$stdoutTask.GetAwaiter().GetResult() } catch {}
      try { [void]$stderrTask.GetAwaiter().GetResult() } catch {}
      return [ordered]@{ success = $false; exitCode = $null; durationMs = $stopwatch.ElapsedMilliseconds; timedOut = $true; error = 'timeout'; executablePath = $executablePath }
    }
    [void]$stdoutTask.GetAwaiter().GetResult()
    [void]$stderrTask.GetAwaiter().GetResult()

    return [ordered]@{
      success = ($process.ExitCode -eq 0)
      exitCode = $process.ExitCode
      durationMs = $stopwatch.ElapsedMilliseconds
      timedOut = $false
      error = $null
      executablePath = $executablePath
    }
  }
  catch {
    $nativeErrorCode = if ($_.Exception.InnerException -and $null -ne $_.Exception.InnerException.NativeErrorCode) {
      $_.Exception.InnerException.NativeErrorCode
    }
    elseif ($null -ne $_.Exception.NativeErrorCode) {
      $_.Exception.NativeErrorCode
    }
    else {
      $null
    }

    return [ordered]@{
      success = $false
      exitCode = $null
      durationMs = $stopwatch.ElapsedMilliseconds
      timedOut = $false
      error = $_.Exception.Message
      nativeErrorCode = $nativeErrorCode
      executablePath = $null
    }
  }
  finally {
    $stopwatch.Stop()
    $process.Dispose()
  }
}

function Invoke-CodexGitHubCliGuard {
  param([Parameter(Mandatory)][object]$State)
  $repairs = @()
  $sourceExists = Test-Path -LiteralPath $GhSourcePath -PathType Leaf
  $processPathOk = Test-EnvironmentPathEntry -PathValue ([Environment]::GetEnvironmentVariable('Path', 'Process')) -Expected $ToolsBinPath
  $processConfig = [Environment]::GetEnvironmentVariable('GH_CONFIG_DIR', 'Process')
  $processConfigOk = [string]::Equals((Normalize-PathEntry $processConfig), (Normalize-PathEntry $ExpectedGhConfigDir), [StringComparison]::OrdinalIgnoreCase)
  $State.restartRequired = (-not $processPathOk) -or (-not $processConfigOk)
  $persistentEnvironment = Protect-GhPersistentEnvironment
  $repairs += @($persistentEnvironment['repairs'])

  $linkRepair = Repair-GhHardLink
  if ($linkRepair['changed']) {
    $repairs += 'nativeHardLink'
  }

  $hardLinkState = Get-HardLinkState -SourcePath $GhSourcePath -LinkPath $GhNativePath
  $nativeLinkOk = $hardLinkState['status'] -eq 'valid'
  $signatureState = Get-GhSignatureState
  $hostsExists = Test-Path -LiteralPath $ExpectedHostsPath -PathType Leaf
  $resolvedExecutablePath = Get-ResolvedGhExecutablePath
  $managedResolutionOk = Test-GhExecutableIsManaged -Path $resolvedExecutablePath
  $versionAttempts = @()
  if ($processPathOk -and $nativeLinkOk -and [bool]$signatureState['valid'] -and $managedResolutionOk) {
    $versionAttempts += Invoke-NativeProbe -FileName $resolvedExecutablePath -Arguments @('--version') -TimeoutMs 1000
    if (-not [bool]$versionAttempts[-1]['success'] -and $versionAttempts[-1]['nativeErrorCode'] -ne 2) {
      $versionAttempts += Invoke-NativeProbe -FileName $resolvedExecutablePath -Arguments @('--version') -TimeoutMs 1000
    }
    $versionProbe = $versionAttempts[-1]
    $versionProbe['attemptCount'] = $versionAttempts.Count
  }
  else {
    $versionProbe = [ordered]@{ success = $false; skipped = $true; attemptCount = 0 }
  }
  $versionExecutablePath = if ($null -ne $versionProbe['executablePath']) { $versionProbe['executablePath'] } else { $resolvedExecutablePath }
  $versionExecutableManaged = Test-GhExecutableIsManaged -Path $versionExecutablePath

  $authProbe = if (-not $CheckAuth) {
    [ordered]@{ checked = $false; success = $null; skipped = $true }
  }
  elseif ($processPathOk -and $nativeLinkOk -and [bool]$signatureState['valid'] -and $processConfigOk -and $managedResolutionOk -and $versionExecutableManaged -and [bool]$versionProbe['success']) {
    $probe = Invoke-NativeProbe -FileName $resolvedExecutablePath -Arguments @('auth', 'status') -TimeoutMs 5000
    $probe['checked'] = $true
    $probe
  }
  else {
    [ordered]@{ checked = $true; success = $false; skipped = $true }
  }
  $authExecutablePath = if ($null -ne $authProbe['executablePath']) { $authProbe['executablePath'] } else { $resolvedExecutablePath }
  $authExecutableManaged = (-not $CheckAuth) -or (Test-GhExecutableIsManaged -Path $authExecutablePath)
  $restartRequired = [bool]$State.restartRequired
  $authOk = (-not $CheckAuth) -or ([bool]$authProbe['success'] -and $authExecutableManaged)

  $payload = [ordered]@{
    ok = ($sourceExists -and [bool]$signatureState['valid'] -and $nativeLinkOk -and $processPathOk -and [bool]$persistentEnvironment['pathOk'] -and $processConfigOk -and [bool]$persistentEnvironment['ghConfigDirOk'] -and $managedResolutionOk -and $versionExecutableManaged -and [bool]$versionProbe['success'] -and $authOk)
    sourcePath = $GhSourcePath
    nativePath = $GhNativePath
    sourceExists = $sourceExists
    sourceSignature = $signatureState
    hardLinkState = $hardLinkState
    nativeHardLinkOk = $nativeLinkOk
    processPathOk = $processPathOk
    persistentPathOk = [bool]$persistentEnvironment['pathOk']
    resolvedExecutablePath = $resolvedExecutablePath
    managedResolutionOk = $managedResolutionOk
    processGhConfigDirOk = $processConfigOk
    persistentGhConfigDirOk = [bool]$persistentEnvironment['ghConfigDirOk']
    hostsExists = $hostsExists
    versionProbe = $versionProbe
    authProbe = $authProbe
    authCheckRequested = [bool]$CheckAuth
    repairs = @($repairs)
    backupPath = $linkRepair['backupPath']
    restartRequired = $restartRequired
    changed = [bool]$State.changed
    errors = [string[]]$(if ($sourceExists -and [bool]$signatureState['valid'] -and $nativeLinkOk -and $processPathOk -and [bool]$persistentEnvironment['pathOk'] -and $processConfigOk -and [bool]$persistentEnvironment['ghConfigDirOk'] -and $managedResolutionOk -and $versionExecutableManaged -and [bool]$versionProbe['success'] -and $authOk) { @() } else { @('github-cli health check failed') })
  }
  return $payload
}

$operation = {
  param($state)
  $script:ActiveGitHubGuardState = $state
  try { Invoke-CodexGitHubCliGuard -State $state }
  finally { $script:ActiveGitHubGuardState = $null }
}
$healthWriter = {
  param($state, $payload)
  $GuardStopwatch.Stop()
  $healthErrors = if ([bool]$payload['ok']) { [string[]]@() } else { [string[]]@($payload['errors']) }
  $healthPayload = [pscustomobject][ordered]@{
    hookId = 'github-cli'; runId = [guid]::NewGuid().ToString('N')
    startedAtUtc = $GuardStarted.ToString('o'); completedAtUtc = [DateTime]::UtcNow.ToString('o')
    durationMs = [long]$GuardStopwatch.ElapsedMilliseconds; ok = [bool]$payload['ok']
    changed = [bool]$state.changed; restartRequired = [bool]$state.restartRequired; errors = [string[]]$healthErrors
  }
  Write-CodexHookLatestHealth -HookId 'github-cli' -Payload $healthPayload
}
Invoke-CodexGitHubCliGuardEntry -Operation $operation -HealthWriter $healthWriter -Json:$Json -Strict:$Strict
