#!/bin/sh
# 本机端到端测试: Go 守护进程 + stub sing-box, 在 /tmp 下跑完整生命周期与故障注入
# 覆盖: 启停/开关/崩溃自愈/配置热重载/非法配置拒绝/看门狗自愈/日志截断
# 用法: ./test_local.sh
set -e

ROOT=$(cd "$(dirname "$0")" && pwd)
T=${SBX_TEST_DIR:-/tmp/sbx-e2e}
PASS=0

say() { echo ""; echo "== $* =="; }
ok() { PASS=$((PASS + 1)); echo "  ✓ $*"; }
fail() { echo "  ✗ FAIL: $*"; echo "--- watchdog.log ---"; cat "$T/data/logs/watchdog.log" 2>/dev/null | tail -40; exit 1; }

proc_state() { sed -e 's/^.*) //' "/proc/$1/stat" 2>/dev/null | cut -d' ' -f1; }
alive() { s=$(proc_state "$1"); [ -n "$s" ] && [ "$s" != "Z" ]; }
SBX() { SING_BOX_DATA_DIR="$T/data" "$T/module/bin/sing-box-init" "$@"; }
core_pid() { cat "$T/data/sing-box.pid" 2>/dev/null; }
wd_pid() { cat "$T/data/sing-box-watchdog.pid" 2>/dev/null; }
state_field() { sed -n "s/^$1=//p" "$T/data/logs/watchdog.state" 2>/dev/null; }

# 用 argv 精确统计存活的内核个数 (不看 pid 文件; 脚本内核的路径在 argv[1])
count_cores() {
    ps -eo args= 2>/dev/null | awk -v p="$T/module/bin/sing-box" '{ if ($1 == p || $2 == p) n++ } END { print n + 0 }'
}

wait_count() {
    i=0
    while [ "$i" -lt 100 ]; do
        [ "$(count_cores)" = "$1" ] && return 0
        sleep 0.1
        i=$((i + 1))
    done
    return 1
}

wait_pid_change() {
    i=0
    while [ "$i" -lt 100 ]; do
        now=$(core_pid)
        [ -n "$now" ] && [ "$now" != "$1" ] && return 0
        sleep 0.1
        i=$((i + 1))
    done
    return 1
}

wait_pid_dead() {
    i=0
    while [ "$i" -lt 100 ]; do
        alive "$1" || return 0
        sleep 0.1
        i=$((i + 1))
    done
    return 1
}

echo "单元测试 (go test)..."
(cd "$ROOT" && go test ./...)

# 清理上一次运行的残留 (先 TERM 再 KILL; 内核可能正忽略 TERM; 不用 pkill -f, 模式会匹配到自己)
for f in "$T/data/sing-box.pid" "$T/data/sing-box-watchdog.pid"; do
    [ -f "$f" ] && kill "$(cat "$f" 2>/dev/null)" 2>/dev/null || true
done
sleep 2
for f in "$T/data/sing-box.pid" "$T/data/sing-box-watchdog.pid"; do
    [ -f "$f" ] && kill -9 "$(cat "$f" 2>/dev/null)" 2>/dev/null || true
done
# pid 文件也掉了的孤儿内核: 直接按 argv 找出来清掉
ps -eo pid=,args= 2>/dev/null | awk -v p="$T/module/bin/sing-box" '{ if ($2 == p || $3 == p) print $1 }' | while read -r pid; do
    kill -9 "$pid" 2>/dev/null || true
done
sleep 0.5
rm -rf "$T"
mkdir -p "$T/module/bin" "$T/data/conf.d"

echo "编译本机版..."
(cd "$ROOT" && go build -o "$T/module/bin/sing-box-init" ./src)

cat >"$T/module/module.prop" <<'EOF'
id=sing-box-init
name=sing-box init
version=test
versionCode=0
description=让 sing-box 内核像 systemd 服务一样持久运行
EOF

# stub sing-box: version / check / run 三个子命令
cat >"$T/module/bin/sing-box" <<EOF
#!/bin/sh
case "\$1" in
  version)
    if [ "$2" = "-n" ]; then echo "stub-1.0.0"; else echo "sing-box version stub-1.0.0"; fi
    exit 0 ;;
  check)
    if ls "$T/data/conf.d"/bad*.json >/dev/null 2>&1; then
      echo "FATAL decode config: unknown field"
      exit 1
    fi
    exit 0 ;;
  run)
    if [ -f "$T/data/ignore-term" ]; then trap '' TERM; else trap 'exit 0' TERM; fi
    while true; do sleep 1; done ;;
