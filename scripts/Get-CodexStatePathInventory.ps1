[CmdletBinding()]
param(
    [string]$Mode = 'Inventory',
    [string]$FixtureRoot,
    [string]$InventoryGeneration,
    [string]$ApprovedMappingHash,
    [string]$EvidencePath,
    [switch]$Json
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# This script's JSON protocol is consumed through UTF-8 ProcessStartInfo readers.
$ProtocolEncoding = [Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = $ProtocolEncoding

trap {
    if ($Json) {
        [Console]::Out.WriteLine(([ordered]@{
            schemaVersion = 1
            mode = if ([string]::IsNullOrWhiteSpace($Mode)) { 'Unknown' } else { [string]$Mode }
            ok = $false
            error = [ordered]@{
                code = 'state-path-maintenance-failed'
                message = 'state path maintenance failed'
            }
        } | ConvertTo-Json -Compress))
        exit 1
    }
    throw $_
}

$ProjectRoot = 'D:\Codex\projects\统一环境'
$FixtureParent = Join-Path $ProjectRoot 'reports\codex-state-path-repair-test'
$ProductionCodexHome = 'D:\Codex\.codex'
$ProductionEvidenceRoot = 'D:\Codex\.codex\run-evidence\env-governance\codex-state-preflight'
$CorePath = Join-Path $ProjectRoot 'managed\codex-hooks\hooks\codex-state-policy-guard.py'
$PythonPath = 'D:\Codex\tools\python314-official\python.exe'
$FixtureMarker = '.codex-state-path-repair-fixture'
$FixtureMarkerValue = 'codex-state-path-repair-test-v1'
. (Join-Path $ProjectRoot 'scripts\lib\CodexHostSafety.ps1')
. (Join-Path $ProjectRoot 'scripts\lib\CodexRepairTransaction.ps1')

function Invoke-HiddenProcess {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter()][string[]]$Arguments = @()
    )

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $FilePath
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.StandardOutputEncoding = $ProtocolEncoding
    $startInfo.StandardErrorEncoding = $ProtocolEncoding
    foreach ($argument in $Arguments) {
        [void]$startInfo.ArgumentList.Add($argument)
    }

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    $started = $false
    try {
        if (-not $process.Start()) { throw "failed to start hidden process: $FilePath" }
        $started = $true
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        $text = $stdout
        if (-not [string]::IsNullOrEmpty($stderr)) {
            if (-not [string]::IsNullOrEmpty($text) -and -not $text.EndsWith("`n")) { $text += [Environment]::NewLine }
            $text += $stderr
        }
        [pscustomobject]@{
            ExitCode = $process.ExitCode
            StdOut = $stdout
            StdErr = $stderr
            Text = $text
        }
    } finally {
        if ($started -and -not $process.HasExited) {
            try { $process.Kill($true); $process.WaitForExit() } catch {}
        }
        $process.Dispose()
    }
}

function Assert-DPathWithoutReparse {
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$RequireLeaf
    )

    $full = [IO.Path]::GetFullPath($Path)
    if (-not $full.StartsWith('D:\', [StringComparison]::OrdinalIgnoreCase) -or $full.Substring(2).Contains(':')) {
        throw 'path capability must be a normal D drive path'
    }
    $root = [IO.Path]::GetPathRoot($full)
    $current = $root
    foreach ($segment in @($full.Substring($root.Length) -split '[\\/]' | Where-Object { $_ -ne '' })) {
        $current = Join-Path $current $segment
        if (-not (Test-Path -LiteralPath $current)) {
            if ($RequireLeaf) { throw 'required capability path is missing' }
            break
        }
        $item = Get-Item -LiteralPath $current -Force
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'path capability crosses a reparse point'
        }
    }
    $full
}

function Resolve-PathCapability {
    if ([string]::IsNullOrWhiteSpace($FixtureRoot)) {
        return [pscustomobject]@{
            codexHome = $ProductionCodexHome
            evidenceRoot = $ProductionEvidenceRoot
            candidateRoot = 'D:\Documents\Codex'
            fixture = $false
        }
    }

    $resolvedFixture = Assert-DPathWithoutReparse -Path $FixtureRoot -RequireLeaf
    $resolvedParent = Assert-DPathWithoutReparse -Path $FixtureParent -RequireLeaf
    if ([IO.Path]::GetDirectoryName($resolvedFixture) -ine $resolvedParent) {
        throw 'fixture capability must be a direct child of the fixed test root'
    }
    $marker = Join-Path $resolvedFixture $FixtureMarker
    if (-not (Test-Path -LiteralPath $marker -PathType Leaf) -or (Get-Content -Raw -LiteralPath $marker) -cne $FixtureMarkerValue) {
        throw 'fixture capability marker is invalid'
    }
    $fixtureCodexHome = Assert-DPathWithoutReparse -Path (Join-Path $resolvedFixture 'codex-home') -RequireLeaf
    [pscustomobject]@{
        codexHome = $fixtureCodexHome
        evidenceRoot = Join-Path $resolvedFixture 'evidence'
        candidateRoot = Assert-DPathWithoutReparse -Path (Join-Path $resolvedFixture 'candidate-root') -RequireLeaf
        fixture = $true
    }
}

