#!/system/bin/sh
# sing-box-init 守护进程引擎 (内部脚本, 不面向用户)
# 由 service.sh (开机自启) / action.sh (开关) / uninstall.sh (卸载) 调用
# 子命令: start|stop|restart|toggle|status|update_desc|watchdog_loop

MODDIR=$(cd "${0%/*}" && pwd)
[ -f "$MODDIR/module.prop" ] || MODDIR=/data/adb/modules/sing-box-init

BIN="$MODDIR/bin/sing-box"
DATA_DIR=${SING_BOX_DATA_DIR:-/data/adb/sing-box}
CONFIG="$DATA_DIR/config.json"
# 配置目录模式 (-C): 合并 conf.d/ 下所有 json, 排除规则等独立文件丢进 conf.d/ 即可, 不用改脚本
CONF_DIR="$DATA_DIR/conf.d"
LOG_DIR="$DATA_DIR/logs"
PIDFILE="$DATA_DIR/sing-box.pid"
WPIDFILE="$DATA_DIR/sing-box-watchdog.pid"
STOPFLAG="$DATA_DIR/.stop"
RESTART_DELAY=3

export KSU_MODULE=${KSU_MODULE:-sing-box-init}

mkdir -p "$LOG_DIR" "$CONF_DIR"

log() { echo "$(date '+%F %T') [$1] $2" >> "$LOG_DIR/watchdog.log"; }

# 进程是否真的存活: /proc/PID/cmdline 含 sing-box (防止陈旧 pid 误判)
pid_alive() {
    [ -n "$1" ] || return 1
    grep -q 'sing-box' "/proc/$1/cmdline" 2>/dev/null
}

proc_alive() { pid_alive "$(cat "$1" 2>/dev/null)"; }
running() { proc_alive "$PIDFILE"; }
watchdog_alive() { proc_alive "$WPIDFILE"; }

# 把运行状态写进模块描述, KernelSU Manager 的模块卡片上直接可见
update_desc() {
    PID=$(cat "$PIDFILE" 2>/dev/null)
    if pid_alive "$PID"; then
        st="运行中 (pid $PID)"
    elif watchdog_alive; then
        st="重启中 (看门狗存活)"
    else
        st="未运行"
    fi
    if command -v ksud >/dev/null 2>&1; then
        ksud module config set override.description "sing-box: $st" 2>/dev/null
    fi
    # 同步写 module.prop 的 description 行: 兼容直接读 module.prop 的 Manager 实现
    sed -i "s/^description=.*/description=sing-box: $st/" "$MODDIR/module.prop" 2>/dev/null
}

stop() {
    touch "$STOPFLAG"
    if running; then
        PID=$(cat "$PIDFILE")
        log INFO "stopping sing-box (pid $PID)"
        kill -TERM "$PID" 2>/dev/null
        i=0
        while [ "$i" -lt 10 ] && running; do
            sleep 1
            i=$((i + 1))
        done
        if running; then
            log WARN "graceful stop timed out, forcing kill"
            kill -KILL "$PID" 2>/dev/null
        fi
    fi
    rm -f "$PIDFILE"
    log INFO "sing-box stopped"
    update_desc
}

# 看门狗: 循环拉起 sing-box, 对应 systemd 的 Restart=always
watchdog_loop() {
    cd "$DATA_DIR" || exit 1
    echo "$$" > "$WPIDFILE"
    while :; do
        [ -f "$STOPFLAG" ] && { rm -f "$STOPFLAG"; break; }
        # 目录模式 (-C): conf.d/config.json 缺主配置时从旧位置自动迁移一份
        if [ ! -f "$CONF_DIR/config.json" ] && [ -f "$CONFIG" ]; then
            cp -f "$CONFIG" "$CONF_DIR/config.json" 2>/dev/null
        fi
        if [ -f "$CONF_DIR/config.json" ]; then
            "$BIN" run -C "$CONF_DIR" >> "$LOG_DIR/sing-box.log" 2>&1 &
        else
            "$BIN" run -c "$CONFIG" >> "$LOG_DIR/sing-box.log" 2>&1 &
        fi
        PID=$!
        echo "$PID" > "$PIDFILE"
        log INFO "sing-box started (pid $PID)"
        update_desc
        wait "$PID"
        RC=$?
        if [ -f "$STOPFLAG" ]; then
            rm -f "$STOPFLAG"
            break
        fi
        log WARN "sing-box exited unexpectedly (rc=$RC), restarting in ${RESTART_DELAY}s"
        sleep "$RESTART_DELAY"
    done
    rm -f "$PIDFILE" "$WPIDFILE"
    update_desc
}

start() {
    [ -x "$BIN" ] || { log ERROR "binary not found or not executable: $BIN"; exit 1; }
    [ -f "$CONFIG" ] || { log ERROR "config not found: $CONFIG"; exit 1; }
    if watchdog_alive || running; then
        log INFO "already running, skip"
        update_desc
        return 0
    fi
    rm -f "$STOPFLAG"
    log INFO "starting sing-box via watchdog"
    # setsid + 重定向 + </dev/null: 脱离调用方会话, 否则 su/action 会话结束时看门狗会被一起杀掉
    # 用 sh 调用自身, 不依赖可执行位 (安装后脚本可能没有 +x)
    setsid sh "$MODDIR/daemon.sh" watchdog_loop </dev/null >> "$LOG_DIR/watchdog.log" 2>&1 &
    # 等看门狗真正把 sing-box 拉起来再写描述, 避免状态尚未生效就更新
    i=0
    while [ "$i" -lt 5 ] && ! watchdog_alive && ! running; do
        sleep 1
        i=$((i + 1))
    done
    update_desc
}

status() {
    if running; then
        echo "sing-box 运行中 (pid $(cat "$PIDFILE"))"
    elif watchdog_alive; then
        echo "sing-box 重启中 (看门狗存活)"
    else
        echo "sing-box 未运行"
    fi
}

# Action 按钮开关: 未运行 -> 启动; 运行中/重启中 -> 停止
toggle() {
    status
    if running || watchdog_alive; then
        echo "sing-box 停止中..."
        stop
    else
        echo "sing-box 启动中..."
        start
    fi
    status
}

case "$1" in
    start) start ;;
    stop) stop ;;
    restart) stop; start ;;
    toggle) toggle ;;
    status) status ;;
    update_desc) update_desc ;;
    watchdog_loop) watchdog_loop ;;
    *)
        echo "usage: $0 {start|stop|restart|toggle|status}" >&2
        exit 1
        ;;
esac
exit 0
