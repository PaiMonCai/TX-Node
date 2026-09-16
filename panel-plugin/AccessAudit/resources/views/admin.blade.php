<!DOCTYPE html>
<html lang="zh-CN">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0" />
  <title>访问审计</title>
  <style>
    :root { --blue: #2563eb; --red: #dc2626; --gray: #4b5563; --line: #e5e7eb; --bg: #f7f8fa; }
    * { box-sizing: border-box; }
    body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif; margin: 0; background: var(--bg); color: #1f2937; }
    .wrap { max-width: 1080px; margin: 0 auto; padding: 24px; }
    .card { background: #fff; border: 1px solid var(--line); border-radius: 12px; padding: 20px; margin-bottom: 16px; box-shadow: 0 1px 2px rgba(0,0,0,0.04); }
    input, select, textarea { padding: 9px 12px; border: 1px solid #d1d5db; border-radius: 8px; font-size: 14px; }
    input:focus, select:focus, textarea:focus { outline: 2px solid #bfdbfe; border-color: var(--blue); }
    textarea { width: 100%; min-height: 72px; font-family: inherit; }
    button { padding: 9px 16px; border: 0; border-radius: 8px; background: var(--blue); color: #fff; cursor: pointer; font-size: 14px; }
    button:hover { filter: brightness(1.08); }
    button.danger { background: var(--red); }
    button.secondary { background: var(--gray); }
    button.ghost { background: #e5e7eb; color: #374151; }
    button.small { padding: 4px 10px; font-size: 12px; }
    button:disabled { opacity: .5; cursor: not-allowed; }
    table { width: 100%; border-collapse: collapse; margin-top: 12px; }
    th, td { border-bottom: 1px solid var(--line); padding: 9px 10px; text-align: left; font-size: 13px; }
    th { color: #6b7280; font-weight: 600; white-space: nowrap; }
    .row { display: flex; gap: 10px; align-items: center; flex-wrap: wrap; }
    .hint { font-size: 12px; color: #6b7280; }
    .badge { display: inline-block; padding: 2px 8px; border-radius: 999px; font-size: 12px; white-space: nowrap; }
    .badge.ok { background: #dcfce7; color: #166534; }
    .badge.no { background: #fee2e2; color: #991b1b; }
    .badge.warn { background: #fef9c3; color: #854d0e; }
    .msg { margin-top: 10px; padding: 10px 14px; border-radius: 8px; font-size: 14px; display: none; }
    .msg.ok { display: block; background: #dcfce7; color: #166534; }
    .msg.err { display: block; background: #fee2e2; color: #991b1b; }
    .mono { font-family: ui-monospace, SFMono-Regular, monospace; font-size: 12px; }

    /* 顶栏 */
    .topbar { display: flex; align-items: center; justify-content: space-between; margin-bottom: 20px; }
    .topbar h1 { font-size: 20px; margin: 0; display: flex; align-items: center; gap: 10px; }
    .topbar .user { font-size: 13px; color: #6b7280; }

    /* 统计卡片 */
    .stats { display: grid; grid-template-columns: repeat(auto-fit, minmax(150px, 1fr)); gap: 12px; margin-bottom: 16px; }
    .stat { background: #fff; border: 1px solid var(--line); border-radius: 12px; padding: 14px 16px; }
    .stat .num { font-size: 26px; font-weight: 700; }
    .stat .label { font-size: 12px; color: #6b7280; margin-top: 2px; }
    .stat.red .num { color: var(--red); }
    .stat.blue .num { color: var(--blue); }

    /* Tab */
    .tabs { display: flex; gap: 4px; border-bottom: 2px solid var(--line); margin-bottom: 16px; }
    .tabs button { background: none; color: #6b7280; border-radius: 8px 8px 0 0; padding: 10px 18px; font-size: 14px; border-bottom: 2px solid transparent; margin-bottom: -2px; }
    .tabs button:hover { color: #111; filter: none; }
    .tabs button.active { color: var(--blue); border-bottom-color: var(--blue); font-weight: 600; }
    .pane { display: none; }
    .pane.active { display: block; }

    /* 规则表单 */
    .rule-form { display: grid; grid-template-columns: 1fr 170px 110px 120px 1fr auto; gap: 10px; align-items: center; }
    .rule-form .full { grid-column: 1 / -1; }
    @media (max-width: 860px) { .rule-form { grid-template-columns: 1fr 1fr; } }

    /* 登录 */
    .login-card { max-width: 380px; margin: 12vh auto 0; }
    .login-card h2 { margin-top: 0; }
    .login-card input { width: 100%; margin-bottom: 10px; }
    .login-card button { width: 100%; }

    /* 编辑态行高亮 */
    tr.editing td { background: #eff6ff; }
  </style>
</head>
<body>

<!-- 登录 -->
<div class="wrap" id="loginWrap" style="display:none">
  <div class="card login-card">
    <h2>🛡️ 访问审计</h2>
    <div class="hint" style="margin-bottom:16px">使用 Xboard 管理员账号登录。凭据仅保存在当前页面内存，刷新需重新登录。</div>
    <input id="loginEmail" type="email" placeholder="管理员邮箱" autocomplete="username" />
    <input id="loginPassword" type="password" placeholder="密码" autocomplete="current-password" onkeydown="if(event.key==='Enter')login()" />
    <button onclick="login()">登 录</button>
    <div id="loginMsg" class="msg"></div>
  </div>
</div>

<!-- 工作区 -->
<div class="wrap" id="workspace" style="display:none">
  <div class="topbar">
    <h1>🛡️ 访问审计</h1>
    <div class="row">
      <span class="user" id="userLabel"></span>
      <button class="ghost small" onclick="logout()">退出</button>
    </div>
  </div>

  <div class="stats">
    <div class="stat blue"><div class="num" id="sRules">-</div><div class="label">启用规则 / 总规则</div></div>
    <div class="stat"><div class="num" id="sReports">-</div><div class="label">命中记录（总）</div></div>
    <div class="stat"><div class="num" id="sReportsToday">-</div><div class="label">今日命中</div></div>
    <div class="stat red"><div class="num" id="sBans">-</div><div class="label">封禁（总）</div></div>
    <div class="stat red"><div class="num" id="sBansToday">-</div><div class="label">今日封禁</div></div>
  </div>

  <div class="tabs">
    <button class="active" data-tab="rules" onclick="switchTab('rules')">审计规则</button>
    <button data-tab="reports" onclick="switchTab('reports')">命中记录</button>
    <button data-tab="nodes" onclick="switchTab('nodes')">节点状态</button>
    <button data-tab="bans" onclick="switchTab('bans')">封禁管理</button>
  </div>

  <!-- 规则 -->
  <div class="pane active" id="pane-rules">
    <div class="card">
      <div class="hint" style="margin-bottom:12px">
        匹配类型：<b>domain</b> 精确域名 · <b>domain_suffix</b> 域名后缀（含子域名，如规则 <span class="mono">example.com</span> 命中 <span class="mono">a.example.com</span>）·
        <b>keyword</b> 目标包含关键字 · <b>ip_cidr</b> IP 段（<span class="mono">1.2.3.0/24</span>）。
        匹配值每行一个。阈值/窗口留空用全局默认（插件配置里改）。
      </div>
      <input type="hidden" id="rId" />
      <div class="rule-form">
        <input id="rName" placeholder="规则名称 *" />
        <select id="rType">
          <option value="domain_suffix">domain_suffix</option>
          <option value="domain">domain</option>
          <option value="keyword">keyword</option>
          <option value="ip_cidr">ip_cidr</option>
        </select>
        <input id="rThreshold" type="number" min="1" placeholder="阈值(默认)" />
        <input id="rWindow" type="number" min="1" placeholder="窗口分钟(默认)" />
        <input id="rRemark" placeholder="备注" />
        <button id="rSubmit" onclick="saveRule()">添加规则</button>
        <div class="full"><textarea id="rValue" placeholder="匹配值 *（每行一个）&#10;gambling-example.com&#10;porn-example.org"></textarea></div>
      </div>
      <div class="row" id="rEditBar" style="display:none; margin-top:8px">
        <span class="badge warn">正在编辑规则 #<span id="rEditId"></span></span>
        <button class="ghost small" onclick="resetForm()">取消编辑</button>
      </div>
      <div id="ruleMsg" class="msg"></div>
      <table>
        <thead><tr><th>ID</th><th>名称</th><th>类型</th><th>匹配值</th><th>阈值/窗口</th><th>状态</th><th>备注</th><th>操作</th></tr></thead>
        <tbody id="rulesBody"></tbody>
      </table>
    </div>
  </div>

  <!-- 命中记录 -->
  <div class="pane" id="pane-reports">
    <div class="card">
      <div class="row" style="margin-bottom:4px">
        <input id="fUserId" type="number" placeholder="用户ID" style="width:110px" />
        <select id="fNodeId" style="width:170px"><option value="">全部节点</option></select>
        <input id="fKeyword" placeholder="目标关键字" style="width:160px" />
        <button class="secondary" onclick="loadReports()">查询</button>
        <button class="ghost" onclick="document.getElementById('fUserId').value='';document.getElementById('fNodeId').value='';document.getElementById('fKeyword').value='';loadReports()">重置</button>
      </div>
      <div class="hint">最近 200 条；目标关键字为前端过滤。命中记录按插件配置的保留天数自动清理。</div>
      <table>
        <thead><tr><th>ID</th><th>用户</th><th>规则</th><th>目标</th><th>节点</th><th>来源IP</th><th>触发封禁</th><th>时间</th></tr></thead>
        <tbody id="reportsBody"></tbody>
      </table>
    </div>
  </div>

  <!-- 节点状态 -->
  <div class="pane" id="pane-nodes">
    <div class="card">
      <div class="row" style="margin-bottom:8px">
        <button class="ghost" onclick="loadNodes()">刷新</button>
      </div>
      <div class="hint">节点健康状态来自审计上报通道（tx-node 内嵌 / audit-agent.py 旁路）。"静默时长"为距最后一次上报的时间；超过插件配置的中断阈值会触发 TG 告警。</div>
      <table>
        <thead><tr><th>节点</th><th>最后上报</th><th>静默时长</th><th>上报批次</th><th>上报事件</th><th>命中</th><th>触发封禁</th></tr></thead>
        <tbody id="nodesBody"></tbody>
      </table>
    </div>
  </div>

  <!-- 封禁管理 -->
  <div class="pane" id="pane-bans">
    <div class="card">
      <div class="row" style="margin-bottom:8px">
        <input id="opEmail" type="email" placeholder="用户邮箱" style="min-width:240px" />
        <input id="opReason" placeholder="原因（可选）" style="min-width:200px" />
        <button class="danger" onclick="opUser('ban')">封禁</button>
        <button class="secondary" onclick="opUser('unban')">解封</button>
        <button class="ghost" onclick="loadBanLogs()">刷新</button>
      </div>
      <div id="opMsg" class="msg"></div>
      <table>
        <thead><tr><th>ID</th><th>用户</th><th>动作</th><th>规则</th><th>命中/阈值</th><th>操作人</th><th>原因</th><th>时间</th></tr></thead>
        <tbody id="banLogsBody"></tbody>
      </table>
    </div>
  </div>
</div>

<script>
let token = null;
let rulesCache = [];
let nodesCache = [];

/* ── 基础 ── */
function ts(t) { return t ? new Date(t * 1000).toLocaleString('zh-CN', { hour12: false }) : '-'; }
function esc(s) { const d = document.createElement('div'); d.textContent = s == null ? '' : String(s); return d.innerHTML; }
function showMsg(id, text, ok) {
  const el = document.getElementById(id);
  el.textContent = text;
  el.className = 'msg ' + (ok ? 'ok' : 'err');
  setTimeout(() => { el.className = 'msg'; }, 4000);
}

async function api(url, payload) {
  const opt = { headers: { 'Accept': 'application/json', 'Authorization': token } };
  if (payload !== undefined) {
    opt.method = 'POST';
    opt.headers['Content-Type'] = 'application/json';
    opt.body = JSON.stringify(payload);
  }
  const resp = await fetch(url, opt);
  if (resp.status === 401 || resp.status === 403) {
    logout();
    showMsg('loginMsg', '登录已过期，请重新登录', false);
    throw new Error('unauthorized');
  }
  return resp.json();
}

/* ── 登录 ── */
async function login() {
  const email = document.getElementById('loginEmail').value.trim();
  const password = document.getElementById('loginPassword').value;
  if (!email || !password) { showMsg('loginMsg', '请输入邮箱和密码', false); return; }
  let body;
  try {
    const resp = await fetch('/api/v1/passport/auth/login', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'Accept': 'application/json' },
      body: JSON.stringify({ email, password })
    });
    body = await resp.json();
  } catch (e) { showMsg('loginMsg', '网络错误', false); return; }
  const d = body.data || {};
  if (!d.is_admin || !d.auth_data) {
    showMsg('loginMsg', body.message || '登录失败：仅管理员可访问', false);
    return;
  }
  token = d.auth_data;
  document.getElementById('loginPassword').value = '';
  document.getElementById('userLabel').textContent = email;
  document.getElementById('loginWrap').style.display = 'none';
  document.getElementById('workspace').style.display = '';
  loadStats(); loadRules(); loadNodes().then(() => loadReports()); loadBanLogs();
}

function logout() {
  token = null;
  document.getElementById('workspace').style.display = 'none';
  document.getElementById('loginWrap').style.display = '';
}

function switchTab(name) {
  document.querySelectorAll('.tabs button').forEach(b => b.classList.toggle('active', b.dataset.tab === name));
  document.querySelectorAll('.pane').forEach(p => p.classList.toggle('active', p.id === 'pane-' + name));
  if (name === 'reports') loadReports();
  if (name === 'nodes') loadNodes();
  if (name === 'bans') loadBanLogs();
}

/* ── 节点状态 ── */
async function loadNodes() {
  const r = await api('/plugin/access-audit/nodes');
  nodesCache = r.data || [];
  // 同步刷新命中记录页的节点下拉
  const sel = document.getElementById('fNodeId');
  const cur = sel.value;
  sel.innerHTML = '<option value="">全部节点</option>' + nodesCache.map(n =>
    `<option value="${n.node_id}">${esc(n.node_name)}</option>`).join('');
  sel.value = cur;
  document.getElementById('nodesBody').innerHTML = nodesCache.map(n => {
    const silent = n.silent_minutes;
    const badge = silent === null ? '<span class="badge">未上报</span>'
      : (silent >= 10 ? `<span class="badge no">静默 ${silent} 分钟</span>` : '<span class="badge ok">正常</span>');
    return `<tr>
      <td>${esc(n.node_name)} <span class="mono" style="color:#9ca3af">#${n.node_id}</span></td>
      <td style="white-space:nowrap">${n.last_report_at ? ts(n.last_report_at) : '-'}</td>
      <td>${badge}</td>
      <td>${n.total_reports}</td>
      <td>${n.total_events}</td>
      <td>${n.total_matched}</td>
      <td>${n.total_banned}</td>
    </tr>`;
  }).join('') || '<tr><td colspan="7" class="hint">暂无节点上报数据（配置 tx-node 或 audit-agent 后自动出现）</td></tr>';
}

/* ── 统计 ── */
async function loadStats() {
  const r = await api('/plugin/access-audit/stats');
  const d = r.data || {};
  document.getElementById('sRules').textContent = (d.rules_enabled ?? 0) + ' / ' + (d.rules_total ?? 0);
  document.getElementById('sReports').textContent = d.reports_total ?? 0;
  document.getElementById('sReportsToday').textContent = d.reports_today ?? 0;
  document.getElementById('sBans').textContent = d.bans_total ?? 0;
  document.getElementById('sBansToday').textContent = d.bans_today ?? 0;
}

/* ── 规则 ── */
async function loadRules() {
  const r = await api('/plugin/access-audit/rules');
  rulesCache = r.data || [];
  document.getElementById('rulesBody').innerHTML = rulesCache.map(x => {
    const vals = (x.match_value || '').split('\n').filter(Boolean);
    const shown = vals.slice(0, 2).join(', ');
    return `<tr id="rule-row-${x.id}">
      <td>${x.id}</td>
      <td>${esc(x.name)}</td>
      <td class="mono">${esc(x.match_type)}</td>
      <td class="mono" title="${esc(vals.join('\n'))}">${esc(shown)}${vals.length > 2 ? ` …共${vals.length}条` : ''}</td>
      <td>${x.threshold || '默认'} / ${x.window_minutes ? x.window_minutes + '分' : '默认'}</td>
      <td>${x.enabled ? '<span class="badge ok">启用</span>' : '<span class="badge no">停用</span>'}</td>
      <td>${esc(x.remark || '')}</td>
      <td style="white-space:nowrap">
        <button class="small ghost" onclick="editRule(${x.id})">编辑</button>
        <button class="small secondary" onclick="toggleRule(${x.id})">${x.enabled ? '停用' : '启用'}</button>
        <button class="small danger" onclick="delRule(${x.id})">删除</button>
      </td>
    </tr>`;
  }).join('') || '<tr><td colspan="8" class="hint">暂无规则</td></tr>';
  loadStats();
}

function editRule(id) {
  const x = rulesCache.find(r => r.id === id);
  if (!x) return;
  document.getElementById('rId').value = x.id;
  document.getElementById('rName').value = x.name;
  document.getElementById('rType').value = x.match_type;
  document.getElementById('rValue').value = x.match_value;
  document.getElementById('rThreshold').value = x.threshold || '';
  document.getElementById('rWindow').value = x.window_minutes || '';
  document.getElementById('rRemark').value = x.remark || '';
  document.getElementById('rSubmit').textContent = '保存修改';
  document.getElementById('rEditId').textContent = x.id;
  document.getElementById('rEditBar').style.display = '';
  document.querySelectorAll('#rulesBody tr').forEach(tr => tr.classList.remove('editing'));
  const row = document.getElementById('rule-row-' + id);
  if (row) row.classList.add('editing');
  window.scrollTo({ top: 0, behavior: 'smooth' });
}

function resetForm() {
  document.getElementById('rId').value = '';
  ['rName', 'rValue', 'rThreshold', 'rWindow', 'rRemark'].forEach(i => document.getElementById(i).value = '');
  document.getElementById('rSubmit').textContent = '添加规则';
  document.getElementById('rEditBar').style.display = 'none';
  document.querySelectorAll('#rulesBody tr').forEach(tr => tr.classList.remove('editing'));
}

async function saveRule() {
  const id = document.getElementById('rId').value;
  const payload = {
    name: document.getElementById('rName').value.trim(),
    match_type: document.getElementById('rType').value,
    match_value: document.getElementById('rValue').value.trim(),
    threshold: parseInt(document.getElementById('rThreshold').value) || null,
    window_minutes: parseInt(document.getElementById('rWindow').value) || null,
    remark: document.getElementById('rRemark').value.trim(),
    enabled: true,
  };
  if (id) {
    payload.id = parseInt(id);
    const old = rulesCache.find(r => r.id === payload.id);
    if (old) payload.enabled = !!old.enabled;
  }
  if (!payload.name || !payload.match_value) { showMsg('ruleMsg', '名称和匹配值必填', false); return; }
  const r = await api('/plugin/access-audit/rules/save', payload);
  if (r.error) { showMsg('ruleMsg', r.error.message || '保存失败', false); return; }
  showMsg('ruleMsg', (id ? '已更新' : '已添加') + '规则「' + payload.name + '」', true);
  resetForm();
  loadRules();
}

async function toggleRule(id) {
  const x = rulesCache.find(r => r.id === id);
  if (!x) return;
  await api('/plugin/access-audit/rules/save', {
    id: x.id, name: x.name, match_type: x.match_type, match_value: x.match_value,
    threshold: x.threshold, window_minutes: x.window_minutes, remark: x.remark,
    enabled: x.enabled ? 0 : 1,
  });
  loadRules();
}

async function delRule(id) {
  if (!confirm('确认删除该规则？相关历史记录保留。')) return;
  await api('/plugin/access-audit/rules/delete', { id });
  resetForm();
  loadRules();
}

/* ── 命中记录 ── */
async function loadReports() {
  const uid = document.getElementById('fUserId').value;
  const nid = document.getElementById('fNodeId').value;
  const kw = document.getElementById('fKeyword').value.trim().toLowerCase();
  const params = new URLSearchParams();
  if (uid) params.set('user_id', uid);
  if (nid) params.set('node_id', nid);
  const url = '/plugin/access-audit/reports' + (params.toString() ? '?' + params.toString() : '');
  const r = await api(url);
  let rows = r.data || [];
  if (kw) rows = rows.filter(x => (x.target || '').toLowerCase().includes(kw) || (x.rule_name || '').toLowerCase().includes(kw));
  const nodeName = id => { const n = nodesCache.find(v => v.node_id === id); return n ? n.node_name : '#' + id; };
  document.getElementById('reportsBody').innerHTML = rows.map(x => `
    <tr>
      <td>${x.id}</td>
      <td>${esc(x.user_email)}</td>
      <td>${esc(x.rule_name)}</td>
      <td class="mono">${esc(x.target)}</td>
      <td title="#${x.node_id}">${esc(nodeName(x.node_id))}</td>
      <td class="mono">${esc(x.source_ip || '-')}</td>
      <td>${x.banned ? '<span class="badge no">是</span>' : '<span class="badge ok">否</span>'}</td>
      <td style="white-space:nowrap">${ts(x.created_at)}</td>
    </tr>`).join('') || '<tr><td colspan="8" class="hint">暂无记录</td></tr>';
}

/* ── 封禁管理 ── */
async function loadBanLogs() {
  const r = await api('/plugin/access-audit/ban-logs');
  document.getElementById('banLogsBody').innerHTML = (r.data || []).map(x => `
    <tr>
      <td>${x.id}</td>
      <td>${esc(x.user_email)}</td>
      <td>${x.action === 'ban' ? '<span class="badge no">封禁</span>' : '<span class="badge ok">解封</span>'}</td>
      <td>${esc(x.rule_name || '-')}</td>
      <td>${x.hit_count}/${x.threshold || '-'}</td>
      <td>${x.operator_id ? '#' + x.operator_id : '自动'}</td>
      <td>${esc(x.reason || '')}</td>
      <td style="white-space:nowrap">${ts(x.created_at)}</td>
    </tr>`).join('') || '<tr><td colspan="8" class="hint">暂无日志</td></tr>';
}

async function opUser(action) {
  const email = document.getElementById('opEmail').value.trim();
  if (!email) return;
  const verb = action === 'ban' ? '封禁' : '解封';
  if (!confirm(`确认${verb} ${email}？`)) return;
  const r = await api('/plugin/access-audit/' + action, {
    email,
    reason: document.getElementById('opReason').value.trim()
  });
  if (r.error) { showMsg('opMsg', r.error.message || verb + '失败', false); return; }
  showMsg('opMsg', r.data.message, true);
  document.getElementById('opEmail').value = '';
  document.getElementById('opReason').value = '';
  loadBanLogs(); loadStats();
}

/* 进入页面：直接显示登录卡片 */
document.getElementById('loginWrap').style.display = '';
document.getElementById('loginEmail').focus();
</script>
</body>
</html>
