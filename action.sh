#!/system/bin/sh
# sing-box-init action.sh: KernelSU Manager 的 Action 按钮 = 重启 sing-box
# sing-box 的开关 = 模块本身的启用/禁用开关 (Manager 模块页), 看门狗自动响应
# 注意: 一律用 sh 调用 daemon.sh, 不依赖可执行位 (安装后脚本可能没有 +x)

MODDIR=$(cd "${0%/*}" && pwd)
[ -f "$MODDIR/module.prop" ] || MODDIR=/data/adb/modules/sing-box-init

sh "$MODDIR/daemon.sh" restart

exit 0
