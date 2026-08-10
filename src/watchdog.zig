//! 看门狗: 显式状态机 + 事件驱动 (方案 B)
//!
//! 替代旧版 "大循环 + 3 秒标志轮询" 的实现:
//!   - inotify:   监听 $MODDIR (disable/remove) 与 $DATA_DIR (.stop / include_package),
//!                文件变化即时唤醒; 其中 include_package 变化 → 白名单热重载 (无需手动重启)
//!   - signalfd:  阻塞 SIGCHLD, 子进程退出即时得知 (不用轮询 waitpid)
//!   - poll 定时器: 按状态精确控制 拉起确认超时 / 强杀期限 / 崩溃退避
//!
//! 设计原则: inotify/signalfd 只是"提前唤醒"; 每次 tick 仍**全量重查标志**作为权威,
//! 事件丢失 (队列溢出/watch 失效) 最多退化为 3 秒低频轮询, 行为不劣于旧版。
//!
//! 状态机核心 (transition) 是纯函数, 无副作用, 可直接单测。

const std = @import("std");
const context = @import("context.zig");
const whitelist = @import("whitelist.zig");

const Context = context.Context;

// ---------------------------------------------------------------------------
// 状态机定义: 状态 + 事件 + 纯转换 (可单测)
// ---------------------------------------------------------------------------

/// 看门狗生命周期状态
pub const State = enum {
    disabled,       // 模块禁用: 等重新启用
    starting,       // 拉起 sing-box 中: 等确认运行
    running,        // sing-box 运行中: 监控
    stopping,       // 停止中: TERM 已发, 等退出 (超时强杀)
    crash_backoff,  // 崩溃/启动失败: 退避后重试
    exiting,        // 收到 .stop: 收尾退出
};

/// 停止原因: 决定 stopping 结束后去哪
pub const StopReason = enum {
    disabled,  // 模块禁用 → 停完进 disabled 等启用
    whitelist, // 白名单热重载 → 停完重新拉起 (starting)
    config,    // 配置文件热重载 → 停完重新拉起 (starting)
};

/// 热重载类型 (inotify 提示)
pub const ReloadKind = enum {
    none,
    whitelist, // include_package 变化
    config,    // conf.d/*.json 变化
};

/// 状态机事件
pub const Event = enum {
    disable_on,        // disable/remove 标记出现
    disable_off,       // 标记消失 (重新启用)
    stop_flag,         // .stop 出现 → 退出
    whitelist_changed, // include_package 变化 → 热重载
    config_changed,    // conf.d/*.json 变化 → 热重载
    singbox_started,   // sing-box 确认运行
    singbox_exited,    // sing-box 进程退出 (waitpid 捕到)
    timeout,           // 当前状态期限到期 (确认超时/退避结束)
};

/// 纯状态转换: (状态, 事件, 停止原因) → 新状态。无副作用, 便于单测。
pub fn transition(state: State, ev: Event, reason: StopReason) State {
    // 内层 switch 统一用 `Event.` 前缀, 避免 0.17 嵌套 switch 裸标签歧义
    // 注意: 必须用 `return switch` 表达式形式 (语句形式嵌套 switch 会报 EnumLiteral 错)
    return switch (state) {
        .disabled => switch (ev) {
            Event.disable_off => .starting, // 重新启用 → 自动拉起
            Event.stop_flag => .exiting,
            else => .disabled,
        },
        .starting => switch (ev) {
            Event.singbox_started => .running,
            Event.singbox_exited, Event.timeout => .crash_backoff, // 拉不起/确认超时 → 退避重试
            Event.disable_on => .stopping,
            Event.stop_flag => .exiting,
            else => .starting,
        },
        .running => switch (ev) {
            Event.singbox_exited => .crash_backoff,
            Event.disable_on => .stopping,
            Event.whitelist_changed, Event.config_changed => .stopping,
            Event.stop_flag => .exiting,
            else => .running,
        },
        .stopping => switch (ev) {
            Event.singbox_exited => switch (reason) {
                .disabled => .disabled,
                .whitelist, .config => .starting,
            },
            Event.disable_on => .disabled,
            Event.stop_flag => .exiting,
            else => .stopping,
        },
        .crash_backoff => switch (ev) {
            Event.timeout => .starting, // 退避结束 → 重新拉起
            Event.disable_on => .disabled,
            Event.stop_flag => .exiting,
            else => .crash_backoff,
        },
        .exiting => .exiting,
    };
}

