#!/bin/sh
# 构建 sing-box-init 模块安装包, 生成后在 KernelSU Manager 中刷入
set -e
cd "$(dirname "$0")"

VER=$(sed -n 's/^version=//p' module.prop)
OUT="sing-box-init-v${VER}.zip"

if ! command -v zip >/dev/null 2>&1; then
    echo "错误: 需要 zip 命令 (Debian/Ubuntu: apt install zip)"
    exit 1
fi

rm -f "$OUT"
zip -q -r "$OUT" module.prop customize.sh service.sh daemon.sh action.sh uninstall.sh build.sh config webroot bin
echo "已生成: $OUT"
