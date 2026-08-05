#!/system/bin/sh
# sing-box-init action.sh: KernelSU Manager 的 Action 按钮 = 开关切换
# 未运行 -> 启动; 运行中/重启中 -> 停止
# 注意: 一律用 sh 调用 daemon.sh, 不依赖可执行位 (安装后脚本可能没有 +x)

MODDIR=${0%/*}
[ -f "$MODDIR/module.prop" ] || MODDIR=/data/adb/modules/sing-box-init

STATUS=$(sh "$MODDIR/daemon.sh" status)
echo "$STATUS"
case "$STATUS" in
    *"is not running"*)
        echo "sing-box: starting..."
        sh "$MODDIR/daemon.sh" start
        ;;
    *)
        echo "sing-box: stopping..."
        sh "$MODDIR/daemon.sh" stop
        ;;
esac
sh "$MODDIR/daemon.sh" status

exit 0
