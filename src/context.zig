//! 运行上下文: 集中管理设备路径、IO 句柄与日志
//!
//! 本模块是 0.17 版 std 全面 Io 化 (std.Io) 后的收拢点:
//! 所有子命令共享一个 Context, 字段是解析好的绝对路径, 方法封装底层 IO,
//! 业务代码 (daemon.zig / whitelist.zig) 只跟 Context 打交道, 不直接碰 syscall。
//! 也提供几个不依赖 Context 的自由函数 (procfs 读取等), 供 main 在初始化前使用。

const std = @import("std");

// ---------------------------------------------------------------------------
// 自由函数 (不依赖 Context, 供 main 初始化阶段使用)
// ---------------------------------------------------------------------------

/// 读 procfs 文件到固定缓冲区。
/// 注意: procfs (/proc/...) 的 stat size 恒为 0, 不能走先 stat 再分配的老路,
/// 这里用 read(2) 循环读到缓冲区满或 EOF。
pub fn readProcFile(path: []const u8, buf: []u8) []u8 {
    const fd = std.posix.openat(std.posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY }, 0) catch return buf[0..0];
    defer _ = std.os.linux.close(fd);
    var n: usize = 0;
    while (n < buf.len) {
        const got = std.posix.read(fd, buf[n..]) catch break;
        if (got == 0) break;
        n += got;
    }
    return buf[0..n];
}

/// 文件是否存在 (绝对路径)
pub fn fileExistsAt(io: std.Io, path: []const u8) bool {
    const dir = std.Io.Dir.cwd();
    _ = dir.access(io, path, .{}) catch return false;
    return true;
}

/// 读环境变量 (不存在 → null); 从 /proc/self/environ 解析 (NUL 分隔 KEY=VALUE)
/// 不依赖 std.process args/env API (dev 版变动频繁, /proc 是 Linux/Android 上最稳的入口)
pub fn getEnvVar(gpa: std.mem.Allocator, key: []const u8) ?[]const u8 {
    var buf: [65536]u8 = undefined;
    const content = readProcFile("/proc/self/environ", &buf);
    var it = std.mem.splitScalar(u8, content, 0);
    while (it.next()) |entry| {
        if (std.mem.indexOfScalar(u8, entry, '=')) |eq| {
            if (std.mem.eql(u8, entry[0..eq], key)) {
                return gpa.dupe(u8, entry[eq + 1 ..]) catch null;
            }
        }
    }
    return null;
}

/// 当前进程环境 (从 /proc/self/environ 读取)
/// 0.17 的 process.spawn 用 Io.Threaded 自带的环境 (默认空) 生成子进程环境,
/// 必须显式传入进程环境, 否则子进程拿不到 PATH/自定义变量 (如 SING_BOX_DATA_DIR)。
/// 返回的 Environ 持有进程生命周期, 不释放 (与真正的 environ 一样是常驻数据)。
pub fn currentEnviron() ?std.process.Environ {
    var buf: [65536]u8 = undefined;
    const content = readProcFile("/proc/self/environ", &buf);
    // 复制一份常驻内存 (读入的缓冲区是栈上的)
    // 用 page_allocator: 环境数据进程生命周期常驻, 不参与 DebugAllocator 泄漏检测
    const env_copy = std.heap.page_allocator.dupe(u8, content) catch return null;
    // 数一下有多少个 KEY=VALUE 段
    var count: usize = 0;
    var it = std.mem.splitScalar(u8, env_copy, 0);
    while (it.next()) |entry| {
        if (entry.len > 0) count += 1;
    }
    // 指针数组 (null 结尾), 各段指向 env_copy 内 NUL 分隔的原始字节
    const ptrs = std.heap.page_allocator.allocSentinel(?[*:0]const u8, count, null) catch return null;
    var i: usize = 0;
    it = std.mem.splitScalar(u8, env_copy, 0);
    while (it.next()) |entry| {
        if (entry.len == 0) continue;
        // 段末尾的原始 NUL 保留在 env_copy 中, 所以可以直接当 C 字符串用
        ptrs[i] = @ptrCast(entry.ptr);
        i += 1;
    }
    return .{ .block = .{ .slice = ptrs } };
}

