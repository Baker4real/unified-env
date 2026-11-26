# Antigravity Third-Party Addons Reconciler

Automated, version-agnostic, fail-closed reconciler that keeps Antigravity's third-party overlays intact across official Antigravity updates without disabling auto-updates or writing new files to `C:\`.

## Managed Overlay Layers

1. **WSL guard** (`dist/wsl.js`): skips `wsl.exe` calls when no WSL distribution is registered and sets `windowsHide: true` (works alongside the host-level IFEO stub guard in `D:\Codex\tools\wsl-guard\`).
2. **desktop-zhcn** (`desktop-zhcn-v3.0.8`): extracts the embedded UI bundle from the installed `resources\bin\language_server.exe`, translates it into `state\language-<version>\agy_zhcn_ui_main.js` (offline defaults: `onlineTranslate: false`, `titleWriteBack: false`), patches `dist/customScheme.js` & `dist/loadingOverlay.js`, and redirects the `will-quit` hook to `state\post-quit-hook.json`.
3. **pulse** (`pulse-v1.3.2`, embed-only): injects the context capsule payload into `dist/preload.js`.
4. **context-viewer** (`context-viewer-v0.8.8`, meter-only): mounts `contextMeterAPI` and the 21 overlay files with resilient single-match hub-navigation anchor detection (`loadHubWindowUrl` / `win.loadURL`), full D-drive state redirection (`state\context` for `accounts_v1.json`, `modules.json`, `pricing_ledger_v1.json`, `account_ledgers\`, `custom_plan_v1.json`, and `token_usage_archive_v1/v2.json`), bounded corruption/repair backups (`.corrupt.bak.json` size+mtime deduplication in `dist/meter-storage.js` and single conditional `.bak-pre-elv89.json` in `dist/meter-collector.js` so corrupt or live ledgers never accumulate timestamped copies), and the Antigravity 2.34+ authenticated-bootstrap CSRF compatibility patch (`dist/local-api.js` resolves `authBootstrap` -> HTML `__APP_CONFIG__` -> CDP -> live same-origin `daemon/hub_*.json`; `dist/meter-collector.js` reuses it with 401 rotation; `dist/meter-renderer.js` falls back to `localStorage['agy_session_csrf_token']`).
5. **updater** (`dist/updater.js` relaunch hand-off & taskbar AUMID alignment): binds Electron's process `AppUserModelID` (`com.google.antigravity`, matching the official NSIS installer's `WinShell::SetLnkAUMI`) and `BrowserWindow.setAppDetails` (`relaunchCommand` -> `LaunchAntigravity.exe`, `appIconPath` -> `Antigravity.exe,0`) before any window opens so pinned taskbar shortcuts and post-update relaunched windows always merge into a single taskbar icon; when `state\post-quit-hook.json` and `D:\Apps\Google.Antigravity.Local\LaunchAntigravity.exe` are present on Windows, suppresses NSIS `--force-run` (`autoRunAppAfterInstall = false`) for silent updates and spawns `post-quit-reconcile.vbs --relaunch` once the installer launches. On interactive (`isSilent = false`) menu updates, electron-builder's NSIS `oneClick` installer preserves `ShutdownBlockReasonCreate` and unconditionally invokes `Start Menu\Programs\Antigravity.lnk` (`LaunchAntigravity.exe`) via `ExecShellAsUser` right before exiting; `PostQuit` heals shortcuts upfront, holds `Local\AntigravityAddonsReconcileMutex` while reconciling all addon layers in place on the unlocked `app.asar`, and coordinates with the waiting `LaunchAntigravity.exe` (`-Mode Apply` 120 s mutex wait, `RunHiddenReconciler` 150 s timeout, and duplicate-relaunch suppression when `LaunchAntigravity.exe` is already queued) so Antigravity opens once with proxy + all addons active on the very first launch.

Each layer runs independent syntax (`node --check` + `vm.Script`) and offline behavioral gates. If an upstream update changes an anchor for one layer, that single layer degrades cleanly (`skipped`) while other verified layers still apply and official Antigravity stays bootable.

## Automatic Triggers

- **Pre-launch fast-path (`D:\Apps\Google.Antigravity.Local\LaunchAntigravity.exe`)**:
  - Normal launches: compares `app.asar` SHA-256 against `state\active-build.json` (~12 ms) and launches immediately.
  - Pre-staged update: swaps verified `state\pending-app.asar` into `resources\app.asar` in < 50 ms before launch.
  - Cold update (no pre-staged build, no desktop window running): runs `Sync-AntigravityAddons.ps1 -Mode Apply -Quiet` before launch.
  - Strictly fail-open: any error is ignored so Antigravity always starts.
- **Post-quit hook (`state\post-quit-hook.json` -> `post-quit-reconcile.vbs`)**:
  - Triggered by Antigravity Electron `will-quit`.
  - Exits immediately on normal quits when no updater is running and `app.asar` is already up to date.
  - After an in-app update, waits up to 90 s for NSIS (`Antigravity-x64.exe`) to finish, builds & verifies the new combined `app.asar` (swapping immediately if unlocked or pre-staging `state\pending-app.asar` if NSIS already relaunched Antigravity), and heals Start Menu / TaskBar / Desktop shortcuts back to `LaunchAntigravity.exe` with `System.AppUserModel.ID = com.google.antigravity`.

## Manual Commands

```powershell
# Check or deploy repository sources + compiled LaunchAntigravity.exe to live D: targets
& 'D:\agents\projects\统一环境\managed\host-diagnostics\antigravity-addons\Deploy-AntigravityAddons.ps1' -Mode Check
& 'D:\agents\projects\统一环境\managed\host-diagnostics\antigravity-addons\Deploy-AntigravityAddons.ps1' -Mode Apply

# Check current state, official backup, and shortcut targets
& 'D:\Codex\tools\antigravity-addons\Sync-AntigravityAddons.ps1' -Mode Status

# Reconcile immediately (or pre-stage if Antigravity is running)
& 'D:\Codex\tools\antigravity-addons\Sync-AntigravityAddons.ps1' -Mode Apply

# Rebuild cleanly from immutable official backup (e.g., after upgrading a local addon)
& 'D:\Codex\tools\antigravity-addons\Sync-AntigravityAddons.ps1' -Mode Rebuild -StageOnly

# Roll back to the immutable official app.asar.<version>.original (close Antigravity first)
& 'D:\Codex\tools\antigravity-addons\Sync-AntigravityAddons.ps1' -Mode Rollback

# 在仓库根目录运行 CI 回归，包括合成跨版本更新与登记诊断
node managed/host-diagnostics/antigravity-addons/antigravity-addons.test.mjs

# 在仓库根目录运行官方 2.34.0 载荷离线演练
node managed/host-diagnostics/antigravity-addons/test-reconcile-addons.mjs --e2e

# Inspect arbitrary Electron app.asar members (canonical host tool, no ad-hoc unpacker)
python -B -I 'D:\Codex\tools\asar-extract\asar_extract.py' grep 'D:\Apps\Google.Antigravity\resources\app.asar' 'listWslDistros' --paths '^dist/'
```

## 更新目标与离线验收

`Status` 的 `updateTarget` 按 `Registry32`、`Registry64` 分别读取 HKCU 的 NSIS 产品 `InstallLocation` 和卸载登记。已验证的 2.34.0 每用户安装器在更新器未传入 `/D` 时采用产品键。`product-location-mismatch` 指向需要核对的产品键和实际目录，`uninstall-path-mismatch` 指向卸载目录或卸载程序路径。`machineRegistrationPresent` 提示存在同产品的机器级登记。`deployment` 给出受管磁盘路径和文件缺失、不可读或重解析点原因。

`running` 观察当前 Windows 会话的可见桌面。`desktop-not-running` 可与 `ready: true` 同时出现。`other-installation-running` 附带实际映像路径，`running-path-unverified` 表示读取不完整。`ready` 检查当前部署、两个登记视图和可见桌面的一致性。实际更新行为以对应版本安装器为准。

离线演练使用经签名核验记录绑定的 2.34.0 ASAR 和语言服务器副本，以及本机三个已安装的补丁包。测试在临时目录模拟安装器覆盖文件，用 Windows 文件句柄和夹具桌面进程模拟重开。启动器在发现可见夹具桌面时跳过晋升，关闭该进程后仍受文件锁约束。释放句柄后沿同一启动前入口晋升补丁，核对四层补丁和同版本原件备份。CI 用合成跨版本载荷验证相同状态转换。

## Paths & State

- Immutable official backups: `D:\Apps\Google.Antigravity.Local\app.asar.<version>.original`
- Active / pending metadata & per-version UI bundles: `D:\Codex\tools\antigravity-addons\state\`
- Audit receipts (`result.json` per sync run): `D:\agents\run-evidence\antigravity-addons\sync-*`
