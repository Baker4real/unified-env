# Source Provenance

Skill: `subagent-orchestration`
Local path: `D:\Codex\.codex\skills\subagent-orchestration`
Active root: `D:\Codex\.codex\skills`
Recorded: 2026-08-06
Status: source-review
Decision: update
Source type: local-candidate
Source repository: `local candidate supplied by the user`
Upstream path: `subagent-orchestration`
Ref: `local-composition-2026-08-06`
Retrieval: `guarded wrapper local candidate verified by candidate_integrity`
writing-for-agents gate: no-behavior-change-provenance-reclassification
Local overlay: preserved (本地组合 skill，行为与菜单文件保持不变。组合来源：本机 reasoning-and-adversarial-review 治理协议为主体；参考 asgeirtj/system_prompts_leaks@656021e2fb804aa60b6f75b3ea29ffcfcf26bd85 的 batch orchestration 概念；对齐 OpenAI Codex Multi-agent V2@578c1b2230288104041e880a86d0f7f3a5ca6e47 的递归委派能力；适配 mattpocock/skills to-tickets@ed37663cc5fbef691ddfecd080dff42f7e7e350d 的 tracer-bullet、frontier 与 expand-migrate-contract 切分规则。未复制外部 prompt 文本。)
Guarded activation: complete only after ledger, closure, catalog, and hash postchecks pass.
Guarded transaction evidence: `D:\Codex\.codex\run-evidence\skill-install-guarded\install-20260806T210828-4efdf88d2ba04cba9eacec29d5d85be3`
Decision manifest: `D:\Codex\.codex\run-evidence\skill-install-guarded\install-20260806T210828-4efdf88d2ba04cba9eacec29d5d85be3\decision-manifest.json`

---

# Source Provenance

Skill: `subagent-orchestration`
Local path: `D:\Codex\.codex\skills\subagent-orchestration`
Active root: `D:\Codex\.codex\skills`
Recorded: 2026-08-10
Status: source-review
Decision: update
Source type: local-candidate
Source repository: `local candidate supplied by the user`
Upstream path: `subagent-orchestration`
Ref: `local-composition-2026-08-06`
Retrieval: `guarded wrapper local candidate verified by candidate_integrity`
writing-for-agents gate: Added a Claude Code harness adaptation layer as disclosed reference behind a branch pointer; the always-loaded description and the Codex execution path are unchanged.
Local overlay: replayed (Preserved the recorded local composition and agents/openai.yaml unchanged. Added `references/claude-code.md`: Claude Code 2.1.226 scheduling surface — Agent/SendMessage/TaskStop in place of spawn_agent/list_agents, self-accounted concurrency against the default 20-subagent cap with no-retry on `Concurrent subagent limit reached`, the default 3-layer spawn depth whose limit presents as a withheld `Agent` tool, tool-boundary-enforced read-only workers, CLAUDE.md inheritance gaps for built-in Explore/Plan, fork context inheritance as a privacy constraint, background completion-notification acceptance, and harness output-scan markers. Facts verified against code.claude.com/docs/en/sub-agents and the local `claude --version`; the shared no branch/worktree/PR/push/external-update/GUI boundary, unique ownership, and privacy rules were preserved rather than restated.)
Guarded activation: complete only after ledger, closure, catalog, and hash postchecks pass.
Guarded transaction evidence: `D:\Codex\.codex\run-evidence\skill-writing-audit\20260807-015847+0800\transactions\wave1\apply\install-20260807T023503-1a51ee8154124110801a0d9a402b6511`
Decision manifest: `D:\Codex\.codex\run-evidence\skill-writing-audit\20260807-015847+0800\transactions\wave1\apply\install-20260807T023503-1a51ee8154124110801a0d9a402b6511\decision-manifest.json`

---

# Source Provenance

Skill: `subagent-orchestration`
Local path: `D:\Codex\.codex\skills\subagent-orchestration`
Active root: `D:\Codex\.codex\skills`
Recorded: 2026-08-10
Status: source-review
Decision: update
Source type: local-candidate
Source repository: `local candidate supplied by the user`
Upstream path: `subagent-orchestration`
Ref: `local-composition-2026-08-06`
Retrieval: `guarded wrapper local candidate verified by candidate_integrity`
writing-for-agents gate: no-change
Local overlay: none
Guarded activation: complete only after ledger, closure, catalog, and hash postchecks pass.
Guarded transaction evidence: `D:\Codex\.codex\run-evidence\skill-install-guarded\install-20260810T234625-ba10ed5503164f398b6e88d4cd5addf1`
Decision manifest: `D:\Codex\.codex\run-evidence\skill-install-guarded\install-20260810T234625-ba10ed5503164f398b6e88d4cd5addf1\decision-manifest.json`