// ---------------------------------------------------------------------------
// 状态机 (含副作用执行)
// ---------------------------------------------------------------------------

pub const Fsm = struct {
    ctx: *Context,
    state: State,
    stop_reason: StopReason,
    singbox_pid: ?std.posix.pid_t,
    /// 当前状态期限 (单调毫秒, null = 无期限, 靠兜底心跳)
    deadline_ms: ?i64,
    /// 停止阶段是否已强杀 (KILL 后只再等 5 秒, 不再重复发)
    force_killed: bool,
    /// inotify 提示: 热重载请求 (仅 running 状态消费, 其余状态丢弃)
    /// 去抖: 事件后等 reload_debounce_ms 静默期再触发, 连续编辑自动顺延
    reload_dirty: ReloadKind,
    reload_deadline: ?i64,

    /// 热重载去抖: 编辑器保存会产生多个事件, 等静默期后再重启
    const reload_debounce_ms = 800;
    /// 拉起确认超时 / 优雅停止期限 / 崩溃退避 (毫秒)
    const start_confirm_ms = 5000;
    const stop_grace_ms = 10000;
    const crash_backoff_ms = 3000;
    /// 无期限状态下的兜底心跳 (inotify/signalfd 全部失效时仍能发现变化)
    const heartbeat_ms = 3000;

    pub fn init(ctx: *Context) Fsm {
        return .{
            .ctx = ctx,
            .state = if (ctx.moduleDisabled()) .disabled else .starting,
            .stop_reason = .disabled,
            .singbox_pid = null,
            .deadline_ms = null,
            .force_killed = false,
            .reload_dirty = .none,
            .reload_deadline = null,
        };
    }

    /// 看门狗主循环: 事件驱动, 直到 exiting
    pub fn run(self: *Fsm) void {
        self.ctx.writePidFile(self.ctx.wpidfile, std.os.linux.getpid());
        self.apply(self.state); // 初始状态副作用 (disabled 更新描述 / starting 拉起 sing-box)
        // 事件源初始化失败 → 降级为纯轮询 (每 tick 全量重查, 行为同旧版)
        var src: ?EventSource = EventSource.init(self.ctx) catch null;
        defer if (src) |*s| s.deinit();
        while (true) {
            const timeout_ms = self.nextTimeoutMs();
            if (src) |*s| {
                s.wait(self, timeout_ms);
            } else {
                self.ctx.sleepMs(timeout_ms);
            }
            self.tick();
            if (self.state == .exiting) break;
        }
        // 收尾: 清理 pid 文件 + 更新描述
        self.ctx.removeFile(self.ctx.pidfile);
        self.ctx.removeFile(self.ctx.wpidfile);
        self.ctx.updateDesc();
    }

    /// 一轮状态评估: 收割子进程 → 全量重查标志 → 合成事件 → 转换
    fn tick(self: *Fsm) void {
        // 热重载只在 running 状态有意义 (其余状态重新生成配置时会覆盖)
        if (self.state != .running) {
            self.reload_dirty = .none;
            self.reload_deadline = null;
        }
        const singbox_exited = self.collectChildren();

        // 合成事件 (优先级: stop > 模块禁用 > 进程退出 > 白名单 > 启动确认 > 期限)
        var ev: ?Event = null;
        if (self.ctx.fileExists(self.ctx.stopflag)) {
            ev = .stop_flag;
        } else if (self.state != .disabled and self.ctx.moduleDisabled()) {
            ev = .disable_on;
            self.stop_reason = .disabled;
        } else if (self.state == .disabled and !self.ctx.moduleDisabled()) {
            ev = .disable_off;
        } else if (singbox_exited) {
            ev = .singbox_exited;
        } else if (self.state == .stopping and self.singbox_pid == null) {
            ev = .singbox_exited; // 无进程可等 (spawn 前就被停) → 立即转出
        } else if (self.state == .running and self.reloadDue()) {
            const kind = self.reload_dirty;
            self.reload_dirty = .none;
            self.reload_deadline = null;
            switch (kind) {
                .none => unreachable,
                .whitelist => {
                    ev = .whitelist_changed;
                    self.stop_reason = .whitelist;
                },
                .config => {
                    ev = .config_changed;
                    self.stop_reason = .config;
                },
            }
        } else if (self.state == .starting and self.confirmStarted()) {
            ev = .singbox_started;
        } else if (self.deadlineExpired()) {
            if (self.state == .stopping) {
                // 优雅停止超时 → 强杀 (状态不变, 再等 5 秒)
                self.forceKill();
            } else {
                ev = .timeout;
            }
        }

        if (ev) |e| {
            const next = transition(self.state, e, self.stop_reason);
            if (next != self.state) self.apply(next);
        }
    }

    /// 收割所有子进程 (waitpid WNOHANG 循环), 返回是否捕到 sing-box 退出
    /// 顺带处理僵尸回收 (date/ksud 等辅助进程的退出也在此收割)
    fn collectChildren(self: *Fsm) bool {
        var singbox_died = false;
        while (true) {
            var status: i32 = 0;
            const rc = std.os.linux.waitpid(-1, &status, std.os.linux.W.NOHANG);
            if (rc == 0) break; // 没有已退出子进程
            if (std.posix.errno(rc) != .SUCCESS) break; // ECHILD 等
            const pid: std.posix.pid_t = @intCast(rc);
            if (self.singbox_pid == pid) {
                singbox_died = true;
                self.singbox_pid = null;
            }
            // 其他子进程 (date/ksud): 已收割, 忽略
        }
        if (singbox_died) self.ctx.removeFile(self.ctx.pidfile);
        return singbox_died;
    }

    /// sing-box 是否确认运行 (spawn 出的 pid 存活)
    fn confirmStarted(self: *Fsm) bool {
        const pid = self.singbox_pid orelse return false;
        return self.ctx.pidAlive(pid);
    }

    /// 当前状态期限是否已到 (单调时钟)
    fn deadlineExpired(self: *Fsm) bool {
        const dl = self.deadline_ms orelse return false;
        return nowMs(self.ctx) >= dl;
    }

    /// 下次 poll 超时 (毫秒): 有期限状态精确到期限, 其余 3 秒兜底心跳
    /// running 状态下热重载去抖期限优先 (精确到静默期结束, 不靠心跳)
    fn nextTimeoutMs(self: *Fsm) i32 {
        if (self.state == .running) {
            if (self.reload_deadline) |dl| {
                return @intCast(@max(dl - nowMs(self.ctx), 0));
            }
        }
        const dl = self.deadline_ms orelse return heartbeat_ms;
        const remain = dl - nowMs(self.ctx);
        return @intCast(@max(remain, 0));
    }

    /// 热重载去抖是否到期 (running 状态消费)
    fn reloadDue(self: *Fsm) bool {
        if (self.reload_dirty == .none) return false;
        const dl = self.reload_deadline orelse return false;
        return nowMs(self.ctx) >= dl;
    }

    /// 记录热重载请求 (inotify 事件触发): 重置去抖静默期
    fn notifyReload(self: *Fsm, kind: ReloadKind) void {
        self.reload_dirty = kind;
        self.reload_deadline = nowMs(self.ctx) + reload_debounce_ms;
    }

    /// 优雅停止超时 → 强杀 (KILL 后只再等 5 秒)
    fn forceKill(self: *Fsm) void {
        if (self.force_killed) return;
        self.force_killed = true;
        if (self.singbox_pid) |pid| {
            self.ctx.log("WARN", "graceful stop timed out, forcing kill", .{});
            std.posix.kill(pid, .KILL) catch {};
        }
        self.deadline_ms = nowMs(self.ctx) + stop_grace_ms;
    }

    /// 执行进入新状态的副作用
    fn apply(self: *Fsm, next: State) void {
        // 按新状态重算期限
        self.deadline_ms = switch (next) {
            .starting => nowMs(self.ctx) + start_confirm_ms,
            .stopping => nowMs(self.ctx) + stop_grace_ms,
            .crash_backoff => nowMs(self.ctx) + crash_backoff_ms,
            else => null,
        };
        self.force_killed = false;
        switch (next) {
            .starting => self.startSingbox(),
            .stopping => self.stopSingbox(),
            .crash_backoff => self.ctx.log("WARN", "sing-box exited unexpectedly, restarting in 3s", .{}),
            else => {},
        }
        self.state = next;
        self.ctx.updateDesc();
    }

    // ---- 启动 / 停止 sing-box ----

    /// 启动 sing-box: 先跑白名单生成 (严格 JSON 注入), 失败回退原始 conf.d
    fn startSingbox(self: *Fsm) void {
        const ctx = self.ctx;
        const main_conf = std.Io.Dir.path.join(ctx.gpa, &.{ ctx.conf_dir, "config.json" }) catch {
            self.deadline_ms = 0; // 立即重试
            return;
        };
        defer ctx.gpa.free(main_conf);
        // 目录模式 (-C): conf.d/config.json 缺主配置时从旧位置自动迁移一份
        if (!ctx.fileExists(main_conf) and ctx.fileExists(ctx.config_file)) {
            ctx.copyFile(ctx.config_file, main_conf);
        }
        if (ctx.fileExists(main_conf)) {
            // 白名单开关 (仅提示日志): include_package 被改名 .disable → 关闭白名单
            if (!ctx.fileExists(ctx.include_package) and ctx.fileExists(ctx.include_package_disable)) {
                ctx.log("INFO", "whitelist disabled (include_package renamed to .disable), config loaded as-is", .{});
            }
            // 生成白名单注入后的配置到 gen_dir, 以 -C 加载; 失败回退原始 conf.d (sing-box 报真实错误)
            if (whitelist.run(ctx)) {
                self.spawnSingbox(&.{ "run", "-C", ctx.gen_dir });
            } else {
                ctx.log("WARN", "whitelist generation failed, fallback to raw conf.d", .{});
                self.spawnSingbox(&.{ "run", "-C", ctx.conf_dir });
            }
        } else {
            // 旧版单文件模式
            self.spawnSingbox(&.{ "run", "-c", ctx.config_file });
        }
    }

    /// 启动 sing-box 进程: cwd=数据目录 (配置里的相对路径以此解析, AGENTS.md 约束 5),
    /// stdout/stderr 追加到 sing-box.log; 记录 pid。失败时把期限清零 → 下一轮立即重试。
    fn spawnSingbox(self: *Fsm, args: []const []const u8) void {
        const ctx = self.ctx;
        if (!ctx.fileExists(ctx.bin)) {
            ctx.log("ERROR", "sing-box 二进制不存在: {s}", .{ctx.bin});
            self.deadline_ms = 0;
            return;
        }
        const log_file = ctx.openAppend(ctx.singbox_log) orelse {
            ctx.log("ERROR", "无法打开 sing-box 日志: {s}", .{ctx.singbox_log});
            self.deadline_ms = 0;
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
            self.deadline_ms = 0;
            return;
        };
        const pid = child.id orelse {
            self.deadline_ms = 0;
            return;
        };
        self.singbox_pid = pid;
        ctx.writePidFile(ctx.pidfile, pid);
        ctx.log("INFO", "sing-box started (pid {d})", .{pid});
    }

    /// 停止 sing-box (TERM): 进程不存在则立即标记为已退出, 让下一轮 tick 转出
    fn stopSingbox(self: *Fsm) void {
        const ctx = self.ctx;
        if (self.singbox_pid) |pid| {
            if (ctx.pidAlive(pid)) {
                ctx.log("INFO", "stopping sing-box (pid {d})", .{pid});
                std.posix.kill(pid, .TERM) catch {};
            } else {
                self.singbox_pid = null; // 已死 (waitpid 会随后收割)
                ctx.removeFile(ctx.pidfile);
            }
        } else {
            ctx.removeFile(ctx.pidfile);
        }
    }
};

