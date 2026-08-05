#!/system/bin/sh
# sing-box-init 开机启动脚本: 让 sing-box 持久运行 (开机自启 + 崩溃自动重启)
# KernelSU/Magisk 在 late_start service 阶段执行本脚本, 无参数
# 手动开关: KernelSU Manager 模块页的 Action 按钮 (action.sh)
# 注意: 一律用 sh 调用 daemon.sh, 不依赖可执行位 (安装后脚本可能没有 +x)

MODDIR=${0%/*}
[ -f "$MODDIR/module.prop" ] || MODDIR=/data/adb/modules/sing-box-init

sh "$MODDIR/daemon.sh" start
sh "$MODDIR/daemon.sh" update_desc

exit 0
