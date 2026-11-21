# Antigravity Third-Party Addons Reconciler

Automated, version-agnostic, fail-closed reconciler that keeps Antigravity's third-party overlays intact across official Antigravity updates without disabling auto-updates or writing new files to `C:\`.

## Managed Overlay Layers

1. **WSL guard** (`dist/wsl.js`): skips `wsl.exe` calls when no WSL distribution is registered and sets `windowsHide: true` (works alongside the host-level IFEO stub guard in `D:\Codex\tools\wsl-guard\`).
2. **desktop-zhcn** (`desktop-zhcn-v3.0.8`): extracts the embedded UI bundle from the installed `resources\bin\language_server.exe`, translates it into `state\language-<version>\agy_zhcn_ui_main.js` (offline defaults: `onlineTranslate: false`, `titleWriteBack: false`), patches `dist/customScheme.js` & `dist/loadingOverlay.js`, and redirects the `will-quit` hook to `state\post-quit-hook.json`.
3. **pulse** (`pulse-v1.3.2`, embed-only): injects the context capsule payload into `dist/preload.js`.
4. **context-viewer** (`context-viewer-v0.8.8`, meter-only): mounts `contextMeterAPI` and the 21 overlay files with resilient single-match hub-navigation anchor detection (`loadHubWindowUrl` / `win.loadURL`) and D-drive state (`state\context`).

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
  - After an in-app update, waits up to 90 s for NSIS (`Antigravity-x64.exe`) to finish, builds & verifies the new combined `app.asar` (swapping immediately if unlocked or pre-staging `state\pending-app.asar` if NSIS already relaunched Antigravity), and heals Start Menu / TaskBar / Desktop shortcuts back to `LaunchAntigravity.exe`.

## Manual Commands

```powershell
# Check current state, official backup, and shortcut targets
& 'D:\Codex\tools\antigravity-addons\Sync-AntigravityAddons.ps1' -Mode Status

# Reconcile immediately (or pre-stage if Antigravity is running)
& 'D:\Codex\tools\antigravity-addons\Sync-AntigravityAddons.ps1' -Mode Apply

# Rebuild cleanly from immutable official backup (e.g., after upgrading a local addon)
& 'D:\Codex\tools\antigravity-addons\Sync-AntigravityAddons.ps1' -Mode Rebuild -StageOnly

# Roll back to the immutable official app.asar.<version>.original (close Antigravity first)
& 'D:\Codex\tools\antigravity-addons\Sync-AntigravityAddons.ps1' -Mode Rollback

# Run fast unit tests (< 1s, synthetic ASAR, CI-safe)
node 'D:\Codex\tools\antigravity-addons\test-reconcile-addons.mjs' --unit

# Run full offline E2E test suite against official 2.34.0 fixture (never touches live install)
node 'D:\Codex\tools\antigravity-addons\test-reconcile-addons.mjs' --e2e

# Inspect arbitrary Electron app.asar members (canonical host tool, no ad-hoc unpacker)
python -B -I 'D:\Codex\tools\asar-extract\asar_extract.py' grep 'D:\Apps\Google.Antigravity\resources\app.asar' 'listWslDistros' --paths '^dist/'
```

Canonical source mirror & CI guardrails live in `D:\agents\projects\统一环境\managed\host-diagnostics\antigravity-addons\`.

## Paths & State

- Immutable official backups: `D:\Apps\Google.Antigravity.Local\app.asar.<version>.original`
- Active / pending metadata & per-version UI bundles: `D:\Codex\tools\antigravity-addons\state\`
- Audit receipts (`result.json` per sync run): `D:\agents\run-evidence\antigravity-addons\sync-*`
