Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Set-LineEnding([string]$Path, [string]$NewLine) {
    [IO.File]::WriteAllText($Path, ([IO.File]::ReadAllText($Path) -replace "`r?`n", $NewLine), [Text.UTF8Encoding]::new($false))
}

function Invoke-ExternalProcess {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [hashtable]$Environment = @{}
    )

    $utf8 = [Text.UTF8Encoding]::new($false)
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $FilePath
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.StandardOutputEncoding = $utf8
    $startInfo.StandardErrorEncoding = $utf8
    foreach ($argument in $ArgumentList) {
        [void]$startInfo.ArgumentList.Add($argument)
    }
    foreach ($key in $Environment.Keys) {
        $value = $Environment[$key]
        if ($null -eq $value) {
            [void]$startInfo.Environment.Remove([string]$key)
        }
        else {
            $startInfo.Environment[[string]$key] = [string]$value
        }
    }

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        [void]$process.Start()
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        return [pscustomobject]@{
            exitCode = [int]$process.ExitCode
            stdout = [string]$stdoutTask.GetAwaiter().GetResult()
            stderr = [string]$stderrTask.GetAwaiter().GetResult()
        }
    }
    finally {
        $process.Dispose()
    }
}

function Invoke-WrapperCli {
    param(
        [Parameter(Mandatory)][string]$WrapperPath,
        [string[]]$Arguments = @(),
        [hashtable]$Environment = @{}
    )

    Assert-True ($WrapperPath.EndsWith('.ps1', [StringComparison]::OrdinalIgnoreCase)) "canonical wrapper must be a .ps1 entrypoint: $WrapperPath"
    $pwshExe = (Get-Process -Id $PID).Path
    return Invoke-ExternalProcess `
        -FilePath $pwshExe `
        -ArgumentList (@('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $WrapperPath) + $Arguments) `
        -Environment $Environment
}

function Remove-FixtureRunRoot {
    param([Parameter(Mandatory)][string]$Path)

    if (-not [IO.Directory]::Exists($Path)) { return }
    $parent = Split-Path -Parent $Path
    $snapshot = Get-CodexHookCapabilityDirectoryTreeSnapshot `
        -Path $Path `
        -CapabilityRoot $parent `
        -AllowedExactPaths @($Path) `
        -Name 'skill install deployment test cleanup snapshot'
    Remove-CodexHookCapabilityDirectoryTree `
        -Path $Path `
        -CapabilityRoot $parent `
        -AllowedExactPaths @($Path) `
        -ExpectedRootIdentity @($snapshot.rootIdentity) `
        -ExpectedTreeManifest $snapshot `
        -Scope 'skill install deployment test cleanup'
}

$projectRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $projectRoot 'scripts\lib\CodexHostSafety.ps1')
$deployPath = Join-Path $projectRoot 'scripts\Deploy-SkillInstallGuarded.ps1'
$implementationRoot = Join-Path $projectRoot 'modules\skill-supply-chain\implementation'
$wrapperPath = Join-Path $implementationRoot 'install_skill_guarded.py'
$retiredCmdWrapperPath = Join-Path $projectRoot 'scripts\install-skill-guarded.cmd'
$psCommandWrapperPath = Join-Path $projectRoot 'scripts\install-skill-guarded.ps1'
$sourceRecordPath = Join-Path $implementationRoot 'skill_source_record.py'
$systemRepairPath = Join-Path $implementationRoot 'system_skill_provenance_repair.py'
$systemPackageProviderPath = Join-Path $implementationRoot 'system_package_identity.py'
$sourceRoot = $implementationRoot
$wrapperSource = Get-Content -LiteralPath $wrapperPath -Raw
$installerModules = @(Get-ChildItem -LiteralPath $implementationRoot -Filter 'install_skill_guarded_*.py' -File | ForEach-Object Name)
$installerSource = (@($wrapperPath) + @($installerModules | ForEach-Object { Join-Path $implementationRoot $_ }) |
    ForEach-Object { Get-Content -LiteralPath $_ -Raw }) -join "`n"
Assert-True (-not (Test-Path -LiteralPath $retiredCmdWrapperPath)) 'retired batch wrapper scripts\install-skill-guarded.cmd must be removed from repository source'
Assert-True (@([IO.Directory]::GetFiles((Join-Path $projectRoot 'scripts'), '*install-skill-guarded*.cmd')).Count -eq 0) 'scripts directory must not contain retired install-skill-guarded .cmd wrappers'
Assert-True (Test-Path -LiteralPath $psCommandWrapperPath -PathType Leaf) 'deployment source is missing the canonical PowerShell command wrapper'
$psCommandWrapperSource = Get-Content -LiteralPath $psCommandWrapperPath -Raw

Assert-True ($installerModules.Count -gt 0) 'installer modules beside the entry are missing'
Assert-True `
    ($wrapperSource.Contains('Path(__file__).absolute().with_name("generate_skill_catalog.py")', [StringComparison]::Ordinal)) `
    'installer default generator must resolve beside the deployed wrapper'
Assert-True `
    (-not $installerSource.Contains('D:\agents\projects\统一环境\scripts\generate_skill_catalog.py', [StringComparison]::OrdinalIgnoreCase)) `
    'installer must not depend on the source repository generator path'
Assert-True (Test-Path -LiteralPath $sourceRecordPath -PathType Leaf) 'deployment source is missing the shared SOURCE.md parser'
Assert-True (Test-Path -LiteralPath $systemRepairPath -PathType Leaf) 'deployment source is missing the system provenance repair module'
Assert-True (Test-Path -LiteralPath $systemPackageProviderPath -PathType Leaf) 'deployment source is missing the Store package identity provider'
Assert-True `
    ($psCommandWrapperSource.Contains('D:\Codex\tools\python315-official\python.exe', [StringComparison]::Ordinal)) `
    'canonical PowerShell command wrapper must pin the managed Python 3.15 runtime'
Assert-True `
    ($psCommandWrapperSource.Contains('-X utf8 -I', [StringComparison]::Ordinal)) `
    'canonical PowerShell command wrapper must enable UTF-8 mode before isolated execution'

# Each run keeps its fixtures under its own root and removes that root, pass or fail.
$runRoot = Join-Path 'D:\Codex\tmp\skill-install-guarded-deployment-fixture' ('run-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $runRoot | Out-Null
$cleanupError = $null
try {
    $shadowRoot = Join-Path $runRoot 'yaml-shadow'
    $shadowModule = Join-Path $shadowRoot 'yaml.py'
    $hadPythonPath = Test-Path Env:PYTHONPATH
    $previousPythonPath = $env:PYTHONPATH
    $hadDontWriteBytecode = Test-Path Env:PYTHONDONTWRITEBYTECODE
    $previousDontWriteBytecode = $env:PYTHONDONTWRITEBYTECODE
    try {
        New-Item -ItemType Directory -Path $shadowRoot | Out-Null
        [IO.File]::WriteAllText(
            $shadowModule,
            "raise RuntimeError('untrusted yaml shadow imported')`n",
            [Text.UTF8Encoding]::new($false)
        )
        $env:PYTHONPATH = $shadowRoot
        $env:PYTHONDONTWRITEBYTECODE = '1'
        $result = & $deployPath `
            -SourceRoot $sourceRoot `
            -AllowUncommittedSource `
            -CodexRoot (Join-Path $runRoot 'whatif-codex') `
            -EvidenceRoot (Join-Path $runRoot 'whatif-evidence') `
            -WhatIf
        $wrapperHelpOutput = @(& $psCommandWrapperPath --help 2>&1)
        $wrapperHelpExitCode = $LASTEXITCODE
        $poisonedEnv = @{
            PYTHONPATH = $shadowRoot
            PYTHONDONTWRITEBYTECODE = '1'
            CODEX_PYTHON = (Join-Path $runRoot 'poisoned-codex-python\python.exe')
        }
        $psHelpProc = Invoke-WrapperCli -WrapperPath $psCommandWrapperPath -Arguments @('--help') -Environment $poisonedEnv
    }
    finally {
        if ($hadPythonPath) { $env:PYTHONPATH = $previousPythonPath }
        else { Remove-Item Env:PYTHONPATH -ErrorAction SilentlyContinue }
        if ($hadDontWriteBytecode) { $env:PYTHONDONTWRITEBYTECODE = $previousDontWriteBytecode }
        else { Remove-Item Env:PYTHONDONTWRITEBYTECODE -ErrorAction SilentlyContinue }
        Remove-Item -LiteralPath $shadowModule -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $shadowRoot -Force -ErrorAction SilentlyContinue
    }

    $wrapperHelpText = $wrapperHelpOutput | Out-String
    Assert-True `
        ($wrapperHelpExitCode -eq 0) `
        "canonical PowerShell command wrapper must ignore PYTHONPATH yaml shadowing; exit=$wrapperHelpExitCode output=$wrapperHelpText"
    Assert-True `
        ($wrapperHelpText.Contains('--decision-manifest', [StringComparison]::Ordinal)) `
        "canonical PowerShell command wrapper --help output missing expected options; output=$wrapperHelpText"
    Assert-True `
        (-not $wrapperHelpText.Contains('untrusted yaml shadow imported', [StringComparison]::Ordinal)) `
        'canonical PowerShell command wrapper imported the untrusted yaml shadow module'
    Assert-True `
        ($psHelpProc.exitCode -eq 0) `
        "canonical .ps1 wrapper must ignore PYTHONPATH and CODEX_PYTHON; exit=$($psHelpProc.exitCode) stderr=$($psHelpProc.stderr)"
    Assert-True `
        ($psHelpProc.stdout.Contains('--decision-manifest', [StringComparison]::Ordinal) -and -not $psHelpProc.stdout.Contains('untrusted yaml shadow imported', [StringComparison]::Ordinal)) `
        "canonical .ps1 wrapper --help stdout mismatch; stdout=$($psHelpProc.stdout)"
    Assert-True `
        ([string]::IsNullOrEmpty($psHelpProc.stderr)) `
        "canonical .ps1 wrapper --help must not write to stderr; stderr=$($psHelpProc.stderr)"

    # Argument forwarding, exit-code propagation, and fail-closed checks for the sole canonical .ps1 wrapper.
    $utf8NoBom = [Text.UTF8Encoding]::new($false)
    $probeRoot = Join-Path $runRoot 'wrapper-probe'
    New-Item -ItemType Directory -Path $probeRoot | Out-Null
    $probePs1 = Join-Path $probeRoot 'install-skill-guarded.ps1'
    Copy-Item -LiteralPath $psCommandWrapperPath -Destination $probePs1
    $probeWrapperPy = Join-Path $probeRoot 'install_skill_guarded.py'
    $probeScript = @'
import json
import sys

exit_code = 0
stderr_text = None
argv = sys.argv[1:]
for idx, token in enumerate(argv):
    if token == "--probe-exit" and idx + 1 < len(argv):
        exit_code = int(argv[idx + 1])
    elif token == "--probe-stderr" and idx + 1 < len(argv):
        stderr_text = argv[idx + 1]
payload = {
    "argv": argv,
    "executable": sys.executable,
    "utf8_mode": sys.flags.utf8_mode,
    "isolated": sys.flags.isolated,
}
print(json.dumps(payload, ensure_ascii=False))
if stderr_text is not None:
    print(stderr_text, file=sys.stderr)
raise SystemExit(exit_code)
'@
    [IO.File]::WriteAllText($probeWrapperPy, $probeScript, $utf8NoBom)

    # 1. Argument forwarding (spaces, Chinese UTF-8, flags, key=value) + pinned runtime flags.
    $sharedArgs = @(
        '--candidate', (Join-Path $probeRoot 'dir with spaces\中文候选'),
        '--name', 'parity-skill',
        '--decision-manifest', (Join-Path $probeRoot 'decision.json'),
        '--dry-run',
        '--ref=main',
        '--probe-stderr', 'probe-stderr-line'
    )
    $psForward = Invoke-WrapperCli -WrapperPath $probePs1 -Arguments $sharedArgs
    Assert-True ($psForward.exitCode -eq 0) "probe forwarding must exit 0; ps1=$($psForward.exitCode) stderr=$($psForward.stderr)"
    $psPayload = $psForward.stdout | ConvertFrom-Json
    Assert-True ($psPayload.executable -ieq 'D:\Codex\tools\python315-official\python.exe') "canonical .ps1 wrapper must run pinned Python 3.15; got=$($psPayload.executable)"
    Assert-True ([int]$psPayload.utf8_mode -eq 1 -and [int]$psPayload.isolated -eq 1) "canonical .ps1 wrapper must pass -X utf8 -I; utf8=$($psPayload.utf8_mode) isolated=$($psPayload.isolated)"
    Assert-True ((@($psPayload.argv) | ConvertTo-Json -Compress) -ceq (@($sharedArgs) | ConvertTo-Json -Compress)) "canonical .ps1 wrapper must forward arguments losslessly; got=$(@($psPayload.argv) -join ' | ')"
    Assert-True ($psForward.stderr.Trim() -ceq 'probe-stderr-line') 'canonical .ps1 wrapper must preserve stderr output'

    # 2. PowerShell-specific pass-through: common-parameter-like flags and empty/separator tokens must not be eaten by pwsh.
    $psSpecialArgs = @('--flag', '', '-Verbose', '-ErrorAction', 'SilentlyContinue', '--', '--after-dash')
    $psSpecial = Invoke-WrapperCli -WrapperPath $probePs1 -Arguments $psSpecialArgs
    Assert-True ($psSpecial.exitCode -eq 0) "canonical .ps1 wrapper must forward PowerShell-like flags without binding them; exit=$($psSpecial.exitCode) stderr=$($psSpecial.stderr)"
    $psSpecialPayload = $psSpecial.stdout | ConvertFrom-Json
    Assert-True ((@($psSpecialPayload.argv) | ConvertTo-Json -Compress) -ceq (@($psSpecialArgs) | ConvertTo-Json -Compress)) "canonical .ps1 wrapper altered special arguments; got=$(@($psSpecialPayload.argv) -join ' | ')"

    # 3. Non-zero exit code pass-through without swallowing stdout/stderr (out-of-process AND in-process with $PSNativeCommandUseErrorActionPreference = $true).
    foreach ($expectedExit in @(2, 17)) {
        $exitArgs = @('--probe-exit', [string]$expectedExit, '--probe-stderr', "err-$expectedExit")
        $psExitProc = Invoke-WrapperCli -WrapperPath $probePs1 -Arguments $exitArgs
        Assert-True ($psExitProc.exitCode -eq $expectedExit) "non-zero exit code $expectedExit must pass through; ps1=$($psExitProc.exitCode)"
        Assert-True ($psExitProc.stdout.Contains('"isolated": 1', [StringComparison]::Ordinal)) "non-zero exit $expectedExit must not swallow stdout"
        Assert-True ($psExitProc.stderr.Trim() -ceq "err-$expectedExit") "non-zero exit $expectedExit must preserve stderr"
    }
    $pwshExe = (Get-Process -Id $PID).Path
    $inProcessCheckScript = Join-Path $probeRoot 'check-in-process.ps1'
    $inProcessBody = @'
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$target = $args[0]
& $target --probe-exit 17 --probe-stderr 'inproc-err'
exit $LASTEXITCODE
'@
    [IO.File]::WriteAllText($inProcessCheckScript, $inProcessBody, $utf8NoBom)
    $inProcResult = Invoke-ExternalProcess -FilePath $pwshExe -ArgumentList @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $inProcessCheckScript, $probePs1)
    Assert-True ($inProcResult.exitCode -eq 17) "in-process & invocation with PSNativeCommandUseErrorActionPreference=true must preserve exit 17; got=$($inProcResult.exitCode) stderr=$($inProcResult.stderr)"
    Assert-True ($inProcResult.stdout.Contains('"isolated": 1', [StringComparison]::Ordinal)) "in-process & invocation must not swallow stdout; got=$($inProcResult.stdout)"
    Assert-True ($inProcResult.stderr.Trim() -ceq 'inproc-err') "in-process & invocation must preserve clean stderr without NativeCommandExitException; got=$($inProcResult.stderr)"

    # 4. Missing wrapper fail-closed (exit 2 + stderr, empty stdout).
    $missingWrapperRoot = Join-Path $runRoot 'missing-wrapper'
    New-Item -ItemType Directory -Path $missingWrapperRoot | Out-Null
    $missingWrapperPs1 = Join-Path $missingWrapperRoot 'install-skill-guarded.ps1'
    Copy-Item -LiteralPath $psCommandWrapperPath -Destination $missingWrapperPs1
    $psMissingWrapper = Invoke-WrapperCli -WrapperPath $missingWrapperPs1 -Arguments @('--help')
    $expectedMissingWrapperPath = Join-Path $missingWrapperRoot 'install_skill_guarded.py'
    Assert-True ($psMissingWrapper.exitCode -eq 2) "missing wrapper must fail closed with exit 2; ps1=$($psMissingWrapper.exitCode)"
    Assert-True ([string]::IsNullOrEmpty($psMissingWrapper.stdout)) "missing wrapper must not write to stdout; got=$($psMissingWrapper.stdout)"
    Assert-True ($psMissingWrapper.stderr.Trim() -ceq "ERROR: missing guarded skill wrapper: $expectedMissingWrapperPath") "missing wrapper stderr mismatch; got=$($psMissingWrapper.stderr)"

    # 5. Missing managed Python runtime fail-closed (exit 2 + stderr, empty stdout).
    $missingRuntimeRoot = Join-Path $runRoot 'missing-runtime'
    New-Item -ItemType Directory -Path $missingRuntimeRoot | Out-Null
    $pinnedPython = 'D:\Codex\tools\python315-official\python.exe'
    $missingPython = Join-Path $missingRuntimeRoot 'absent-python\python.exe'
    $psRuntimeCount = ([regex]::Matches($psCommandWrapperSource, [regex]::Escape($pinnedPython))).Count
    Assert-True ($psRuntimeCount -eq 1) "canonical .ps1 wrapper must pin the managed Python runtime literal once; ps1=$psRuntimeCount"
    $missingRuntimePs1 = Join-Path $missingRuntimeRoot 'install-skill-guarded.ps1'
    [IO.File]::WriteAllText($missingRuntimePs1, $psCommandWrapperSource.Replace($pinnedPython, $missingPython), $utf8NoBom)
    [IO.File]::WriteAllText((Join-Path $missingRuntimeRoot 'install_skill_guarded.py'), "raise SystemExit(0)`n", $utf8NoBom)
    $psMissingRuntime = Invoke-WrapperCli -WrapperPath $missingRuntimePs1 -Arguments @('--help')
    Assert-True ($psMissingRuntime.exitCode -eq 2) "missing runtime must fail closed with exit 2; ps1=$($psMissingRuntime.exitCode)"
    Assert-True ([string]::IsNullOrEmpty($psMissingRuntime.stdout)) "missing runtime must not write to stdout; got=$($psMissingRuntime.stdout)"
    Assert-True ($psMissingRuntime.stderr.Trim() -ceq "ERROR: missing managed Python runtime: $missingPython") "missing runtime stderr mismatch; got=$($psMissingRuntime.stderr)"

    $relativeFiles = @($result.files | ForEach-Object { [string]$_.relative })
    Assert-True ($result.status -ceq 'what-if') 'deployment fixture must remain a WhatIf'
    Assert-True ($result.yamlDependency -ceq 'passed') 'deployment must verify the managed Python PyYAML dependency'
    Assert-True ($relativeFiles.Count -eq 6 + $installerModules.Count) 'deployment bundle must contain the six base runtime files plus every installer module'
    foreach ($installerModule in $installerModules) {
        Assert-True ($relativeFiles -contains $installerModule) "deployment bundle is missing installer module $installerModule"
    }
    Assert-True ($relativeFiles -contains 'skill_source_record.py') 'deployment bundle is missing the shared SOURCE.md parser'
    Assert-True ($relativeFiles -contains 'install_skill_guarded.py') 'deployment bundle is missing the Python wrapper'
    Assert-True ($relativeFiles -contains 'install-skill-guarded.ps1') 'deployment bundle is missing the canonical PowerShell command wrapper'
    Assert-True (-not ($relativeFiles -contains 'install-skill-guarded.cmd')) 'deployment bundle must not include retired install-skill-guarded.cmd'
    Assert-True (@($relativeFiles | Where-Object { $_.EndsWith('.cmd', [StringComparison]::OrdinalIgnoreCase) }).Count -eq 0) 'deployment bundle must not include any retired .cmd command wrapper'
    Assert-True ($relativeFiles -contains 'generate_skill_catalog.py') 'deployment bundle is missing the catalog generator'
    Assert-True ($relativeFiles -contains 'system_skill_provenance_repair.py') 'deployment bundle is missing the system provenance repair module'
    Assert-True ($relativeFiles -contains 'system_package_identity.py') 'deployment bundle is missing the Store package identity provider'
    Assert-True (@($result.changed).Count -eq $relativeFiles.Count) 'a WhatIf into an empty target must list every file as changed'

    $scriptsRootWhatIf = & $deployPath `
        -SourceRoot (Join-Path $projectRoot 'scripts') `
        -AllowUncommittedSource `
        -CodexRoot (Join-Path $runRoot 'scriptsroot-codex') `
        -EvidenceRoot (Join-Path $runRoot 'scriptsroot-evidence') `
        -WhatIf
    $scriptsRootPsRecord = @($scriptsRootWhatIf.files | Where-Object { [string]$_.relative -ceq 'install-skill-guarded.ps1' })[0]
    Assert-True ([string]$scriptsRootPsRecord.source -ieq $psCommandWrapperPath) "scripts SourceRoot must bind install-skill-guarded.ps1 from scripts\; got=$($scriptsRootPsRecord.source)"
    Assert-True (@($scriptsRootWhatIf.files | Where-Object { [string]$_.relative -ceq 'install-skill-guarded.cmd' }).Count -eq 0) 'scripts SourceRoot WhatIf must not include retired install-skill-guarded.cmd'

    $realCodexRoot = Join-Path $runRoot 'real-codex'
    $realEvidenceRoot = Join-Path $runRoot 'real-evidence'
    $realResult = & $deployPath `
        -SourceRoot $sourceRoot `
        -AllowUncommittedSource `
        -CodexRoot $realCodexRoot `
        -EvidenceRoot $realEvidenceRoot
    Assert-True ($realResult.status -ceq 'succeeded') 'real deployment must succeed'
    foreach ($record in @($realResult.files)) {
        Assert-True ((Get-FileHash -LiteralPath ([string]$record.target) -Algorithm SHA256).Hash.ToUpperInvariant() -ceq [string]$record.sourceSha256) "real deployment hash mismatch: $($record.relative)"
        Assert-True ($null -ne $record.writtenIdentity) "real deployment must record written identity: $($record.relative)"
    }
    $realManifest = Get-Content -LiteralPath (Join-Path ([string]$realResult.evidence) 'manifest.json') -Raw | ConvertFrom-Json
    Assert-True ($realManifest.status -ceq 'succeeded') 'real deployment manifest must be succeeded'
    Assert-True ($realManifest.sourceCommitCheck -ceq 'skipped') 'real deployment manifest must record the skipped source commit check'
    # The installer modules load from the deployed directory, but a yaml.py there must never shadow PyYAML.
    $deployedYamlShadow = Join-Path $realCodexRoot 'scripts\yaml.py'
    $deployedRetiredCmdWrapper = Join-Path $realCodexRoot 'scripts\install-skill-guarded.cmd'
    $deployedPsWrapper = Join-Path $realCodexRoot 'scripts\install-skill-guarded.ps1'
    Assert-True (Test-Path -LiteralPath $deployedPsWrapper -PathType Leaf) 'real deployment must deploy install-skill-guarded.ps1'
    Assert-True (-not (Test-Path -LiteralPath $deployedRetiredCmdWrapper)) 'real deployment must not deploy retired install-skill-guarded.cmd'
    [IO.File]::WriteAllText(
        $deployedYamlShadow,
        "raise RuntimeError('untrusted yaml shadow imported')`n",
        [Text.UTF8Encoding]::new($false)
    )
    try {
        $deployedHelpOutput = @(& $deployedPsWrapper --help 2>&1)
        $deployedHelpExitCode = $LASTEXITCODE
        $deployedPsHelpProc = Invoke-WrapperCli -WrapperPath $deployedPsWrapper -Arguments @('--help')
    }
    finally {
        Remove-Item -LiteralPath $deployedYamlShadow -Force -ErrorAction SilentlyContinue
    }
    $deployedHelpText = $deployedHelpOutput | Out-String
    Assert-True `
        ($deployedHelpExitCode -eq 0 -and $deployedHelpText.Contains('--decision-manifest', [StringComparison]::Ordinal) -and -not $deployedHelpText.Contains('untrusted yaml shadow imported', [StringComparison]::Ordinal)) `
        "deployed command wrapper must load every installer module from its own directory and ignore a yaml.py there; exit=$deployedHelpExitCode output=$deployedHelpText"
    Assert-True `
        ($deployedPsHelpProc.exitCode -eq 0 -and $deployedPsHelpProc.stdout.Contains('--decision-manifest', [StringComparison]::Ordinal) -and [string]::IsNullOrEmpty($deployedPsHelpProc.stderr)) `
        "deployed .ps1 wrapper must pass --help cleanly and ignore yaml.py; exit=$($deployedPsHelpProc.exitCode) stderr=$($deployedPsHelpProc.stderr)"
    Assert-True `
        (-not (Test-Path -LiteralPath (Join-Path $realCodexRoot 'scripts\__pycache__'))) `
        'deployed installer must not write bytecode beside itself'

    # End-to-end deployed --dry-run and fail-closed error verification for the sole deployed .ps1 wrapper.
    $dryRunFixture = Join-Path $runRoot 'deployed-dry-run'
    $dryRunCandidate = Join-Path $dryRunFixture 'candidate-parity'
    $dryRunActive = Join-Path $dryRunFixture 'active'
    $dryRunCache = Join-Path $dryRunFixture 'plugin-cache'
    $dryRunTemp = Join-Path $dryRunFixture 'staging'
    $dryRunLock = Join-Path $dryRunFixture 'lock'
    $dryRunEvidence = Join-Path $dryRunFixture 'evidence'
    New-Item -ItemType Directory -Path $dryRunCandidate, $dryRunActive, $dryRunCache, $dryRunTemp, $dryRunLock, $dryRunEvidence | Out-Null
    [IO.File]::WriteAllText(
        (Join-Path $dryRunCandidate 'SKILL.md'),
        "---`nname: fixture-parity-skill`ndescription: 测试干跑等价性夹具`n---`n`n# fixture-parity-skill`n",
        $utf8NoBom
    )
    $dryRunLedger = Join-Path $dryRunActive '.downloaded-skills-source-state.json'
    $dryRunLedgerBefore = '{"updated_at":"2026-11-21","notes":[],"sources":[],"unresolved":[],"deleted":[]}'
    [IO.File]::WriteAllText($dryRunLedger, $dryRunLedgerBefore, $utf8NoBom)
    $dryRunClosureScript = Join-Path $dryRunFixture 'fixture_closure.py'
    $closureFixtureCode = @'
import argparse
import json
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("--root", required=True)
parser.add_argument("--strict", action="store_true")
parser.add_argument("--format", default="json")
args = parser.parse_args()
root = Path(args.root).resolve()
active_count = len(list(root.rglob("SKILL.md")))
print(json.dumps({
    "summary": {
        "root": str(root),
        "active_skill_count": active_count,
        "finding_count": 0,
        "missing_resource_count": 0,
        "missing_source_count": 0,
        "missing_ledger_count": 0,
        "duplicate_ledger_count": 0,
        "stale_ledger_count": 0,
    },
    "findings": [],
}, ensure_ascii=False))
'@
    [IO.File]::WriteAllText($dryRunClosureScript, $closureFixtureCode, $utf8NoBom)
    $psIntegrityProc = Invoke-WrapperCli -WrapperPath $deployedPsWrapper -Arguments @('--candidate-integrity-only', '--candidate', $dryRunCandidate)
    Assert-True ($psIntegrityProc.exitCode -eq 0) "deployed --candidate-integrity-only must exit 0; ps1=$($psIntegrityProc.exitCode) stderr=$($psIntegrityProc.stderr)"
    $integrityPayload = $psIntegrityProc.stdout | ConvertFrom-Json
    $dryRunManifestPath = Join-Path $dryRunFixture 'decision-manifest.json'
    $dryRunDecision = [ordered]@{
        decision = 'install'
        source_status = 'source-review'
        writing_for_agents = [ordered]@{ status = 'no-change' }
        skills = @('fixture-parity-skill')
        source = [ordered]@{ id = 'local-parity-test'; ref = 'local' }
        candidate_integrity = $integrityPayload.candidate_integrity
    }
    [IO.File]::WriteAllText($dryRunManifestPath, ($dryRunDecision | ConvertTo-Json -Depth 8), $utf8NoBom)
    $dryRunArgs = @(
        '--candidate', $dryRunCandidate,
        '--name', 'fixture-parity-skill',
        '--decision-manifest', $dryRunManifestPath,
        '--active-root', $dryRunActive,
        '--plugin-cache-root', $dryRunCache,
        '--ledger', $dryRunLedger,
        '--catalog', (Join-Path $dryRunFixture 'catalog.json'),
        '--closure-script', $dryRunClosureScript,
        '--temp-root', $dryRunTemp,
        '--lock-root', $dryRunLock,
        '--evidence-root', $dryRunEvidence,
        '--dry-run',
        '--summary'
    )
    $psDryRun = Invoke-WrapperCli -WrapperPath $deployedPsWrapper -Arguments $dryRunArgs
    Assert-True ($psDryRun.exitCode -eq 0) "deployed --dry-run must exit 0; ps1=$($psDryRun.exitCode) psErr=$($psDryRun.stderr)"
    $psDryRunJson = $psDryRun.stdout | ConvertFrom-Json
    Assert-True ($psDryRunJson.status -ceq 'dry-run-pass') "deployed --dry-run must return dry-run-pass; ps1=$($psDryRunJson.status)"
    Assert-True ((@($psDryRunJson.targets) -join ',') -ceq 'fixture-parity-skill') 'deployed --dry-run targets must match'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $dryRunActive 'fixture-parity-skill'))) 'deployed --dry-run must not mutate active root'
    Assert-True ([IO.File]::ReadAllText($dryRunLedger, $utf8NoBom) -ceq $dryRunLedgerBefore) 'deployed --dry-run must not mutate source ledger'
    $psNoArgs = Invoke-WrapperCli -WrapperPath $deployedPsWrapper -Arguments @()
    Assert-True ($psNoArgs.exitCode -eq 2) "deployed wrapper with missing required source flags must pass through exit 2; ps1=$($psNoArgs.exitCode)"
    Assert-True (-not [string]::IsNullOrWhiteSpace($psNoArgs.stderr)) 'deployed .ps1 error must write failure details to stderr'

    # A target that already holds its source's bytes is left alone; only a drifted one is rewritten.
    $repeatResult = & $deployPath `
        -SourceRoot $sourceRoot `
        -AllowUncommittedSource `
        -CodexRoot $realCodexRoot `
        -EvidenceRoot $realEvidenceRoot
    Assert-True ($repeatResult.status -ceq 'succeeded') 'repeat deployment must succeed'
    Assert-True (@($repeatResult.changed).Count -eq 0) "repeat deployment must leave identical targets alone: $(@($repeatResult.changed) -join ', ')"
    Assert-True (@($repeatResult.files | Where-Object { [string]$_.status -cne 'unchanged' }).Count -eq 0) 'identical targets must be recorded as unchanged'
    $driftedTarget = Join-Path $realCodexRoot 'scripts\skill_source_record.py'
    [IO.File]::AppendAllText($driftedTarget, "# drifted`n")
    $driftWhatIf = & $deployPath `
        -SourceRoot $sourceRoot `
        -AllowUncommittedSource `
        -CodexRoot $realCodexRoot `
        -EvidenceRoot $realEvidenceRoot `
        -WhatIf
    Assert-True ((@($driftWhatIf.changed) -join ',') -ceq 'skill_source_record.py') "WhatIf must list only the drifted target as changed: $(@($driftWhatIf.changed) -join ', ')"
    $driftResult = & $deployPath `
        -SourceRoot $sourceRoot `
        -AllowUncommittedSource `
        -CodexRoot $realCodexRoot `
        -EvidenceRoot $realEvidenceRoot
    Assert-True ((@($driftResult.changed) -join ',') -ceq 'skill_source_record.py') "deployment must rewrite only the drifted target: $(@($driftResult.changed) -join ', ')"
    $driftRecord = @($driftResult.files | Where-Object { [string]$_.relative -ceq 'skill_source_record.py' })[0]
    Assert-True ([string]$driftRecord.status -ceq 'deployed') 'the drifted target must be deployed'
    Assert-True ((Get-FileHash -LiteralPath $driftedTarget -Algorithm SHA256).Hash.ToUpperInvariant() -ceq [string]$driftRecord.sourceSha256) 'the drifted target must hold its source bytes again'

    $rollbackCodexRoot = Join-Path $runRoot 'rollback-codex'
    $rollbackEvidenceRoot = Join-Path $runRoot 'rollback-evidence'
    $rollbackScriptsRoot = Join-Path $rollbackCodexRoot 'scripts'
    New-Item -ItemType Directory -Path $rollbackScriptsRoot -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $rollbackScriptsRoot 'generate_skill_catalog.py') -Force | Out-Null
    $rollbackFailure = $null
    try {
        $null = & $deployPath `
            -SourceRoot $sourceRoot `
            -AllowUncommittedSource `
            -CodexRoot $rollbackCodexRoot `
            -EvidenceRoot $rollbackEvidenceRoot `
            2>&1
    }
    catch { $rollbackFailure = $_ }
    Assert-True ($null -ne $rollbackFailure) 'deployment must fail against a pre-existing target directory'
    $rollbackManifestPath = Get-ChildItem -LiteralPath $rollbackEvidenceRoot -Filter 'manifest.json' -Recurse | Select-Object -First 1 -ExpandProperty FullName
    Assert-True ($null -ne $rollbackManifestPath) 'rollback deployment must leave a manifest'
    $rollbackManifest = Get-Content -LiteralPath $rollbackManifestPath -Raw | ConvertFrom-Json
    Assert-True ($rollbackManifest.status -ceq 'rolled-back') 'failed deployment must roll back'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $rollbackScriptsRoot 'skill_source_record.py') -PathType Leaf)) 'rollback must remove the first deployed file'
    Assert-True (Test-Path -LiteralPath (Join-Path $rollbackScriptsRoot 'generate_skill_catalog.py') -PathType Container) 'rollback must preserve the pre-existing target directory'

    $failureCodexRoot = Join-Path $runRoot 'failure-codex'
    $failureEvidenceRoot = Join-Path $runRoot 'failure-evidence'
    $failureRuntimeRoot = Join-Path $runRoot 'failure-runtime'
    $nonPythonPath = Join-Path $failureRuntimeRoot 'not-python.exe'
    $dependencyFailure = $null
    try {
        New-Item -ItemType Directory -Path $failureRuntimeRoot | Out-Null
        Copy-Item -LiteralPath (Join-Path $env:WINDIR 'System32\where.exe') -Destination $nonPythonPath
        try {
            $null = & $deployPath `
                -SourceRoot $sourceRoot `
                -AllowUncommittedSource `
                -CodexRoot $failureCodexRoot `
                -EvidenceRoot $failureEvidenceRoot `
                -PythonPath $nonPythonPath `
                2>&1
        }
        catch {
            $dependencyFailure = $_
        }

        Assert-True ($null -ne $dependencyFailure) 'deployment must fail when the target runtime cannot import PyYAML'
        Assert-True `
            ($dependencyFailure.Exception.Message -like '*缺少 PyYAML*') `
            'deployment must report the missing PyYAML dependency'
        Assert-True (-not (Test-Path -LiteralPath $failureCodexRoot)) 'failed dependency probe must not create the target Codex root'
        Assert-True (-not (Test-Path -LiteralPath $failureEvidenceRoot)) 'failed dependency probe must not create deployment evidence'
    }
    finally {
        Remove-Item -LiteralPath $nonPythonPath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $failureRuntimeRoot -Force -ErrorAction SilentlyContinue
    }

    # Sessions share the project work tree; a deploy must not ship bytes that no commit holds.
    $sourceRepo = Join-Path $runRoot 'source-repo'
    $sourceRepoImplementation = Join-Path $sourceRepo 'modules\skill-supply-chain\implementation'
    $sourceRepoScripts = Join-Path $sourceRepo 'scripts'
    New-Item -ItemType Directory -Path $sourceRepoImplementation, $sourceRepoScripts | Out-Null
    Copy-Item -LiteralPath $deployPath, $psCommandWrapperPath -Destination $sourceRepoScripts
    foreach ($relative in @($relativeFiles | Where-Object { $_ -cne 'install-skill-guarded.ps1' })) {
        Copy-Item -LiteralPath (Join-Path $implementationRoot $relative) -Destination $sourceRepoImplementation
    }
    # A git archive snapshot holds the same layout outside any work tree.
    $snapshot = Join-Path $runRoot 'snapshot'
    Copy-Item -LiteralPath $sourceRepo -Destination $snapshot -Recurse
    $snapshotResult = & (Join-Path $snapshot 'scripts\Deploy-SkillInstallGuarded.ps1') `
        -CodexRoot (Join-Path $runRoot 'snapshot-codex') `
        -EvidenceRoot (Join-Path $runRoot 'snapshot-evidence') `
        -WhatIf
    Assert-True ($snapshotResult.sourceCommitCheck -ceq 'outside-work-tree') 'a snapshot outside any work tree must deploy without the commit check'
    # Under core.autocrlf=true, the Windows default, git status leaves CRLF already committed alone
    # and normalizes CRLF that a checkout wrote over an LF blob; neither is an uncommitted change.
    $crlfCommittedPath = Join-Path $sourceRepoImplementation 'generate_skill_catalog.py'
    $crlfCheckoutPath = Join-Path $sourceRepoImplementation 'skill_source_record.py'
    $crlfCheckoutPsPath = Join-Path $sourceRepoScripts 'install-skill-guarded.ps1'
    Set-LineEnding $crlfCommittedPath "`r`n"
    Set-LineEnding $crlfCheckoutPath "`n"
    Set-LineEnding $crlfCheckoutPsPath "`n"
    & git -C $sourceRepo -c init.defaultBranch=main init -q
    & git -C $sourceRepo config core.autocrlf true
    & git -C $sourceRepo -c core.autocrlf=false add --all
    & git -C $sourceRepo -c user.name=fixture -c user.email=fixture@invalid commit -q -m fixture
    Assert-True ($LASTEXITCODE -eq 0) 'fixture source repository must commit the deployment sources'
    Set-LineEnding $crlfCheckoutPath "`r`n"
    Set-LineEnding $crlfCheckoutPsPath "`r`n"
    $sourceRepoDeployPath = Join-Path $sourceRepoScripts 'Deploy-SkillInstallGuarded.ps1'
    $committedResult = & $sourceRepoDeployPath `
        -CodexRoot (Join-Path $runRoot 'committed-codex') `
        -EvidenceRoot (Join-Path $runRoot 'committed-evidence') `
        -WhatIf
    Assert-True ($committedResult.sourceCommitCheck -ceq 'matches-head') 'a work-tree source that matches HEAD, CRLF included, must pass the commit check'
    [IO.File]::AppendAllText((Join-Path $sourceRepoImplementation 'install_skill_guarded_system_overlay.py'), "# another session, not committed`n")
    [IO.File]::AppendAllText((Join-Path $sourceRepoScripts 'install-skill-guarded.ps1'), "# another session, not committed`n")
    $uncommittedCodexRoot = Join-Path $runRoot 'uncommitted-codex'
    $uncommittedEvidenceRoot = Join-Path $runRoot 'uncommitted-evidence'
    foreach ($whatIf in $true, $false) {
        $uncommittedFailure = $null
        try {
            $null = & $sourceRepoDeployPath `
                -CodexRoot $uncommittedCodexRoot `
                -EvidenceRoot $uncommittedEvidenceRoot `
                -WhatIf:$whatIf `
                2>&1
        }
        catch { $uncommittedFailure = $_ }
        Assert-True ($null -ne $uncommittedFailure) "deployment must refuse sources that differ from HEAD (WhatIf=$whatIf)"
        foreach ($name in 'install_skill_guarded_system_overlay.py', 'install-skill-guarded.ps1') {
            Assert-True ($uncommittedFailure.Exception.Message.Contains($name, [StringComparison]::Ordinal)) "refusal must name $name (WhatIf=$whatIf)"
        }
        Assert-True (-not (Test-Path -LiteralPath $uncommittedCodexRoot)) 'refused deployment must not create the target Codex root'
        Assert-True (-not (Test-Path -LiteralPath $uncommittedEvidenceRoot)) 'refused deployment must not create deployment evidence'
    }
    $allowedResult = & $sourceRepoDeployPath `
        -CodexRoot $uncommittedCodexRoot `
        -EvidenceRoot $uncommittedEvidenceRoot `
        -AllowUncommittedSource `
        -WhatIf
    Assert-True ($allowedResult.status -ceq 'what-if') '-AllowUncommittedSource must let an uncommitted source through'
    Assert-True ($allowedResult.sourceCommitCheck -ceq 'skipped') '-AllowUncommittedSource must record the skipped commit check'
}
finally {
    # A failed run keeps its own error; a cleanup error surfaces only after a passing run.
    try { Remove-FixtureRunRoot -Path $runRoot }
    catch { $cleanupError = $_ }
}
if ($null -ne $cleanupError) { throw $cleanupError }
Assert-True (-not (Test-Path -LiteralPath $runRoot)) "deployment test must remove its fixture run root: $runRoot"

Write-Output "PASS Test-SkillInstallGuardedDeployment files=$($relativeFiles.Count) whatIf=1 real=1 deployedHelp=passed rollback=1 yamlDependency=passed runtimeIsolation=passed missingYamlFailure=passed repositoryPathDependency=0 uncommittedSource=refused sourceCommitStates=3 fixtureRunRoot=removed"
