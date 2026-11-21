# WSL Inbox Stub IFEO Guard

在已卸载 WSL 的 Windows 11 主机上，通过 Image File Execution Options（IFEO）把 `wsl.exe` 重定向到微软签名的 GUI 脚本宿主 `wscript.exe //B //NoLogo "D:\Codex\tools\wsl-guard\wsl-disabled.vbs"`，以退出码 `1` 静默退出、避免弹出 60 秒 Windows Terminal 安装提示。

- 启用（需管理员权限）：
  `& 'D:/Codex/tools/wsl-guard/Enable-WslStubGuard.ps1'`
- 恢复原状（重装 WSL 前必须先运行，需管理员权限）：
  `& 'D:/Codex/tools/wsl-guard/Disable-WslStubGuard.ps1'`
- 涉及注册表键（64 位与 WOW6432Node）：
  - `HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\wsl.exe` (`Debugger`)
  - `HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\wsl.exe` (`Debugger`)
