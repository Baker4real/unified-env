#!/usr/bin/env python3
"""Read the installed Codex Store package and signature identity as JSON."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path


SUBPROCESS_CREATION_FLAGS = subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _powershell() -> str:
    candidates = (
        Path(r"D:\Codex\tools\powershell\7\pwsh.exe"),
        Path(r"C:\Program Files\PowerShell\7\pwsh.exe"),
    )
    for candidate in candidates:
        if candidate.is_file():
            return str(candidate)
    discovered = shutil.which("pwsh.exe")
    if discovered:
        return discovered
    raise RuntimeError("PowerShell Core 7 不可用")


def inspect(package_name: str) -> dict[str, str | int]:
    script = r"""
$ErrorActionPreference = 'Stop'
$packages = @(Get-AppxPackage -Name $env:CODEX_SYSTEM_PACKAGE_NAME)
if ($packages.Count -ne 1) { throw "expected exactly one package; count=$($packages.Count)" }
$package = $packages[0]
$manifest = Join-Path ([string]$package.InstallLocation) 'AppxManifest.xml'
$signaturePath = Join-Path ([string]$package.InstallLocation) 'AppxSignature.p7x'
$signature = Get-AuthenticodeSignature -LiteralPath $signaturePath -ErrorAction Stop
[ordered]@{
  schema_version = 1
  package_name = [string]$package.Name
  package_full_name = [string]$package.PackageFullName
  package_family_name = [string]$package.PackageFamilyName
  version = [string]$package.Version
  publisher = [string]$package.Publisher
  signature_kind = [string]$package.SignatureKind
  signature_status = [string]$signature.Status
  appx_status = [string]$package.Status
  install_location = [string]$package.InstallLocation
  appx_manifest_path = $manifest
  appx_signature_path = $signaturePath
} | ConvertTo-Json -Compress
"""
    completed = subprocess.run(
        [
            _powershell(),
            "-NoLogo",
            "-NoProfile",
            "-NonInteractive",
            "-Command",
            script,
        ],
        env={**os.environ, "CODEX_SYSTEM_PACKAGE_NAME": package_name},
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        check=False,
        creationflags=SUBPROCESS_CREATION_FLAGS,
    )
    if completed.returncode != 0:
        raise RuntimeError(
            f"Get-AppxPackage identity probe failed exit={completed.returncode}: "
            f"{(completed.stderr or completed.stdout).strip()}"
        )
    value = json.loads(completed.stdout)
    manifest = Path(value["appx_manifest_path"])
    signature = Path(value["appx_signature_path"])
    if not manifest.is_file() or not signature.is_file():
        raise RuntimeError("AppX manifest/signature file is missing")
    value["appx_manifest_sha256"] = _sha256(manifest)
    value["appx_signature_sha256"] = _sha256(signature)
    return value


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--package-name", required=True)
    args = parser.parse_args(argv)
    try:
        print(json.dumps(inspect(args.package_name), ensure_ascii=False))
        return 0
    except Exception as exc:
        print(json.dumps({"ok": False, "error": str(exc)}, ensure_ascii=False), file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
