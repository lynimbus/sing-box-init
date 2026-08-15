//! 单元测试: 白名单生成逻辑 (whitelist.zig) + 进程存活检查 (context.zig)
//! 运行: zig build test
//!
//! 测试不碰真实设备: 在 /tmp 下建独立目录组装 Context, 用 stub 占位, 全部本机完成。

const std = @import("std");
const context = @import("context.zig");
const whitelist = @import("whitelist.zig");
const watchdog = @import("watchdog.zig");

const Context = context.Context;

// ---------------------------------------------------------------------------
// 测试脚手架: 临时目录 + 最小 Context
// ---------------------------------------------------------------------------

const TestEnv = struct {
    gpa: std.mem.Allocator,
    threaded: *std.Io.Threaded, // 堆分配: io 的 userdata 指向它, 实例不能随结构体拷贝而移动
    io: std.Io,
    root: []const u8,
    moddir: []const u8,
    data_dir: []const u8,
    ctx: Context,

    fn init(gpa: std.mem.Allocator) !TestEnv {
        // 0.17 dev 的 std.testing.io 未初始化 (vtable 是垃圾值), 每个测试自建 Threaded
        const threaded = try gpa.create(std.Io.Threaded);
        threaded.* = std.Io.Threaded.init(gpa, .{});
        const io = threaded.io();
        const root = try std.fmt.allocPrint(gpa, "/tmp/sing-box-init-test-{d}-{x}", .{ std.os.linux.getpid(), @intFromPtr(threaded) });
        const moddir = try std.Io.Dir.path.join(gpa, &.{ root, "module" });
        const data_dir = try std.Io.Dir.path.join(gpa, &.{ root, "data" });
        // 建目录 + module.prop (Context 的模块目录检查依赖它)
        const cwd = std.Io.Dir.cwd();
        try cwd.createDirPath(io, moddir);
        try cwd.createDirPath(io, data_dir);
        const prop_path = try std.Io.Dir.path.join(gpa, &.{ moddir, "module.prop" });
        defer gpa.free(prop_path);
        try cwd.writeFile(io, .{ .sub_path = prop_path, .data = "id=sing-box-init\nversion=test\n" });
        const ctx = try Context.init(gpa, io, moddir, data_dir);
        return .{ .gpa = gpa, .threaded = threaded, .io = io, .root = root, .moddir = moddir, .data_dir = data_dir, .ctx = ctx };
    }

    fn deinit(self: *TestEnv) void {
        self.ctx.deinit();
        std.Io.Dir.cwd().deleteTree(self.io, self.root) catch {};
        self.gpa.free(self.root);
        self.gpa.free(self.moddir);
        self.gpa.free(self.data_dir);
        self.threaded.deinit();
        self.gpa.destroy(self.threaded);
    }

    /// 写一个 conf.d 配置文件
    fn writeConf(self: *TestEnv, name: []const u8, content: []const u8) !void {
        const path = try std.Io.Dir.path.join(self.gpa, &.{ self.ctx.conf_dir, name });
        defer self.gpa.free(path);
        try std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = path, .data = content });
    }

    /// 写白名单文件
    fn writePkgs(self: *TestEnv, content: []const u8) !void {
        try std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = self.ctx.include_package, .data = content });
    }

    /// 读生成目录里的文件内容
    fn readGen(self: *TestEnv, name: []const u8) ![]u8 {
        const path = try std.Io.Dir.path.join(self.gpa, &.{ self.ctx.gen_dir, name });
        defer self.gpa.free(path);
        const content = try self.ctx.readFileAlloc(path);
        return content; // 调用方 free
    }

    /// 路由规则文件是否存在
    fn rulesFileExists(self: *TestEnv) bool {
        const path = std.Io.Dir.path.join(self.gpa, &.{ self.ctx.gen_dir, "00-include-package.json" }) catch return false;
        defer self.gpa.free(path);
        return context.fileExistsAt(self.io, path);
    }
};

// ---------------------------------------------------------------------------
// 测试用例
// ---------------------------------------------------------------------------

