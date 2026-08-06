#!/system/bin/sh
# sing-box-init action.sh: KernelSU Manager 的 Action 按钮 = 开关切换
# 未运行 -> 启动; 运行中/重启中 -> 停止 (逻辑在 daemon.sh 的 toggle 子命令)
# 注意: 一律用 sh 调用 daemon.sh, 不依赖可执行位 (安装后脚本可能没有 +x)

MODDIR=$(cd "${0%/*}" && pwd)
[ -f "$MODDIR/module.prop" ] || MODDIR=/data/adb/modules/sing-box-init

sh "$MODDIR/daemon.sh" toggle

exit 0
