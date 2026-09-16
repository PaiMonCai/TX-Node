<?php

namespace Plugin\AccessAudit;

use App\Services\Plugin\AbstractPlugin;
use Illuminate\Console\Scheduling\Schedule;
use Plugin\AccessAudit\Models\AuditReport;
use Plugin\AccessAudit\Services\NodeHealthMonitor;

class Plugin extends AbstractPlugin
{
    public function boot(): void
    {
        // 本插件以接收节点上报 + 管理员手动操作为主，暂不注册核心 hook
    }

    public function install(): void
    {
        // 迁移由 PluginManager 自动执行
    }

    public function cleanup(): void
    {
        // 预留
    }

    public function update(string $oldVersion, string $newVersion): void
    {
        // 预留
    }

    public function schedule(Schedule $schedule): void
    {
        $days = (int) ($this->getConfigValue('report_retention_days', 30) ?: 30);
        if ($days <= 0) {
            return;
        }

        $schedule->call(function () use ($days) {
            AuditReport::query()
                ->where('created_at', '<', time() - $days * 86400)
                ->delete();
        })->name('access-audit:purge')->daily()->onOneServer()->withoutOverlapping(5);

        // 节点级异常监控：上报中断 + 命中突增（每分钟）
        $schedule->call(function () {
            (new NodeHealthMonitor())->run();
        })->name('access-audit:node-health')->everyMinute()->onOneServer()->withoutOverlapping(2);
    }
}