function Initialize-ApprovalRoots {
    param([Parameter(Mandatory)][object]$Capability,[switch]$DeferLedgerValidation)
    $rootCapability = if ($Capability.fixture) { [string]$FixtureRoot } else { Split-Path -Parent ([string]$Capability.evidenceRoot) }
    [void](New-CodexHookCapabilityDirectory -Path ([string]$Capability.evidenceRoot) -CapabilityRoot $rootCapability -Name 'state path evidence root')
    $approvals = Join-Path ([string]$Capability.evidenceRoot) 'approvals'
    $claims = Join-Path ([string]$Capability.evidenceRoot) '.claims'
    $consumed = Join-Path ([string]$Capability.evidenceRoot) '.consumed-approvals'
    [void](New-CodexHookCapabilityDirectory -Path $approvals -CapabilityRoot ([string]$Capability.evidenceRoot) -Name 'state path approval root')
    [void](New-CodexHookCapabilityDirectory -Path $claims -CapabilityRoot ([string]$Capability.evidenceRoot) -Name 'state path claim root')
    [void](New-CodexHookCapabilityDirectory -Path $consumed -CapabilityRoot ([string]$Capability.evidenceRoot) -Name 'state path consumed approvals root')
    $ledgerRoot=Join-Path ([string]$Capability.evidenceRoot) '.approval-ledger'
    if($DeferLedgerValidation){[void](New-CodexHookCapabilityDirectory -Path $ledgerRoot -CapabilityRoot ([string]$Capability.evidenceRoot) -Name 'state repair ledger root')}else{[void](Get-CodexRepairLedgerState -EvidenceRoot ([string]$Capability.evidenceRoot) -AllowInitialize)}
    [pscustomobject]@{ approvals = $approvals; claims = $claims; consumed = $consumed; ledger = $ledgerRoot }
}

function Set-NewCapabilityJson {
    param([string]$Path,[object]$Value,[string]$CapabilityRoot,[string]$Scope)
    [byte[]]$bytes=[Text.UTF8Encoding]::new($false).GetBytes(($Value|ConvertTo-Json -Depth 64 -Compress))
    $sha=Get-CodexHookBytesSha256 -Bytes $bytes
    Set-CodexHookAtomicFileBytesWithCapability -Path $Path -Bytes $bytes -ExpectedExists $false -ExpectedSha256 $null -AfterSha256 $sha -CapabilityRoot $CapabilityRoot -AllowedExactPaths @($Path) -Scope $Scope
    $sha
}

function Get-StatePathApprovalPayload {
    param([Parameter(Mandatory)][object]$Artifact)
    [pscustomobject][ordered]@{
        artifactType = [string]$Artifact.artifactType
        schemaVersion = [int]$Artifact.schemaVersion
        generationId = [string]$Artifact.generationId
        coreInventoryGeneration = [string]$Artifact.coreInventoryGeneration
        nonce = [string]$Artifact.nonce
        generatedAtUtc = [string]$Artifact.generatedAtUtc
        expiresAtUtc = [string]$Artifact.expiresAtUtc
        stateSha256 = [string]$Artifact.stateSha256
        mappingSha256 = [string]$Artifact.mappingSha256
        approvedMappingHash = [string]$Artifact.approvedMappingHash
        candidateRoot = [string]$Artifact.candidateRoot
        approvedMap = $Artifact.approvedMap
        entries = @($Artifact.entries)
        state = [string]$Artifact.state
    }
}

