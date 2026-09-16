<?php

namespace Plugin\AccessAudit\Http\Controllers;

use App\Http\Controllers\Controller;
use App\Models\User;
use Illuminate\Http\Request;
use Plugin\AccessAudit\Models\AuditAccessLog;
use Plugin\AccessAudit\Models\AuditBanLog;
use Plugin\AccessAudit\Models\AuditNodeStatus;
use Plugin\AccessAudit\Models\AuditReport;
use Plugin\AccessAudit\Models\AuditRule;
use Plugin\AccessAudit\Services\AuditProcessor;

class AdminController extends Controller
{
    public function page()
    {
        return response()->view('AccessAudit::admin');
    }

    public function stats()
    {
        $todayStart = strtotime('today');
        return response()->json(['data' => [
            'rules_total' => AuditRule::query()->count(),
            'rules_enabled' => AuditRule::query()->where('enabled', 1)->count(),
            'reports_total' => AuditReport::query()->count(),
            'reports_today' => AuditReport::query()->where('created_at', '>=', $todayStart)->count(),
            'bans_total' => AuditBanLog::query()->where('action', 'ban')->count(),
            'bans_today' => AuditBanLog::query()->where('action', 'ban')->where('created_at', '>=', $todayStart)->count(),
        ]]);
    }

    // ── 节点维度 ──────────────────────────────────────────────

    /**
     * 节点列表 + 上报健康状态（供分节点查看的选择器）
     */
    public function nodes()
    {
        $statuses = AuditNodeStatus::query()->get()->keyBy('node_id');
        // 节点名称从 v2_server 取
        $servers = \App\Models\Server::query()->whereIn('id', $statuses->keys())->pluck('name', 'id');

        $now = time();
        return response()->json(['data' => $statuses->map(fn ($s) => [
            'node_id' => $s->node_id,
            'node_name' => $servers[$s->node_id] ?? "节点 #{$s->node_id}",
            'last_report_at' => (int) $s->last_report_at,
            'silent_minutes' => $s->last_report_at > 0 ? intdiv($now - (int) $s->last_report_at, 60) : null,
            'last_events_count' => (int) $s->last_events_count,
            'total_reports' => (int) $s->total_reports,
            'total_events' => (int) $s->total_events,
            'total_matched' => (int) $s->total_matched,
            'total_banned' => (int) $s->total_banned,
        ])->values()]);
    }

    // ── 规则管理 ──────────────────────────────────────────────

    public function rules()
    {
        return response()->json([
            'data' => AuditRule::query()->orderByDesc('id')->get(),
        ]);
    }

    public function saveRule(Request $request)
    {
        $data = $request->validate([
            'id' => 'nullable|integer',
            'name' => 'required|string|max:100',
            'match_type' => 'required|in:' . implode(',', AuditRule::TYPES),
            'match_value' => 'required|string',
            'enabled' => 'nullable|boolean',
            'threshold' => 'nullable|integer|min:1',
            'window_minutes' => 'nullable|integer|min:1',
            'remark' => 'nullable|string|max:255',
        ]);

        $data['enabled'] = $request->boolean('enabled', true);
        $data['threshold'] = $data['threshold'] ?? null;
        $data['window_minutes'] = $data['window_minutes'] ?? null;

        if (!empty($data['id'])) {
            $rule = AuditRule::find($data['id']);
            if (!$rule) {
                return response()->json(['error' => ['message' => '规则不存在']], 404);
            }
            $rule->update($data);
        } else {
            $rule = AuditRule::create($data);
        }

        return response()->json(['data' => $rule]);
    }

    public function deleteRule(Request $request)
    {
        $rule = AuditRule::find($request->input('id'));
        if (!$rule) {
            return response()->json(['error' => ['message' => '规则不存在']], 404);
        }
        $rule->delete();
        return response()->json(['data' => true]);
    }

    // ── 审计记录 ──────────────────────────────────────────────