// ---------------------------------------------------------------------------
// 事件源: inotify (文件变化) + signalfd (子进程退出) + poll (定时器)
// ---------------------------------------------------------------------------

const EventSource = struct {
    ctx: *Context,
    inotify_fd: std.posix.fd_t,
    moddir_wd: ?i32,
    datadir_wd: ?i32,
    confdir_wd: ?i32,
    signalfd_fd: std.posix.fd_t,
    /// inotify 事件缓冲 (一次性读完)
    buf: [8192]u8,

    /// 监听的事件: 创建/删除/移动/写入 (disable、.stop、include_package)
    const watch_mask = std.os.linux.IN.CREATE | std.os.linux.IN.DELETE |
        std.os.linux.IN.MOVED_TO | std.os.linux.IN.MOVED_FROM |
        std.os.linux.IN.CLOSE_WRITE | std.os.linux.IN.MODIFY;

    fn init(ctx: *Context) !EventSource {
        // --- inotify: 监听模块目录与数据目录 ---
        const inotify_rc = std.os.linux.inotify_init1(std.os.linux.IN.CLOEXEC | std.os.linux.IN.NONBLOCK);
        if (std.posix.errno(inotify_rc) != .SUCCESS) return error.InotifyInit;
        const inotify_fd: std.posix.fd_t = @intCast(inotify_rc);
        errdefer _ = std.os.linux.close(inotify_fd);
        const moddir_wd = addWatch(inotify_fd, ctx.moddir);
        const datadir_wd = addWatch(inotify_fd, ctx.data_dir);
        // 用户配置目录 conf.d/ (注意: 绝不监听生成目录 conf.d.generated/, 那是自己写的, 会无限重启)
        const confdir_wd = addWatch(inotify_fd, ctx.conf_dir);
        // --- signalfd: 阻塞 SIGCHLD, 子进程退出即时唤醒 ---
        var set = std.posix.sigemptyset();
        std.posix.sigaddset(&set, .CHLD);
        std.posix.sigprocmask(std.posix.SIG.BLOCK, &set, null);
        const signalfd_fd = try std.posix.signalfd(
            -1,
            &set,
            std.os.linux.SFD.CLOEXEC | std.os.linux.SFD.NONBLOCK,
        );
        errdefer _ = std.os.linux.close(signalfd_fd);
        return .{
            .ctx = ctx,
            .inotify_fd = inotify_fd,
            .moddir_wd = moddir_wd,
            .datadir_wd = datadir_wd,
            .confdir_wd = confdir_wd,
            .signalfd_fd = signalfd_fd,
            .buf = undefined,
        };
    }

    fn deinit(self: *EventSource) void {
        _ = std.os.linux.close(self.inotify_fd);
        _ = std.os.linux.close(self.signalfd_fd);
    }

    /// 等待事件或超时; 醒来后读取 inotify/signalfd 事件 (仅白名单变化是 inotify 独有信息,
    /// disable/.stop 等标志由 tick 全量重查, 这里只负责提前唤醒)
    fn wait(self: *EventSource, fsm: *Fsm, timeout_ms: i32) void {
        var fds = [_]std.posix.pollfd{
            .{ .fd = self.inotify_fd, .events = @intCast(std.posix.POLL.IN), .revents = 0 },
            .{ .fd = self.signalfd_fd, .events = @intCast(std.posix.POLL.IN), .revents = 0 },
        };
        _ = std.posix.poll(&fds, timeout_ms) catch {};
        // 读 inotify 事件 (非阻塞, 读到 EAGAIN 为止)
        while (true) {
            const n = std.posix.read(self.inotify_fd, &self.buf) catch break;
            if (n == 0) break;
            self.parseEvents(fsm, self.buf[0..n]);
        }
        // 读 signalfd 清空信号 (收割在 tick 里做)
        // ⚠️ 缓冲区必须 ≥ sizeof(signalfd_siginfo) (128B), 否则 read 返回 EINVAL
        var sink: [@sizeOf(std.os.linux.signalfd_siginfo)]u8 = undefined;
        while (true) {
            const n = std.posix.read(self.signalfd_fd, &sink) catch break;
            if (n == 0) break;
        }
    }

    /// 解析 inotify 事件; 只关心 include_package 的变化 (热重载提示)
    fn parseEvents(self: *EventSource, fsm: *Fsm, data: []const u8) void {
        var off: usize = 0;
        const ev_size = @sizeOf(std.os.linux.inotify_event);
        while (off + ev_size <= data.len) {
            const ev: *const std.os.linux.inotify_event = @ptrCast(@alignCast(data.ptr + off));
            const mask = ev.mask;
            // 队列溢出: 事件可能丢失 → tick 的全量重查会兜底, 无需处理
            if (mask & std.os.linux.IN.Q_OVERFLOW == 0) {
                const write_or_move = mask & (std.os.linux.IN.CLOSE_WRITE | std.os.linux.IN.MOVED_TO) != 0;
                if (ev.wd == (self.datadir_wd orelse -1) and write_or_move) {
                    // 白名单变化 (mv 走 MOVED_TO, 编辑器保存走 CLOSE_WRITE)
                    if (nameIs(ev, data, off, "include_package")) {
                        fsm.notifyReload(.whitelist);
                    }
                } else if (ev.wd == (self.confdir_wd orelse -1) and write_or_move) {
                    // 用户配置目录变化 (任意 .json, 如 config.json) → 热重载
                    if (nameEndsWithJson(ev, data, off)) {
                        fsm.notifyReload(.config);
                    }
                }
                // moddir 上的 disable/remove 变化不需要处理: tick 会全量重查
            }
            off += ev_size + ev.len;
        }
    }

    /// inotify 事件的 name 字段是否等于给定文件名

    /// inotify 事件的 name 是否以 .json 结尾
    fn nameEndsWithJson(ev: *const std.os.linux.inotify_event, data: []const u8, ev_off: usize) bool {
        const name = eventName(ev, data, ev_off);
        if (name.len < 5) return false;
        return std.mem.eql(u8, name[name.len - 5 ..], ".json");
    }

    /// inotify 事件的 name 字段是否等于给定文件名
    /// ⚠️ 实测本内核把 len 恒报为 16 (name 区域圆整到 16 字节), 必须用 NUL 截断解析
    fn nameIs(ev: *const std.os.linux.inotify_event, data: []const u8, ev_off: usize, want: []const u8) bool {
        return std.mem.eql(u8, eventName(ev, data, ev_off), want);
    }

    /// 提取事件 name (到第一个 NUL 为止)
    fn eventName(ev: *const std.os.linux.inotify_event, data: []const u8, ev_off: usize) []const u8 {
        const start = ev_off + @sizeOf(std.os.linux.inotify_event);
        const end = @min(start + ev.len, data.len);
        if (start >= end) return "";
        const region = data[start..end];
        if (std.mem.indexOfScalar(u8, region, 0)) |nul| return region[0..nul];
        return region;
    }
};

/// inotify 添加目录 watch; 失败返回 null (兜底轮询接管, 不致命)
fn addWatch(inotify_fd: std.posix.fd_t, dir_path: []const u8) ?i32 {
    const path_z = std.heap.page_allocator.allocSentinel(u8, dir_path.len, 0) catch return null;
    @memcpy(path_z[0..dir_path.len], dir_path);
    defer std.heap.page_allocator.free(path_z);
    const rc = std.os.linux.inotify_add_watch(
        inotify_fd,
        path_z.ptr,
        EventSource.watch_mask,
    );
    if (std.posix.errno(rc) != .SUCCESS) return null;
    return @intCast(rc);
}

/// 单调时钟 (毫秒): 与 Io.sleep 使用同一时钟, 期限计算一致
fn nowMs(ctx: *Context) i64 {
    return @intCast(@divTrunc(std.Io.Clock.now(.boot, ctx.io).nanoseconds, std.time.ns_per_ms));
}