test "白名单: 写路由规则 00-include-package.json, 原配置复制不改动" {
    var env = try TestEnv.init(std.testing.allocator);
    defer env.deinit();
    try env.writeConf("config.json",
        \\{ "inbounds": [ { "type": "tun", "tag": "tun-in" } ] }
    );
    try env.writeConf("route.json",
        \\{ "route": { "rules": [ { "action": "reject" } ] } }
    );
    try env.writePkgs("com.example.a\ncom.example.b\n");

    try std.testing.expect(whitelist.run(&env.ctx));

    // 原配置未被改写 (复制后原样, 不解析不重写)
    const out = try env.readGen("config.json");
    defer env.gpa.free(out);
    try std.testing.expectEqualSlices(u8, "{ \"inbounds\": [ { \"type\": \"tun\", \"tag\": \"tun-in\" } ] }", std.mem.trim(u8, out, "\n"));
    const route_out = try env.readGen("route.json");
    defer env.gpa.free(route_out);
    try std.testing.expectEqualSlices(u8, "{ \"route\": { \"rules\": [ { \"action\": \"reject\" } ] } }", std.mem.trim(u8, route_out, "\n"));

    // 路由规则文件存在且内容正确
    const rules = try env.readGen("00-include-package.json");
    defer env.gpa.free(rules);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, rules, .{});
    defer parsed.deinit();
    const rule = parsed.value.object.get("route").?.object.get("rules").?.array.items[0].object;
    try std.testing.expectEqualSlices(u8, "route", rule.get("action").?.string);
    const names = rule.get("package_name").?.array;
    try std.testing.expectEqual(@as(usize, 2), names.items.len);
    try std.testing.expectEqualSlices(u8, "com.example.a", names.items[0].string);
    try std.testing.expectEqualSlices(u8, "com.example.b", names.items[1].string);
}

test "白名单过滤: 注释 / 空行 / CR / 首尾空白" {
    var env = try TestEnv.init(std.testing.allocator);
    defer env.deinit();
    try env.writeConf("config.json",
        \\{ "inbounds": [ { "type": "tun" } ] }
    );
    try env.writePkgs(
        \\# 注释行
        \\   # 带缩进注释
        \\
        \\  com.example.a  
        \\com.example.b
        \\com.example.c
    );
    try std.testing.expect(whitelist.run(&env.ctx));

    const rules = try env.readGen("00-include-package.json");
    defer env.gpa.free(rules);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, rules, .{});
    defer parsed.deinit();
    const names = parsed.value.object.get("route").?.object.get("rules").?.array.items[0].object.get("package_name").?.array;
    try std.testing.expectEqual(@as(usize, 3), names.items.len);
    try std.testing.expectEqualSlices(u8, "com.example.a", names.items[0].string);
    try std.testing.expectEqualSlices(u8, "com.example.b", names.items[1].string);
    try std.testing.expectEqualSlices(u8, "com.example.c", names.items[2].string);
}

test "include_package 缺失: 白名单关闭, 不写路由规则, 配置原样复制" {
    var env = try TestEnv.init(std.testing.allocator);
    defer env.deinit();
    try env.writeConf("config.json",
        \\{ "inbounds": [ { "type": "tun" } ] }
    );
    // 不写 include_package 文件
    try std.testing.expect(whitelist.run(&env.ctx));
    try std.testing.expect(!env.rulesFileExists());
    const out = try env.readGen("config.json");
    defer env.gpa.free(out);
    try std.testing.expectEqualSlices(u8, "{ \"inbounds\": [ { \"type\": \"tun\" } ] }", std.mem.trim(u8, out, "\n"));
}

test "空白名单: 全部流量走代理, 不写路由规则" {
    var env = try TestEnv.init(std.testing.allocator);
    defer env.deinit();
    try env.writeConf("config.json",
        \\{ "inbounds": [ { "type": "tun" } ] }
    );
    try env.writePkgs("");
    try std.testing.expect(whitelist.run(&env.ctx));
    try std.testing.expect(!env.rulesFileExists());
}

