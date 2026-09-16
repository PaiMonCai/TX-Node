<?php

namespace Plugin\AccessAudit\Http\Controllers;

use App\Http\Controllers\Controller;
use App\Models\User;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\Log;
use Plugin\AccessAudit\Models\AuditNodeStatus;
use Plugin\AccessAudit\Services\AuditProcessor;
use Plugin\AccessAudit\Services\RuleMatcher;

/**
 * 节点上报接口（ServerV2 中间件认证：server_token + node_id / machine token）
 *
 * POST /api/v1/plugin/access-audit/report?token=<server_token>&node_id=<id>
 * Body: {
 *   "events": [
 *     {"user_id": 123, "target": "example.com", "source_ip": "1.2.3.4"},
 *     ...
 *   ]
 * }
 * node_id 从认证属性 node_info 取，不信上报方自报（防伪造）。
 */
class ReportController extends Controller
{
    private const MAX_EVENTS = 500;

    public function report(Request $request, AuditProcessor $processor)
    {
        $node = $request->attributes->get('node_info');
        if (!$node) {
            // handshake 路径允许不带 node_id，但上报必须带
            return response()->json(['error' => ['message' => '缺少 node_id']], 422);
        }
        $nodeId = (int) $node->id;

        $data = $request->validate([
            'events' => 'required|array|min:1|max:' . self::MAX_EVENTS,
            'events.*.user_id' => 'required|integer|min:1',
            'events.*.target' => 'required|string|max:255',
            'events.*.source_ip' => 'nullable|string|max:45',
        ]);

        $matcher = new RuleMatcher();

        // 批量取用户，避免每条一次查询
        $userIds = array_values(array_unique(array_map(
            fn ($e) => (int) $e['user_id'], $data['events']
        )));
        $users = User::query()->whereIn('id', $userIds)->get()->keyBy('id');

        $matched = 0;
        $banned = 0;
        foreach ($data['events'] as $event) {
            $user = $users->get((int) $event['user_id']);
            if (!$user) {
                continue;
            }
            try {
                $result = $processor->process(
                    $user,
                    (string) $event['target'],
                    $nodeId,
                    $event['source_ip'] ?? null,
                    $matcher
                );
                if ($result['rule_id']) {
                    $matched++;
                }
                if ($result['banned']) {
                    $banned++;
                }
            } catch (\Throwable $e) {
                Log::error('[AccessAudit] 上报处理失败: ' . $e->getMessage(), [
                    'user_id' => $event['user_id'],
                    'target' => $event['target'],
                    'node_id' => $nodeId,
                ]);
            }
        }

        // 更新节点健康状态（供节点级异常通报 + 管理页节点状态展示）
        try {
            $status = AuditNodeStatus::query()->firstOrNew(['node_id' => $nodeId]);
            $status->last_report_at = time();
            $status->last_events_count = count($data['events']);
            $status->last_matched_count = $matched;
            $status->last_banned_count = $banned;
            $status->total_reports = (int) $status->total_reports + 1;
            $status->total_events = (int) $status->total_events + count($data['events']);
            $status->total_matched = (int) $status->total_matched + $matched;
            $status->total_banned = (int) $status->total_banned + $banned;
            $status->save();
        } catch (\Throwable $e) {
            Log::warning('[AccessAudit] 节点状态更新失败: ' . $e->getMessage(), ['node_id' => $nodeId]);
        }

        return response()->json(['data' => [
            'node_id' => $nodeId,
            'received' => count($data['events']),
            'matched' => $matched,
            'banned' => $banned,
        ]]);
    }

    /**
     * 下发当前启用的规则给节点（用于本地预过滤，只上报命中项）
     *
     * GET /api/v1/plugin/access-audit/rules?token=<server_token>&node_id=<id>
     */
    public function rules(Request $request)
    {
        $rules = \Plugin\AccessAudit\Models\AuditRule::query()
            ->where('enabled', 1)
            ->get(['id', 'name', 'match_type', 'match_value']);

        return response()->json(['data' => $rules]);
    }
}
