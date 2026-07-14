# 调查发现

## 当前状态

- 本机 active skill 根目录：`D:\Codex\.codex\skills`。
- 统一来源台账：`D:\Codex\.codex\skills\.downloaded-skills-source-state.json`。
- 本次规则：上游 stable 是内容基线，本机 overlay 需要三方合并保留；`skills/in-progress/**` 完全排除。

## 初始盘点

- 当前 active skill 根目录有 56 个非 `.system` skill，另有 5 个 bundled `.system` skill；每个 active 目录当前都有 `SOURCE.md`。
- 统一台账有 19 个来源组，更新时间为 2026-07-13；其中 Matt 来源仍只列旧的 28 个 active skill，`wayfinder` 尚未安装。
- `agent-reach` 实时体检可用，GitHub 后端为 `gh CLI`；`agent-reach check-update` 报告当前 v1.5.0 已是最新。
- 当前 active 目录和台账中同时存在 source-backed、官方 bundled、vendor/local overlay 与 source-unresolved 边界，不能用单一 git pull 代替逐来源合并。
