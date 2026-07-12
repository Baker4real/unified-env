---
generationId: 991cafff-4575-4182-8af1-225ad6ed7c2b
sourceJsonSha256: dc59fe8d4509f8178aa56b6cca28601af54fb3a8716479f4e7e4fd0ce55cb097
---
# Codex Hook production registration-repair 计划

- profile：codex-hook-production-registration-repair-v1
- 生成时间（UTC）：2026-07-12T08:14:15.7954581+00:00
- 模式：registration-repair
- 可执行：True
- registry 动作数：1
- 文件动作数：0
- 环境动作数：0
- registry before SHA-256：b342a2e2700cbeddf7cdc56fdc494224d07e5c7a98d7105d9e3d308ac72ca106
- registry after SHA-256：eb55a1b92aa9828ab9ab1c410aeb188fe64c39815f216bc96889ce93cd913b6f
- managed before order：provider-stability,github-cli,codex-state-policy,serena-activate,serena-dashboard
- managed after order：provider-stability,codex-state-policy,serena-activate,serena-dashboard,github-cli
- Stop projection：count=1, sha256=8f2bdfeafb701192ddbcee576082e8d0ebbca401406dcbd87104731e6fa7d073
- PreToolUse projection：count=2, sha256=80437e4279edb794e42055a0928fe2b55bcd6c9c3b8abdfa21697295c496a373
- unknown projection：count=0, sha256=74b2c6b8ea18d639e3b3c3019ffdc3c586f5fca5a411b4e0fb98098ecea50397
- restartRequired：True
- fileActions：0
- environmentActions：0
- freshness gate：生成后 60 分钟内执行，并在 production mutex 内 fresh rederive
- 完整性并发边界：最终 verified target handle 排除内容写入并持有到同目录 crash-atomic rename 完成
- 残余边界：普通用户态 Windows API 不保证阻止不合作外部 delete/replace 恰在最终系统调用前发生；本计划不声称绝对 CAS

此计划只读生成；必须先通过独立审查，才能由主 agent 显式执行 production apply。
本报告不包含 desired registry、raw registry command 或环境变量原值。