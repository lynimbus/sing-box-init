//! daemon 引擎 (替代 shell 版 daemon.sh)
//!
//! 子命令与 shell 版一一对应: start | stop | restart | status | update_desc | watchdog_loop
//! 行为保真 + 顺带修复 (Q7): 错误信息更明确, 进程操作更可靠 (见各函数注释)

const std = @import("std");
const context = @import("context.zig");
const whitelist = @import("whitelist.zig");

const Context = context.Context;

// ---------------------------------------------------------------------------
// 子命令
// ---------------------------------------------------------------------------

/// 启动: 拉起常驻看门狗 (看门狗负责拉起/守护 sing-box, 见 watchdogLoop)
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

/// 看门狗: 常驻监听, 模块开关状态决定 sing-box 启停, 运行中崩溃自动重启 (对应 Restart=always)
/// 注意: 这是设计上的常驻进程, 模块禁用时也保持存活 (监听重新启用), 绝不自行退出
pub fn watchdogLoop(ctx: *Context) void {
    // 脱离调用方会话: 否则 su/action 会话结束时看门狗会被一起杀掉 (AGENTS.md 约束 3)
    _ = std.os.linux.setsid();
    ctx.writePidFile(ctx.wpidfile, std.os.linux.getpid());
    while (true) {
        // 显式停止标记 (uninstall.sh 触发) → 看门狗退出
        if (ctx.fileExists(ctx.stopflag)) {
            ctx.removeFile(ctx.stopflag);
            break;
        }
        if (ctx.moduleDisabled()) {
            // 模块被禁用/卸载 → 停 sing-box; 看门狗保持存活, 监听模块重新启用
            stopSingbox(ctx, "module disabled");
            ctx.updateDesc();
            // 轮询等待模块重新启用 (或收到显式停止)
            while (true) {
                if (ctx.fileExists(ctx.stopflag)) {
                    ctx.removeFile(ctx.stopflag);
                    return;
                }
                if (!ctx.moduleDisabled()) break;
                ctx.sleep(Context.monitor_interval);
            }
            continue;
        }
        // 模块启用: 确保 sing-box 在运行
        if (!ctx.singboxRunning()) {
            // 上一次的进程可能刚退出还是僵尸, 先收尸再拉起新的
            if (ctx.readPidFile(ctx.pidfile)) |old_pid| ctx.reap(old_pid);
            ensureConfig(ctx);
            startSingbox(ctx);
            ctx.updateDesc();
        }
        // 监控: 每轮检查 sing-box 存活与模块开关状态
        while (ctx.singboxRunning() and !ctx.moduleDisabled() and !ctx.fileExists(ctx.stopflag)) {
            ctx.sleep(Context.monitor_interval);
        }
        if (ctx.fileExists(ctx.stopflag)) {
            ctx.removeFile(ctx.stopflag);
            break;
        }
        if (ctx.moduleDisabled()) continue;
        // 到这里: sing-box 意外退出且模块仍启用 → 崩溃重启
        ctx.log("WARN", "sing-box exited unexpectedly, restarting in {d}s", .{Context.restart_delay});
        ctx.sleep(Context.restart_delay);
    }
    ctx.removeFile(ctx.pidfile);
    ctx.removeFile(ctx.wpidfile);
    ctx.updateDesc();
}

// ---------------------------------------------------------------------------
// 内部实现
// ---------------------------------------------------------------------------

/// 目录模式 (-C): conf.d/config.json 缺主配置时从旧位置自动迁移一份
fn ensureConfig(ctx: *Context) void {
    const main_conf = std.Io.Dir.path.join(ctx.gpa, &.{ ctx.conf_dir, "config.json" }) catch return;
    defer ctx.gpa.free(main_conf);
    if (!ctx.fileExists(main_conf) and ctx.fileExists(ctx.config_file)) {
        ctx.copyFile(ctx.config_file, main_conf);
    }
}

/// 启动 sing-box: 先跑白名单生成 (严格 JSON 注入), 失败回退原始 conf.d
fn startSingbox(ctx: *Context) void {
    const main_conf = std.Io.Dir.path.join(ctx.gpa, &.{ ctx.conf_dir, "config.json" }) catch return;
    defer ctx.gpa.free(main_conf);
    if (ctx.fileExists(main_conf)) {
        // 白名单开关 (仅提示日志): include_package 被改名 .disable → 关闭白名单, 配置原样加载
        if (!ctx.fileExists(ctx.include_package) and ctx.fileExists(ctx.include_package_disable)) {
            ctx.log("INFO", "whitelist disabled (include_package renamed to .disable), config loaded as-is", .{});
        }
        // 生成白名单注入后的配置到 gen_dir, 以 -C 加载; 失败回退原始 conf.d (sing-box 报真实错误)
        if (whitelist.run(ctx)) {
            spawnSingbox(ctx, &.{ "run", "-C", ctx.gen_dir });
        } else {
            ctx.log("WARN", "whitelist generation failed, fallback to raw conf.d", .{});
            spawnSingbox(ctx, &.{ "run", "-C", ctx.conf_dir });
        }
    } else {
        // 旧版单文件模式
        spawnSingbox(ctx, &.{ "run", "-c", ctx.config_file });
    }
}

/// 启动 sing-box 进程: cwd=数据目录 (配置里的 cache_file/dashboard path 是相对路径,
/// 解析基准是 cwd, AGENTS.md 约束 5), stdout/stderr 追加到 sing-box.log; 记录 pid
fn spawnSingbox(ctx: *Context, args: []const []const u8) void {
    const log_file = ctx.openAppend(ctx.singbox_log) orelse {
        ctx.log("ERROR", "无法打开 sing-box 日志: {s}", .{ctx.singbox_log});
        return;
    };
    defer std.Io.File.close(log_file, ctx.io);
    // argv = [sing-box 路径] ++ args
    const argv = std.mem.concat(ctx.gpa, []const u8, &.{ &.{ctx.bin}, args }) catch return;
    defer ctx.gpa.free(argv);
    const child = std.process.spawn(ctx.io, .{
        .argv = argv,
        .cwd = .{ .path = ctx.data_dir },
        .stdin = .ignore,
        .stdout = .{ .file = log_file },
        .stderr = .{ .file = log_file },
    }) catch {
        ctx.log("ERROR", "sing-box 启动失败", .{});
        return;
    };
    const pid = child.id orelse return;
    ctx.writePidFile(ctx.pidfile, pid);
    ctx.log("INFO", "sing-box started (pid {d})", .{pid});
}

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
