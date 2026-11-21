' Silent post-quit hook for Antigravity third-party addons reconciliation.
' Invoked by Antigravity Electron will-quit via state\post-quit-hook.json.
Option Explicit
Dim shell, cmd
Set shell = CreateObject("WScript.Shell")
cmd = """D:\Codex\tools\PowerShell\7.7.0\pwsh.exe"" -NoProfile -NonInteractive -WindowStyle Hidden -File ""D:\Codex\tools\antigravity-addons\Sync-AntigravityAddons.ps1"" -Mode PostQuit -Quiet"
shell.Run cmd, 0, False
WScript.Quit 0