esac
exit 0
EOF
chmod 0755 "$T/module/bin/sing-box"

cat >"$T/data/conf.d/config.json" <<'EOF'
{
  "inbounds": [ { "type": "ebpf", "tag": "ebpf-in", "mode": "hybrid" } ],
  "outbounds": [ { "type": "direct", "tag": "direct" } ]
}
EOF

say "status (未启动)"
SBX status

say "start"
SBX start
WPID=$(wd_pid)
SPID=$(core_pid)
[ -n "$WPID" ] && alive "$WPID" || fail "看门狗未启动"
ok "看门狗已启动 (pid $WPID)"
[ -n "$SPID" ] && alive "$SPID" || fail "sing-box 未启动"
ok "sing-box 已启动 (pid $SPID)"
[ "$(state_field state)" = "running" ] && ok "状态文件 state=running" || fail "状态文件不对: $(cat "$T/data/logs/watchdog.state" 2>/dev/null)"
grep -q "^description=sing-box: 运行中" "$T/module/module.prop" && ok "module.prop 描述已更新" || fail "描述未更新"
grep -q "core stub-1.0.0" "$T/module/module.prop" && ok "描述含核心版本" || fail "描述缺核心版本"

say "配置热重载 (改 conf.d/*.json)"
OLD=$SPID
printf '{\n  "inbounds": [ { "type": "ebpf", "tag": "ebpf-in", "mode": "local" } ],\n  "outbounds": [ { "type": "direct", "tag": "direct" } ]\n}\n' >"$T/data/conf.d/config.json"
wait_pid_change "$OLD" || fail "配置变化后未重启"
NEW=$(core_pid)
ok "配置变化触发重启 ($OLD → $NEW)"
wait_pid_dead "$OLD" || fail "旧内核进程未消失"
ok "旧内核进程已消失"
sleep 3
[ "$(core_pid)" = "$NEW" ] && ok "重启后稳定, 无重启循环" || fail "出现重启循环"

say "非法配置: 拒绝重启并保留旧内核"
OLD=$NEW
printf '{"bad": true}\n' >"$T/data/conf.d/bad.json"
sleep 3
[ "$(core_pid)" = "$OLD" ] && alive "$OLD" || fail "非法配置时不应重启内核"
ok "旧内核仍在运行 (pid $OLD), 未被非法配置打断"
grep -q "新配置校验失败" "$T/data/logs/watchdog.log" || fail "日志缺少配置校验失败记录"
ok "日志记录了配置校验失败"
grep -q "配置错误" "$T/module/module.prop" && ok "描述标出配置错误" || fail "描述未标出配置错误"

say "撤销非法配置: 恢复当前版本, 不重启"
rm -f "$T/data/conf.d/bad.json"
sleep 2
[ "$(core_pid)" = "$OLD" ] && alive "$OLD" || fail "撤销非法配置不应重启内核"
ok "撤销非法配置后内核未被打扰 (pid $OLD)"
grep -q "配置已恢复到当前运行版本" "$T/data/logs/watchdog.log" || fail "未记录配置恢复"
ok "日志记录了配置恢复"
grep -q "配置错误" "$T/module/module.prop" && fail "描述仍标着配置错误" || ok "描述已清掉配置错误标记"

say "换一份合法配置: 重新正常重载"
printf '{\n  "inbounds": [ { "type": "ebpf", "tag": "ebpf-in", "mode": "hybrid" } ],\n  "outbounds": [ { "type": "direct", "tag": "direct" } ]\n}\n' >"$T/data/conf.d/config.json"
wait_pid_change "$OLD" || fail "合法配置变化后未重载"
ok "恢复重载能力 ($OLD → $(core_pid))"

say "崩溃自动恢复 (kill -9 内核)"
OLD=$(core_pid)
kill -9 "$OLD"
wait_pid_dead "$OLD" || fail "被 kill -9 的内核仍在"
wait_pid_change "$OLD" || fail "崩溃后未自动拉起"
NEW=$(core_pid)
alive "$NEW" || fail "恢复后的内核未存活"
ok "崩溃后自动恢复 ($OLD → $NEW)"
grep -q "sing-box 意外退出" "$T/data/logs/watchdog.log" || fail "日志无意外退出记录"
ok "日志记录了意外退出"

