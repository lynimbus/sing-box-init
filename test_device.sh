#!/bin/sh
# 真机验收: adb 驱动的故障注入矩阵
#
# 前置: 模块已安装到设备, 设备已通过 adb 连接且 su 可用
# 用法: sh test_device.sh
#
# 覆盖: 启停 / 崩溃恢复 / 看门狗被 kill -9 后的孤儿收敛 / 模块开关 / 配置热重载 /
#       非法配置拒绝重启 / Action 重启 / 最终状态一致性
# 所有"内核到底死没死"的断言都用设备上的 ps 实测, 不看 pid 文件。
set -e

ADB=${ADB:-adb}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

cat >"$TMP/devcheck.sh" <<'EOS'
#!/system/bin/sh
MODDIR=/data/adb/modules/sing-box-init
DATA=/data/adb/sing-box
LOG=$DATA/logs/watchdog.log
STATE=$DATA/logs/watchdog.state
FAILS=0

ok() { echo "  ✓ $*"; }
bad() { FAILS=$((FAILS + 1)); echo "  ✗ FAIL: $*"; }
say() { echo ""; echo "== $* =="; }
sleep1() { sleep 1; }

core_lines() { ps -A -o PID,ARGS 2>/dev/null | grep "[s]ing-box run"; }
core_pids() {
    for pid in $(core_lines | sed 's/^ *//; s/ .*//'); do
        a0=$(tr '\0' '\n' <"/proc/$pid/cmdline" 2>/dev/null | sed -n 1p)
        [ "$a0" = "$MODDIR/bin/sing-box" ] && echo "$pid"
    done
}
core_count() { core_pids | grep -c . ; }
core_pid() { core_pids | head -n1; }
# toybox ps 只打印 comm + 参数 (不打印 argv[0] 路径), 所以必须回 /proc/<pid>/cmdline 核对绝对路径
wd_pid() {
    for pid in $(ps -A -o PID,ARGS 2>/dev/null | grep "[s]ing-box-init [w]atchdog_loop" | sed 's/^ *//; s/ .*//'); do
        a0=$(tr '\0' '\n' <"/proc/$pid/cmdline" 2>/dev/null | sed -n 1p)
        if [ "$a0" = "$MODDIR/bin/sing-box-init" ]; then
            echo "$pid"
            return
        fi
    done
}
alive() { [ -n "$1" ] && [ -d "/proc/$1" ]; }

wait_count() {
    i=0
    while [ "$i" -lt 100 ]; do
        [ "$(core_count)" = "$1" ] && return 0
        sleep1
        i=$((i + 1))
    done
    return 1
}

wait_pid_change() {
    i=0
    while [ "$i" -lt 100 ]; do
        now=$(core_pid)
        [ -n "$now" ] && [ "$now" != "$1" ] && return 0
        sleep1
        i=$((i + 1))
    done
    return 1
}

say "前置检查"
[ -f "$MODDIR/module.prop" ] || { echo "模块未安装: $MODDIR"; exit 1; }
[ -x "$MODDIR/bin/sing-box" ] || { echo "内核二进制缺失/不可执行"; exit 1; }
[ -f "$DATA/conf.d/config.json" ] || { echo "配置缺失: $DATA/conf.d/config.json"; exit 1; }
ok "模块与配置就位 ($(sed -n 's/^version=//p' "$MODDIR/module.prop"))"

say "start"
sh "$MODDIR/daemon.sh" start
wait_count 1 || bad "start 后内核未起来 (实测 $(core_count) 个)"
[ "$(core_count)" = "1" ] && ok "内核已启动 (pid $(core_pid))"
WPID=$(wd_pid)
alive "$WPID" && ok "看门狗存活 (pid $WPID)" || bad "看门狗未存活"
grep -q "^description=sing-box: 运行中" "$MODDIR/module.prop" && ok "描述显示运行中" || bad "描述未更新"

say "崩溃恢复 (kill -9 内核)"
OLD=$(core_pid)
kill -9 "$OLD"
sleep1
wait_pid_change "$OLD" || bad "崩溃后未自动拉起"
NEW=$(core_pid)
alive "$OLD" && bad "旧内核进程仍在 ($OLD)" || ok "旧内核已消失 ($OLD)"
[ "$(core_count)" = "1" ] && ok "恢复后只有 1 个内核 (pid $NEW)" || bad "内核数量异常 (实测 $(core_count) 个)"
grep -q "sing-box 意外退出" "$LOG" && ok "日志记录了意外退出" || bad "日志无意外退出记录"

