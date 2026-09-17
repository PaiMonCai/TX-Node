# TX-Node v2.2.1

本版本重点修复 AccessAudit 管理页统计展示与导航体验，并同步更新插件作者信息。

## AccessAudit v2.2.1

- 主审计页右上角新增“数据分析与设置”入口，可直接进入 `/plugin/access-audit/insights`。
- 修复主页统计卡片可能因 60 秒进程内缓存而长期显示旧值的问题；今日访问、今日命中、封禁、规则及在线节点现在每次请求直接读取数据库。
- 修复 `approxRowCount()` 回退逻辑：统计 `audit_access_logs` 失败时不再错误回退到 `audit_reports`。
- 保留大表历史总行数的 `information_schema.TABLE_ROWS` 估算策略，避免首页总量统计拖慢数据库。
- AccessAudit 插件版本升级至 `2.2.1`。
- 插件作者更新为 `PaiMonCai`。

## 兼容性

- TX-Node → 面板的访问审计上报协议保持不变。
- 现有规则、命中记录、访问日志和分析聚合数据不会因本次升级主动删除。
- 本次没有新增数据库 migration。

## Release assets

CI 发布以下文件：

- `xboard-node-linux-amd64`
- `xboard-node-linux-arm64`
- `xbctl-linux-amd64`
- `xbctl-linux-arm64`
- `AccessAudit-plugin.zip`
