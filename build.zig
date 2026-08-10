const std = @import("std");

// sing-box-init 构建脚本
//   zig build                          # 本机架构构建 (调试用)
//   zig build -Dtarget=aarch64-linux-musl -Doptimize=ReleaseSmall   # 设备端 (Android)
//   zig build test                     # 单元测试 (白名单生成逻辑等)

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // 单线程: 看门狗是纯轮询进程, 无需线程;
    // 同时保证 Io.Threaded 走单线程实现 (无后台 worker), 进程派生语义简单可靠
    const exe_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .single_threaded = true,
    });
    const exe = b.addExecutable(.{
        .name = "sing-box-init",
        .root_module = exe_module,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "运行 sing-box-init");
    run_step.dependOn(&run_cmd.step);

    const test_module = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
        .single_threaded = true,
    });
    const unit_tests = b.addTest(.{
        .root_module = test_module,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "运行单元测试");
    test_step.dependOn(&run_unit_tests.step);
}
