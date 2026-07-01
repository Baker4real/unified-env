# codex-account-switch 依赖更新 DRY-RUN 计划

生成时间：2026-07-01T09:10:04.4436244+08:00

> DRY-RUN：本计划只读取目标项目状态并生成候选方案，不执行依赖更新、不修改 `package.json` / `package-lock.json`、不重建或删除 `node_modules`。

## 摘要

- 目标项目：`D:\Codex\projects\codex-account-switch`
- 项目版本：`codex_switch@1.5.12`
- 当前 Node：`v24.15.0`
- 当前 npm：`11.12.1`
- npm cache：`D:\Codex\tools\npm-cache`
- 目标项目 dirty：否
- 执行允许：否

## 当前事实

- `package-lock.json` lockfileVersion：`3`
- `package-lock.json` package entries：`78`
- 项目根 reparse point：否
- `node_modules` reparse point：否

### 顶层依赖

| 名称 | 类型 | package.json 版本 | 当前安装版本 | latest |
| --- | --- | --- | --- | --- |
| @tauri-apps/api | dependencies | 2.10.1 | 2.10.1 | 2.11.1 |
| @tauri-apps/cli | devDependencies | 2.10.1 | 2.10.1 | 2.11.4 |
| typescript | devDependencies | 5.9.2 | 5.9.2 | 6.0.3 |
| vite | devDependencies | 7.3.6 | 7.3.6 | 8.1.2 |

### npm audit

| 包 | 严重级别 | 直接依赖 | 范围 | fixAvailable | fix 版本 |
| --- | --- | --- | --- | --- | --- |

## 建议

- 更新策略：当前安全补丁已满足；后续只单独评估大版本或框架 minor 更新。
- 当前状态：`no-action-required`
- 当前 npm audit 未发现漏洞，安全补丁候选已经不需要继续执行。
- 目标项目当前 git status clean；真实执行前仍必须重新检查 dirty 状态。

### 候选命令预览

- `无自动候选命令。当前 npm audit 未发现漏洞。`

### 暂不执行的动作

- 不执行 `npm ci` 作为更新手段：它只会按当前 lockfile 重建旧依赖，不能让依赖保持最新。
- 暂不直接跳到 `vite 8.1.2`：当前项目声明为 `vite 7.3.6`，latest 是潜在大版本升级，应单独评估构建和 Tauri 开发服务器兼容性。
- 暂不直接跳到 `typescript 6.0.3`：当前项目声明为 `typescript 5.9.2`，latest 是潜在大版本升级，应单独评估类型检查变化。
- 暂不合并 Tauri minor 更新：`@tauri-apps/api` 和 `@tauri-apps/cli` 可后续独立评估，避免把安全补丁和框架更新混在一次变更里。
- 不删除、不重建现有 `node_modules`；真实更新前先只改锁文件和声明文件，再通过项目验证确认。

## 执行前 gate

- 用户明确授权真实依赖更新范围，且确认目标项目当前不是 dirty。
- 真实执行前重新运行 `git status --short --branch`、`npm outdated --json --depth=0` 和 `npm audit --json`。
- 先审查 `package.json` / `package-lock.json` diff，再决定是否重建 `node_modules`。
- 若目标项目出现未提交业务改动，必须先由 owner 决定保留、提交或搁置这些改动。

## 验证命令预览

- `npm ls --depth=0`
- `npm audit`
- `npm run version:check`
- `npm run build`
- `npm run check:rust:windows`

## 回滚边界

- 回滚只恢复 `package.json` 和 `package-lock.json` 到更新前版本。
- 不得删除现有 `node_modules` 作为回滚手段。
- 如果后续真实执行曾重建依赖，先用 git diff 和 npm 验证确认影响，再按目标项目自己的流程恢复。
- 本 dry-run 不生成可直接 apply 的删除、迁移或重装步骤。

## 策略

- 本计划只读查询目标项目状态，不执行 npm install、npm ci、npm audit fix 或依赖更新。
- 候选命令只是后续真实授权 issue 的预览，不代表当前可以执行。
- 真实更新前必须重新确认目标项目 dirty 状态和 npm audit 输出。
- 输出只能位于 D 盘允许报告目录。
- 回滚边界限定在 package.json 和 package-lock.json；不得删除现有 node_modules。
