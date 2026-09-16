<?php

namespace Plugin\AccessAudit\Services;

use App\Models\User;
use App\Services\TelegramService;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Log;
use Plugin\AccessAudit\Models\AuditBanLog;
use Plugin\AccessAudit\Models\AuditReport;
use Plugin\AccessAudit\Models\AuditRule;

/**
 * 审计处理器：记录命中 → 阈值判定 → 自动封禁 → TG 告警
 */
class AuditProcessor
{
    private array $cfg;

    public function __construct()
    {
        $config = app(\App\Services\Plugin\PluginConfigService::class)->getConfig('access_audit');
        $val = fn (string $key, $default) => $config[$key]['value'] ?? $default;
        $this->cfg = [
            'auto_ban' => (int) $val('auto_ban_enabled', 1) === 1,
            'threshold' => max(1, (int) $val('default_threshold', 3)),
            'window' => max(1, (int) $val('default_window_minutes', 60)),
            'chat_id' => trim((string) $val('alert_chat_id', '')),
        ];
    }

    /**
     * 处理单条上报。返回 ['rule_id' => ?int, 'banned' => bool]
     */
    public function process(User $user, string $target, int $nodeId, ?string $sourceIp, RuleMatcher $matcher): array
    {
        $rule = $matcher->match($target);
        if (!$rule) {
            return ['rule_id' => null, 'banned' => false];
        }

        AuditReport::create([
            'user_id' => $user->id,
            'rule_id' => $rule->id,
            'node_id' => $nodeId,
            'target' => mb_substr($target, 0, 255),
            'source_ip' => $sourceIp ? mb_substr($sourceIp, 0, 45) : null,
            'banned' => 0,
            'created_at' => time(),
        ]);

        $banned = false;
        if ($this->cfg['auto_ban'] && !$user->banned) {
            $banned = $this->checkThresholdAndBan($user, $rule, $target, $nodeId);
        }

        return ['rule_id' => $rule->id, 'banned' => $banned];
    }

    private function checkThresholdAndBan(User $user, AuditRule $rule, string $target, int $nodeId): bool
    {
        $threshold = $rule->threshold ?: $this->cfg['threshold'];
        $windowMin = $rule->window_minutes ?: $this->cfg['window'];

        $hits = AuditReport::query()
            ->where('user_id', $user->id)
            ->where('rule_id', $rule->id)
            ->where('created_at', '>=', time() - $windowMin * 60)
            ->count();

        if ($hits < $threshold) {
            return false;
        }

        $this->ban($user, $rule, $hits, $threshold, $windowMin,
            "自动封禁：{$windowMin} 分钟内命中规则「{$rule->name}」{$hits} 次（最近目标：{$target}，节点 #{$nodeId}）");
        return true;
    }

    /**
     * 封禁用户 + 写日志 + TG 告警（自动与手动共用）
     */
    public function ban(User $user, AuditRule $rule, int $hits, int $threshold, int $windowMin, string $reason, int $operatorId = 0): void
    {
        DB::transaction(function () use ($user, $rule, $hits, $threshold, $windowMin, $reason, $operatorId) {
            $user->banned = 1;
            $user->save();

            AuditBanLog::create([
                'user_id' => $user->id,
                'user_email' => $user->email,
                'rule_id' => $rule->id,
                'rule_name' => $rule->name,
                'hit_count' => $hits,
                'threshold' => $threshold,
                'window_minutes' => $windowMin,
                'operator_id' => $operatorId,
                'action' => 'ban',
                'reason' => $reason,
                'created_at' => time(),
            ]);

            AuditReport::query()
                ->where('user_id', $user->id)
                ->where('rule_id', $rule->id)
                ->where('banned', 0)
                ->update(['banned' => 1]);
        });

        $this->notify("🚫 <b>访问审计封禁</b>\n"
            . "用户：{$user->email} (#{$user->id})\n"
            . "规则：{$rule->name}\n"
            . "命中：{$hits} 次 / 阈值 {$threshold} 次（{$windowMin} 分钟窗口）\n"
            . "原因：{$reason}");
    }

    /**
     * 解封（仅手动）
     */
    public function unban(User $user, int $operatorId, string $reason = ''): void
    {
        DB::transaction(function () use ($user, $operatorId, $reason) {
            $user->banned = 0;
            $user->save();

            AuditBanLog::create([
                'user_id' => $user->id,
                'user_email' => $user->email,
                'rule_id' => 0,
                'rule_name' => '',
                'hit_count' => 0,
                'threshold' => 0,
                'window_minutes' => 0,
                'operator_id' => $operatorId,
                'action' => 'unban',
                'reason' => $reason ?: '管理员手动解封',
                'created_at' => time(),
            ]);
        });

        $this->notify("✅ <b>访问审计解封</b>\n用户：{$user->email} (#{$user->id})\n操作：管理员手动解封");
    }

    private function notify(string $text): void
    {
        try {
            $chatId = $this->cfg['chat_id'];
            if ($chatId === '') {
                $admin = User::query()
                    ->where('is_admin', 1)
                    ->whereNotNull('telegram_id')
                    ->where('telegram_id', '>', 0)
                    ->orderBy('id')
                    ->first();
                if (!$admin) {
                    Log::warning('[AccessAudit] 无可用 TG 告警接收人（未配置 chat_id 且无管理员绑定 TG）');
                    return;
                }
                $chatId = (string) $admin->telegram_id;
            }
            app(TelegramService::class)->sendMessage((int) $chatId, $text, 'HTML');
        } catch (\Throwable $e) {
            Log::error('[AccessAudit] TG 告警发送失败: ' . $e->getMessage());
        }
    }
}
