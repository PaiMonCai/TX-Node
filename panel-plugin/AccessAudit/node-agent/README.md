# 节点审计 agent 部署指南

在**每台节点服务器**上部署一个 agent，解析 xray access log，命中名单后上报面板。

> ⚠️ **仅适用 xray 内核**。sing-box 内核目前不输出带用户标识的 access log（xboard-node 未开 log output），无法用本方案审计；sing-box 节点请用面板路由规则做纯阻断。

## 1. 节点开启 access log + sniffing

xboard-node 默认把 xray access log 丢弃（`"access": ""`）且不开 sniffing。需要给节点加一份 custom config。

在节点服务器创建 `/usr/local/xboard-node/conf/custom-audit.json`（路径随意，能读到就行）：

```json
{
  "log": {
    "access": "/var/log/xray/access.log",
    "loglevel": "warning"
  }
}
```

> 说明：`log` 在 xboard-node 的 merge 保护名单里，custom config 的 `log.access` 是否生效取决于你部署的 xboard-node 版本。验证方法：改完后 `cat` 生成的运行时配置（通常在 `/usr/local/xboard-node/` 下，或用 `xbctl` 查看），确认 `log.access` 指向了文件。**如果自定义不生效，替代方案：直接给 xray 加一个独立 access log（见第 4 节 FAQ）。**

xboard-node 的 `config.yml` 里对应实例加：

```yaml
kernel:
  custom_config: "/usr/local/xboard-node/conf/custom-audit.json"
```

sniffing：xboard-node 生成的 inbound 默认**没有** sniffing 配置。由于 `inbounds` 在 merge 保护名单里，custom config 无法覆盖。两个办法：

- **办法 A（推荐）**：多数情况下不需要 sniffing——代理协议本身携带目标域名（SNI/HTTP host/vmess 地址），access log 里的 `accepted tcp:域名:端口` 就是真实目标。只有客户端直连 IP 且靠 TLS SNI 才知道域名的场景才需要 sniffing。
- **办法 B**：需要 sniffing 时，fork/补丁 xboard-node 的 `buildInbound` 加 `"sniffing": {"enabled": true, "destOverride": ["http", "tls", "quic"]}`。

改完重启节点：`systemctl restart xboard-node`（或 docker 重启）。

准备日志目录并配置轮转（防撑爆磁盘）：

```bash
mkdir -p /var/log/xray && chmod 755 /var/log/xray

cat > /etc/logrotate.d/xray-audit <<'EOF'
/var/log/xray/access.log {
    daily
    rotate 3
    maxsize 100M
    missingok
    notifempty
    copytruncate
}
EOF
```

`copytruncate` 模式下 agent 的 tailer 已处理（文件大小变小自动重开）。

## 2. 部署 agent

```bash
mkdir -p /opt/xboard-audit-agent
cd /opt/xboard-audit-agent

# 上传 audit-agent.py 和 audit-agent.yml.example
cp audit-agent.yml.example audit-agent.yml
vim audit-agent.yml   # 填 panel_url / api_secret / node_id / log_path

# systemd 托管
cp audit-agent.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now audit-agent
systemctl status audit-agent
journalctl -u audit-agent -f
```

无 PyYAML 也能跑（内置降级解析器），有则更稳：`pip3 install pyyaml` 或 `apt install python3-yaml`。

## 3. 联调验证

1. 面板 `/plugin/access-audit` 添加一条测试规则：`domain_suffix` = `test-illegal.example.com`
2. 节点上看 agent 日志：`规则已刷新: 1 条`
3. 手动往 access log 写一条模拟记录（格式对齐真实日志）：
   ```bash
   echo "2026/09/16 10:00:00 from 1.2.3.4:5678 accepted tcp:test-illegal.example.com:443 [vmess-in >> direct] email: user@6" >> /var/log/xray/access.log
   ```
4. 15 秒内 agent 日志出现 `上报 1 条: matched=1 banned=0`
5. 面板「命中记录」出现该条记录
6. 连续写 3 条 → 用户 6 被封禁（测试用户！），TG 收到告警
7. 测完在面板删除测试规则、解封/删除测试用户、清空命中记录

## 4. FAQ

**Q: access log 里 email 不是 user@ID 格式？**
A: 确认节点跑的是 xboard-node（它把 user_id 编进 email 做流量统计）。其他面板/内核（V2bX 等）email 是真实邮箱，本 agent 的 `XRAY_RE` 只认 `user@<id>`，需要改正则。

**Q: custom config 的 log.access 不生效？**
A: 老版本 xboard-node 可能硬编码丢弃。检查 xboard-node 运行时生成的 xray 配置；实在不行，用 sidecar 方案：iptables/nflog 或 eBPF 抓 SNI（超纲，需要再说）。

**Q: 性能影响？**
A: agent 是单线程逐行正则 + 内存匹配，实测万级规则下单行匹配 <1ms；上报攒批 15s 一次。瓶颈通常在 xray 写日志本身——所以规则只配"需要审计的"，不要追求全量。

**Q: 用户量大时会不会漏？**
A: 队列在内存里，agent 崩溃会丢未上报的命中。封禁是阈值制（窗口内 N 次），丢一两条只会延迟封禁不会漏判。
