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

> 首次使用前确认 GitHub Packages 里 `tx-node` 包的可见性为 **Public**
> （Packages → tx-node → Package settings → Change visibility），
> 否则节点拉取镜像需要先 `docker login ghcr.io`。

### 1. 准备配置文件

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

### 2. 启动

```bash
docker run -d --restart=always --network=host \
  --name tx-node \
  -v /etc/xboard-node/config.yml:/etc/xboard-node/config.yml \
  ghcr.io/paimoncai/tx-node:latest
```

### 3. 验证

```bash
docker logs tx-node | grep "audit reporter enabled"
```

看到这行 = 审计模块已启用并连上面板。之后在面板 `/plugin/access-audit` 配置审计规则，命中记录和节点状态都会出现在管理页。

### Docker Compose

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
| 批量 | 攒批 50 条 / 15 秒上报一次；面板不可达时本地排队（上限 5000 条），恢复后自动补报 |
| 内核范围 | **仅 sing-box**。xray 内核请用 AccessAudit 插件自带的旁路 `audit-agent.py`（tail access log） |
| 目标提取 | sniff 域名 > 代理协议自带域名 > 目标 IP（代理协议自带域名，绝大多数场景不依赖 sniff） |

可调参数（都有默认值）：

```yaml
audit:
  enabled: true
  batch_max: 50        # 每次上报最多事件数
  flush_interval: 15   # 上报间隔（秒）
  rules_refresh: 5     # 规则拉取间隔（分钟）
  queue_cap: 5000      # 面板不可达时的本地队列上限
```

## 配套面板插件（AccessAudit）

`panel-plugin/AccessAudit/` 是 Xboard 面板侧的审计插件（v2.0）：接收节点上报、名单匹配、阈值自动封禁、TG 告警、分节点查看、节点级异常通报（上报中断/命中突增）。

- 源码直接在本仓库 `panel-plugin/AccessAudit/`，发布时 CI 自动打包 `AccessAudit-plugin.zip`（Release 附件）
- 安装：zip 上传到 Xboard 后台插件管理（或放 `plugins/` 目录）→ 启用 → 管理页 `/plugin/access-audit`
- xray 内核节点用的旁路 agent 也在插件包内（`node-agent/audit-agent.py`）

详细文档见插件包内 `README.md`。

## 原版用法（不变的部分）

环境变量快捷模式（无审计）：`-e apiHost=... -e apiKey=... -e nodeID=...`；xbctl 多实例管理；自定义路由/出站（`docs-custom-routes.md` / `docs-custom-outbounds.md`）；ACME DNS-01 证书（`docs-dns-providers.md`）——均与上游一致，详见上游 README 和文档。

## License

MPL-2.0（与上游一致）。

> **Disclaimer**: This project is for educational and learning purposes only.
