#!/system/bin/sh
# sing-box-init 开机启动脚本: 让 sing-box 持久运行 (开机自启 + 崩溃自动重启)
# KernelSU/Magisk 在 late_start service 阶段执行本脚本, 无参数
# 手动开关: Manager 模块页的启用/禁用开关控制 sing-box; Action 按钮 = 重启 (action.sh)
# 注意: 一律用 sh 调用 daemon.sh, 不依赖可执行位 (安装后脚本可能没有 +x)

MODDIR=$(cd "${0%/*}" && pwd)
[ -f "$MODDIR/module.prop" ] || MODDIR=/data/adb/modules/sing-box-init

# start 内部已负责 update_desc, 无需再单独调用
sh "$MODDIR/daemon.sh" start

exit 0