// ---------------------------------------------------------------------------
// Context
// ---------------------------------------------------------------------------

pub const Context = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    moddir: []const u8,   // 模块目录 (含 module.prop)
    data_dir: []const u8, // 数据目录 (默认 /data/adb/sing-box)

    // --- 派生路径 (init 时一次性拼接, 全部绝对路径) ---
    bin: []const u8,                 // $MODDIR/bin/sing-box          (内核二进制)
    config_file: []const u8,         // $DATA_DIR/config.json         (旧版单文件配置)
    conf_dir: []const u8,            // $DATA_DIR/conf.d              (配置目录, -C 模式)
    gen_dir: []const u8,             // $DATA_DIR/conf.d.generated    (白名单注入后的生成目录)
    log_dir: []const u8,             // $DATA_DIR/logs
    watchdog_log: []const u8,        // $DATA_DIR/logs/watchdog.log
    singbox_log: []const u8,         // $DATA_DIR/logs/sing-box.log
    pidfile: []const u8,             // $DATA_DIR/sing-box.pid
    wpidfile: []const u8,            // $DATA_DIR/sing-box-watchdog.pid
    stopflag: []const u8,            // $DATA_DIR/.stop                (显式停止标记, 仅卸载用)
    module_prop: []const u8,         // $MODDIR/module.prop
    disable_flag: []const u8,        // $MODDIR/disable                (Manager 禁用标记)
    remove_flag: []const u8,         // $MODDIR/remove                 (待卸载标记)
    include_package: []const u8,     // $DATA_DIR/include_package      (应用白名单)
    include_package_disable: []const u8, // $DATA_DIR/include_package.disable (白名单关闭开关)

    /// 看门狗轮询间隔 (秒): 每轮检查 sing-box 存活与模块开关状态
    pub const monitor_interval: i64 = 3;
    /// 崩溃重启延迟 (秒), 对应 systemd Restart=always 的保险丝
    pub const restart_delay: i64 = 3;

    pub fn init(gpa: std.mem.Allocator, io: std.Io, moddir: []const u8, data_dir: []const u8) !Context {
        var ctx = Context{
            .gpa = gpa,
            .io = io,
            .moddir = try gpa.dupe(u8, moddir),
            .data_dir = try gpa.dupe(u8, data_dir),
            .bin = undefined,
            .config_file = undefined,
            .conf_dir = undefined,
            .gen_dir = undefined,
            .log_dir = undefined,
            .watchdog_log = undefined,
            .singbox_log = undefined,
            .pidfile = undefined,
            .wpidfile = undefined,
            .stopflag = undefined,
            .module_prop = undefined,
            .disable_flag = undefined,
            .remove_flag = undefined,
            .include_package = undefined,
            .include_package_disable = undefined,
        };
        errdefer ctx.deinit();
        ctx.bin = try join(gpa, &.{ ctx.moddir, "bin", "sing-box" });
        ctx.config_file = try join(gpa, &.{ ctx.data_dir, "config.json" });
        ctx.conf_dir = try join(gpa, &.{ ctx.data_dir, "conf.d" });
        ctx.gen_dir = try join(gpa, &.{ ctx.data_dir, "conf.d.generated" });
        ctx.log_dir = try join(gpa, &.{ ctx.data_dir, "logs" });
        ctx.watchdog_log = try join(gpa, &.{ ctx.log_dir, "watchdog.log" });
        ctx.singbox_log = try join(gpa, &.{ ctx.log_dir, "sing-box.log" });
        ctx.pidfile = try join(gpa, &.{ ctx.data_dir, "sing-box.pid" });
        ctx.wpidfile = try join(gpa, &.{ ctx.data_dir, "sing-box-watchdog.pid" });
        ctx.stopflag = try join(gpa, &.{ ctx.data_dir, ".stop" });
        ctx.module_prop = try join(gpa, &.{ ctx.moddir, "module.prop" });
        ctx.disable_flag = try join(gpa, &.{ ctx.moddir, "disable" });
        ctx.remove_flag = try join(gpa, &.{ ctx.moddir, "remove" });
        ctx.include_package = try join(gpa, &.{ ctx.data_dir, "include_package" });
        ctx.include_package_disable = try join(gpa, &.{ ctx.data_dir, "include_package.disable" });
        // 对应 shell 版顶部的 mkdir -p (数据/日志/配置/生成目录)
        ctx.mkdirs(ctx.data_dir);
        ctx.mkdirs(ctx.log_dir);
        ctx.mkdirs(ctx.conf_dir);
        ctx.mkdirs(ctx.gen_dir);
        return ctx;
    }

    pub fn deinit(self: *Context) void {
        const paths = [_][]const u8{
            self.bin, self.config_file, self.conf_dir, self.gen_dir,
            self.log_dir, self.watchdog_log, self.singbox_log,
            self.pidfile, self.wpidfile, self.stopflag,
            self.module_prop, self.disable_flag, self.remove_flag,
            self.include_package, self.include_package_disable,
            self.moddir, self.data_dir,
        };
        for (paths) |p| self.gpa.free(p);
    }

    // ---- 文件操作 ----

    /// 追加一行日志 (对应 shell 版 log()): `时间 [级别] 内容`
    pub fn log(self: *Context, comptime level: []const u8, comptime fmt: []const u8, args: anytype) void {
        const ts = self.localTimestamp() catch return;
        defer self.gpa.free(ts);
        const body = std.fmt.allocPrint(self.gpa, fmt, args) catch return;
        defer self.gpa.free(body);
        const line = std.fmt.allocPrint(self.gpa, "{s} [{s}] {s}\n", .{ ts, level, body }) catch return;
        defer self.gpa.free(line);
        self.appendFile(self.watchdog_log, line);
    }

    /// 本地时间戳, 与 shell 版 `date '+%F %T'` 输出一致 (设备必有 toybox date)
    fn localTimestamp(self: *Context) ![]const u8 {
        if (self.runCapture(&.{ "date", "+%F %T" })) |out| {
            defer self.gpa.free(out);
            const trimmed = std.mem.trim(u8, out, " \n\r");
            if (trimmed.len > 0) return self.gpa.dupe(u8, trimmed);
        }
        // 退回: 自 1970 起的 Unix 秒数 (date 缺失的理论场景)
        const ts = std.Io.Clock.now(.real, self.io);
        return std.fmt.allocPrint(self.gpa, "{d}", .{@divTrunc(ts.nanoseconds, std.time.ns_per_s)});
    }

    /// 运行命令并捕获 stdout (失败返回 null); 只用于 date 这类短输出命令
    fn runCapture(self: *Context, argv: []const []const u8) ?[]const u8 {
        const res = std.process.run(self.gpa, self.io, .{ .argv = argv }) catch return null;
        defer self.gpa.free(res.stderr);
        return res.stdout; // 调用方负责 free
    }

    /// 以 O_APPEND 追加写文件 (对应 shell 的 `>>`)
    pub fn appendFile(self: *Context, path: []const u8, bytes: []const u8) void {
        _ = self;
        const fd = std.posix.openat(std.posix.AT.FDCWD, path, .{
            .ACCMODE = .WRONLY,
            .CREAT = true,
            .APPEND = true,
        }, 0o644) catch return;
        defer _ = std.os.linux.close(fd);
        _ = std.os.linux.write(fd, bytes.ptr, bytes.len);
    }

    /// 打开日志文件 (O_APPEND 追加模式); 失败返回 null
    /// 返回的 File 可交给 spawn 的 stdout/stderr, 子进程天然追加写
    pub fn openAppend(self: *Context, path: []const u8) ?std.Io.File {
        _ = self;
        const fd = std.posix.openat(std.posix.AT.FDCWD, path, .{
            .ACCMODE = .WRONLY,
            .CREAT = true,
            .APPEND = true,
        }, 0o644) catch return null;
        return std.Io.File{ .handle = fd, .flags = .{ .nonblocking = false } };
    }

    /// 读取整个文件 (先 stat 拿大小再读); 失败返回 error
    pub fn readFileAlloc(self: *Context, path: []const u8) ![]u8 {
        const dir = std.Io.Dir.cwd();
        const stat = try dir.statFile(self.io, path, .{});
        const buf = try self.gpa.alloc(u8, @intCast(stat.size));
        errdefer self.gpa.free(buf);
        return dir.readFile(self.io, path, buf);
    }

    /// 文件是否存在
    pub fn fileExists(self: *Context, path: []const u8) bool {
        return fileExistsAt(self.io, path);
    }

    /// 目录是否存在
    pub fn dirExists(self: *Context, path: []const u8) bool {
        var dir = std.Io.Dir.openDirAbsolute(self.io, path, .{}) catch return false;
        dir.close(self.io);
        return true;
    }

    /// 删除文件 (不存在时静默)
    pub fn removeFile(self: *Context, path: []const u8) void {
        std.Io.Dir.deleteFileAbsolute(self.io, path) catch {};
    }

    /// 写文件 (创建或整体覆盖, 对应 shell 的 `>`)
    pub fn writeFileBytes(self: *Context, path: []const u8, data: []const u8) void {
        std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = path, .data = data }) catch {};
    }

    /// 复制文件 (整体覆盖目标)
    pub fn copyFile(self: *Context, src: []const u8, dst: []const u8) void {
        const data = self.readFileAlloc(src) catch return;
        defer self.gpa.free(data);
        self.writeFileBytes(dst, data);
    }

    /// 递归创建目录 (对应 shell 的 mkdir -p)
    pub fn mkdirs(self: *Context, path: []const u8) void {
        std.Io.Dir.cwd().createDirPath(self.io, path) catch {};
    }

    // ---- 进程 / 状态 ----

    /// 进程是否真的存活: /proc/PID/cmdline 含 "sing-box" (防止陈旧 pid 误判, AGENTS.md 约束 4)
    pub fn pidAlive(self: *Context, pid: std.posix.pid_t) bool {
        _ = self;
        var buf: [64]u8 = undefined;
        const proc_path = std.fmt.bufPrint(&buf, "/proc/{d}/cmdline", .{pid}) catch return false;
        var content_buf: [2048]u8 = undefined;
        const content = readProcFile(proc_path, &content_buf);
        return std.mem.indexOf(u8, content, "sing-box") != null;
    }

    /// 读 pid 文件 (不存在/非法 → null)
    pub fn readPidFile(self: *Context, path: []const u8) ?std.posix.pid_t {
        _ = self;
        var buf: [64]u8 = undefined;
        const content = readProcFile(path, &buf);
        return std.fmt.parseInt(std.posix.pid_t, std.mem.trim(u8, content, " \n\r\t"), 10) catch null;
    }

    /// 写 pid 文件
    pub fn writePidFile(self: *Context, path: []const u8, pid: std.posix.pid_t) void {
        const s = std.fmt.allocPrint(self.gpa, "{d}\n", .{pid}) catch return;
        defer self.gpa.free(s);
        self.writeFileBytes(path, s);
    }

    /// sing-box 是否在运行 (pid 文件 + 存活检查)
    pub fn singboxRunning(self: *Context) bool {
        const pid = self.readPidFile(self.pidfile) orelse return false;
        return self.pidAlive(pid);
    }

    /// 看门狗是否在运行
    pub fn watchdogAlive(self: *Context) bool {
        const pid = self.readPidFile(self.wpidfile) orelse return false;
        return self.pidAlive(pid);
    }

    /// 模块开关状态: KernelSU/Magisk 的 Manager 禁用模块 = 在模块目录创建 disable 标记文件
    /// (ksud 源码 disable_module/enable_module 确认: 只建/删这个文件, 不执行任何脚本)
    /// remove 标记表示待卸载; 模块目录不存在 (已卸载) 也视为停止
    pub fn moduleDisabled(self: *Context) bool {
        if (!self.dirExists(self.moddir)) return true;
        if (self.fileExists(self.disable_flag)) return true;
        return self.fileExists(self.remove_flag);
    }

    /// 运行状态文字 (描述/status 共用): 运行中 (pid X) / 未运行 (模块已禁用) / 未运行 (看门狗待命) / 未运行
    /// 返回 gpa 分配的字符串, 调用方负责 free
    pub fn statusText(self: *Context) []const u8 {
        if (self.singboxRunning()) {
            if (self.readPidFile(self.pidfile)) |pid| {
                return std.fmt.allocPrint(self.gpa, "运行中 (pid {d})", .{pid}) catch self.gpa.dupe(u8, "运行中") catch "运行中";
            }
        }
        if (self.moduleDisabled()) return self.gpa.dupe(u8, "未运行 (模块已禁用)") catch "未运行";
        if (self.watchdogAlive()) return self.gpa.dupe(u8, "未运行 (看门狗待命)") catch "未运行";
        return self.gpa.dupe(u8, "未运行") catch "未运行";
    }

    /// 把运行状态写进模块描述 (AGENTS.md 约束 8: 双写, 时机由调用方保证)
    /// ① ksud module config set override.description (KSU_MODULE 由模块脚本环境提供)
    /// ② 改写 module.prop 的 description 行 (ResukiSU 等 Manager 可能直接读 module.prop)
    pub fn updateDesc(self: *Context) void {
        const st = self.statusText();
        defer self.gpa.free(st);
        const desc = std.fmt.allocPrint(self.gpa, "sing-box: {s}", .{st}) catch return;
        defer self.gpa.free(desc);
        // ① ksud (失败静默, 交由 ② 兜底)
        self.spawnQuiet(&.{ "ksud", "module", "config", "set", "override.description", desc });
        // ② module.prop
        self.replaceDescriptionLine(desc);
    }

    /// 改写 module.prop 的 description 行, 其余内容原样保留
    fn replaceDescriptionLine(self: *Context, new_desc: []const u8) void {
        const content = self.readFileAlloc(self.module_prop) catch return;
        defer self.gpa.free(content);
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(self.gpa);
        var it = std.mem.splitScalar(u8, content, '\n');
        while (it.next()) |line| {
            if (std.mem.startsWith(u8, line, "description=")) {
                out.appendSlice(self.gpa, "description=") catch return;
                out.appendSlice(self.gpa, new_desc) catch return;
            } else {
                out.appendSlice(self.gpa, line) catch return;
            }
            out.append(self.gpa, '\n') catch return;
        }
        self.writeFileBytes(self.module_prop, out.items);
    }

    /// 运行命令并忽略全部输出 (用于 ksud); 失败静默
    pub fn spawnQuiet(self: *Context, argv: []const []const u8) void {
        // 先确认命令存在: 直接 spawn 不存在的命令会在 fork 后 exec 失败, 留下僵尸进程
        if (argv.len == 0 or !commandExists(self, argv[0])) return;
        var child = std.process.spawn(self.io, .{
            .argv = argv,
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
        }) catch return;
        _ = child.wait(self.io) catch {};
    }

    /// 收割已退出的子进程 (僵尸): 防止进程表泄漏
    /// 看门狗用 pid 而非 Child 句柄管理 sing-box, 停止/重启后需要手动 waitpid 收尸
    pub fn reap(self: *Context, pid: std.posix.pid_t) void {
        _ = self;
        var status: i32 = 0;
        _ = std.os.linux.waitpid(pid, &status, std.os.linux.W.NOHANG);
    }

    /// 命令是否在 PATH 中 (避免 spawn 不存在的命令产生僵尸)
    fn commandExists(self: *Context, name: []const u8) bool {
        if (std.mem.indexOfScalar(u8, name, '/') != null) return self.fileExists(name);
        const env_path = getEnvVar(self.gpa, "PATH") orelse return false;
        defer self.gpa.free(env_path);
        var it = std.mem.splitScalar(u8, env_path, ':');
        while (it.next()) |dir| {
            const candidate = std.Io.Dir.path.join(self.gpa, &.{ dir, name }) catch continue;
            defer self.gpa.free(candidate);
            if (self.fileExists(candidate)) return true;
        }
        return false;
    }

    /// 睡眠 (看门狗轮询用)
    pub fn sleep(self: *Context, secs: i64) void {
        std.Io.sleep(self.io, std.Io.Duration.fromSeconds(secs), .boot) catch {};
    }
};

// ---------------------------------------------------------------------------
// 内部辅助
// ---------------------------------------------------------------------------

fn join(gpa: std.mem.Allocator, parts: []const []const u8) ![]const u8 {
    return std.Io.Dir.path.join(gpa, parts);
}