say "看门狗被 kill -9 → 孤儿收敛"
WPID=$(wd_pid)
SPID=$(core_pid)
kill -9 "$WPID"
sleep1
alive "$WPID" && bad "看门狗未被杀死" || ok "看门狗已被 kill -9"
alive "$SPID" && ok "内核孤儿化 (预期行为: SIGKILL 无法捕获)" || bad "内核不应随看门狗一起死"
sh "$MODDIR/daemon.sh" start
wait_count 1 || bad "重新拉起后内核数量不是 1"
sleep1
WPID2=$(wd_pid)
alive "$WPID2" && ok "看门狗已重新拉起 (pid $WPID2)" || bad "看门狗未恢复"
grep -q "发现无人看管的内核进程" "$LOG" && ok "日志记录了孤儿清理" || bad "未走孤儿清理路径"
[ "$(core_count)" = "1" ] && ok "孤儿已清理, 只剩 1 个内核 (pid $(core_pid))" || bad "孤儿未清理干净"

say "模块开关 (disable/enable)"
ksud module disable sing-box-init
wait_count 0 || bad "禁用后内核仍在跑 (实测 $(core_count) 个)"
[ "$(core_count)" = "0" ] && ok "禁用后内核已停 (ps 实测 0 个)"
alive "$(wd_pid)" && ok "看门狗保持存活" || bad "看门狗不应随禁用消失"
ksud module enable sing-box-init
wait_count 1 || bad "启用后内核未拉起"
[ "$(core_count)" = "1" ] && ok "启用后内核自动拉起 (pid $(core_pid))" || bad "启用后内核未恢复"

say "配置热重载 (改 conf.d/*.json)"
OLD=$(core_pid)
printf '\n' >>"$DATA/conf.d/config.json"
wait_pid_change "$OLD" || bad "配置变化后未重启"
[ "$(core_pid)" != "$OLD" ] && ok "配置变化触发重启 ($OLD → $(core_pid))" || bad "配置变化未触发重启"

say "非法配置: 拒绝重启并保留旧内核"
OLD=$(core_pid)
echo '{' >"$DATA/conf.d/zz-test-bad.json"
sleep 3
[ "$(core_pid)" = "$OLD" ] && alive "$OLD" && ok "旧内核未被打断 (pid $OLD)" || bad "非法配置导致内核被重启/打断"
grep -q "新配置校验失败" "$LOG" && ok "日志记录了配置校验失败" || bad "日志缺少校验失败记录"
grep -q "配置错误" "$MODDIR/module.prop" && ok "描述标出配置错误" || bad "描述未标出配置错误"
rm -f "$DATA/conf.d/zz-test-bad.json"
sleep 3
grep -q "配置已恢复到当前运行版本" "$LOG" && ok "撤销非法配置后清掉了错误标记" || bad "未记录配置恢复"
grep -q "配置错误" "$MODDIR/module.prop" && bad "描述仍标着配置错误" || ok "描述恢复正常"

say "Action 按钮 (ksud module action)"
OLD=$(core_pid)
ksud module action sing-box-init
wait_pid_change "$OLD" || bad "Action 未触发重启"
[ "$(core_count)" = "1" ] && ok "Action 重启完成 (pid $(core_pid))" || bad "Action 后内核数量异常"

say "热点/USB 共享劫持 (shared 平面)"
IFACES=$(tr -d ' \n' <"$DATA/conf.d/config.json" | sed -n 's/.*"interface":\[\([^]]*\)\].*/\1/p' | tr ',' ' ' | tr -d '"')
if [ -z "$IFACES" ]; then
    echo "  - 配置里没有 shared.interface, 跳过 (只接管本机流量)"
else
    for iface in $IFACES; do
        if [ ! -d "/sys/class/net/$iface" ]; then
            echo "  - $iface: 接口当前不存在 (下游未开), 跳过"
        elif tc filter show dev "$iface" ingress 2>/dev/null | grep -q sb_share_in; then
            ok "$iface: shared 已挂载 (sb_share_in)"
        else
            bad "$iface: 接口存在但未挂 sb_share_in (不在 shared.interface / 或它正是当前上网出口)"
        fi
    done
fi

say "最终状态"
sh "$MODDIR/daemon.sh" status
echo "--- 描述 ---"; grep "^description=" "$MODDIR/module.prop"
echo "--- 状态文件 ---"; cat "$STATE"
echo "--- 日志最近 15 行 ---"; tail -n 15 "$LOG"
echo "--- 日志行数 ---"; wc -l "$LOG"

echo ""
if [ "$FAILS" -eq 0 ]; then
    echo "=== 真机验收全部通过 ==="
else
    echo "=== 真机验收有 $FAILS 项失败 ==="
    exit 1
fi

echo ""
echo "仍需手动验证的一项: 热点劫持的端到端效果"
echo "  1. 让一台设备连上手机热点 (上面若显示 shared 已挂载, 劫持本身已生效)"
echo "  2. 在那台设备上对比劫持前后的出口 IP: curl https://api.ipify.org"
echo "  3. 访问一个直连不通的站点 (如 https://www.google.com), 应当可以打开"
EOS

adb push "$TMP/devcheck.sh" /data/local/tmp/sbx-devcheck.sh >/dev/null
STATUS=0
adb shell "su -c 'sh /data/local/tmp/sbx-devcheck.sh'" || STATUS=$?
adb shell "su -c 'rm -f /data/local/tmp/sbx-devcheck.sh'" || true
exit $STATUS
