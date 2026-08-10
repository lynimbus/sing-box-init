//! daemon 引擎 (Zig 版)
//!
//! 子命令与旧 shell 版一一对应: start | stop | restart | status | update_desc | watchdog_loop
//! 看门狗本体 (watchdog_loop) 由 watchdog.zig 的显式状态机实现 (事件驱动), 见该文件。

const std = @import("std");
const context = @import("context.zig");
const watchdog = @import("watchdog.zig");

const Context = context.Context;

// ---------------------------------------------------------------------------
// 子命令
// ---------------------------------------------------------------------------

/// 启动: 拉起常驻看门狗 (看门狗负责拉起/守护 sing-box, 见 watchdog.zig)
/// 看门狗必须以独立进程脱离调用方会话, 否则 su/action 会话结束时会被一起杀掉
pub fn start(ctx: *Context) !void {
    // 前置检查: 二进制与配置必须存在
    if (!ctx.fileExists(ctx.bin)) {
        ctx.log("ERROR", "sing-box 二进制不存在: {s}", .{ctx.bin});
        return error.MissingBinary;
    }
    const main_conf = std.Io.Dir.path.join(ctx.gpa, &.{ ctx.conf_dir, "config.json" }) catch return error.Oom;
    defer ctx.gpa.free(main_conf);
    if (!ctx.fileExists(main_conf) and !ctx.fileExists(ctx.config_file)) {
        ctx.log("ERROR", "配置不存在: {s}", .{ctx.config_file});
        return error.MissingConfig;
    }
    if (ctx.watchdogAlive()) {
        ctx.log("INFO", "watchdog already running, skip", .{});
        ctx.updateDesc();
        return;
    }
    ctx.removeFile(ctx.stopflag);
    ctx.log("INFO", "starting watchdog", .{});
    // 以自身二进制 spawn 一个 watchdog_loop 子进程 (相当于 shell 版
    // `setsid sh daemon.sh watchdog_loop </dev/null >>watchdog.log 2>&1 &`)
    const self_path = std.process.executablePathAlloc(ctx.io, ctx.gpa) catch return error.SelfPath;
    defer ctx.gpa.free(self_path);
    const log_file = ctx.openAppend(ctx.watchdog_log) orelse return error.LogOpen;
    defer std.Io.File.close(log_file, ctx.io);
    const child = std.process.spawn(ctx.io, .{
        .argv = &.{ self_path, "watchdog_loop" },
        .stdin = .ignore,
        .stdout = .{ .file = log_file },
        .stderr = .{ .file = log_file },
    }) catch {
        ctx.log("ERROR", "无法拉起看门狗进程", .{});
        return error.SpawnFailed;
    };
    _ = child; // 看门狗由 stop 显式终止, 这里不 wait (父进程即将退出, 子进程过继给 init)
    // 等看门狗起来 (最多 5 秒); 模块启用时再等 sing-box 真正拉起,
    // 避免状态尚未生效就写描述 (时机竞态, AGENTS.md 约束 8)
    var i: usize = 0;
    while (i < 5 and !ctx.watchdogAlive()) : (i += 1) ctx.sleep(1);
    i = 0;
    while (i < 5 and ctx.watchdogAlive() and !ctx.moduleDisabled() and !ctx.singboxRunning()) : (i += 1) ctx.sleep(1);
    ctx.updateDesc();
}

/// 显式停止 (仅卸载用): 结束 sing-box 和看门狗, 不留常驻监听进程
pub fn stop(ctx: *Context) void {
    // 写停止标记 → 看门狗收到后自行退出 (只 kill 死进程无法真正停止, AGENTS.md 约束 7)
    ctx.writeFileBytes(ctx.stopflag, "");
    stopSingbox(ctx, "explicit stop");
    if (ctx.readPidFile(ctx.wpidfile)) |wpid| {
        if (ctx.pidAlive(wpid)) {
            ctx.log("INFO", "stopping watchdog (pid {d})", .{wpid});
            stopProcess(ctx, wpid, 5);
        }
    }
    ctx.removeFile(ctx.wpidfile);
    ctx.removeFile(ctx.stopflag);
    ctx.log("INFO", "sing-box stopped", .{});
    ctx.updateDesc();
}

/// 重启 = 停止 + 启动 (KernelSU Manager 的 Action 按钮 = 只重启;
/// sing-box 的开关 = 模块本身的启用/禁用开关)
pub fn restart(ctx: *Context) !void {
    stop(ctx);
    try start(ctx);
}

/// 打印运行状态到 stdout (用户可见, 中文)
pub fn status(ctx: *Context) void {
    const st = ctx.statusText();
    defer ctx.gpa.free(st);
    const line = std.fmt.allocPrint(ctx.gpa, "sing-box {s}\n", .{st}) catch return;
    defer ctx.gpa.free(line);
    const out = std.Io.File.stdout();
    var buf: [256]u8 = undefined;
    var w = std.Io.File.Writer.init(out, ctx.io, &buf);
    w.interface.writeAll(line) catch {};
    w.flush() catch {};
}

/// 看门狗入口: 脱离调用方会话后交给状态机 (watchdog.zig)
/// 注意: 这是设计上的常驻进程, 模块禁用时也保持存活 (监听重新启用), 绝不自行退出
pub fn watchdogLoop(ctx: *Context) void {
    // 脱离调用方会话: 否则 su/action 会话结束时看门狗会被一起杀掉 (AGENTS.md 约束 3)
    _ = std.os.linux.setsid();
    var fsm = watchdog.Fsm.init(ctx);
    fsm.run();
}

// ---------------------------------------------------------------------------
// 内部实现 (stop 命令用)
// ---------------------------------------------------------------------------

/// 停掉 sing-box (TERM → 10 秒 → KILL), 并清理 pid 文件
/// 停止后立刻收割僵尸进程: 看门狗用 pid 管理 sing-box, 不 wait 会留下 <defunct>
fn stopSingbox(ctx: *Context, reason: []const u8) void {
    if (ctx.readPidFile(ctx.pidfile)) |pid| {
        if (ctx.pidAlive(pid)) {
            ctx.log("INFO", "stopping sing-box (pid {d}): {s}", .{ pid, reason });
            stopProcess(ctx, pid, 10);
        }
        ctx.reap(pid);
    }
    ctx.removeFile(ctx.pidfile);
}

/// 优雅终止进程: TERM → 轮询等待退出 → 超时 KILL
fn stopProcess(ctx: *Context, pid: std.posix.pid_t, timeout_secs: usize) void {
    std.posix.kill(pid, .TERM) catch {};
    var i: usize = 0;
    while (i < timeout_secs and ctx.pidAlive(pid)) : (i += 1) ctx.sleep(1);
    if (ctx.pidAlive(pid)) {
        ctx.log("WARN", "graceful stop timed out, forcing kill", .{});
        std.posix.kill(pid, .KILL) catch {};
    }
}
