#!/system/bin/sh
# sing-box-init 卸载脚本: 停止守护进程并清理运行时文件
# 注意: /data/adb/sing-box/config.json 配置会被保留, 如需彻底删除请手动执行:
#   su -c "rm -rf /data/adb/sing-box"

MODDIR=${0%/*}
[ -f "$MODDIR/module.prop" ] || MODDIR=/data/adb/modules/sing-box-init

DATA_DIR=${SING_BOX_DATA_DIR:-/data/adb/sing-box}

sh "$MODDIR/daemon.sh" stop
rm -rf "$DATA_DIR/logs"

exit 0
