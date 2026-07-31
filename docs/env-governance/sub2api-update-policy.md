---
type: reference
title: Sub2API 受管更新策略
tags: [Sub2API, 更新, Docker]
intent: 约束 Sub2API 稳定版升级、静默窗口和联合回滚
---

# Sub2API 受管更新策略

## 适用范围

本策略约束本机受管 Sub2API Docker 部署的自动和人工稳定版升级。运行时事实源、官方 upstream、版本比较、敏感信息处理和证据要求继续以现有自动任务及宿主治理规则为准。

## 短暂中断授权

Sub2API 升级不再以零中断为硬门槛。在以下条件全部成立时，现有“升级到官方最新稳定版”的持续授权包含仅重建 `sub2api` application service 所需的可控短暂中断，无需逐次另行取得维护窗口授权：

- Docker context 可用，升级前三项 Compose 服务均健康，宿主 `/health` 通过；
- 已确认没有活跃依赖请求，能够建立安全静默窗口；
- 目标版本是可验证的官方严格稳定版，目标镜像 tag、固定 digest 和本机平台一致；
- 已建立并验证 ACL 保护的联合回滚点，覆盖 Compose 快照、PostgreSQL 逻辑备份和三个命名卷，并有可执行的联合恢复步骤；
- Release notes 未要求破坏性数据操作、未说明兼容性的数据库迁移、卷布局转换或其他必须人工处理的变更。

任一条件无法证明时，升级必须延期或标记为需要人工审查。无活跃请求只是允许短暂中断的前置条件，不得用来省略备份、回滚或健康验证。

## 允许的服务变更

升级事务只能修改 Compose 中 `sub2api` service 的唯一 application image pin，并保留旧镜像用于回滚。切换只能使用官方 Docker Compose 的 application-only 路径，以 `--no-deps --wait` 仅重建 `sub2api` service。

短暂中断授权不扩大到以下操作：

- 停止、重建或升级 PostgreSQL、Redis；
- 执行 `docker compose down`、删除卷、全服务 pull、全栈重建、prune 或强制重建；
- 修改端口、卷、网络、`.env`、凭据、Codex provider、CC Switch 模板或本地源码 checkout；
- 接受数据丢失、破坏性迁移、来源不明镜像、预发布版本或同 tag digest 漂移。

## 验收与恢复

更新后必须重新读取运行容器的 image tag、digest 和 OCI version，并验证三项服务 healthy、宿主 `/health` 通过、非 application-image 配置未漂移以及 host reconciler Check 通过。不得用可能计费或使用 OAuth 凭据的模型请求做健康检查。

更新或验证失败时，立即停止继续写入，并按已验证的联合恢复步骤恢复旧 image、Compose pin、PostgreSQL 和三个卷，再执行同一健康检查。无法证明完整恢复时，只能报告 `failed/recovery-required`，不得声称已回滚。