function Assert-StatePathApprovalPayload {
    param([Parameter(Mandatory)][object]$Payload,[Parameter(Mandatory)][object]$Capability)
    Assert-CodexHookExactProperties $Payload @('artifactType','schemaVersion','generationId','coreInventoryGeneration','nonce','generatedAtUtc','expiresAtUtc','stateSha256','mappingSha256','approvedMappingHash','candidateRoot','approvedMap','entries','state') 'state path approval payload'
    if($Payload.artifactType-cne'env-governance.codex-state-path-approval'-or[int]$Payload.schemaVersion-ne1-or$Payload.generationId-cnotmatch'^approval-v1-[0-9a-f]{32}$'-or$Payload.nonce-cnotmatch'^[0-9a-f]{32}$'-or$Payload.state-cne'fresh'-or$Payload.stateSha256-cnotmatch'^[0-9a-f]{64}$'-or$Payload.mappingSha256-cnotmatch'^[0-9a-f]{64}$'-or$Payload.approvedMappingHash-cnotmatch'^[0-9a-f]{64}$'-or$Payload.candidateRoot-cne[string]$Capability.candidateRoot){throw 'approval artifact binding is invalid'}
    try{
        $generated=[datetimeoffset]::Parse([string]$Payload.generatedAtUtc,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind)
        $expires=[datetimeoffset]::Parse([string]$Payload.expiresAtUtc,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind)
    }catch{throw 'approval artifact time binding is invalid'}
    if($generated.ToString('o')-cne[string]$Payload.generatedAtUtc-or$expires.ToString('o')-cne[string]$Payload.expiresAtUtc){throw 'approval artifact time binding is not canonical'}
    $now=[datetimeoffset]::UtcNow
    if($generated-gt$now.AddMinutes(1)-or$expires-le$now-or$expires-$generated-ne[timespan]::FromMinutes(30)){throw 'approval artifact freshness is invalid'}
    Assert-CodexHookExactProperties $Payload.approvedMap @('inventoryGeneration','stateSha256','mappingSha256','mappings') 'state path approved map'
    foreach($entry in @($Payload.entries)){
        Assert-CodexHookExactProperties $entry @('mapName','identity','sourcePath','candidate','finalIdentity','reparse','disposition','reason') 'state path approval entry'
        if($entry.disposition-cnotin@('approved-candidate','retained')){throw 'state path approval entry disposition is invalid'}
        if($entry.disposition-ceq'approved-candidate'-and(@($entry.finalIdentity).Count-ne2-or[string]$entry.finalIdentity[0]-cnotmatch'^[0-9a-f]{8}$'-or[string]$entry.finalIdentity[1]-cnotmatch'^[0-9a-f]{16}$')){throw 'state path approval entry identity is invalid'}
    }
}

function Assert-StatePathApprovalMatchesFreshProjection {
    param([Parameter(Mandatory)][object]$Artifact,[Parameter(Mandatory)][object]$Document)
    if($Artifact.coreInventoryGeneration-cne[string]$Document.generationId-or$Artifact.stateSha256-cne[string]$Document.stateSha256-or$Artifact.mappingSha256-cne[string]$Document.mappingSha256-or$Artifact.approvedMappingHash-cne[string]$Document.approvedMappingHash-or$Artifact.candidateRoot-cne[string]$Document.candidateRoot){throw 'approval artifact does not match fresh projection'}
    $approvedText=$Artifact.approvedMap|ConvertTo-Json -Depth 64 -Compress
    $freshApprovedText=$Document.approvedMap|ConvertTo-Json -Depth 64 -Compress
    $entriesText=@($Artifact.entries)|ConvertTo-Json -Depth 64 -Compress
    $freshEntriesText=@($Document.entries)|ConvertTo-Json -Depth 64 -Compress
    if($approvedText-cne$freshApprovedText-or$entriesText-cne$freshEntriesText){throw 'approval artifact projection closure is invalid'}
}

if (-not (Test-Path -LiteralPath $CorePath -PathType Leaf)) { throw 'state core source is unavailable' }
if (-not (Test-Path -LiteralPath $PythonPath -PathType Leaf)) { throw 'official Python runtime is unavailable' }
if($Mode-cnotin@('Inventory','Repair','Restore')){throw 'unsupported state path maintenance mode'}
if ($Mode -eq 'Inventory' -and (-not [string]::IsNullOrWhiteSpace($InventoryGeneration) -or -not [string]::IsNullOrWhiteSpace($ApprovedMappingHash) -or -not [string]::IsNullOrWhiteSpace($EvidencePath))) { throw 'inventory mode received unrelated parameters' }
if($Mode -eq 'Restore' -and ([string]::IsNullOrWhiteSpace($EvidencePath)-or-not[string]::IsNullOrWhiteSpace($InventoryGeneration)-or-not[string]::IsNullOrWhiteSpace($ApprovedMappingHash))){throw 'restore mode parameter contract is invalid'}
if ($Mode -eq 'Repair' -and (
    $InventoryGeneration -cnotmatch '^approval-v1-[0-9a-f]{32}$' -or
    $ApprovedMappingHash -cnotmatch '^[0-9a-f]{64}$' -or
    -not [string]::IsNullOrWhiteSpace($EvidencePath)
)) {
    throw 'repair requires an exact inventory generation and approved mapping hash'
}

