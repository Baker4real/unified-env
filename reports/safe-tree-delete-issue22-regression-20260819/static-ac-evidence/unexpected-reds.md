# 本次回归的两个意外红：原始失败输出摘录（2026-08-19）

> 复跑（修复后）覆盖了同名 stdout/stderr 文件，原始失败运行的完整 stderr 已不在本目录；
> 以下为失败当场从落盘文件提取的原文摘录（退出码与断言消息逐字保留）。

## 1. tests/Test-CodexSafeTreeDeletePhase3Integration.ps1 — exit=1, elapsedMs=10052

```text
Exception: D:\Codex\projects\统一环境\tests\Test-CodexSafeTreeDeletePhase3Integration.ps1:60
Line |
 60 |      if (-not $Condition) { throw $Message }
     |                             ~~~~~~~~~~~~~~
     | #36 metTarget 必须仍是 false（未达 3x）
```

触发时现场快照状态（被套件内先跑的 Phase1Integration 用 #42 生产并行管线重写）：
`reports/safe-tree-delete-issue36-20260817/scale-phase1.json` = `{metTarget: true, speedup: 3.845,
baseline: {plan 116933ms, apply 355447ms, purge 308803ms}}`；git HEAD 提交版 = `{metTarget: false,
speedup: 0.633, baseline: {plan 95604ms, apply 285218ms, purge 217376ms}}`。

## 2. tests/Test-CodexSafeTreeDeleteParallelismBenchmark.ps1 — exit=1, elapsedMs=178830

```text
Exception: D:\Codex\projects\统一环境\tests\Test-CodexSafeTreeDeleteParallelismBenchmark.ps1:72
Line |
 72 |      if (-not $Condition) { throw $Message }
     |                             ~~~~~~~~~~~~~~
     | FromDetection optimize 必须等于本机小文件峰值效率 DOP 4，实际为 2
```

即：本机当轮实测小文件峰值效率 DOP=4，而实现常量（#40 2026-08-19 复测钉定 2/2/2）返回 2。
#42 团队 2026-08-19T02:16Z 的回归（reports/safe-tree-delete-issue42-20260819/iteration-2-full-regression.stdout.txt
第 27-28、33-34 行）中本测试 exit=0（当轮实测=2 恰与常量一致），Phase3Integration 同样 exit=1 ms=9730。

## 处置

两处修复见 `unexpected-red-fixes.diff`；修复后经 runner 续跑机制单独重跑：
ParallelismBenchmark exit=0（184034ms，2026-08-19T17:22:52Z）、Phase3Integration exit=0（984991ms，
2026-08-19T17:39:17Z）。最终 summary.json：27/27 完成、26 pass、唯一 fail 为 #35 waiver 的 FileSystem。

透明性记载（绿轮重跑时的快照状态，经 summary.json 守护哈希核验）：Phase3Integration 绿轮重跑
（17:22:52–17:39:17Z）期间，`reports/safe-tree-delete-issue36-20260817/scale-phase1.json` 仍为套件内
Phase1Integration 写脏版——续跑进程的 `guardedSnapshotsAtStart` 与 `guardedSnapshotsAtEnd` 均为
`048f9ced797d3b14a4ad7998ee328785971570d13ef4ae5c1ba634fd38748c8b`（即 metTarget=true / speedup=3.845
版本），`git checkout --` 恢复为提交版（metTarget=false，SHA `be288d57…`）发生在其后约 17:55Z。因此绿轮
实际重演了触发首红的 metTarget=true 路径并通过；即便在任一快照状态下，新断言「字段存在且为 bool」都是
类型级检查、对 metTarget 取 true/false 两路径等价，绿轮效力不依赖快照状态。
