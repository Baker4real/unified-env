# 自习室设备环境说明

## 设备身份

- 设备标识：`zi-xi-shi`
- Windows 主机名：`Baker`
- 统一环境仓库：`D:\Codex\projects\统一环境`
- Codex 受管根：`D:\Codex\.codex`

网络地址、SSH 用户、密钥路径、登录态和凭据属于调用端本地事实，不写入仓库；连接前必须从当前设备的本地配置重新确认。

## Skill 安装入口

- 活动 skill 根：`D:\Codex\.codex\skills`
- 受守卫安装入口：`D:\Codex\.codex\scripts\install-skill-guarded.cmd`
- 项目部署入口：`scripts\Deploy-SkillInstallGuarded.ps1`
- 本机 catalog：`D:\Codex\.codex\skill-catalog\catalog.json`
- 运行证据：`D:\Codex\.codex\run-evidence\skill-install-guarded\`

不得把安装后的回写职责放入被安装的 skill，也不得直接修改 bundled `.system` 安装器。新安装或更新必须经过 decision manifest、`writing-great-skills` 证据、SOURCE/ledger、严格资源闭包和 catalog 后置校验；任一门槛失败都应回滚。

## 跨设备同步与验收

1. 先同步本仓库的已提交默认分支，不复制调用端的 dirty worktree。
2. 从仓库源部署 wrapper，并确认部署文件与项目源文件哈希一致。
3. 运行严格资源闭包和 catalog dry-run；只有两者都通过，才把设备视为已同步。
4. 设备上的日志、临时 staging 和验证快照留在该设备的 D 盘 evidence 路径，不提交到仓库。

最近一次验证日期为 2026-07-14；数量、哈希和工具版本属于易变状态，后续操作必须实时复核，不能把本页当作当前运行结果。