$capability = Resolve-PathCapability
$approvalRoots = $null
$approvalArtifact = $null
$candidateLeases = $null
$evidenceLease = $null
if($Mode -eq 'Restore'){
    $restoreFailFast=[bool]($capability.fixture-and$env:CODEX_STATE_PATH_REPAIR_FIXTURE_FAILFAST_AFTER_RESTORE_RENAME-eq'1')
    $restoreIntentFailFast=[bool]($capability.fixture-and$env:CODEX_STATE_PATH_REPAIR_FIXTURE_FAILFAST_AFTER_RESTORE_INTENT_CREATE-eq'1')
    $restoreAttestationFailFast=[bool]($capability.fixture-and$env:CODEX_STATE_PATH_REPAIR_FIXTURE_FAILFAST_AFTER_RESTORE_ATTESTATION_CREATE-eq'1')
    $restoreRenameFailure=[bool]($capability.fixture-and$env:CODEX_STATE_PATH_REPAIR_FIXTURE_THROW_ON_RESTORE_RENAME-eq'1')
    $applyTempCleanupFailFast=[bool]($capability.fixture-and$env:CODEX_STATE_PATH_REPAIR_FIXTURE_FAILFAST_AFTER_APPLY_TEMP_CLEANUP-eq'1')
    $restore=Invoke-CodexRepairStateRestore -TargetPath (Join-Path ([string]$capability.codexHome) '.codex-global-state.json') -CapabilityRoot ([string]$capability.codexHome) -EvidenceRoot ([string]$capability.evidenceRoot) -EvidencePath $EvidencePath -FixtureFailFastAfterRestoreRename:$restoreFailFast -FixtureFailFastAfterRestoreIntentCreate:$restoreIntentFailFast -FixtureFailFastAfterRestoreAttestationCreate:$restoreAttestationFailFast -FixtureThrowOnRestoreRename:$restoreRenameFailure -FixtureFailFastAfterApplyTempCleanup:$applyTempCleanupFailFast
    $result=[ordered]@{schemaVersion=1;mode='Restore';ok=$true;restored=[bool]$restore.restored;noOp=[bool]$restore.noOp;evidencePath=[string]$restore.evidencePath}
    if($Json){$result|ConvertTo-Json -Compress}else{[pscustomobject]$result}
    exit 0
}
if ($Mode -eq 'Repair') {
    $approvalRoots = Initialize-ApprovalRoots -Capability $capability -DeferLedgerValidation
    $artifactPath = Join-Path $approvalRoots.approvals "$InventoryGeneration.json"
    $artifactSnapshot = Get-CodexHookCapabilityFileSnapshot -Path $artifactPath -CapabilityRoot $approvalRoots.approvals -AllowedExactPaths @($artifactPath) -Name 'state path approval artifact'
    if (-not $artifactSnapshot.exists -or $artifactSnapshot.state -cne 'regular-file') { throw 'approval artifact is unavailable' }
    $approvalArtifact = ConvertFrom-CodexRepairStrictJsonSnapshot -Snapshot $artifactSnapshot -Name 'state path approval artifact'
    Assert-CodexHookExactProperties $approvalArtifact @('artifactType','schemaVersion','generationId','coreInventoryGeneration','nonce','generatedAtUtc','expiresAtUtc','stateSha256','mappingSha256','approvedMappingHash','candidateRoot','approvedMap','entries','state','attestation') 'state path approval artifact'
    $approvalPayload=Get-StatePathApprovalPayload -Artifact $approvalArtifact
    Assert-StatePathApprovalPayload -Payload $approvalPayload -Capability $capability
    $attestedApproval=Unprotect-CodexRepairApprovalPayload -Envelope $approvalArtifact.attestation
    Assert-StatePathApprovalPayload -Payload $attestedApproval -Capability $capability
    if(($approvalPayload|ConvertTo-Json -Depth 64 -Compress)-cne($attestedApproval|ConvertTo-Json -Depth 64 -Compress)-or$approvalArtifact.generationId-cne$InventoryGeneration-or$approvalArtifact.approvedMappingHash-cne$ApprovedMappingHash){throw 'approval artifact authentication or request binding is invalid'}
}
$request = [ordered]@{
    mode = $Mode
    codexHome = [string]$capability.codexHome
    evidenceRoot = [string]$capability.evidenceRoot
    candidateRoot = [string]$capability.candidateRoot
    inventoryGeneration = if($null-ne$approvalArtifact){[string]$approvalArtifact.coreInventoryGeneration}else{$InventoryGeneration}
    approvedMappingHash = $ApprovedMappingHash
    corePath = $CorePath
}

