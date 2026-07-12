param(
  [switch]$Watch,
  [switch]$CheckNetwork,
  [switch]$Json
)

$ErrorActionPreference = "Stop"
$ConfigPath = "D:\Codex\.codex\config.toml"
$ConfigMutexName = "Local\CodexConfigTomlGuard"
$ConfigBackupRoot = "D:\Codex\.codex\backups_state\provider-stability-guard"
$TempRoot = "D:\Codex\.codex\tmp"
$PythonPath = "D:\Codex\tools\python314-official\python.exe"
$MobilePermissionGuardPath = "D:\Codex\.codex\hooks\codex-mobile-permission-guard.py"
$ExpectedProxyUrl = "http://127.0.0.1:10808"
$ExpectedNoProxy = "localhost,127.0.0.1,::1"
$ExpectedProxyEnvironment = @(
  [ordered]@{ Name = "HTTP_PROXY"; Value = $ExpectedProxyUrl },
  [ordered]@{ Name = "HTTPS_PROXY"; Value = $ExpectedProxyUrl },
  [ordered]@{ Name = "http_proxy"; Value = $ExpectedProxyUrl },
  [ordered]@{ Name = "https_proxy"; Value = $ExpectedProxyUrl },
  [ordered]@{ Name = "ALL_PROXY"; Value = $ExpectedProxyUrl },
  [ordered]@{ Name = "all_proxy"; Value = $ExpectedProxyUrl },
  [ordered]@{ Name = "NO_PROXY"; Value = $ExpectedNoProxy },
  [ordered]@{ Name = "no_proxy"; Value = $ExpectedNoProxy }
)

function Get-Newline {
  param([string]$Text)
  if ($Text.Contains("`r`n")) { return "`r`n" }
  return "`n"
}

function Format-KeyLine {
  param([string]$Key, [object]$Value)
  return "$Key = $Value"
}

function Ensure-TomlSectionKeys {
  param(
    [string]$Text,
    [string]$Section,
    [System.Collections.Specialized.OrderedDictionary]$Keys
  )

  $nl = Get-Newline $Text
  $sectionPattern = "(?ms)^\s*\[$([regex]::Escape($Section))\]\s*(?:\#[^\r\n]*)?(?:\r?\n|\z).*?(?=^\s*\[\[?[^\r\n\]]+\]\]?\s*(?:\#[^\r\n]*)?(?:\r?\n|$)|\z)"
  $matches = [regex]::Matches($Text, $sectionPattern)

  if ($matches.Count -eq 0) {
    $lines = @("[$Section]")
    foreach ($key in $Keys.Keys) {
      $lines += (Format-KeyLine $key $Keys[$key])
    }
    $block = ($lines -join $nl) + $nl
    return $Text.TrimEnd() + $nl + $nl + $block
  }

  if ($matches.Count -gt 1) {
    throw "Duplicate TOML section [$Section] found."
  }

  $match = [regex]::Match($Text, $sectionPattern)
  $sectionText = $match.Value.TrimEnd()
  $lines = $sectionText -split "\r?\n"
  $header = $lines[0]
  $body = @()

  for ($i = 1; $i -lt $lines.Count; $i++) {
    $line = $lines[$i]
    $isManaged = $false
    foreach ($key in $Keys.Keys) {
      if ($line -match "^\s*$([regex]::Escape($key))\s*=") {
        $isManaged = $true
        break
      }
    }
    if (-not $isManaged) {
      $body += $line
    }
  }

  while ($body.Count -gt 0 -and [string]::IsNullOrWhiteSpace($body[$body.Count - 1])) {
    $body = $body[0..($body.Count - 2)]
  }

  $newLines = @($header) + $body
  foreach ($key in $Keys.Keys) {
    $newLines += (Format-KeyLine $key $Keys[$key])
  }
  $newSection = ($newLines -join $nl) + $nl

  return $Text.Remove($match.Index, $match.Length).Insert($match.Index, $newSection)
}

