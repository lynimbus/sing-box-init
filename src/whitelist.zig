//! 应用白名单生成 (替代 shell 版 whitelist.sh + whitelist.awk)
//!
//! 与旧版文本注入不同, 本实现用 std.json **严格解析** 用户配置:
//! 任一配置文件不是合法 JSON → 生成失败, daemon 回退直接用原始 conf.d
//! (配置都写不合法, sing-box 也起不来; 回退后 sing-box 会报真实错误)
//!
//! 流程 (对应 whitelist.sh):
//!   1. 重建生成目录: 清掉旧 json, 把 conf.d/ 下所有 *.json 复制过来
//!   2. include_package 不存在 (或已改名 .disable) → 白名单关闭, 配置原样加载
//!   3. 过滤白名单文件: 空行 / `#` 注释 / 首尾空白与 \r 忽略
//!   4. 递归找每个文件里的 ebpf 入站 (任意深度的 type == "ebpf" 对象),
//!      把 include_package 整体替换为白名单 (已有则替换, 没有则插入)
//!   5. 所有文件都没有 ebpf 入站 (如 tun 模式) → 写路由规则 00-include-package.json
//!      (package_name 白名单 + action: route, 列出的应用走 final 代理)
//!
//! 返回 true = 生成成功 (daemon 用 gen_dir 启动); false = 失败 (回退原始 conf.d)

const std = @import("std");
const context = @import("context.zig");

const Context = context.Context;

pub fn run(ctx: *Context) bool {
    // 整个生成过程用 arena: 解析/注入/序列化一次生命周期完成, 无需逐项释放
    var arena = std.heap.ArenaAllocator.init(ctx.gpa);
    defer arena.deinit();
    const a = arena.allocator();

    // ---- 1. 重建生成目录 ----
    // 清掉旧生成文件 (对应 shell: rm -f "$DST"/*.json)
    if (listJsonFiles(ctx, a, ctx.gen_dir)) |old| {
        for (old) |name| {
            ctx.removeFile(std.Io.Dir.path.join(a, &.{ ctx.gen_dir, name }) catch return false);
        }
    }
    // 列出并复制 conf.d/ 下所有 json (对应 shell: for f in "$SRC"/*.json; cp)
    const files = listJsonFiles(ctx, a, ctx.conf_dir) orelse return false;
    for (files) |name| {
        const src = std.Io.Dir.path.join(a, &.{ ctx.conf_dir, name }) catch return false;
        const dst = std.Io.Dir.path.join(a, &.{ ctx.gen_dir, name }) catch return false;
        ctx.copyFile(src, dst);
    }

    // ---- 2. 白名单开关 ----
    // include_package 不存在 (或已改名成 .disable) → 关闭白名单, 配置原样加载 (仅副本)
    if (!ctx.fileExists(ctx.include_package)) return true;
    const pkgs = readPkgs(ctx, a) orelse return false;
    if (pkgs.len == 0) return true; // 空白名单 = 全部流量走代理

    // ---- 3/4. 注入 ebpf 入站 ----
    var found_ebpf = false;
    for (files) |name| {
        const path = std.Io.Dir.path.join(a, &.{ ctx.gen_dir, name }) catch return false;
        const content = ctx.readFileAlloc(path) catch return false;
        defer ctx.gpa.free(content);
        // 严格解析: 非法 JSON → 生成失败 (Q2 决策: 严格模式, 不静默放过)
        var parsed = std.json.parseFromSliceLeaky(std.json.Value, a, content, .{}) catch {
            ctx.log("ERROR", "白名单生成失败: 配置文件不是合法 JSON: {s} (请检查格式)", .{path});
            return false;
        };
        // 递归注入 include_package; 含 ebpf 入站的文件重新序列化
        if (injectEbpfObjects(a, &parsed, pkgs)) {
            found_ebpf = true;
            writeJsonFile(ctx, a, path, parsed);
        }
        // 无 ebpf 入站的文件保持原样 (步骤 1 已复制, 这里不重写)
    }

    // ---- 5. 无 ebpf → 路由规则 ----
    if (!found_ebpf) writeRouteRules(ctx, a, pkgs);
    return true;
}

// ---------------------------------------------------------------------------
// 内部实现
// ---------------------------------------------------------------------------

