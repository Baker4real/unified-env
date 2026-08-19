# iteration-2 Purge profile

## 串行段拆解（10k×4KB typical DOP2）

迭代 1 Purge ≈ 121s，协调器 2–4s。迭代 2b typical-s1：

| 段 | ms | 安全语义 |
| --- | ---: | --- |
| locked preflight C# walker | 2973 | 与 Apply 同一 identity/lease/hash；不削弱 |
| batch collect/validate | 0 | C# walker 已填 cache，跳过重复 pass |
| coordinator + 组内空目录 | 3213 | 顶级 guard + child walk；根文件组后置 |
| 空根目录 | 31 | 仍串行，仅 quarantine 根 |
| Purge 其余（stream-set 目录、dispositions、transaction） | ≈26400 | 仍在 Purge 墙钟内 |
| **Purge 合计** | **32645** | |
| Plan | 88030 | 未动（#31） |
| Apply | 21374 | 未动 |
| **全管线** | **142049** | 4.057x vs iter1 baseline 576238 |

## 可行性

- 4x 阈值 144059ms。typical 两组 142049 / 143215，均达标。
- 6x 阈值 96040ms。Plan 单独 88–96s，加上 Apply 21s 已超过 96s。不动 Plan 不可能 6x。
- Plan 哈希并行属 #31。本票不跨界。
