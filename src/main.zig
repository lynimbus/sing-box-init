//! sing-box-init — 让 sing-box 内核像 systemd 服务一样持久运行 (KernelSU/Magisk 模块)
//!
//! Zig 实现 (替代原 shell 版 daemon.sh + whitelist.sh/whitelist.awk):
//!   - 子命令: start | stop | restart | status | update_desc | watchdog_loop
//!   - 模块开关 = sing-box 开关 (Manager 禁用/启用模块)
//!   - 看门狗常驻监听: 崩溃自动重启, 模块重新启用时自动拉起
//!
//! 入口脚本 (service.sh / action.sh / uninstall.sh) 经 daemon.sh 薄包装转发到本二进制。
//! 交叉编译设备版: zig build -Dtarget=aarch64-linux-musl -Doptimize=ReleaseSmall

const std = @import("std");
const context = @import("context.zig");
const daemon = @import("daemon.zig");

pub fn main() !void {
    // 全局分配器 (单线程构建, 无并发访问)
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    // 0.17 std.Io 抽象; 单线程构建下无后台 worker 线程 (见 build.zig)
    // 必须传入当前环境: process.spawn 用 Threaded 自带环境生成子进程环境, 默认是空的
    var threaded = std.Io.Threaded.init(gpa, .{ .environ = context.currentEnviron() orelse std.process.Environ.empty });
    defer threaded.deinit();
    const io = threaded.io();

    // 子命令 = argv[1]; 从 /proc/self/cmdline 解析, 不依赖 std.process.args API
    // (dev 版 std 变动频繁, /proc/self/cmdline 是 Linux/Android 上最稳的入口)
    const cmd = argv1(gpa) orelse {
        usage(gpa, io);
        return error.MissingSubcommand;
    };
    defer gpa.free(cmd);

    // 模块目录: 二进制位于 $MODDIR/bin/ 下, 由自身路径推导 (带 module.prop 兜底)
    const self_path = std.process.executablePathAlloc(io, gpa) catch return error.SelfPath;
    defer gpa.free(self_path);
    const moddir = resolveModdir(gpa, io, self_path);
    defer gpa.free(moddir);

    // 数据目录: 环境变量可重定向 (本机测试用, 避免触碰 /data/adb), 默认 /data/adb/sing-box
    const env_data_dir = context.getEnvVar(gpa, "SING_BOX_DATA_DIR");
    defer if (env_data_dir) |d| gpa.free(d);
    const data_dir = env_data_dir orelse "/data/adb/sing-box";

    var ctx = context.Context.init(gpa, io, moddir, data_dir) catch return error.Init;
    defer ctx.deinit();

    // 子命令分发 (与 shell 版 case 一一对应)
    if (std.mem.eql(u8, cmd, "start")) return daemon.start(&ctx);
    if (std.mem.eql(u8, cmd, "stop")) return daemon.stop(&ctx);
    if (std.mem.eql(u8, cmd, "restart")) return daemon.restart(&ctx);
    if (std.mem.eql(u8, cmd, "status")) return daemon.status(&ctx);
    if (std.mem.eql(u8, cmd, "update_desc")) return ctx.updateDesc();
    if (std.mem.eql(u8, cmd, "watchdog_loop")) return daemon.watchdogLoop(&ctx);

    usage(gpa, io);
    return error.UnknownSubcommand;
}

// ---------------------------------------------------------------------------
// 内部实现
// ---------------------------------------------------------------------------

/// 读取 argv[1] (子命令): /proc/self/cmdline 按 NUL 分隔, 取第 2 段
fn argv1(gpa: std.mem.Allocator) ?[]const u8 {
    var buf: [4096]u8 = undefined;
    const content = context.readProcFile("/proc/self/cmdline", &buf);
    const first_end = std.mem.indexOfScalar(u8, content, 0) orelse return null;
    const rest = content[first_end + 1 ..];
    const second_end = std.mem.indexOfScalar(u8, rest, 0) orelse rest.len;
    if (second_end == 0) return null;
    return gpa.dupe(u8, rest[0..second_end]) catch null;
}

/// 模块目录 = 二进制所在目录的上一级 (bin/ 的父目录);
/// 兜底: 推导出的目录里没有 module.prop 时回退固定路径 (与 shell 版一致)
fn resolveModdir(gpa: std.mem.Allocator, io: std.Io, self_path: []const u8) []const u8 {
    const fallback = "/data/adb/modules/sing-box-init";
    const bin_dir = std.Io.Dir.path.dirname(self_path) orelse return gpa.dupe(u8, fallback) catch fallback;
    const moddir = std.Io.Dir.path.dirname(bin_dir) orelse return gpa.dupe(u8, fallback) catch fallback;
    const prop = std.Io.Dir.path.join(gpa, &.{ moddir, "module.prop" }) catch return gpa.dupe(u8, fallback) catch fallback;
    defer gpa.free(prop);
    if (context.fileExistsAt(io, prop)) return gpa.dupe(u8, moddir) catch moddir;
    return gpa.dupe(u8, fallback) catch fallback;
}

fn usage(gpa: std.mem.Allocator, io: std.Io) void {
    _ = gpa;
    const msg = "usage: sing-box-init {start|stop|restart|status|update_desc|watchdog_loop}\n";
    const out = std.Io.File.stderr();
    var buf: [128]u8 = undefined;
    var w = std.Io.File.Writer.init(out, io, &buf);
    w.interface.writeAll(msg) catch {};
    w.flush() catch {};
}
