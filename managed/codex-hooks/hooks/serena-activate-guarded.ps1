$ErrorActionPreference = 'Stop'

$hookInput = [Console]::In.ReadToEnd()
if ($hookInput.Trim().Length -gt 0) {
    $hookInput | & 'D:\Codex\tools\uv\bin\serena-hooks.exe' activate --client=codex
}
