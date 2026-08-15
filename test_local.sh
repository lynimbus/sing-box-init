#!/bin/sh
# 本机端到端测试: 用真实 zig 二进制 + stub sing-box 在 /tmp 下模拟整个模块生命周期
# 用法: ./test_local.sh   (先 zig build 出本机版二进制)
set -e

ROOT=$(cd "$(dirname "$0")" && pwd)
ZIG_OUT="$ROOT/zig-out/bin/sing-box-init"
# 重建本机版 (build.sh 交叉编译后 zig-out 里是 aarch64 二进制, 本机跑不了)
echo "编译本机版 (zig build)..."
(cd "$ROOT" && zig build) || { echo "zig build 失败"; exit 1; }
[ -x "$ZIG_OUT" ] || { echo "缺少 zig-out/bin/sing-box-init"; exit 1; }

T=/tmp/sbx-e2e
# 清理上一次测试残留的进程 (先读旧 pid 文件再删, 避免误杀)
for f in "$T"/data/*.pid; do
    [ -f "$f" ] && kill "$(cat "$f" 2>/dev/null)" 2>/dev/null || true
done
sleep 0.5
rm -rf "$T"
mkdir -p "$T/module/bin" "$T/data/conf.d"
cp "$ZIG_OUT" "$T/module/bin/sing-box-init"
chmod 0755 "$T/module/bin/sing-box-init"

# stub sing-box: 长驻进程, 路径含 sing-box → /proc 存活检查可命中
cat > "$T/module/bin/sing-box" <<'EOF'
#!/bin/sh
# stub: 模拟 sing-box 内核长驻 (参数原样忽略)
while true; do sleep 10; done
EOF
chmod 0755 "$T/module/bin/sing-box"

cat > "$T/module/module.prop" <<'EOF'
id=sing-box-init
name=sing-box init (zig)
version=test
versionCode=0
description=让 sing-box 内核像 systemd 服务一样持久运行
EOF

cat > "$T/data/conf.d/config.json" <<'EOF'
{
  "log": { "level": "info", "timestamp": true },
  "inbounds": [
    { "type": "tun", "tag": "tun-in", "auto_route": true, "stack": "system" }
  ],
  "outbounds": [ { "type": "direct", "tag": "direct" } ]
}
EOF

cat > "$T/data/include_package" <<'EOF'
# 白名单: 走代理的应用
com.example.app1
com.example.app2
EOF

SBX() { SING_BOX_DATA_DIR="$T/data" "$T/module/bin/sing-box-init" "$@"; }

echo "== status (未启动) =="
SBX status

echo "== start =="
SBX start
sleep 1
WPID=$(cat "$T/data/sing-box-watchdog.pid" 2>/dev/null || echo 无)
SPID=$(cat "$T/data/sing-box.pid" 2>/dev/null || echo 无)
echo "看门狗 pid: $WPID, sing-box(stub) pid: $SPID"
[ "$WPID" = 无 ] && { echo "FAIL: 看门狗未启动"; exit 1; }
[ "$SPID" = 无 ] && { echo "FAIL: sing-box 未启动"; exit 1; }
kill -0 "$WPID" 2>/dev/null && echo "看门狗进程存活 ✓" || { echo "FAIL: 看门狗已死"; exit 1; }
kill -0 "$SPID" 2>/dev/null && echo "sing-box(stub) 进程存活 ✓" || { echo "FAIL: sing-box 已死"; exit 1; }

echo "== 白名单路由规则验证 =="
GEN_RULES="$T/data/conf.d.generated/00-include-package.json"
python3 - "$GEN_RULES" <<'PY'
import json, sys
rules = json.load(open(sys.argv[1]))
rule = rules["route"]["rules"][0]
assert rule["action"] == "route", f"action 错误: {rule}"
pkgs = rule["package_name"]
assert pkgs == ["com.example.app1", "com.example.app2"], f"路由规则错误: {pkgs}"
print("路由规则已生成 ✓:", pkgs)
PY
# 原配置保持原样 (不再注入 ebpf 字段)
python3 - "$T/data/conf.d.generated/config.json" <<'PY'
import json, sys
cfg = json.load(open(sys.argv[1]))
assert "include_package" not in json.dumps(cfg), "配置不应被改写"
print("原配置保持原样 ✓ (无 include_package 注入)")
PY

echo "== 看门狗日志 =="
cat "$T/data/logs/watchdog.log"

echo "== status (运行中) =="
SBX status
grep -q "^description=sing-box: 运行中" "$T/module/module.prop" && echo "module.prop 描述已更新 ✓" || { echo "FAIL: 描述未更新"; cat "$T/module/module.prop"; exit 1; }

echo "== 模拟禁用模块 (disable 标记, 事件驱动 <1s) =="
touch "$T/module/disable"
sleep 2   # inotify 事件驱动, 比旧版 3 秒轮询快得多
kill -0 "$SPID" 2>/dev/null && { echo "FAIL: 禁用后 sing-box 还在跑"; exit 1; }
echo "禁用后 sing-box 已停 ✓ (看门狗仍存活)"
kill -0 "$WPID" 2>/dev/null && echo "看门狗保持存活 ✓" || { echo "FAIL: 看门狗也死了"; exit 1; }

echo "== 重新启用 =="
rm "$T/module/disable"
sleep 4
SPID2=$(cat "$T/data/sing-box.pid" 2>/dev/null || echo 无)
[ "$SPID2" = 无 ] && { echo "FAIL: 重新启用后未拉起 sing-box"; exit 1; }
kill -0 "$SPID2" 2>/dev/null && echo "重新启用后 sing-box 自动拉起 ✓ (新 pid $SPID2)" || { echo "FAIL: 新 sing-box 未存活"; exit 1; }

echo "== 崩溃自动恢复 (kill -9, signalfd 即时检测) =="
CRASH_PID=$(cat "$T/data/sing-box.pid")
kill -9 "$CRASH_PID"
sleep 1   # signalfd 事件驱动: 崩溃 1 秒内应被检测并记录
grep -q "exited unexpectedly" "$T/data/logs/watchdog.log" && echo "崩溃即时检测 ✓ (<1s)" || { echo "FAIL: 崩溃未及时检测"; exit 1; }
sleep 5   # 退避 3s + 拉起
RECOVER_PID=$(cat "$T/data/sing-box.pid" 2>/dev/null || echo 无)
[ "$RECOVER_PID" = 无 ] && { echo "FAIL: 崩溃后未自动拉起"; exit 1; }
[ "$CRASH_PID" = "$RECOVER_PID" ] && { echo "FAIL: pid 未变化"; exit 1; }
kill -0 "$RECOVER_PID" 2>/dev/null || { echo "FAIL: 恢复后的 sing-box 未存活"; exit 1; }
echo "崩溃后自动恢复 ✓ (pid $CRASH_PID → $RECOVER_PID)"

echo "== 白名单热重载 (改 include_package, 无需手动重启) =="
OLD_PID=$(cat "$T/data/sing-box.pid")
printf 'com.example.app1\ncom.example.app3\n' > "$T/data/include_package"
sleep 2   # inotify 捕获变化 → 自动 restart
NEW_PID=$(cat "$T/data/sing-box.pid")
[ "$OLD_PID" = "$NEW_PID" ] && { echo "FAIL: 热重载后 pid 未变 (sing-box 未重启)"; exit 1; }
kill -0 "$NEW_PID" 2>/dev/null || { echo "FAIL: 热重载后的 sing-box 未存活"; exit 1; }
echo "热重载触发重启 ✓ (pid $OLD_PID → $NEW_PID)"
python3 - "$T/data/conf.d.generated/00-include-package.json" <<'PY'
import json, sys
rules = json.load(open(sys.argv[1]))
rule = rules["route"]["rules"][0]
pkgs = rule["package_name"]
assert pkgs == ["com.example.app1", "com.example.app3"], f"热重载路由规则错误: {pkgs}"
print("新白名单已生效 ✓:", pkgs)
PY
grep -q "sing-box started" "$T/data/logs/watchdog.log" && echo "看门狗日志有重启记录 ✓"

echo "== 配置热重载 (改 conf.d/config.json, 无需手动重启) =="
OLD_PID=$(cat "$T/data/sing-box.pid")
sed -i 's/"stack": "system"/"stack": "gvisor"/' "$T/data/conf.d/config.json"
sleep 3   # 去抖 0.8s + 重启
NEW_PID=$(cat "$T/data/sing-box.pid")
[ "$OLD_PID" = "$NEW_PID" ] && { echo "FAIL: 配置热重载后 pid 未变"; exit 1; }
kill -0 "$NEW_PID" 2>/dev/null || { echo "FAIL: 配置热重载后的 sing-box 未存活"; exit 1; }
echo "配置热重载触发重启 ✓ (pid $OLD_PID → $NEW_PID)"
grep -q "gvisor" "$T/data/conf.d.generated/config.json" && echo "新配置已注入生成目录 ✓" || { echo "FAIL: 新配置未生效"; exit 1; }
# 稳定性验证: 热重载后不再反复重启 (生成目录是 watch 盲区, 不会触发自身)
sleep 4
STABLE_PID=$(cat "$T/data/sing-box.pid")
[ "$NEW_PID" = "$STABLE_PID" ] && echo "重启后保持稳定, 无重启循环 ✓" || { echo "FAIL: 出现重启循环 (pid 又变了)"; exit 1; }

echo "== stop (卸载路径) =="
SBX stop
sleep 1
[ -f "$T/data/sing-box.pid" ] && { echo "FAIL: pid 文件残留"; exit 1; }
[ -f "$T/data/sing-box-watchdog.pid" ] && { echo "FAIL: watchdog pid 残留"; exit 1; }
echo "stop 后 pid 文件已清理 ✓"
SBX status

echo ""
echo "=== 端到端测试全部通过 ==="
