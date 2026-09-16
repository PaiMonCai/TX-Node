# tx-node

> fork of [cedar2025/Xboard-Node](https://github.com/cedar2025/Xboard-Node) with an embedded access-audit reporter for the **sing-box** kernel.
> 与原版 100% 兼容：配置格式、上报接口、xbctl、install.sh 全部不变，可做 drop-in 替换。

## 与原版 xboard-node 的差异

只有一个增量：**sing-box 内核连接级审计内嵌上报**（`internal/audit/`）。

- 在 `config.yml` 加 `audit:` 段即启用；不加 = 与原版行为完全一致（零开销）
- 上报**复用节点已有的面板认证**（panel.url + token + node_id / machine token），与原版流量上报走同一套 Xboard `ServerV2` 中间件，无需额外密钥
- 面板侧配套 [AccessAudit 插件](https://github.com/cedar2025/Xboard) v2.0+：分节点查看命中日志、自动封禁、TG 告警、节点级异常通报（上报中断 / 命中突增）
- xray 内核不在此列：xray 侧请继续使用 AccessAudit 的旁路 `audit-agent.py`（tail access log）

## 启用方式

```yaml
# config.yml（在原版配置基础上追加）
audit:
  enabled: true
  # batch_max: 50        # 每次上报最多事件数
  # flush_interval: 15   # 上报间隔（秒）
  # rules_refresh: 5     # 规则拉取间隔（分钟）
  # queue_cap: 5000      # 面板不可达时的本地队列上限
```

重启后日志出现 `audit reporter enabled` 即生效。

## 数据流

```
客户端连接 → sing-box 内核路由
  → ConnTracker.RoutedConnection/RoutedPacketConnection（原版挂点）
  → audit.Reporter.Observe(user_id, target, source_ip)
  → 本地规则预过滤（规则每 5 分钟从面板拉取）
  → 命中才入队 → 攒批 50 条 / 15s
  → POST /api/v1/plugin/access-audit/report?token=<panel token>&node_id=<id>
```

目标提取优先级：sniff 域名 > 代理协议自带域名 > 目标 IP。代理协议本身携带目标域名，绝大多数域名审计场景不依赖 sniff。

## 构建

```bash
go build -tags "with_quic with_utls with_wireguard with_clash_api" -o tx-node ./cmd/xboard-node
```

## 许可证

MPL-2.0（与上游一致）。修改过的文件保留版权头并注明修改。
