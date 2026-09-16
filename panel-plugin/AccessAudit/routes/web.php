<?php

use Illuminate\Support\Facades\Route;
use Plugin\AccessAudit\Http\Controllers\AdminController;

// 页面本体不挂 admin（页面内置管理员登录表单），数据/操作接口挂 admin
Route::middleware(['web'])->group(function () {
    Route::get('/plugin/access-audit', [AdminController::class, 'page']);
});

Route::middleware(['web', 'admin'])->group(function () {
    Route::get('/plugin/access-audit/stats', [AdminController::class, 'stats']);
    Route::get('/plugin/access-audit/nodes', [AdminController::class, 'nodes']);
    Route::get('/plugin/access-audit/rules', [AdminController::class, 'rules']);
    Route::post('/plugin/access-audit/rules/save', [AdminController::class, 'saveRule']);
    Route::post('/plugin/access-audit/rules/delete', [AdminController::class, 'deleteRule']);

    Route::get('/plugin/access-audit/reports', [AdminController::class, 'reports']);
    Route::get('/plugin/access-audit/logs', [AdminController::class, 'logs']);
    Route::get('/plugin/access-audit/ban-logs', [AdminController::class, 'banLogs']);

    Route::post('/plugin/access-audit/ban', [AdminController::class, 'ban']);
    Route::post('/plugin/access-audit/unban', [AdminController::class, 'unban']);
});