function Remove-TomlKeyLines {
  param(
    [string]$Text,
    [string[]]$Keys
  )

  $nl = Get-Newline $Text
  $lines = [regex]::Split($Text, "\r?\n")
  $kept = @()

  foreach ($line in $lines) {
    $remove = $false
    foreach ($key in $Keys) {
      if ($line -match "^\s*$([regex]::Escape($key))\s*=") {
        $remove = $true
        break
      }
    }
    if (-not $remove) {
      $kept += $line
    }
  }

  return ($kept -join $nl)
}

function Assert-ProviderTomlFileValid {
  param([Parameter(Mandatory = $true)][string]$Path)

  if (-not (Test-Path -LiteralPath $PythonPath -PathType Leaf)) {
    throw "Python TOML validator not found: $PythonPath"
  }
  $code = 'import pathlib, sys, tomllib; tomllib.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))'
  $output = @(& $PythonPath -c $code $Path 2>&1)
  if ($LASTEXITCODE -ne 0) {
    throw "TOML validation failed for ${Path}: $($output -join ' ')"
  }
}

function Write-ValidatedProviderToml {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$Text
  )

  New-Item -ItemType Directory -Path $TempRoot -Force | Out-Null
  $unique = "{0}-{1}-{2}" -f (Get-Date -Format 'yyyyMMdd-HHmmss-fff'), $PID, ([guid]::NewGuid().ToString('N').Substring(0, 8))
  $tempPath = Join-Path $TempRoot "config-provider-$unique.toml"
  try {
    [IO.File]::WriteAllText($tempPath, $Text, [Text.UTF8Encoding]::new($false))
    Assert-ProviderTomlFileValid -Path $tempPath
    $backupDirectory = Join-Path $ConfigBackupRoot $unique
    New-Item -ItemType Directory -Path $backupDirectory -Force | Out-Null
    Copy-Item -LiteralPath $Path -Destination (Join-Path $backupDirectory 'config.toml')
    [IO.File]::Move($tempPath, $Path, $true)
    $tempPath = $null
  }
  finally {
    if ($null -ne $tempPath -and (Test-Path -LiteralPath $tempPath)) {
      Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
    }
  }
}

function Apply-ProviderStabilityGuard {
  $mutex = [Threading.Mutex]::new($false, $ConfigMutexName)
  $acquired = $false
  try {
    try {
      $acquired = $mutex.WaitOne(10000)
    }
    catch [Threading.AbandonedMutexException] {
      $acquired = $true
    }
    if (-not $acquired) {
      throw "Timed out waiting for the shared Codex TOML mutex."
    }
    if (-not (Test-Path -LiteralPath $ConfigPath)) {
      return
    }

    Assert-ProviderTomlFileValid -Path $ConfigPath
    $original = Get-Content -LiteralPath $ConfigPath -Raw
    $text = $original

    $featureKeys = [ordered]@{
      unified_exec = "true"
      image_generation = "false"
      responses_websockets_v2 = "false"
      responses_websockets = "false"
      network_proxy = "false"
      respect_system_proxy = "false"
    }
    $networkKeys = [ordered]@{
      enabled = "true"
      allow_local_binding = "true"
      allow_upstream_proxy = "true"
      proxy_url = '"http://127.0.0.1:10808"'
    }

    $text = Remove-TomlKeyLines $text @("experimental_use_unified_exec_tool")
    $text = Ensure-TomlSectionKeys $text "features" $featureKeys
    $text = Ensure-TomlSectionKeys $text "network" $networkKeys

    $changed = $text -ne $original
    if ($changed) {
      Write-ValidatedProviderToml -Path $ConfigPath -Text $text
    }

    return $changed
  }
  finally {
    if ($acquired) {
      $mutex.ReleaseMutex()
    }
    $mutex.Dispose()
  }
}

function Test-ProxyEnvironmentPlaceholder {
  param([AllowNull()] [string]$Value)
  return ($null -ne $Value -and $Value -match '\[REDACTED\]')
}

