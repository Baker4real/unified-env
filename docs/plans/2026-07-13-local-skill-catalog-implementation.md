# 本机 Skill Catalog 实现计划

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

  Cover these behaviors with real temporary files:
  1. active and plugin-cache roots are separated and same-name skills keep different artifact IDs;
  2. frontmatter extracts `name`, `description`, and `disable-model-invocation` into an invocation record;
  3. source metadata and ledger coverage are represented while runtime state remains `unverified`;
  4. missing roots fail closed with `CatalogError`;
  5. `write_catalog` creates a valid UTF-8 JSON file and `build_catalog` itself does not write output.

- [x] **步骤 2：运行聚焦测试确认 RED**

  Run:

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

  Recursively include exact `SKILL.md` files under the two declared roots, excluding `.agents` and disabled/backup trees. Mark normal active entries as `active`, `.system` entries as `system`, and cache entries as `plugin-cache`; set only plugin-cache entries to read-only. Reparse points are never followed; cache junctions are reported as a partial scan.

- [x] **步骤 2：实现元数据和身份提取**

  Parse the required frontmatter fields, including literal/folded block descriptions, without adding a dependency. Record the skill name, description presence, three-state invocation flag, source record fields, modification facts, content SHA-256, separate artifact/location identities, source-relative path, and package/version locator. Every file read is checked for a replacement during the read.

- [x] **步骤 3：实现 ledger 和闭包事实提取**

  Read the existing JSON ledger by its `sources`, `unresolved`, and `deleted` states so conflicts are visible rather than silently selected; artifact records retain the ledger state instead of collapsing it into a boolean. Store coverage as a fact, not a health claim. Validate an injected closure result against the existing checker schema; production CLI invokes only the fixed local closure checker and records its heuristic coverage without duplicating its rules.

- [x] **步骤 4：实现失败关闭的 catalog 组装**

  Emit `schema_version`, `generated_at`, `authority`, root summaries, checks, snapshot/read-consistency facts, and artifact records. Set every artifact's `runtime_verification` to `unverified`; do not infer capability availability from file presence.

- [x] **步骤 5：实现本地原子输出**

  `write_catalog` creates only the requested output parent, writes UTF-8 JSON to a same-directory temporary file, flushes and fsyncs it, and replaces the target with `os.replace`. Replacement failure cleans the temporary file and leaves an existing target unchanged. No remote or credential code is allowed.

- [x] **步骤 6：运行聚焦测试确认 GREEN**

  结果：14 项 catalog 测试全部通过，无警告。

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

  结果：291 条记录：active 93、system 5、plugin-cache 193；缓存中既有的 junction 被明确报告为只读部分扫描。ledger 覆盖率为 98/98，资源闭包以 heuristic 覆盖方式通过。

- [x] **步骤 2：运行现有严格资源闭包检查器**

  ```powershell
  & 'D:\Codex\tools\python314-official\python.exe' 'D:\Codex\.codex\skills\skill-install-guard\scripts\skill_resource_closure.py' --root 'D:\Codex\.codex\skills' --strict --format json
  ```

  结果：现有检查器返回 active skill 98 个，发现 0 个，缺失/重复/过期资源或 ledger 记录均为 0。

- [x] **步骤 3：仅在 dry-run 和闭包检查通过后写入本地 catalog**

  ```powershell
  & 'D:\Codex\tools\python314-official\python.exe' -B 'D:\Codex\projects\统一环境\scripts\generate_skill_catalog.py' --write --output 'D:\Codex\.codex\skill-catalog\catalog.json'
  ```

  结果：本地 catalog 已原子写入，并验证为 291 条记录的 UTF-8 JSON；它位于项目工作树之外。

- [x] **步骤 4：运行聚焦测试和仓库相关回归测试**

  ```powershell
  & 'D:\Codex\tools\python314-official\python.exe' -B 'D:\Codex\projects\统一环境\tests\Test-SkillCatalog.py'
  & 'D:\Codex\tools\python314-official\python.exe' -B 'D:\Codex\projects\统一环境\tests\Test-CodexStatePathInventory.py'
  & 'D:\Codex\tools\python314-official\python.exe' -B 'D:\Codex\projects\统一环境\tests\Test-CodexStatePolicy.py'
  ```

  结果：catalog 14/14、路径清单 17/17、资源闭包 9/9 通过。无关的 state-policy 套件为 55/56：唯一失败来自既有提交 `54e138a` 的 lease 改动（实际为 `state publish handle final path mismatch`，而测试期待 `concurrent`）；本计划未修改该文件。

- [x] **步骤 5：验证作用域和工作树边界**

  catalog 数量区分 active/system/plugin-cache；聚焦网络守卫通过；生成的 catalog 位于仓库之外；本计划涉及的项目文件仅有计划、扫描器和聚焦测试。既有 pycache 仍保持未跟踪、未暂存。
