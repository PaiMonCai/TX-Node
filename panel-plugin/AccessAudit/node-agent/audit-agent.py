#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Xboard AccessAudit 节点审计 agent

工作原理：
1. 从面板拉取审计规则（GET /rules），本地编译匹配器
2. tail xray access log，逐行解析 (user_id, target)
3. 本地匹配命中才入队（全量日志不出节点）
4. 攒批上报面板（POST /report），达到阈值后面板自动封禁 + TG 告警

要求：python3.7+，仅标准库。Xray 内核（sing-box 不适用，见 README）。

用法：
  python3 audit-agent.py /path/to/audit-agent.yml
"""

import json
import os
import re
import signal
import ssl
import sys
import threading
import time
import urllib.request
import urllib.parse
import urllib.error

try:
    import yaml  # type: ignore
    HAS_YAML = True
except ImportError:
    yaml = None  # type: ignore
    HAS_YAML = False


# ── 极简 YAML 子集解析（无 PyYAML 时的降级，只支持本配置文件的扁平结构）──

def load_config(path):
    with open(path, 'r', encoding='utf-8') as f:
        text = f.read()
    if HAS_YAML:
        return yaml.safe_load(text)
    cfg = {}
    for line in text.splitlines():
        line = line.split('#', 1)[0].rstrip()
        if not line.strip() or ':' not in line:
            continue
        k, _, v = line.partition(':')
        v = v.strip().strip('"').strip("'")
        if v.lower() in ('true', 'false'):
            v = v.lower() == 'true'
        elif v.isdigit():
            v = int(v)
        cfg[k.strip()] = v
    return cfg


# ── 规则匹配器（与面板 RuleMatcher.php 语义一致）──

def ip_to_int(ip):
    try:
        parts = ip.split('.')
        if len(parts) != 4:
            return None
        n = 0
        for p in parts:
            x = int(p)
            if not 0 <= x <= 255:
                return None
            n = (n << 8) | x
        return n
    except ValueError:
        return None


def ip_in_cidr(ip, cidr):
    if '/' not in cidr:
        return ip == cidr
    subnet, bits = cidr.split('/', 1)
    ipn, sn = ip_to_int(ip), ip_to_int(subnet)
    if ipn is None or sn is None:
        return False
    bits = int(bits)
    if bits == 0:
        return True
    mask = (0xFFFFFFFF << (32 - bits)) & 0xFFFFFFFF
    return (ipn & mask) == (sn & mask)


class Matcher(object):
    def __init__(self, rules):
        # rules: [{id, name, match_type, match_value}]
        self.compiled = []
        for r in rules:
            values = [v.strip().lower() for v in re.split(r'[\r\n,]+', r.get('match_value') or '') if v.strip()]
            if values:
                self.compiled.append((r, values))

    def is_ip(self, t):
        return ip_to_int(t) is not None or ':' in t

    def match(self, target):
        t = target.strip().lower()
        if not t:
            return None
        is_ip = self.is_ip(t)
        for rule, values in self.compiled:
            mt = rule.get('match_type')
            if is_ip and mt not in ('ip_cidr', 'keyword'):
                continue
            for v in values:
                if mt == 'domain' and t == v:
                    return rule
                if mt == 'domain_suffix' and (t == v or t.endswith('.' + v)):
                    return rule
                if mt == 'keyword' and v in t:
                    return rule
                if mt == 'ip_cidr' and ip_in_cidr(t, v):
                    return rule
        return None


# ── 日志 tail ──

class LogTailer(object):
    """跟踪日志文件，支持轮转（大小变小或 inode 变化时重开）"""

    def __init__(self, path):
        self.path = path
        self.fh = None
        self.inode = None

    def open_at_end(self):
        st = os.stat(self.path)
        self.fh = open(self.path, 'r', encoding='utf-8', errors='replace')
        self.inode = st.st_ino
        self.fh.seek(0, os.SEEK_END)

    def lines(self):
        """生成器：持续产出新行；文件不存在时等待重试"""
        buf = ''
        while True:
            if self.fh is None:
                try:
                    self.open_at_end()
                    buf = ''
                except OSError:
                    time.sleep(3)
                    continue
            try:
                st = os.stat(self.path)
                if st.st_ino != self.inode or st.st_size < self.fh.tell():
                    # 轮转了：重开新文件从头读
                    self.fh.close()
                    self.open_at_end()
                    self.fh.seek(0)
                    buf = ''
            except OSError:
                time.sleep(2)
                continue

            chunk = self.fh.read()
            if not chunk:
                time.sleep(0.5)
                continue
            buf += chunk
            while '\n' in buf:
                line, buf = buf.split('\n', 1)
                yield line


# ── access log 解析 ──

# xray access 典型格式（email 为 user@<id>）：
# 2026/09/16 10:00:00.123 from 1.2.3.4:5678 accepted tcp:example.com:443 [vmess-in >> direct] email: user@123
# 部分版本: ... accepted tcp:example.com:443 [vmess-in -> proxy] email: user@123
XRAY_RE = re.compile(
    r'from\s+(?P<src>[\d.a-fA-F:]+)\s+accepted\s+(?:tcp|udp):(?P<target>[^:\s]+)(?::\d+)?\s+.*?email:\s*user@(?P<uid>\d+)'
)
# 无 from 的退化格式
XRAY_RE2 = re.compile(
    r'accepted\s+(?:tcp|udp):(?P<target>[^:\s]+)(?::\d+)?\s+.*?email:\s*user@(?P<uid>\d+)'
)

PRIVATE_IP_RE = re.compile(r'^(10\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.|127\.|::1$|fc|fd|fe80)')


def parse_line(line):
    m = XRAY_RE.search(line) or XRAY_RE2.search(line)
    if not m:
        return None
    target = m.group('target').strip()
    # 跳过明显内网/保留目标，减少噪音
    if PRIVATE_IP_RE.match(target):
        return None
    src = m.groupdict().get('src') or None
    if src:
        src = src.rsplit(':', 1)[0] if src.count(':') == 1 else src
    return int(m.group('uid')), target, src


# ── 主循环 ──

class Agent(object):
    def __init__(self, cfg):
        self.panel = str(cfg['panel_url']).rstrip('/')
        # server_token（推荐）或旧版 api_secret 均可；认证字段与原版节点上报一致
        self.token = str(cfg.get('server_token') or cfg.get('api_secret') or '')
        self.node_id = int(cfg.get('node_id', 0))
        self.log_path = str(cfg['log_path'])
        self.batch_size = int(cfg.get('batch_size', 50))
        self.flush_interval = float(cfg.get('flush_interval', 15))
        self.rules_ttl = int(cfg.get('rules_refresh', 300))
        self.insecure = bool(cfg.get('insecure_tls', False))
        self.queue = []
        self.lock = threading.Lock()
        self.matcher = Matcher([])
        self.last_rules = 0
        self.stop = False

        self.ctx = ssl.create_default_context()
        if self.insecure:
            self.ctx.check_hostname = False
            self.ctx.verify_mode = ssl.CERT_NONE

    def api(self, method, path, payload=None):
        # ServerV2 认证：token/node_id 放在 query（GET）或 body（POST），
        # 与 xboard-node 原版上报一致
        if method == 'GET':
            sep = '&' if '?' in path else '?'
            url = self.panel + path + sep + 'token=%s&node_id=%d' % (
                urllib.parse.quote(self.token), self.node_id)
            data = None
        else:
            url = self.panel + path
            payload = dict(payload or {})
            payload['token'] = self.token
            payload['node_id'] = self.node_id
            data = json.dumps(payload).encode()
        req = urllib.request.Request(url, data=data, method=method)
        req.add_header('Accept', 'application/json')
        if data:
            req.add_header('Content-Type', 'application/json')
        with urllib.request.urlopen(req, timeout=30, context=self.ctx) as resp:
            return json.loads(resp.read().decode())

    def refresh_rules(self, force=False):
        if not force and time.time() - self.last_rules < self.rules_ttl:
            return
        try:
            body = self.api('GET', '/api/v1/plugin/access-audit/rules')
            rules = body.get('data') or []
            self.matcher = Matcher(rules)
            self.last_rules = time.time()
            log('规则已刷新: %d 条' % len(rules))
        except Exception as e:
            log('规则刷新失败: %s' % e)

    def flusher(self):
        while not self.stop:
            time.sleep(self.flush_interval)
            self.flush()

    def flush(self):
        with self.lock:
            if not self.queue:
                return
            batch, self.queue = self.queue[:self.batch_size], self.queue[self.batch_size:]
        try:
            body = self.api('POST', '/api/v1/plugin/access-audit/report',
                            {'node_id': self.node_id, 'events': batch})
            d = body.get('data') or {}
            log('上报 %d 条: matched=%s banned=%s' % (len(batch), d.get('matched'), d.get('banned')))
        except Exception as e:
            log('上报失败(重新入队): %s' % e)
            with self.lock:
                self.queue = batch + self.queue

    def run(self):
        self.refresh_rules(force=True)
        t = threading.Thread(target=self.flusher, daemon=True)
        t.start()
        log('开始跟踪日志: %s (node_id=%d, 面板=%s)' % (self.log_path, self.node_id, self.panel))

        for line in LogTailer(self.log_path).lines():
            if self.stop:
                break
            self.refresh_rules()
            parsed = parse_line(line)
            if not parsed:
                continue
            uid, target, src = parsed
            if not self.matcher.match(target):
                continue
            ev = {'user_id': uid, 'target': target}
            if src:
                ev['source_ip'] = src
            with self.lock:
                self.queue.append(ev)
            if len(self.queue) >= self.batch_size:
                self.flush()


def log(msg):
    print('[%s] %s' % (time.strftime('%Y-%m-%d %H:%M:%S'), msg), flush=True)


def main():
    if len(sys.argv) != 2:
        print('用法: python3 audit-agent.py /path/to/audit-agent.yml')
        sys.exit(1)
    cfg = load_config(sys.argv[1])
    for k in ('panel_url', 'log_path'):
        if not cfg.get(k):
            print('配置缺少必填项: %s' % k)
            sys.exit(1)
    if not (cfg.get('server_token') or cfg.get('api_secret')):
        print('配置缺少必填项: server_token（面板节点通讯密钥）')
        sys.exit(1)
    if not cfg.get('node_id'):
        print('配置缺少必填项: node_id')
        sys.exit(1)

    agent = Agent(cfg)

    def on_sig(*_):
        agent.stop = True
        agent.flush()
        sys.exit(0)
    signal.signal(signal.SIGTERM, on_sig)
    signal.signal(signal.SIGINT, on_sig)

    agent.run()


if __name__ == '__main__':
    main()