function Test-ProxyEnvironmentSyntax {
  param(
    [string]$Name,
    [AllowNull()] [string]$Value
  )

  if ($Name -match '^(NO_PROXY|no_proxy)$') {
    return -not (Test-ProxyEnvironmentPlaceholder -Value $Value)
  }

  if ([string]::IsNullOrWhiteSpace($Value)) {
    return $false
  }
  if (Test-ProxyEnvironmentPlaceholder -Value $Value) {
    return $false
  }

  try {
    $uri = [uri]$Value
    return (
      $uri.IsAbsoluteUri -and
      $uri.Scheme -in @('http', 'https', 'socks4', 'socks4a', 'socks5', 'socks5h') -and
      -not [string]::IsNullOrWhiteSpace($uri.Host)
    )
  } catch {
    return $false
  }
}

function Protect-CodexProxyEnvironment {
  $repairedUser = @()
  $repairedProcess = @()
  $staleInheritedProcess = @()
  $machineConflicts = @()

  foreach ($entry in $ExpectedProxyEnvironment) {
    $name = [string]$entry['Name']
    $expected = [string]$entry['Value']
    $userBefore = [Environment]::GetEnvironmentVariable($name, 'User')
    $processBefore = [Environment]::GetEnvironmentVariable($name, 'Process')
    $machineBefore = [Environment]::GetEnvironmentVariable($name, 'Machine')

    if ($userBefore -ne $expected) {
      [Environment]::SetEnvironmentVariable($name, $expected, 'User')
      $repairedUser += [ordered]@{
        name = $name
        before = if ($null -eq $userBefore) { $null } elseif (Test-ProxyEnvironmentPlaceholder -Value $userBefore) { '[REDACTED]' } else { $userBefore }
        after = $expected
      }
    }

    if ($processBefore -ne $expected) {
      [Environment]::SetEnvironmentVariable($name, $expected, 'Process')
      $repairedProcess += [ordered]@{
        name = $name
        before = if ($null -eq $processBefore) { $null } elseif (Test-ProxyEnvironmentPlaceholder -Value $processBefore) { '[REDACTED]' } else { $processBefore }
        after = $expected
      }

      $staleInheritedProcess += [ordered]@{
        name = $name
        before = if ($null -eq $processBefore) { $null } elseif (Test-ProxyEnvironmentPlaceholder -Value $processBefore) { '[REDACTED]' } else { $processBefore }
        expected = $expected
      }
    }

    if (-not [string]::IsNullOrWhiteSpace($machineBefore) -and $machineBefore -ne $expected) {
      $machineConflicts += [ordered]@{
        name = $name
        value = if (Test-ProxyEnvironmentPlaceholder -Value $machineBefore) { '[REDACTED]' } else { $machineBefore }
        validSyntax = Test-ProxyEnvironmentSyntax -Name $name -Value $machineBefore
      }
    }
  }

  return [ordered]@{
    expectedProxyUrl = $ExpectedProxyUrl
    expectedNoProxy = $ExpectedNoProxy
    repairedUser = @($repairedUser)
    repairedProcess = @($repairedProcess)
    staleInheritedProcess = @($staleInheritedProcess)
    machineConflicts = @($machineConflicts)
  }
}

function Test-CodexBackendConnectivity {
  $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
  if (-not $curl) {
    return [ordered]@{
      checked = $false
      ok = $false
      reason = 'curl.exe not found'
    }
  }

  $output = & $curl.Source -sS -o NUL -w "http_code=%{http_code} proxy=%{proxy_used}" --connect-timeout 8 "https://chatgpt.com/backend-api/codex/models" 2>&1
  $exitCode = $LASTEXITCODE
  $text = ($output | Out-String).Trim()
  $httpCode = if ($text -match 'http_code=(\d{3})') { $Matches[1] } else { $null }
  $proxyUsed = if ($text -match 'proxy=([01])') { $Matches[1] } else { $null }

  return [ordered]@{
    checked = $true
    ok = ($exitCode -eq 0 -and $httpCode -in @('200', '401', '403') -and $proxyUsed -eq '1')
    exitCode = $exitCode
    httpCode = $httpCode
    proxyUsed = $proxyUsed
    output = $text
  }
}