say "禁用模块 = 停内核, 看门狗保持存活"
WPID=$(wd_pid)
touch "$T/module/disable"
wait_count 0 || fail "禁用后内核仍在运行 (实测 $(count_cores) 个)"
ok "禁用后内核已停 (ps 实测 0 个)"
alive "$WPID" || fail "看门狗不应随禁用消失"
ok "看门狗保持存活 (pid $WPID)"

say "重新启用"
rm -f "$T/module/disable"
wait_count 1 || fail "启用后内核未拉起"
ok "启用后内核自动拉起 (pid $(core_pid))"

say "看门狗被 kill -9: 内核成为孤儿, 重新拉起看门狗必须接管并清理"
WPID=$(wd_pid)
SPID=$(core_pid)
kill -9 "$WPID"
wait_pid_dead "$WPID" || fail "看门狗未被杀死"
alive "$SPID" || fail "内核不应随看门狗一起死 (孤儿化)"
ok "看门狗已死, 内核孤儿仍在 (这类残留只能靠 Action/重启收敛)"
SBX status | grep -q "看门狗未运行" && ok "status 指出看门狗未运行" || fail "status 未指出看门狗缺失"
SBX start
WPID=$(wd_pid)
[ -n "$WPID" ] && alive "$WPID" || fail "重新拉起后看门狗未存活"
ok "看门狗已重新拉起 (pid $WPID)"
grep -q "发现无人看管的内核进程" "$T/data/logs/watchdog.log" || fail "未走看门狗的孤儿清理路径"
ok "日志记录了孤儿内核清理"
wait_count 1 || fail "清理后内核数量不是 1 (实测 $(count_cores) 个)"
ok "孤儿已清理, 只剩 1 个内核 (pid $(core_pid))"

say "内核拒绝 SIGTERM 时必须升级为 SIGKILL"
touch "$T/data/ignore-term"
SBX restart
wait_count 1 || fail "ignore-term 内核未起来"
IGNORING=$(core_pid)
ok "已启动一个忽略 TERM 的内核 (pid $IGNORING)"
SBX restart
wait_pid_dead "$IGNORING" || fail "拒绝 SIGTERM 的旧内核未被强杀"
ok "旧内核最终被杀死 ($IGNORING)"
grep -q "发送 SIGKILL" "$T/data/logs/watchdog.log" || fail "日志缺少 SIGKILL 升级记录"
ok "日志有 SIGKILL 升级记录"
rm -f "$T/data/ignore-term"
wait_count 1 || fail "强杀后新内核未起来"
ok "restart 完成, 新内核在跑 (pid $(core_pid))"

say "日志自动截断 (>1MiB 由看门狗清空)"
dd if=/dev/zero bs=1024 count=1025 2>/dev/null | tr '\0' 'x' >>"$T/data/logs/sing-box.log"
sleep 2
SIZE=$(wc -c <"$T/data/logs/sing-box.log")
[ "$SIZE" -lt 1024 ] && ok "sing-box.log 已截断 (${SIZE} 字节)" || fail "sing-box.log 未截断 (${SIZE} 字节)"

say "看门狗 panic 自愈 (测试用 SING_BOX_INIT_TEST_PANIC)"
SBX stop
rm -f "$T/data/.watchdog-selfheal"
SING_BOX_INIT_TEST_PANIC=6 SING_BOX_DATA_DIR="$T/data" "$T/module/bin/sing-box-init" start
sleep 8
grep -q "看门狗 panic" "$T/data/logs/watchdog.log" || fail "未触发 panic 自愈"
ok "检测到 panic 并自愈"
WPID=$(wd_pid)
[ -n "$WPID" ] && alive "$WPID" || fail "自愈后看门狗未存活"
ok "自愈后看门狗存活 (pid $WPID, exec 保持 pid 不变)"
wait_count 1 || fail "自愈后内核数量异常 (实测 $(count_cores) 个)"
ok "自愈后只剩 1 个内核, 无累积"

say "stop"
SBX stop
sleep 1
wait_count 0 || fail "stop 后内核仍在运行"
ok "stop 后零内核 (ps 实测)"
[ -f "$T/data/sing-box.pid" ] && fail "pid 文件残留" || ok "pid 文件已清理"
[ -f "$T/data/sing-box-watchdog.pid" ] && fail "看门狗 pid 文件残留" || ok "看门狗 pid 文件已清理"
SBX status

echo ""
echo "=== 端到端测试全部通过 ($PASS 项断言) ==="
