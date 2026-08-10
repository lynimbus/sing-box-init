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
    { "type": "ebpf", "tag": "ebpf-in", "dns_mode": "hijack" }
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

echo "== 白名单注入验证 =="
GEN="$T/data/conf.d.generated/config.json"
python3 - "$GEN" <<'PY'
import json, sys
cfg = json.load(open(sys.argv[1]))
ip = cfg["inbounds"][0].get("include_package")
assert ip == ["com.example.app1", "com.example.app2"], f"注入失败: {ip}"
print("include_package 已注入 ✓:", ip)
PY

echo "== 看门狗日志 =="
cat "$T/data/logs/watchdog.log"

echo "== status (运行中) =="
SBX status
grep -q "^description=sing-box: 运行中" "$T/module/module.prop" && echo "module.prop 描述已更新 ✓" || { echo "FAIL: 描述未更新"; cat "$T/module/module.prop"; exit 1; }

echo "== 模拟禁用模块 (disable 标记) =="
touch "$T/module/disable"
sleep 4   # 看门狗 3 秒轮询
kill -0 "$SPID" 2>/dev/null && { echo "FAIL: 禁用后 sing-box 还在跑"; exit 1; }
echo "禁用后 sing-box 已停 ✓ (看门狗仍存活)"
kill -0 "$WPID" 2>/dev/null && echo "看门狗保持存活 ✓" || { echo "FAIL: 看门狗也死了"; exit 1; }

echo "== 重新启用 =="
rm "$T/module/disable"
sleep 4
SPID2=$(cat "$T/data/sing-box.pid" 2>/dev/null || echo 无)
[ "$SPID2" = 无 ] && { echo "FAIL: 重新启用后未拉起 sing-box"; exit 1; }
kill -0 "$SPID2" 2>/dev/null && echo "重新启用后 sing-box 自动拉起 ✓ (新 pid $SPID2)" || { echo "FAIL: 新 sing-box 未存活"; exit 1; }

echo "== stop (卸载路径) =="
SBX stop
sleep 1
[ -f "$T/data/sing-box.pid" ] && { echo "FAIL: pid 文件残留"; exit 1; }
[ -f "$T/data/sing-box-watchdog.pid" ] && { echo "FAIL: watchdog pid 残留"; exit 1; }
echo "stop 后 pid 文件已清理 ✓"
SBX status

echo ""
echo "=== 端到端测试全部通过 ==="