test "include_package.disable: 白名单关闭开关, 不写路由规则" {
    var env = try TestEnv.init(std.testing.allocator);
    defer env.deinit();
    try env.writeConf("config.json",
        \\{ "inbounds": [ { "type": "tun" } ] }
    );
    // 白名单已改名成 .disable (关闭), 不留 include_package
    try std.Io.Dir.cwd().writeFile(env.io, .{ .sub_path = env.ctx.include_package_disable, .data = "" });
    try std.testing.expect(whitelist.run(&env.ctx));
    try std.testing.expect(!env.rulesFileExists());
}

test "非法 JSON 配置: 原样复制不解析, 白名单规则照常生成 (由 sing-box 报真实错误)" {
    var env = try TestEnv.init(std.testing.allocator);
    defer env.deinit();
    // 非严格 JSON (旧版会因注入 ebpf 而解析失败; 现在不解析, 原样交给 sing-box)
    try env.writeConf("config.json", "{ inbounds: [ { type: tun } ] }");
    try env.writePkgs("com.example.a\n");
    try std.testing.expect(whitelist.run(&env.ctx));
    const out = try env.readGen("config.json");
    defer env.gpa.free(out);
    try std.testing.expectEqualSlices(u8, "{ inbounds: [ { type: tun } ] }", std.mem.trim(u8, out, "\n"));
    try std.testing.expect(env.rulesFileExists());
}

test "多文件: 全部原样复制, 白名单规则独立生成" {
    var env = try TestEnv.init(std.testing.allocator);
    defer env.deinit();
    try env.writeConf("a.json",
        \\{ "route": { "final": "direct" } }
    );
    try env.writeConf("b.json",
        \\{ "dns": { "servers": [ { "tag": "dns", "address": "local" } ] } }
    );
    try env.writePkgs("com.example.a\n");
    try std.testing.expect(whitelist.run(&env.ctx));

    const a = try env.readGen("a.json");
    defer env.gpa.free(a);
    try std.testing.expect(std.mem.indexOf(u8, a, "package_name") == null);

    const b = try env.readGen("b.json");
    defer env.gpa.free(b);
    try std.testing.expect(std.mem.indexOf(u8, b, "package_name") == null);

    try std.testing.expect(env.rulesFileExists());
}

test "pidAlive: /proc 存活检查 (sing-box 关键字)" {
    var env = try TestEnv.init(std.testing.allocator);
    defer env.deinit();
    // 当前测试进程的 cmdline 不含 "sing-box" → 视为不存活 (尽管进程在跑)
    try std.testing.expect(!env.ctx.pidAlive(std.os.linux.getpid()));
    // 未知 pid → 不存活
    try std.testing.expect(!env.ctx.pidAlive(99999999));
}

// ---------------------------------------------------------------------------
// 状态机测试 (watchdog.zig): transition 是纯函数, 直接喂事件序列验证
// ---------------------------------------------------------------------------

const State = watchdog.State;
const Event = watchdog.Event;
const StopReason = watchdog.StopReason;

test "状态机: 生命周期主路径 (禁用→启用→运行→崩溃→热重载→停止)" {
    var st = State.starting;
    // 拉起成功 → 运行
    st = watchdog.transition(st, .singbox_started, .disabled);
    try std.testing.expectEqual(State.running, st);
    // 崩溃 → 退避 → 重试
    st = watchdog.transition(st, .singbox_exited, .disabled);
    try std.testing.expectEqual(State.crash_backoff, st);
    st = watchdog.transition(st, .timeout, .disabled);
    try std.testing.expectEqual(State.starting, st);
    // 白名单热重载: 停 → 自动拉起 (不走 disabled)
    st = watchdog.transition(st, .singbox_started, .disabled);
    st = watchdog.transition(st, .whitelist_changed, .whitelist);
    try std.testing.expectEqual(State.stopping, st);
    st = watchdog.transition(st, .singbox_exited, .whitelist);
    try std.testing.expectEqual(State.starting, st);
    // 模块禁用: 停 → disabled → 重新启用 → 自动拉起
    st = watchdog.transition(st, .disable_on, .disabled);
    try std.testing.expectEqual(State.stopping, st);
    st = watchdog.transition(st, .singbox_exited, .disabled);
    try std.testing.expectEqual(State.disabled, st);
    st = watchdog.transition(st, .disable_off, .disabled);
    try std.testing.expectEqual(State.starting, st);
    // 收到 .stop → 退出
    st = watchdog.transition(st, .stop_flag, .disabled);
    try std.testing.expectEqual(State.exiting, st);
}

