## 结论（先于关闭）

#21 可以关闭。端到端断言已并入既有 ProductionSmoke，走真实受管 `.cmd` 链。

**非零主证据只有这一条：**

`reports/safe-tree-delete-issue55-20260816/leaf-delete-failed.json`

已打开该 JSON：`exitCode=1`，`purged=false`，`refusalReason=leaf-delete-failed`，`productionJsonObtained=true`，`lockAcquiredMarkerExists=true`。

不能用 fixture、不能用套件 `ok=true` / suite exit 0、不能用 `revert-forwarding.json` 的 `exitCode=0` 冒充这条非零证明。

## Acceptance criteria

| AC | 结论 | 依据 |
| --- | --- | --- |
| 存在一条断言，经真实受管 wrapper 链验证 `leaf-delete-failed` 返回非零 | **满足** | 唯一非零主证据：`leaf-delete-failed.json` `exitCode=1`。断言在 `tests/Test-CodexSafeTreeDeleteProductionSmoke.ps1` |
| 该断言在 #20 修复前会失败、修复后通过 | **满足（负向切片）** | `reports/safe-tree-delete-issue21-20260816/revert-forwarding.json`：`exitCode=0`，`wrapperSwallowedNonzero=true`，JSON 仍是 `leaf-delete-failed` / `purged=false`。这证明没有转发时非零会丢成 0。**不是**非零主证据 |
| 同时断言 `exit 0` + `refusalReason` 未被破坏 | **满足** | `archive-unconfirmed.meta.json` `actualExitCode=0`；`archive-unconfirmed.stdout.txt` 为 `{"archived":false,"refusalReason":"confirm-archive-required"}` |
| 不新增测试 seam；优先并入既有 ProductionSmoke | **满足** | 只改 `tests/Test-CodexSafeTreeDeleteProductionSmoke.ps1`，未新建测试文件 |
| 不对生产证据根做写操作，或明确说明依赖与隔离 | **满足（选后者）** | live 链必然在生产 evidence 根留下新 operation。隔离方式与 leftover 禁令见 `reports/safe-tree-delete-issue21-20260816/CLOSEABLE.md` |
| 既有全部 safe-tree-delete 测试保持通过 | **部分** | 本票必跑的是上述 live 断言。host-safety 默认 fixture 未在本收口重跑；#35 FileSystem 为已知 waiver。**不得**用套件 exit 0 替代 `leaf-delete-failed.json` 的 exit 1 |

## 同一次调用的配对（不是第二条非零主证据）

- `reports/safe-tree-delete-issue55-20260816/fail-purge-leaf-delete.meta.json`（`actualExitCode=1`，`expectedExitCode=1`）
- `reports/safe-tree-delete-issue55-20260816/fail-purge-leaf-delete.stdout.txt`（生产 JSON，含 metrics `failed-after-retry` / `sharing-violation`）

索引：`reports/safe-tree-delete-issue47-20260816/evidence-index.md`。

## 明确不是非零主证据

| 文件 | 已打开字段 | 为何不能当非零主证据 |
| --- | --- | --- |
| `reports/safe-tree-delete-issue21-20260816/revert-forwarding.json` | `exitCode=0` | 负向：wrapper 吞掉非零 |
| `reports/safe-tree-delete-issue55-20260816/summary.json` | `ok=true` | 套件收口 |
| fixture / mock | — | #47 / #52 明文排除 |

## 引用（仓库相对路径）

- `reports/safe-tree-delete-issue55-20260816/leaf-delete-failed.json`（**唯一非零主证据**，`exitCode=1`）
- `reports/safe-tree-delete-issue55-20260816/fail-purge-leaf-delete.meta.json`
- `reports/safe-tree-delete-issue55-20260816/fail-purge-leaf-delete.stdout.txt`
- `reports/safe-tree-delete-issue21-20260816/revert-forwarding.json`（负向，`exitCode=0`）
- `reports/safe-tree-delete-issue55-20260816/archive-unconfirmed.meta.json`
- `reports/safe-tree-delete-issue55-20260816/archive-unconfirmed.stdout.txt`
- `tests/Test-CodexSafeTreeDeleteProductionSmoke.ps1`
- `reports/safe-tree-delete-issue47-20260816/evidence-index.md`
- `reports/safe-tree-delete-issue21-20260816/CLOSEABLE.md`
