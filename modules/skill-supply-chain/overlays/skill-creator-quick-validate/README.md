# skill-creator quick_validate 兼容 overlay 资产

`test_quick_validate.py` 是 `skill-creator-quick-validate-compatibility` overlay 的回归测试。`implementation/prepare_system_provenance_repair.py skill-creator-overlay` 把它写进候选的 `scripts/`，换行跟随现役 `quick_validate.py`；`SKILL.md` 与 `quick_validate.py` 的两处补丁在同一工具的 `CREATOR_PATCHES` 里。

字节与 2026-09-06 审过的候选 `D:\agents\run-evidence\skill-creator-quick-validate-repair-20260906\candidate\.system\skill-creator\scripts\test_quick_validate.py` 相同。改它就改了 overlay 的 payload：重新生成候选后照常走 wrapper `--dry-run`，合同见 `docs/specs/2026-07-14-skill-install-guarded-wrapper.md` 的 `system_provenance_overlay` 段。
