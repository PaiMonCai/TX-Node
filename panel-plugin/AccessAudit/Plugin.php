<?php

namespace Plugin\AccessAudit;

use App\Services\Plugin\AbstractPlugin;
use Illuminate\Console\Scheduling\Schedule;
use Plugin\AccessAudit\Services\AuditProcessor;
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
        // 配置结构变化后清掉进程内缓存，避免长驻进程（queue worker 等）
        // 继续用旧配置
        AuditProcessor::flushConfigCache();
    }

    public function schedule(Schedule $schedule): void
    {
        $days = (int) ($this->getConfigValue('report_retention_days', 30) ?: 30);
        if ($days <= 0) {
            return;
        }

        $schedule->call(function () use ($days) {
            self::purgeBefore('audit_reports', time() - $days * 86400);
        })->name('access-audit:purge')->daily()->onOneServer()->withoutOverlapping(5);

        // 全量访问日志保留期清理（默认 3 天，量大）
        $logDays = (int) ($this->getConfigValue('access_log_retention_days', 3) ?: 3);
        if ($logDays > 0) {
            $schedule->call(function () use ($logDays) {
                self::purgeBefore('audit_access_logs', time() - $logDays * 86400);
            })->name('access-audit:purge-logs')->daily()->onOneServer()->withoutOverlapping(5);
        }

        // 节点级异常监控：上报中断 + 命中突增（每分钟）
        $schedule->call(function () {
            (new NodeHealthMonitor())->run();
        })->name('access-audit:node-health')->everyMinute()->onOneServer()->withoutOverlapping(2);
    }

    /**
     * 分批删除过期数据。
     *
     * 单条大 DELETE 在 report_all 大表（日增可达数百万行）上会产生长事务：
     * 锁表期间阻塞上报写入、撑大 binlog、长时间占用一个连接——
     * 正是连接池耗尽的另一处隐患。改为每批 self::PURGE_BATCH 行 + 批间歇，
     * 单批执行时间可控，批次之间让出连接与锁。
     */
    private const PURGE_BATCH = 2000;

    private static function purgeBefore(string $table, int $cutoff): void
    {
        $deleted = 0;
        do {
            $n = \Illuminate\Support\Facades\DB::table($table)
                ->where('created_at', '<', $cutoff)
                ->limit(self::PURGE_BATCH)
                ->delete();
            $deleted += $n;
            if ($n >= self::PURGE_BATCH) {
                usleep(100000); // 100ms：给并发读写与复制留窗口
            }
        } while ($n >= self::PURGE_BATCH);

        if ($deleted > 0) {
            \Illuminate\Support\Facades\Log::info('[AccessAudit] 清理完成', [
                'table' => $table,
                'deleted' => $deleted,
            ]);
        }
    }
}