$python = @'
from __future__ import annotations
import base64
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import sys

sys.dont_write_bytecode = True

def canonical_bytes(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")

def load_core(path):
    source = Path(path)
    metadata = source.lstat()
    if int(getattr(metadata, "st_file_attributes", 0)) & 0x0400:
        raise RuntimeError("state core source is redirected")
    spec = importlib.util.spec_from_file_location("codex_state_path_maintenance_core", source)
    if spec is None or spec.loader is None:
        raise RuntimeError("state core loader is unavailable")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module

def build_projection(core, state, candidate_root):
    core.CANONICAL_CANDIDATE_ROOT = core.PureWindowsPath(candidate_root)
    inventory = core.build_path_inventory(
        state,
        core.PROJECTLESS_SOURCE_ROOT,
        candidate_root,
    )
    mappings = {}
    entries = []
    for map_name in core.TARGET_MAPS:
        inventory_entries = inventory.get("maps", {}).get(map_name, {})
        approved = {}
        if isinstance(inventory_entries, dict):
            for identity, entry in inventory_entries.items():
                if not isinstance(entry, dict):
                    continue
                source = entry.get("value")
                candidate = entry.get("candidate")
                safe = entry.get("safe") is True and isinstance(candidate, str)
                raw_identity = entry.get("finalIdentity")
                final_identity = None
                if (
                    isinstance(raw_identity, (list, tuple))
                    and len(raw_identity) == 2
                    and all(isinstance(part, int) and not isinstance(part, bool) for part in raw_identity)
                ):
                    final_identity = [f"{raw_identity[0] & 0xffffffff:08x}", f"{raw_identity[1] & 0xffffffffffffffff:016x}"]
                if safe:
                    approved[str(identity)] = candidate
                entries.append({
                    "mapName": map_name,
                    "identity": str(identity),
                    "sourcePath": source if isinstance(source, str) else None,
                    "candidate": candidate if isinstance(candidate, str) else None,
                    "finalIdentity": final_identity,
                    "reparse": entry.get("reparse") is True,
                    "disposition": "approved-candidate" if safe else "retained",
                    "reason": str(entry.get("reason")),
                })
        if approved:
            mappings[map_name] = approved
    approved_map = {
        "inventoryGeneration": inventory["inventoryGeneration"],
        "stateSha256": inventory["stateSha256"],
        "mappingSha256": inventory["mappingSha256"],
        "mappings": mappings,
    }
    approved_hash = hashlib.sha256(canonical_bytes(approved_map)).hexdigest()
    entries.sort(key=lambda item: (item["mapName"], item["identity"]))
    return inventory, approved_map, approved_hash, entries

def assert_d_path(core, path, name):
    core._assert_check_only_d_path_without_reparse(Path(path), name=name)

request = json.loads(__import__('base64').b64decode(sys.argv[1]).decode('utf-8'))
core = load_core(request["corePath"])
codex_home = Path(request["codexHome"])
evidence_root = Path(request["evidenceRoot"])
candidate_root = Path(request["candidateRoot"])
state_path = codex_home / ".codex-global-state.json"
assert_d_path(core, codex_home, "path maintenance Codex home")
assert_d_path(core, state_path, "path maintenance state source")
assert_d_path(core, evidence_root, "path repair evidence root")
assert_d_path(core, candidate_root, "path repair candidate root")
state_bytes = state_path.read_bytes()
state = core._strict_json_loads(state_bytes)
inventory, approved_map, approved_hash, entries = build_projection(core, state, candidate_root)

base = {
    "schemaVersion": 1,
    "mode": request["mode"],
    "ok": True,
    "readOnly": request["mode"] == "Inventory",
    "generationId": inventory["inventoryGeneration"],
    "stateSha256": inventory["stateSha256"],
    "mappingSha256": inventory["mappingSha256"],
    "approvedMappingHash": approved_hash,
    "candidateRoot": str(candidate_root),
    "approvedMap": approved_map,
    "entries": entries,
    "summary": {
        "safeCount": sum(1 for item in entries if item["disposition"] == "approved-candidate"),
        "retainedCount": sum(1 for item in entries if item["disposition"] == "retained"),
        "missingCount": sum(1 for item in entries if item["reason"] == "unresolved-missing"),
        "reparseCount": sum(1 for item in entries if item["reason"] == "unresolved-reparse"),
        "ambiguousCount": sum(1 for item in entries if item["reason"] == "unresolved-ambiguous"),
    },
}
if request["mode"] == "Inventory":
    print(json.dumps(base, ensure_ascii=True, separators=(",", ":")))
    raise SystemExit(0)

if request.get("inventoryGeneration") != inventory["inventoryGeneration"]:
    raise RuntimeError("approved inventory generation does not match fresh inventory")
if request.get("approvedMappingHash") != approved_hash:
    raise RuntimeError("approved mapping hash does not match fresh inventory")

policy = core.resolve_permission_policy(codex_home)
normalized, change_summary = core.normalize_global_state(
    state,
    permission_policy=policy,
    path_mode="repair-safe-only",
    path_inventory=inventory,
    approved_map=approved_map,
)
after_bytes = core._json_bytes(normalized)
after_state = core._strict_json_loads(after_bytes)
after_inventory, _unused_map, _unused_hash, _unused_entries = build_projection(
    core, after_state, candidate_root
)
_after_normalized, after_summary = core.normalize_global_state(
    after_state,
    permission_policy=policy,
    path_mode="inventory",
    path_inventory=after_inventory,
)
remaining_drift = int(after_summary["pathDriftCount"]) + int(after_summary["heartbeatChangedCount"])
base.update({
    "readOnly": False,
    "changed": after_bytes != state_bytes,
    "beforeBytesBase64": base64.b64encode(state_bytes).decode("ascii"),
    "afterBytesBase64": base64.b64encode(after_bytes).decode("ascii"),
    "afterSha256": core._sha256(after_bytes),
    "remainingDriftCount": remaining_drift,
})
print(json.dumps(base, ensure_ascii=True, separators=(",", ":")))
'@

$requestJson = $request | ConvertTo-Json -Depth 8 -Compress
$requestBase64 = [Convert]::ToBase64String([Text.UTF8Encoding]::new($false).GetBytes($requestJson))
$pythonRun = Invoke-HiddenProcess -FilePath $PythonPath -Arguments @('-I', '-B', '-X', 'utf8', '-c', $python, $requestBase64)
if ($pythonRun.ExitCode -ne 0) {
    if($null-ne$evidenceLease){$evidenceLease.Dispose()}
    Exit-CodexRepairLeaseSet -LeaseSet $candidateLeases
    if ($Json) {
        [pscustomobject][ordered]@{
            schemaVersion = 1
            mode = $Mode
            ok = $false
            error = [pscustomobject][ordered]@{
                code = 'state-path-maintenance-failed'
                message = 'state path inventory or repair failed'
            }
        } | ConvertTo-Json -Compress
    } elseif ($capability.fixture) {
        Write-Error $pythonRun.Text
    }
    exit 1
}

$rendered = $pythonRun.Text
$document = $rendered | ConvertFrom-Json -Depth 64
if ($Mode -eq 'Inventory') {
    $approvalRoots = Initialize-ApprovalRoots -Capability $capability
    $nonce = [guid]::NewGuid().ToString('N')
    $generation = "approval-v1-$nonce"
    $generated = [datetimeoffset]::UtcNow
    $artifactPath = Join-Path $approvalRoots.approvals "$generation.json"
    $artifact = [ordered]@{
        artifactType = 'env-governance.codex-state-path-approval'
        schemaVersion = 1
        generationId = $generation
        coreInventoryGeneration = [string]$document.generationId
        nonce = $nonce
        generatedAtUtc = $generated.ToString('o')
        expiresAtUtc = $generated.AddMinutes(30).ToString('o')
        stateSha256 = [string]$document.stateSha256
        mappingSha256 = [string]$document.mappingSha256
        approvedMappingHash = [string]$document.approvedMappingHash
        candidateRoot = [string]$document.candidateRoot
        approvedMap = $document.approvedMap
        entries = @($document.entries)
        state = 'fresh'
    }
    $artifact.attestation=Protect-CodexRepairApprovalPayload -Payload (Get-StatePathApprovalPayload -Artifact $artifact)
    [void](Set-NewCapabilityJson -Path $artifactPath -Value $artifact -CapabilityRoot $approvalRoots.approvals -Scope 'state path approval artifact')
    $document.generationId = $generation
    $document | Add-Member -NotePropertyName approvalArtifactPath -NotePropertyValue $artifactPath -ErrorAction Stop
    $document.PSObject.Properties.Remove('approvedMap')
} elseif($Mode -eq 'Repair') {
    try {
        Assert-StatePathApprovalMatchesFreshProjection -Artifact $approvalArtifact -Document $document
        $statePath=Join-Path ([string]$capability.codexHome) '.codex-global-state.json'
        if((Test-CodexHookPathWithin -Path ([string]$capability.candidateRoot) -ParentPath ([string]$capability.codexHome))-or(Test-CodexHookPathWithin -Path ([string]$capability.candidateRoot) -ParentPath ([string]$capability.evidenceRoot))-or(Test-CodexHookPathWithin -Path $statePath -ParentPath ([string]$capability.candidateRoot))-or(Test-CodexHookPathWithin -Path ([string]$capability.evidenceRoot) -ParentPath ([string]$capability.candidateRoot))){throw 'candidate capability overlaps state or evidence targets'}
        if(-not[bool]$document.changed){
            $document | Add-Member -NotePropertyName noOp -NotePropertyValue $true -Force
            $document | Add-Member -NotePropertyName evidencePath -NotePropertyValue $null -Force
            $document.PSObject.Properties.Remove('beforeBytesBase64')
            $document.PSObject.Properties.Remove('afterBytesBase64')
            $document.PSObject.Properties.Remove('approvedMap')
            if($Json){$document|ConvertTo-Json -Depth 64 -Compress}else{$document}
            exit 0
        }
        $ledgerRecordFailFast=[bool]($capability.fixture-and$env:CODEX_STATE_PATH_REPAIR_FIXTURE_FAILFAST_AFTER_LEDGER_RECORD_CREATE-eq'1')
        Add-CodexRepairLedgerConsumption -EvidenceRoot ([string]$capability.evidenceRoot) -GenerationId $InventoryGeneration -ApprovalArtifactSha256 ([string]$artifactSnapshot.sha256) -FixtureFailFastAfterRecordCreate:$ledgerRecordFailFast
        $consumedPath=Join-Path $approvalRoots.consumed "$InventoryGeneration.json"
        $consumed=[ordered]@{artifactType='env-governance.codex-state-path-consumed-approval';schemaVersion=1;generationId=$InventoryGeneration;artifactSha256=[string]$artifactSnapshot.sha256;consumedAtUtc=[datetimeoffset]::UtcNow.ToString('o')}
        [void](Set-NewCapabilityJson -Path $consumedPath -Value $consumed -CapabilityRoot $approvalRoots.consumed -Scope 'state path permanent consumed approval')
        $claimPath=Join-Path $approvalRoots.claims "$InventoryGeneration.json"
        $claim=[ordered]@{artifactType='env-governance.codex-state-path-claim';schemaVersion=1;generationId=$InventoryGeneration;artifactSha256=[string]$artifactSnapshot.sha256;state='prepared';claimedAtUtc=[datetimeoffset]::UtcNow.ToString('o')}
        [void](Set-NewCapabilityJson -Path $claimPath -Value $claim -CapabilityRoot $approvalRoots.claims -Scope 'state path permanent claim')
        $candidateLeases=Enter-CodexRepairCandidateLeaseSet -CandidateRoot ([string]$capability.candidateRoot) -Entries @($document.entries)
        $evidenceRootCapability=if($capability.fixture){[string]$FixtureRoot}else{Split-Path -Parent ([string]$capability.evidenceRoot)}
        $evidenceLease=Enter-CodexRepairDirectoryLease -CapabilityRoot $evidenceRootCapability -Path ([string]$capability.evidenceRoot)
        if($capability.fixture -and -not[string]::IsNullOrWhiteSpace($env:CODEX_STATE_PATH_REPAIR_FIXTURE_REPLACE_CANDIDATE)){
            $attack=Join-Path ([string]$capability.candidateRoot) $env:CODEX_STATE_PATH_REPAIR_FIXTURE_REPLACE_CANDIDATE
            $blocked=$false;try{Move-Item -LiteralPath $attack -Destination "$attack-replaced" -ErrorAction Stop}catch{$blocked=$true};if(-not$blocked){throw 'candidate lease did not block replacement'};throw 'fixture candidate replacement rejected'
        }
        if($capability.fixture -and -not[string]::IsNullOrWhiteSpace($env:CODEX_STATE_PATH_REPAIR_FIXTURE_POSIX_REPLACE_CANDIDATE)){
            $attack=Join-Path ([string]$capability.candidateRoot) $env:CODEX_STATE_PATH_REPAIR_FIXTURE_POSIX_REPLACE_CANDIDATE
            $guard=[CodexHookGovernance.VerifiedDirectoryChainGuard]::Acquire([string]$capability.candidateRoot,(Split-Path -Parent $attack),$false)
            $tempPath=Join-Path (Split-Path -Parent $attack) ".candidate-attack-$([guid]::NewGuid().ToString('N')).tmp";$temp=$null;$blocked=$false
            try{$temp=$guard.CreateTempFile($tempPath);$temp.WriteAndFlush([IO.File]::ReadAllBytes($attack));try{$temp.RenameTo($attack,$true)}catch{$blocked=$true}}finally{if($null-ne$temp){$temp.Dispose()};$guard.Dispose();if([IO.File]::Exists($tempPath)){[IO.File]::Delete($tempPath)}}
            if(-not$blocked){throw 'candidate read lease allowed class-65 replacement'}
            throw 'fixture class-65 candidate replacement rejected'
        }
        if($capability.fixture -and -not[string]::IsNullOrWhiteSpace($env:CODEX_STATE_PATH_REPAIR_FIXTURE_SWAP_EVIDENCE_PARENT)){
            $blocked=$false;try{Move-Item -LiteralPath ([string]$capability.evidenceRoot) -Destination $env:CODEX_STATE_PATH_REPAIR_FIXTURE_SWAP_EVIDENCE_PARENT -ErrorAction Stop}catch{$blocked=$true};if(-not$blocked){throw 'evidence lease did not block replacement'};throw 'fixture evidence ancestor replacement rejected'
        }
        [byte[]]$beforeBytes=[Convert]::FromBase64String([string]$document.beforeBytesBase64)
        [byte[]]$afterBytes=[Convert]::FromBase64String([string]$document.afterBytesBase64)
        $injectCompletedFailure = [bool]($capability.fixture -and $env:CODEX_STATE_PATH_REPAIR_FIXTURE_FAIL_COMPLETED -eq '1')
        [byte[]]$fixtureThirdPartyBytes=$null
        if($capability.fixture -and $env:CODEX_STATE_PATH_REPAIR_FIXTURE_THIRD_PARTY_AFTER_APPLY -eq '1'){$fixtureThirdPartyBytes=[Text.UTF8Encoding]::new($false).GetBytes('{"fixtureThirdParty":true}')}
        $replaceTargetAfterApply=[bool]($capability.fixture-and$env:CODEX_STATE_PATH_REPAIR_FIXTURE_REPLACE_TARGET_AFTER_APPLY-eq'1')
        $applyFailFast=[bool]($capability.fixture-and$env:CODEX_STATE_PATH_REPAIR_FIXTURE_FAILFAST_AFTER_APPLY_RENAME-eq'1')
        $rollbackFailFast=[bool]($capability.fixture-and$env:CODEX_STATE_PATH_REPAIR_FIXTURE_FAILFAST_AFTER_ROLLBACK_RENAME-eq'1')
        $applyIntentFailFast=[bool]($capability.fixture-and$env:CODEX_STATE_PATH_REPAIR_FIXTURE_FAILFAST_AFTER_APPLY_INTENT_CREATE-eq'1')
        $rollbackIntentFailFast=[bool]($capability.fixture-and$env:CODEX_STATE_PATH_REPAIR_FIXTURE_FAILFAST_AFTER_ROLLBACK_INTENT_CREATE-eq'1')
        $restoreAttestationFailFast=[bool]($capability.fixture-and$env:CODEX_STATE_PATH_REPAIR_FIXTURE_FAILFAST_AFTER_RESTORE_ATTESTATION_CREATE-eq'1')
        $apply=Invoke-CodexRepairStateApply -TargetPath $statePath -BeforeBytes $beforeBytes -AfterBytes $afterBytes -CapabilityRoot ([string]$capability.codexHome) -EvidenceRoot ([string]$capability.evidenceRoot) -GenerationId $InventoryGeneration -ApprovalArtifactSha256 ([string]$artifactSnapshot.sha256) -Entries @($document.entries) -FixtureFailCompleted:$injectCompletedFailure -FixtureThirdPartyBytes $fixtureThirdPartyBytes -FixtureReplaceTargetAfterApply:$replaceTargetAfterApply -FixtureFailFastAfterApplyRename:$applyFailFast -FixtureFailFastAfterRollbackRename:$rollbackFailFast -FixtureFailFastAfterApplyIntentCreate:$applyIntentFailFast -FixtureFailFastAfterRollbackIntentCreate:$rollbackIntentFailFast -FixtureFailFastAfterRestoreAttestationCreate:$restoreAttestationFailFast
        $document | Add-Member -NotePropertyName noOp -NotePropertyValue $false -Force
        $document | Add-Member -NotePropertyName evidencePath -NotePropertyValue ([string]$apply.evidencePath) -Force
        $document.PSObject.Properties.Remove('beforeBytesBase64')
        $document.PSObject.Properties.Remove('afterBytesBase64')
        $document.PSObject.Properties.Remove('approvedMap')
    } finally {
        if($null-ne$evidenceLease){$evidenceLease.Dispose()}
        Exit-CodexRepairLeaseSet -LeaseSet $candidateLeases
    }
}
if ($Json) {
    $document | ConvertTo-Json -Depth 64 -Compress
} else {
    $document
}
