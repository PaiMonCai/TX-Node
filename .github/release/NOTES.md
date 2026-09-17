# TX-Node v2.2.0

本版本重点完善 AccessAudit 管理能力，同时包含近期 TX-Node 部署与 machine 模式稳定性修复。

## AccessAudit v2.2

- 新增数据分析页：支持 1h / 24h / 7d / 30d 趋势与节点筛选。
- 新增节点、规则、用户、目标排行，以及访问量、命中量、命中率、封禁等核心指标。
- 新增插件设置页，直接使用 Xboard 原生插件配置存储，无需手改 `config.json`。
- 新增 `audit_hourly_stats` 小时聚合表，默认每 5 分钟刷新近期聚合数据。
- 新增分析数据保留时间配置，长期趋势优先读取聚合数据，降低全量日志大表查询压力。
- 优化定时任务注册，避免部分清理配置提前返回后影响其他调度任务。
- AccessAudit 插件版本升级至 `2.2.0`。
- TX-Node → 面板的访问审计上报协议保持不变。

## TX-Node 稳定性

- machine 节点启动失败后支持指数退避自动重试，15 秒起步、最高 5 分钟。
- 修复节点一次启动失败后可能永久被判定为“已在运行”的问题。
- `/healthz` 现在能反映 machine 节点实际健康状态；节点失败时返回 degraded / HTTP 503。
- 节点稳定运行后再失败会重置退避计数并快速恢复。
- 近期部署脚本修复一并包含：同名容器冲突恢复、快捷命令自愈、访问审计开关、启动稳定性保护等。

## 升级提示

- 更新 AccessAudit 插件后需要执行/允许插件 migration，以创建 `audit_hourly_stats` 及新增索引。
- 建议确认 Xboard scheduler / cron 正常运行，分析聚合与数据清理由插件调度任务维护。
- 现有审计规则和历史日志不会因本次升级主动删除；清理仍按插件设置中的保留天数执行。
- 本版本没有 TX-Node 节点上报协议的破坏性变更。

## Release assets

CI 将继续发布：

- `xboard-node-linux-amd64`
- `xboard-node-linux-arm64`
- `xbctl-linux-amd64`
- `xbctl-linux-arm64`
- `AccessAudit-plugin.zip`
