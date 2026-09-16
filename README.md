# TX-Node

Xboard 节点后端（fork of [cedar2025/Xboard-Node](https://github.com/cedar2025/Xboard-Node)），支持 `sing-box` / `xray-core` 双内核。

**与原版唯一差异：内嵌 sing-box 内核的访问审计上报**（配合面板 AccessAudit 插件）。默认关闭，不启用时与原版行为完全一致，可直接替换原版使用。

- 协议：V2Ray 系、Trojan、Shadowsocks、Hysteria2、TUIC、AnyTLS
- 同步：WebSocket 推送 + REST 轮询双通道
- 用户控制：限速、设备数限制、在线 IP 跟踪、热更新
- 部署模式：单节点 / 机器（machine）/ 独立（standalone）
- 多实例：单进程绑定多个面板 / 节点

## 部署（Docker，推荐）

镜像由 GitHub Actions 自动构建发布到 GHCR（amd64 + arm64）：

```
ghcr.io/paimoncai/tx-node:latest
```

### 一键部署脚本（推荐）

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/PaiMonCai/TX-Node/main/deploy.sh)
```

脚本完成：Docker 环境检测/自动安装 → 交互式填写面板地址 / token / node_id（或 machine 模式 machine_id + 机器令牌）→ 生成 `/etc/xboard-node/config.yml` + `docker-compose.yml` → 拉镜像启动 → 部署后自检（容器存活 + 审计模块连通）。重复执行可升级/重配/卸载（幂等）。

> 首次使用前确认 GitHub Packages 里 `tx-node` 包的可见性为 **Public**
> （Packages → tx-node → Package settings → Change visibility），
> 否则节点拉取镜像需要先 `docker login ghcr.io`。

### 手动部署

**1. 准备配置文件**

```bash
mkdir -p /etc/xboard-node
cat > /etc/xboard-node/config.yml <<'EOF'
panel:
  url: "https://你的面板域名"
  token: "面板 server_token"
  node_id: 1            # 面板里这个节点的 ID

kernel:
  type: "singbox"       # 或 xray

# 访问审计（可选，需面板安装 AccessAudit 插件；不配 = 关闭，行为同原版）
audit:
  enabled: true
EOF
```

**2. 启动**

```bash
docker run -d --restart=always --network=host \
  --name tx-node \
  -v /etc/xboard-node/config.yml:/etc/xboard-node/config.yml \
  ghcr.io/paimoncai/tx-node:latest
```

**3. 验证**

```bash
docker logs tx-node | grep "audit reporter enabled"
```

看到这行 = 审计模块已启用并连上面板。之后在面板 `/plugin/access-audit` 配置审计规则，命中记录和节点状态都会出现在管理页。

**4. Docker Compose（等价手动方式）**

```yaml
services:
  tx-node:
    image: ghcr.io/paimoncai/tx-node:latest
    container_name: tx-node
    restart: always
    network_mode: host
    volumes:
      - ./config.yml:/etc/xboard-node/config.yml
```

## 审计说明

| 项 | 行为 |
|---|---|
| 启用方式 | config.yml 加 `audit: enabled: true`（**必须挂配置文件**，纯环境变量模式无法开启审计） |
| 认证 | 复用 `panel.url` / `token` / `node_id`（与原版节点上报同一套 ServerV2 认证，零额外密钥） |
| 数据流 | 连接路由时提取（user_id, 目标域名/IP, 来源 IP）→ 节点本地按面板下发的规则预过滤 → 只上报命中项 |
| 批量 | 攒批 50 条 / 15 秒上报一次；一次 tick 内连续发送直到队列清空（上限 10 批），面板不可达时本地排队（上限 5000 条），恢复后自动补报 |
| 内核范围 | **仅 sing-box**。xray 内核请用 AccessAudit 插件自带的旁路 `audit-agent.py`（tail access log） |
| 目标提取 | sniff 域名 > 代理协议自带域名 > 目标 IP（代理协议自带域名，绝大多数场景不依赖 sniff） |

可调参数（都有默认值）：

```yaml
audit:
  enabled: true
  report_all: false    # true = 上报全部连接（含未命中），面板留存全量访问日志
  batch_max: 50        # 每次上报最多事件数（report_all 默认 200；面板单批上限 500）
  flush_interval: 15   # 上报间隔（秒）
  rules_refresh: 5     # 规则拉取间隔（分钟）
  queue_cap: 5000      # 面板不可达时的本地队列上限（report_all 默认 50000）
```

> `batch_max` 上限为 **500**（面板上报接口 `MAX_EVENTS` 限制），超过会被 422 拒绝整批。

### 负载与容量边界（重要）

**单个节点对面板的压力上界是确定的**，可以按下面的公式估算后再决定是否开启 `report_all`：

```
节点发送速率上限 = batch_max × 10 批 / flush_interval(秒)   [条/秒]
```

默认值下：`50 × 10 / 15 ≈ 33 条/秒`；`report_all` 默认值下：`200 × 10 / 15 ≈ 133 条/秒`。

面板侧每条上报的 SQL 次数（无论批内多少条）为固定开销 + `ceil(N/200)` 次批量插入，**不再随事件数线性放大**。但事件**产生**速率是随在线用户数线性增长的：

| 规模 | 事件产生速率（估算） | report_all 默认配置是否跟得上 |
|---|---|---|
| 1000 在线用户，人均 3 并发，连接均值 300s | ≈ 10 条/秒 | 跟得上 |
| 5000 在线用户，同假设 | ≈ 50 条/秒 | 跟得上（接近上限） |
| 20000 在线用户，同假设 | ≈ 200 条/秒 | **跟不上**，队列会持续堆积并最终丢弃 |

队列满或补报失败溢出时，**事件会被丢弃并记录 `dropped` 计数与限流告警**（每分钟最多一条 WARN），不会静默丢失。

**建议**：
- 只要「命中项上报」（默认模式）时，事件量极小，任何规模都无需调整。
- 需要**全量访问日志**（`report_all`）且在线用户数超过 ~5000 时，请同时调大 `batch_max`（如 500）与 `flush_interval`，或在面板侧接受日志采样；单节点无法保证不丢时，日志仅适合做抽样审计，不适合做计费依据。

## 配套面板插件（AccessAudit）

`panel-plugin/AccessAudit/` 是 Xboard 面板侧的审计插件（v2.1）：接收节点上报、名单匹配、阈值自动封禁、TG 告警、分节点查看、节点级异常通报（上报中断/命中突增）。

- 源码直接在本仓库 `panel-plugin/AccessAudit/`，发布时 CI 自动打包 `AccessAudit-plugin.zip`（Release 附件）
- 安装：zip 上传到 Xboard 后台插件管理（或放 `plugins/` 目录）→ 启用 → 管理页 `/plugin/access-audit`
- xray 内核节点用的旁路 agent 也在插件包内（`node-agent/audit-agent.py`）

详细文档见插件包内 `README.md`。

## 原版用法（不变的部分）

环境变量快捷模式（无审计）：`-e apiHost=... -e apiKey=... -e nodeID=...`；xbctl 多实例管理；自定义路由/出站（`docs-custom-routes.md` / `docs-custom-outbounds.md`）；ACME DNS-01 证书（`docs-dns-providers.md`）——均与上游一致，详见上游 README 和文档。

## License

MPL-2.0（与上游一致）。

> **Disclaimer**: This project is for educational and learning purposes only.
