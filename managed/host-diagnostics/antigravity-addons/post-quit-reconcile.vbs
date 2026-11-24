' Silent post-quit hook for Antigravity third-party addons reconciliation.
' Invoked by Antigravity Electron updater (--relaunch) or will-quit via state\post-quit-hook.json.
Option Explicit

Function CompareVersionParts(a, b)
    Dim maxLen, idx, va, vb
    maxLen = UBound(a)
    If UBound(b) > maxLen Then maxLen = UBound(b)
    For idx = 0 To maxLen
        va = 0
        vb = 0
        If idx <= UBound(a) Then
            If IsNumeric(a(idx)) Then va = CLng(a(idx))
        End If
        If idx <= UBound(b) Then
            If IsNumeric(b(idx)) Then vb = CLng(b(idx))
        End If
        If va > vb Then
            CompareVersionParts = 1
            Exit Function
        ElseIf va < vb Then
            CompareVersionParts = -1
            Exit Function
        End If
    Next
    CompareVersionParts = 0
End Function

Function ResolvePwshPath()
    Dim fso, preferred, root, folder, subFolder, candidate, bestPath, bestParts, curParts
    Set fso = CreateObject("Scripting.FileSystemObject")
    preferred = "D:\Codex\tools\PowerShell\7.7.0\pwsh.exe"
    If fso.FileExists(preferred) Then
        ResolvePwshPath = preferred
        Exit Function
    End If
    root = "D:\Codex\tools\PowerShell"
    bestPath = ""
    If fso.FolderExists(root) Then
        Set folder = fso.GetFolder(root)
        For Each subFolder In folder.SubFolders
            candidate = subFolder.Path & "\pwsh.exe"
            If fso.FileExists(candidate) Then
                If bestPath = "" Then
                    bestPath = candidate
                    bestParts = Split(subFolder.Name, ".")
                Else
                    curParts = Split(subFolder.Name, ".")
                    If CompareVersionParts(curParts, bestParts) > 0 Then
                        bestPath = candidate
                        bestParts = curParts
                    End If
                End If
            End If
        Next
        If bestPath <> "" Then
            ResolvePwshPath = bestPath
            Exit Function
        End If
    End If
    If fso.FileExists("C:\Program Files\PowerShell\7\pwsh.exe") Then
        ResolvePwshPath = "C:\Program Files\PowerShell\7\pwsh.exe"
        Exit Function
    End If
    ResolvePwshPath = "pwsh.exe"
End Function

Dim shell, pwshExe, syncScript, extraArgs, argIdx, cmd
Set shell = CreateObject("WScript.Shell")
pwshExe = ResolvePwshPath()
syncScript = "D:\Codex\tools\antigravity-addons\Sync-AntigravityAddons.ps1"
extraArgs = ""
For argIdx = 0 To WScript.Arguments.Count - 1
    If LCase(WScript.Arguments(argIdx)) = "--relaunch" Then
        extraArgs = " -RelaunchAfterUpdate"
    End If
Next
cmd = """" & pwshExe & """ -NoProfile -NonInteractive -WindowStyle Hidden -File """ & syncScript & """ -Mode PostQuit -Quiet" & extraArgs
shell.Run cmd, 0, False
WScript.Quit 0