function Repair-CodexMobilePermissionDrift {
  if (-not (Test-Path -LiteralPath $MobilePermissionGuardPath)) {
    return [ordered]@{
      checked = $false
      ok = $false
      reason = 'mobile permission guard script not found'
    }
  }

  if (-not (Test-Path -LiteralPath $PythonPath)) {
    return [ordered]@{
      checked = $false
      ok = $false
      reason = 'python runtime not found'
    }
  }

  $output = & $PythonPath $MobilePermissionGuardPath 2>&1
  $exitCode = $LASTEXITCODE
  $text = ($output | Out-String).Trim()

  $payload = $null
  if (-not [string]::IsNullOrWhiteSpace($text)) {
    try {
      $payload = $text | ConvertFrom-Json
    } catch {
      $payload = $null
    }
  }

  [object[]]$threadStateChanged = @()
  [object[]]$heartbeatChanged = @()
  if ($payload -and $null -ne $payload.threadStateChanged) {
    $threadStateChanged = @($payload.threadStateChanged)
  }
  if ($payload -and $null -ne $payload.heartbeatChanged) {
    $heartbeatChanged = @($payload.heartbeatChanged)
  }

  return [ordered]@{
    checked = $true
    ok = ($exitCode -eq 0)
    exitCode = $exitCode
    output = $text
    threadStateChanged = $threadStateChanged
    heartbeatChanged = $heartbeatChanged
  }
}

function Invoke-CodexProviderStabilityGuard {
  $configChanged = Apply-ProviderStabilityGuard
  $environment = Protect-CodexProxyEnvironment
  $mobilePermissions = Repair-CodexMobilePermissionDrift
  $network = if ($CheckNetwork) { Test-CodexBackendConnectivity } else { [ordered]@{ checked = $false } }

  $payload = [ordered]@{
    ok = ($environment['staleInheritedProcess'].Count -eq 0 -and $environment['machineConflicts'].Count -eq 0 -and [bool]$mobilePermissions['ok'] -and (-not $CheckNetwork -or [bool]$network['ok']))
    configChanged = [bool]$configChanged
    environment = $environment
    mobilePermissions = $mobilePermissions
    network = $network
  }

  if ($Json) {
    $payload | ConvertTo-Json -Depth 16
  }
  elseif ($configChanged -or $environment['repairedUser'].Count -gt 0 -or $environment['repairedProcess'].Count -gt 0 -or $mobilePermissions['threadStateChanged'].Count -gt 0 -or $mobilePermissions['heartbeatChanged'].Count -gt 0 -or $CheckNetwork) {
    $summary = "configChanged={0}; repairedUser={1}; repairedProcess={2}; mobileThreadStateChanged={3}; mobileHeartbeatChanged={4}" -f $configChanged, $environment['repairedUser'].Count, $environment['repairedProcess'].Count, $mobilePermissions['threadStateChanged'].Count, $mobilePermissions['heartbeatChanged'].Count
    if ($CheckNetwork) {
      $summary = "$summary; networkOk=$($network['ok']); httpCode=$($network['httpCode']); proxyUsed=$($network['proxyUsed'])"
    }
    Write-Output $summary
  }

  if ($environment['machineConflicts'].Count -gt 0) {
    throw "Machine-level proxy environment conflicts were found. Remove or align the Machine values before relying on fresh Codex sessions."
  }

  if ($environment['staleInheritedProcess'].Count -gt 0) {
    throw "Codex inherited stale proxy environment values. User environment was repaired, but the running Codex process cannot be mutated by a child hook; restart Codex so requests inherit $ExpectedProxyUrl."
  }

  if (-not [bool]$mobilePermissions['ok']) {
    throw "Codex mobile permission drift guard failed: $($mobilePermissions['reason']) $($mobilePermissions['output'])"
  }

  if ($CheckNetwork -and -not [bool]$network['ok']) {
    throw "Codex backend connectivity check failed or did not use the configured proxy."
  }
}

if ($Watch) {
  while ($true) {
    try {
      Invoke-CodexProviderStabilityGuard
    } catch {
      # Keep the watcher alive; hook runs will surface persistent failures.
    }
    Start-Sleep -Seconds 1
  }
} else {
  Invoke-CodexProviderStabilityGuard
}
