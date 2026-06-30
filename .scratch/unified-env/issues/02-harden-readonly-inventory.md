# Issue 02：修正并加固只读环境盘点器

Status: done

## Parent

`.scratch/unified-env/PRD.md`

## What to build

把现有只读盘点能力加固成后续迁移、更新和审查都能信任的环境基线。完成后，盘点器应能稳定生成机器可读 inventory 和中文报告，并且版本探测异常、工具缺失、编码异常或命令输出异常都不会阻断整体报告。

## Acceptance criteria

- [x] 盘点器默认保持只读，不移动文件、不改环境变量、不执行更新。
- [x] 快速模式可以跳过版本探测，并仍生成完整结构的 inventory 和报告。
- [x] 完整模式能容忍单个工具版本探测失败，并把失败记录为证据而不是中断执行。
- [x] inventory 包含稳定字段：`readOnly`、`tools`、`directories`、`pathEntries`、`migrationCandidates`、`manualReviewItems`、`excludedRoots`。
- [x] 中文报告包含只读声明、绝不自动迁移清单、迁移候选和人工审查项。
- [x] 生成的 JSON 可以被 PowerShell JSON parser 读取。

## Blocked by

- `.scratch/unified-env/issues/01-readonly-env-inventory.md`

## Comments

覆盖 PRD 用户故事：1-18。

## Completion notes

- 修复版本探测参数传递，避免 PowerShell 自动 `$args` 变量冲突导致 `--version` 丢失。
- 为每个版本探测加入超时隔离，避免单个工具卡住整体盘点。
- 将失败探测记录为 `probeSucceeded=false`、`error` 和 `evidence`，不再把失败输出伪装成 `version`。
- 补充 `tests/Test-EnvInventory.ps1`，覆盖快速模式、完整模式、JSON 契约、报告内容和失败探测语义。