test "状态机: 启动失败 → 退避重试; 拉起中禁用 → 停止" {
    var st = State.starting;
    // 确认超时 = 启动失败 → 退避
    st = watchdog.transition(st, .timeout, .disabled);
    try std.testing.expectEqual(State.crash_backoff, st);
    // 退避期间禁用 → disabled
    st = watchdog.transition(st, .disable_on, .disabled);
    try std.testing.expectEqual(State.disabled, st);
    // 重新启用
    st = watchdog.transition(st, .disable_off, .disabled);
    try std.testing.expectEqual(State.starting, st);
    // 拉起中又禁用 → stopping
    st = watchdog.transition(st, .disable_on, .disabled);
    try std.testing.expectEqual(State.stopping, st);
    // 停止中再次禁用 → 仍 disabled
    st = watchdog.transition(st, .disable_on, .disabled);
    try std.testing.expectEqual(State.disabled, st);
}

test "状态机: 禁用状态忽略无关事件, 停止中忽略白名单, 退避中崩溃事件幂等" {
    // disabled 状态下白名单变化/崩溃/超时都不影响
    try std.testing.expectEqual(State.disabled, watchdog.transition(.disabled, .whitelist_changed, .disabled));
    try std.testing.expectEqual(State.disabled, watchdog.transition(.disabled, .singbox_exited, .disabled));
    try std.testing.expectEqual(State.disabled, watchdog.transition(.disabled, .timeout, .disabled));
    // running 状态白名单变化 → stopping (reason=whitelist)
    try std.testing.expectEqual(State.stopping, watchdog.transition(.running, .whitelist_changed, .whitelist));
    // stopping 状态忽略白名单/启动事件
    try std.testing.expectEqual(State.stopping, watchdog.transition(.stopping, .whitelist_changed, .disabled));
    try std.testing.expectEqual(State.stopping, watchdog.transition(.stopping, .singbox_started, .disabled));
    // crash_backoff 状态幂等
    try std.testing.expectEqual(State.crash_backoff, watchdog.transition(.crash_backoff, .singbox_exited, .disabled));
    // exiting 终态
    try std.testing.expectEqual(State.exiting, watchdog.transition(.exiting, .disable_off, .disabled));
    try std.testing.expectEqual(State.exiting, watchdog.transition(.exiting, .timeout, .disabled));
}

test "状态机: 配置热重载与白名单热重载行为一致" {
    // running + 配置变化 → stopping (热重载)
    try std.testing.expectEqual(State.stopping, watchdog.transition(.running, .config_changed, .config));
    // 停完 → 自动重新拉起 (不走 disabled)
    try std.testing.expectEqual(State.starting, watchdog.transition(.stopping, .singbox_exited, .config));
    // 热重载中又禁用 → 优先 disabled
    try std.testing.expectEqual(State.disabled, watchdog.transition(.stopping, .disable_on, .config));
    // running 状态白名单/配置变化都进 stopping
    try std.testing.expectEqual(State.stopping, watchdog.transition(.running, .whitelist_changed, .whitelist));
    try std.testing.expectEqual(State.stopping, watchdog.transition(.running, .config_changed, .config));
    // 非 running 状态忽略配置变化事件
    try std.testing.expectEqual(State.disabled, watchdog.transition(.disabled, .config_changed, .config));
    try std.testing.expectEqual(State.crash_backoff, watchdog.transition(.crash_backoff, .config_changed, .config));
}

test "状态机: 全转换矩阵可穷举, 无 panic (回归保护)" {
    const states = [_]State{ .disabled, .starting, .running, .stopping, .crash_backoff, .exiting };
    const events = [_]Event{ .disable_on, .disable_off, .stop_flag, .whitelist_changed, .config_changed, .singbox_started, .singbox_exited, .timeout };
    const reasons = [_]StopReason{ .disabled, .whitelist };
    for (states) |st| {
        for (events) |ev| {
            for (reasons) |rs| {
                _ = watchdog.transition(st, ev, rs);
            }
        }
    }
}
