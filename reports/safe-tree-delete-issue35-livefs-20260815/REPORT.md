# #35 实卷集成验收（2026-08-15）

对照 GitHub #35 最新关闭建议：代码路径已接 `DetectFileSystem` / `DeletionAllowed`，本轮只补**不注入 ForTest** 的真实卷验收。

## 结论

**BLOCKED。** 本机没有现成 FAT32/exFAT/网络卷；一次性 FAT32 VHD 因当前进程非管理员、创建/挂载需要提升而失败。未假装实卷测过。未关票。未 commit / push / comment。

## 本机卷清单

`[IO.DriveInfo]::GetDrives()` 与 `Get-Volume` 一致：

| 盘符 | DriveType | 就绪 | DriveFormat |
| --- | --- | --- | --- |
| C:\ | Fixed | True | NTFS |
| D:\ | Fixed | True | NTFS |
| E:\ | Fixed | True | NTFS |
| F:\ | Fixed | True | NTFS |

无网络盘（`net use` 空；`Get-SmbMapping` 空）。无 FAT32/exFAT。

## 实卷尝试

1. 现成 FAT32/exFAT：无。
2. 授权范围内一次性 VHD（`D:\Codex\temp\issue35-livefs-20260815`，禁止 format 已有磁盘）：
   - `New-VHD`：Hyper-V CIM **拒绝访问**（需 BAKER 上授权管理员）。
   - `diskpart.exe`：Win32 **740**，请求的操作需要提升。
3. `sudo.exe` 处于强制新建窗口模式，本会话未弹出 UAC。
4. 失败后清理了空 workspace；未留下已挂载镜像。

原始错误见 `vhd-attempt.json`。

## 测试行为

`tests/Test-CodexSafeTreeDeleteFileSystem.ps1` 追加实卷切片：

- 先跑原有预构造 capabilities / 本机 NTFS 用例。
- 再枚举真实盘；无 FAT32/exFAT 时尝试一次性 VHD。
- **不传** `FixtureFileSystemCapabilities`。
- VHD/实卷拿不到时 **throw**，整文件不标绿。
- 网络卷：仅当存在且 `DeletionAllowed=false` 才断言 Plan 拒绝；本机无网络卷，结果对象写「本机无网络卷，未验证」。

TDD：先写入「必须有真实 FAT32/exFAT」断言，确认红（盘清单全是 NTFS），再补 VHD helper；helper 在本机提权失败，切片保持红。

未改 Plan/Apply/Purge 热路径、wrapper、生产 policy、ProductionSmoke。

## 验证退出码

| 命令 | 退出码 |
| --- | --- |
| `tests/Test-CodexSafeTreeDeleteFileSystem.ps1` | 1（实卷切片：VHD 需提升，未 skip） |
| `tests/Test-CodexSafeTreeDeleteIdentityV2.ps1` | 0 |
| `git diff --check -- tests/Test-CodexSafeTreeDeleteFileSystem.ps1` | 0 |

预构造 capabilities 的 Plan/Apply/Purge 拒绝在抛出前已经跑过；**真实 FAT32/exFAT 上无 ForTest 的 Plan 未执行**。

## 未验证

- 真实 FAT32/exFAT 上 `DetectFileSystem` 的 FileSystemType / SupportsFileId128 / DeletionAllowed
- 真实 FAT32/exFAT 路径上 fixture Plan（不传 ForTest）是否因 `DeletionAllowed` 拒绝且零写入
- 网络卷 Detect + 推荐策略；本机无网络卷，未验证
- 若 FAT32 只挂到非 D: 盘符，Plan 是路径治理先失败还是 DeletionAllowed 先失败
