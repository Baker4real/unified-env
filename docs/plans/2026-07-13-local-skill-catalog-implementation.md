# 本机 Skill Catalog 实现计划

> **状态（2026-07-13）：** 已实施并验证完成。下方复选框保留实施过程记录，不再表示当前待办；当前派生输出和运行证据以 `D:\Codex\.codex\skill-catalog\` 与 `D:\Codex\.codex\run-evidence\skill-catalog\` 为准。

> **给执行代理：** 按任务逐项执行。保持既有工作树改动不变，只暂存本计划涉及的文件。

**目标：** 生成一份只读派生的本机 Codex skill catalog，区分 active skill 与插件缓存镜像，并用现有 source ledger 与资源闭包检查提供可审计事实。

**架构：** `scripts/generate_skill_catalog.py` 只负责本地扫描、解析、哈希和原子写出；它不安装、更新或修改 skill，不访问网络，不读取凭据，不注册 hook。active root 与 plugin-cache 分域记录；来源以 `SOURCE.md` 与统一 JSON ledger 为权威，运行可用性保持 `unverified`，资源闭包结果委托给现有 `skill_resource_closure.py`。

**技术栈：** Python 3.14 标准库、`unittest`、JSON、SHA-256、PowerShell/Python 本地命令。

## 全局约束

- active skill root 固定为 `D:\Codex\.codex\skills`；插件缓存根为 `D:\Codex\.codex\plugins\cache`。
- 不扫描或创建 `D:\Codex\.agents\skills`，不扫描 backup、tmp、run-evidence 历史树。
- plugin-cache 记录必须是 `read_only=true`，不能计入 active capability 数量；两棵根目录缺失都必须失败关闭。
- dry-run 不写 catalog；write 模式只在 D 盘目标路径原子替换本地 catalog。
- 不包含外部服务、网络请求、access token、OAuth、远端写入或全局 lifecycle hook。
- 不把 `SKILL.md` 存在、哈希一致、AGENTS 文件存在或资源闭包通过说成运行能力已经验证。
- 不修改现有 skill、SOURCE.md、统一 ledger 或当前工作树中不属于本计划的改动。

---

### 任务 1：用失败测试定义 catalog 契约

**文件：**
- 新建：`tests/Test-SkillCatalog.py`
- 参考：`D:\Codex\.codex\skills\.downloaded-skills-source-state.json`
- 参考：`D:\Codex\.codex\skills\skill-install-guard\scripts\skill_resource_closure.py`

**接口：**
- 测试通过 `importlib` 导入 `scripts/generate_skill_catalog.py`。
- 测试定义必须提供的公开函数：`build_catalog(...)`、`write_catalog(...)` 和 `CatalogError`。

- [x] **步骤 1：编写失败测试**

  使用真实临时文件覆盖以下行为：
  1. active 与 plugin-cache 根目录分离，同名 skill 保留不同 artifact ID；
  2. frontmatter 将 `name`、`description` 和 `disable-model-invocation` 提取到调用记录；
  3. 保留来源元数据和 ledger 覆盖事实，同时将运行状态保持为 `unverified`；
  4. 根目录缺失时以 `CatalogError` 失败关闭；
  5. `write_catalog` 生成合法 UTF-8 JSON，而 `build_catalog` 本身不写输出。

- [x] **步骤 2：运行聚焦测试确认 RED**

  运行命令：

  ```powershell
  & 'D:\Codex\tools\python314-official\python.exe' -B 'D:\Codex\projects\统一环境\tests\Test-SkillCatalog.py'
  ```

  结果：聚焦测试明确因 `scripts/generate_skill_catalog.py` 尚不存在而失败。

### 任务 2：实现本地扫描器和 catalog 写入器

**文件：**
- 新建：`scripts/generate_skill_catalog.py`
- 测试：`tests/Test-SkillCatalog.py`

**接口：**
- `build_catalog(active_root: Path, plugin_cache_root: Path, ledger_path: Path, resource_closure: dict | None = None, generated_at: str | None = None) -> dict`
- `write_catalog(catalog: dict, output_path: Path) -> None`
- 缺少根目录、来源数据不可读、JSON 无效或闭包输入失败时抛出 `CatalogError`。

- [x] **步骤 1：实现路径发现和作用域分类**

  递归纳入两个声明根目录下名称严格为 `SKILL.md` 的文件，排除 `.agents` 以及停用/备份历史树。普通 active 项标为 `active`，`.system` 项标为 `system`，缓存项标为 `plugin-cache`；只有 plugin-cache 项标记为只读。永不跟随 reparse point；缓存 junction 报告为部分扫描。

- [x] **步骤 2：实现元数据和身份提取**

  不增加依赖，解析必需的 frontmatter 字段，包括 literal/folded 块描述。记录 skill 名称、描述是否存在、三态调用标记、来源记录字段、修改事实、内容 SHA-256、分离的 artifact/location 身份、来源相对路径和 package/version 定位。每次读取文件后都检查文件是否被替换。

- [x] **步骤 3：实现 ledger 和闭包事实提取**

  按 `sources`、`unresolved` 和 `deleted` 状态读取现有 JSON ledger，使冲突可见而不是静默择一；artifact 记录保留 ledger 状态，不折叠成布尔值。覆盖率只作为事实记录，不作为健康声明。按现有检查器 schema 校验注入的闭包结果；生产 CLI 只调用固定的本地闭包检查器，并记录其 heuristic 覆盖范围，不重复实现检查规则。

- [x] **步骤 4：实现失败关闭的 catalog 组装**

  输出 `schema_version`、`generated_at`、`authority`、根目录摘要、检查结果、快照/读取一致性事实和 artifact 记录。每个 artifact 的 `runtime_verification` 都设为 `unverified`；不从文件存在推断能力可用。

- [x] **步骤 5：实现本地原子输出**

  `write_catalog` 只创建请求的输出父目录，把 UTF-8 JSON 写入同目录临时文件，flush 并 fsync 后用 `os.replace` 替换目标。替换失败时清理临时文件并保持旧目标不变。不允许远程或凭据代码。

- [x] **步骤 6：运行聚焦测试确认 GREEN**

  结果：16 项 catalog 测试全部通过，无警告。

### 任务 3：增加安全 CLI 模式

**文件：**
- 修改：`scripts/generate_skill_catalog.py`
- 测试：`tests/Test-SkillCatalog.py`

**接口：**
- 默认使用 `--dry-run`，只打印摘要，永远不写输出文件。
- `--write --output <D-path>` 在本地写完整 catalog；非 D 盘输出直接拒绝。
- `--active-root`、`--plugin-cache-root` 和 `--ledger` 仅作为明确的只读测试/诊断覆盖项。

- [x] **步骤 1：增加 dry-run 和 write 模式测试**
- [x] **步骤 2：在实现前确认 RED 门槛**

  初始缺失模块运行提供了 RED 证据；后续 CLI 测试在实现被执行前加入。
- [x] **步骤 3：实现 argparse 分发和本地闭包调用**
- [x] **步骤 4：运行聚焦测试确认 GREEN**

### 任务 4：在真实本机上验证

**文件：**
- 输出：`D:\Codex\.codex\skill-catalog\catalog.json`（本机派生状态，不纳入项目提交）
- 证据：仅在需要保存本次运行证据时使用 `D:\Codex\.codex\run-evidence\skill-catalog\`

- [x] **步骤 1：对真实 active 和缓存根目录运行 dry-run**

  ```powershell
  & 'D:\Codex\tools\python314-official\python.exe' -B 'D:\Codex\projects\统一环境\scripts\generate_skill_catalog.py' --dry-run
  ```

  结果：本次运行证据见 `D:\Codex\.codex\run-evidence\skill-catalog\20260713-validation.md`。

- [x] **步骤 2：运行现有严格资源闭包检查器**

  ```powershell
  & 'D:\Codex\tools\python314-official\python.exe' 'D:\Codex\.codex\skills\skill-install-guard\scripts\skill_resource_closure.py' --root 'D:\Codex\.codex\skills' --strict --format json
  ```

  结果：本次运行证据见 `D:\Codex\.codex\run-evidence\skill-catalog\20260713-validation.md`。

- [x] **步骤 3：仅在 dry-run 和闭包检查通过后写入本地 catalog**

  ```powershell
  & 'D:\Codex\tools\python314-official\python.exe' -B 'D:\Codex\projects\统一环境\scripts\generate_skill_catalog.py' --write --output 'D:\Codex\.codex\skill-catalog\catalog.json'
  ```

  结果：本次运行证据见 `D:\Codex\.codex\run-evidence\skill-catalog\20260713-validation.md`；生成物位于项目工作树之外。

- [x] **步骤 4：运行聚焦测试和仓库相关回归测试**

  ```powershell
  & 'D:\Codex\tools\python314-official\python.exe' -B 'D:\Codex\projects\统一环境\tests\Test-SkillCatalog.py'
  & 'D:\Codex\tools\python314-official\python.exe' -B 'D:\Codex\projects\统一环境\tests\Test-CodexStatePathInventory.py'
  & 'D:\Codex\tools\python314-official\python.exe' -B 'D:\Codex\projects\统一环境\tests\Test-CodexStatePolicy.py'
  ```

  结果：本次运行证据见 `D:\Codex\.codex\run-evidence\skill-catalog\20260713-validation.md`；无关的 state-policy 结果和既有提交边界也记录在那里。

- [x] **步骤 5：验证作用域和工作树边界**

  作用域、网络守卫、输出位置和工作树边界的本次证据见 `D:\Codex\.codex\run-evidence\skill-catalog\20260713-validation.md`。