/// 列出目录下所有 *.json 文件名 (arena 分配)
fn listJsonFiles(ctx: *Context, a: std.mem.Allocator, dir_path: []const u8) ?[][]const u8 {
    var dir = std.Io.Dir.openDirAbsolute(ctx.io, dir_path, .{ .iterate = true }) catch return null;
    defer dir.close(ctx.io);
    var list: std.ArrayList([]const u8) = .empty;
    defer list.deinit(a);
    var it = dir.iterate();
    while (it.next(ctx.io) catch null) |entry| {
        const name = entry.name;
        if (name.len < 5 or !std.mem.eql(u8, name[name.len - 5 ..], ".json")) continue;
        list.append(a, a.dupe(u8, name) catch return null) catch return null;
    }
    return list.toOwnedSlice(a) catch return null;
}

/// 读白名单纯文本: 每行一个包名; 空行与 `#` 注释忽略; 去掉首尾空白与 \r (兼容 Windows 换行)
/// 对应 shell: grep -v '^[[:space:]]*#' | grep -v '^[[:space:]]*$' | tr -d '\r' | sed 's/^[ \t]*//; s/[ \t]*$//'
fn readPkgs(ctx: *Context, a: std.mem.Allocator) ?[][]const u8 {
    const content = ctx.readFileAlloc(ctx.include_package) catch return null;
    defer ctx.gpa.free(content);
    var list: std.ArrayList([]const u8) = .empty;
    defer list.deinit(a);
    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        if (line[0] == '#') continue;
        list.append(a, a.dupe(u8, line) catch return null) catch return null;
    }
    return list.toOwnedSlice(a) catch return null;
}

/// 递归遍历 JSON, 给每个 type == "ebpf" 的对象注入 include_package (已有则整体替换)
/// 返回是否找到至少一个 ebpf 对象
fn injectEbpfObjects(a: std.mem.Allocator, value: *std.json.Value, pkgs: []const []const u8) bool {
    var found = false;
    switch (value.*) {
        .object => |*obj| {
            if (isEbpf(obj.*)) {
                found = true;
                obj.put(a, "include_package", whitelistArray(a, pkgs)) catch {};
            }
            var it = obj.iterator();
            while (it.next()) |entry| {
                if (injectEbpfObjects(a, entry.value_ptr, pkgs)) found = true;
            }
        },
        .array => |arr| {
            for (arr.items) |*item| {
                if (injectEbpfObjects(a, item, pkgs)) found = true;
            }
        },
        else => {},
    }
    return found;
}

/// 判断对象是否是 ebpf 入站: 有 "type": "ebpf"
fn isEbpf(obj: std.json.ObjectMap) bool {
    if (obj.get("type")) |t| {
        if (t == .string) return std.mem.eql(u8, t.string, "ebpf");
    }
    return false;
}

/// 构造白名单 JSON 数组: ["com.a", "com.b", ...]
fn whitelistArray(a: std.mem.Allocator, pkgs: []const []const u8) std.json.Value {
    var arr = std.json.Array.init(a);
    for (pkgs) |p| {
        arr.append(.{ .string = p }) catch {};
    }
    return .{ .array = arr };
}

/// 以缩进 2 空格重写 JSON 文件 (生成目录, 便于排查); 末尾补换行
fn writeJsonFile(ctx: *Context, a: std.mem.Allocator, path: []const u8, value: std.json.Value) void {
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    std.json.Stringify.value(value, .{ .whitespace = .indent_2 }, &out.writer) catch return;
    const final = std.fmt.allocPrint(a, "{s}\n", .{out.written()}) catch return;
    ctx.writeFileBytes(path, final);
}

/// 非 ebpf 模式 (如 tun): 写路由规则文件, 列出的应用走 final 代理
/// 文件名 00- 前缀 → conf.d 合并时规则排最前
fn writeRouteRules(ctx: *Context, a: std.mem.Allocator, pkgs: []const []const u8) void {
    var rules = std.json.Array.init(a);
    var rule: std.json.ObjectMap = .empty;
    rule.put(a, "package_name", whitelistArray(a, pkgs)) catch return;
    rule.put(a, "action", .{ .string = "route" }) catch return;
    rules.append(.{ .object = rule }) catch return;
    var route: std.json.ObjectMap = .empty;
    route.put(a, "rules", .{ .array = rules }) catch return;
    var root: std.json.ObjectMap = .empty;
    root.put(a, "route", .{ .object = route }) catch return;
    const path = std.Io.Dir.path.join(a, &.{ ctx.gen_dir, "00-include-package.json" }) catch return;
    writeJsonFile(ctx, a, path, .{ .object = root });
}
