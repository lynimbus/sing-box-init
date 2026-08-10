#!/bin/sh
# 构建 sing-box-init 模块安装包, 生成后在 KernelSU Manager 中刷入
#
# 依赖: zig (0.17-dev, 交叉编译守护进程二进制) + zip
#   zig: https://ziglang.org  (Arch: pacman -S zig)
set -e
cd "$(dirname "$0")"

VER=$(sed -n 's/^version=//p' module.prop)
OUT="sing-box-init-v${VER}.zip"

if ! command -v zig >/dev/null 2>&1; then
    echo "错误: 需要 zig (https://ziglang.org, Arch: pacman -S zig)"
    exit 1
fi
if ! command -v zip >/dev/null 2>&1; then
    echo "错误: 需要 zip 命令 (Debian/Ubuntu: apt install zip)"
    exit 1
fi

# 1. 交叉编译 Zig 守护进程: aarch64-linux-musl 静态二进制, Android 直接运行
#    (模块内 sing-box 也是 arm64; 二进制打进 bin/ 随模块分发)
echo "编译 sing-box-init (aarch64-linux-musl, ReleaseSmall)..."
zig build -Dtarget=aarch64-linux-musl -Doptimize=ReleaseSmall
cp -f zig-out/bin/sing-box-init bin/sing-box-init
chmod 0755 bin/sing-box-init

# 2. 打包 (bin/ 内含: sing-box-init 二进制 + sing-box 内核 tar.gz)
rm -f "$OUT"
zip -q -r "$OUT" module.prop customize.sh service.sh action.sh uninstall.sh build.sh daemon.sh config webroot bin
echo "已生成: $OUT"