    public function reports(Request $request)
    {
        $query = AuditReport::query()->orderByDesc('id');
        if ($request->filled('user_id')) {
            $query->where('user_id', (int) $request->input('user_id'));
        }
        if ($request->filled('rule_id')) {
            $query->where('rule_id', (int) $request->input('rule_id'));
        }
        if ($request->filled('node_id')) {
            $query->where('node_id', (int) $request->input('node_id'));
        }
        $reports = $query->limit(200)->get();

        $emails = User::query()->whereIn('id', $reports->pluck('user_id')->unique())
            ->pluck('email', 'id');
        $ruleNames = AuditRule::query()->whereIn('id', $reports->pluck('rule_id')->unique())
            ->pluck('name', 'id');

        return response()->json(['data' => $reports->map(fn ($r) => [
            'id' => $r->id,
            'user_id' => $r->user_id,
            'user_email' => $emails[$r->user_id] ?? "?#{$r->user_id}",
            'rule_id' => $r->rule_id,
            'rule_name' => $ruleNames[$r->rule_id] ?? "?#{$r->rule_id}",
            'node_id' => $r->node_id,
            'target' => $r->target,
            'source_ip' => $r->source_ip,
            'banned' => (bool) $r->banned,
            'created_at' => $r->created_at,
        ])]);
    }

    public function banLogs()
    {
        return response()->json([
            'data' => AuditBanLog::query()->orderByDesc('id')->limit(100)->get(),
        ]);
    }

    // ── 全量访问日志 ──────────────────────────────────────────

    /**
     * 访问日志查询（节点/用户/目标关键字/时间范围筛选）
     * GET logs?node_id=&user_id=&keyword=&from=&to=&page=
     */
    public function logs(Request $request)
    {
        $query = AuditAccessLog::query()->orderByDesc('id');
        if ($request->filled('node_id')) {
            $query->where('node_id', (int) $request->input('node_id'));
        }
        if ($request->filled('user_id')) {
            $query->where('user_id', (int) $request->input('user_id'));
        }
        if ($request->filled('keyword')) {
            $kw = trim((string) $request->input('keyword'));
            $query->where('target', 'like', '%' . str_replace(['%', '_'], ['\\%', '\\_'], $kw) . '%');
        }
        if ($request->filled('from')) {
            $query->where('created_at', '>=', (int) $request->input('from'));
        }
        if ($request->filled('to')) {
            $query->where('created_at', '<=', (int) $request->input('to'));
        }
        if ($request->filled('matched')) {
            $query->where('matched', (int) $request->input('matched'));
        }

        $page = max(1, (int) $request->input('page', 1));
        $perPage = 50;
        $total = $query->count();
        $logs = $query->offset(($page - 1) * $perPage)->limit($perPage)->get();

        $emails = User::query()->whereIn('id', $logs->pluck('user_id')->unique())
            ->pluck('email', 'id');
        $nodeNames = \App\Models\Server::query()
            ->whereIn('id', $logs->pluck('node_id')->unique())->pluck('name', 'id');

        return response()->json(['data' => [
            'total' => $total,
            'page' => $page,
            'per_page' => $perPage,
            'pages' => (int) ceil($total / $perPage),
            'list' => $logs->map(fn ($l) => [
                'id' => $l->id,
                'node_id' => $l->node_id,
                'node_name' => $nodeNames[$l->node_id] ?? "节点 #{$l->node_id}",
                'user_id' => $l->user_id,
                'user_email' => $emails[$l->user_id] ?? "?#{$l->user_id}",
                'target' => $l->target,
                'source_ip' => $l->source_ip,
                'matched' => (bool) $l->matched,
                'created_at' => $l->created_at,
            ]),
        ]]);
    }

    // ── 手动封禁 / 解封 ───────────────────────────────────────

    public function ban(Request $request, AuditProcessor $processor)
    {
        $data = $request->validate([
            'email' => 'required|email',
            'reason' => 'nullable|string|max:255',
        ]);
        $user = User::byEmail($data['email'])->first();
        if (!$user) {
            return response()->json(['error' => ['message' => '用户不存在']], 404);
        }
        if ($user->banned) {
            return response()->json(['error' => ['message' => '用户已处于封禁状态']], 422);
        }

        // 手动封禁记到一条虚拟规则（rule_id=0 表示手动）
        $rule = new AuditRule();
        $rule->id = 0;
        $rule->name = '手动封禁';
        $processor->ban($user, $rule, 0, 0, 0,
            $data['reason'] ?: '管理员手动封禁',
            (int) $request->user()->id);

        return response()->json(['data' => ['message' => "已封禁 {$user->email}"]]);
    }

    public function unban(Request $request, AuditProcessor $processor)
    {
        $data = $request->validate([
            'email' => 'required|email',
            'reason' => 'nullable|string|max:255',
        ]);
        $user = User::byEmail($data['email'])->first();
        if (!$user) {
            return response()->json(['error' => ['message' => '用户不存在']], 404);
        }

        $processor->unban($user, (int) $request->user()->id, $data['reason'] ?? '');

        return response()->json(['data' => ['message' => "已解封 {$user->email}"]]);
    }
}
