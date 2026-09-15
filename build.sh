#!/bin/sh
# 构建 sing-box-init 模块安装包, 生成后在 KernelSU Manager 中刷入
#
# 依赖: go (交叉编译 aarch64-linux 静态二进制; 纯标准库, 无外部依赖) + zip
# CI 复用同一个脚本, 不另外重写一套构建逻辑
set -e
cd "$(dirname "$0")"

VER=$(sed -n 's/^version=//p' module.prop)
OUT="sing-box-init-v${VER}.zip"

if ! command -v go >/dev/null 2>&1; then
    echo "错误: 需要 go (https://go.dev)"
    exit 1
fi
if ! command -v zip >/dev/null 2>&1; then
    echo "错误: 需要 zip 命令"
    exit 1
fi

echo "编译守护进程 (go → aarch64-linux 静态二进制)..."
mkdir -p bin
GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build -trimpath -ldflags "-s -w" -o bin/sing-box-init ./src
chmod 0755 bin/sing-box-init

rm -f "$OUT"
zip -q -r "$OUT" module.prop customize.sh service.sh action.sh uninstall.sh build.sh daemon.sh config webroot bin
echo "已生成: $OUT"
