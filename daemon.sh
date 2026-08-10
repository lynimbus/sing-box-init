#!/system/bin/sh
# daemon.sh — 薄包装: 转发到 Zig 实现的 sing-box-init 二进制
#
# 保留本文件名是为了兼容既有调用链 (service.sh / action.sh / uninstall.sh 都用
# `sh "$MODDIR/daemon.sh" <子命令>` 调用, 不依赖可执行位), 实际逻辑全在
# $MODDIR/bin/sing-box-init (Zig 交叉编译的静态二进制, 见 build.sh)。
#
# 子命令: start | stop | restart | status | update_desc | watchdog_loop

MODDIR=$(cd "${0%/*}" && pwd)
[ -f "$MODDIR/module.prop" ] || MODDIR=/data/adb/modules/sing-box-init

exec "$MODDIR/bin/sing-box-init" "$@"
