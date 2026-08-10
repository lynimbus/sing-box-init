#!/system/bin/sh
# sing-box-init 守护进程引擎 (内部脚本, 不面向用户)
# 由 service.sh (开机自启) / action.sh (重启) / uninstall.sh (卸载) 调用
# 运行开关 = 模块开关: Manager 里禁用模块 -> 停止 sing-box; 重新启用 -> 自动拉起
# 子命令: start|stop|restart|status|update_desc|watchdog_loop

MODDIR=$(cd "${0%/*}" && pwd)
[ -f "$MODDIR/module.prop" ] || MODDIR=/data/adb/modules/sing-box-init

BIN="$MODDIR/bin/sing-box"
DATA_DIR=${SING_BOX_DATA_DIR:-/data/adb/sing-box}
CONFIG="$DATA_DIR/config.json"
# 配置目录模式 (-C): 合并 conf.d/ 下所有 json (数组追加, 勿重复定义同 tag 的 inbound/outbound), 独立配置丢进 conf.d/ 即可, 不用改脚本
CONF_DIR="$DATA_DIR/conf.d"
# 生成目录: whitelist.sh 把 include_package 白名单注入后的配置写到此处, sing-box 用 -C 加载它 (不改用户配置原文)
GEN_DIR="$DATA_DIR/conf.d.generated"
LOG_DIR="$DATA_DIR/logs"
PIDFILE="$DATA_DIR/sing-box.pid"
WPIDFILE="$DATA_DIR/sing-box-watchdog.pid"
STOPFLAG="$DATA_DIR/.stop"
RESTART_DELAY=3
# 看门狗轮询间隔 (秒): 每轮检查 sing-box 存活与模块开关状态
MONITOR_INTERVAL=3

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

# 模块开关状态: KernelSU/Magisk 的 Manager 禁用模块 = 在模块目录创建 disable 标记文件
# (ksud 源码 disable_module/enable_module 确认: 只建/删这个文件, 不执行任何脚本)
# remove 标记表示待卸载; 模块目录不存在 (已卸载) 也视为停止
module_disabled() {
    [ -d "$MODDIR" ] || return 0
    [ -f "$MODDIR/disable" ] && return 0
    [ -f "$MODDIR/remove" ]
}

# 把运行状态写进模块描述, KernelSU Manager 的模块卡片上直接可见
update_desc() {
    PID=$(cat "$PIDFILE" 2>/dev/null)
    if pid_alive "$PID"; then
        st="运行中 (pid $PID)"
    elif module_disabled; then
        st="未运行 (模块已禁用)"
    elif watchdog_alive; then
        st="未运行 (看门狗待命)"
    else
        st="未运行"
    fi
    if command -v ksud >/dev/null 2>&1; then
        ksud module config set override.description "sing-box: $st" 2>/dev/null
    fi
    # 同步写 module.prop 的 description 行: 兼容直接读 module.prop 的 Manager 实现
    sed -i "s/^description=.*/description=sing-box: $st/" "$MODDIR/module.prop" 2>/dev/null
}

# 显式停止 (仅卸载用): 结束 sing-box 和看门狗, 不留常驻监听进程
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
    if watchdog_alive; then
        WPID=$(cat "$WPIDFILE")
        log INFO "stopping watchdog (pid $WPID)"
        kill -TERM "$WPID" 2>/dev/null
        i=0
        while [ "$i" -lt 5 ] && watchdog_alive; do
            sleep 1
            i=$((i + 1))
        done
        if watchdog_alive; then
            log WARN "watchdog did not exit, forcing kill"
            kill -KILL "$WPID" 2>/dev/null
        fi
    fi
    rm -f "$WPIDFILE" "$STOPFLAG"
    log INFO "sing-box stopped"
    update_desc
}

# 看门狗: 常驻监听, 模块开关状态决定 sing-box 启停, 运行中崩溃自动重启 (对应 Restart=always)
watchdog_loop() {
    cd "$DATA_DIR" || exit 1
    echo "$$" > "$WPIDFILE"
    while :; do
        # 显式停止标记 (uninstall.sh 触发) -> 看门狗退出
        [ -f "$STOPFLAG" ] && { rm -f "$STOPFLAG"; break; }
        if module_disabled; then
            # 模块被禁用/卸载 -> 停止 sing-box; 看门狗保持存活, 监听模块重新启用
            if running; then
                PID=$(cat "$PIDFILE")
                log INFO "module disabled, stopping sing-box (pid $PID)"
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
                rm -f "$PIDFILE"
            fi
            update_desc
            # 轮询等待模块重新启用 (或收到显式停止)
            while :; do
                [ -f "$STOPFLAG" ] && { rm -f "$STOPFLAG"; break 2; }
                module_disabled || break
                sleep "$MONITOR_INTERVAL"
            done
            continue
        fi
        # 模块启用: 确保 sing-box 在运行
        if ! running; then
            # 目录模式 (-C): conf.d/config.json 缺主配置时从旧位置自动迁移一份
            if [ ! -f "$CONF_DIR/config.json" ] && [ -f "$CONFIG" ]; then
                cp -f "$CONFIG" "$CONF_DIR/config.json" 2>/dev/null
            fi
            if [ -f "$CONF_DIR/config.json" ]; then
                # 白名单生成: 读 include_package 纯文本 -> 有 ebpf 入站则注入入站, 否则写路由规则
                # 输出到 GEN_DIR 再以 -C 启动; 生成失败 (awk 异常等) 回退直接用原始 conf.d
                if [ ! -f "$DATA_DIR/include_package" ] && [ -f "$DATA_DIR/include_package.disable" ]; then
                    log INFO "whitelist disabled (include_package renamed to .disable), config loaded as-is"
                fi
                if sh "$MODDIR/whitelist.sh" "$CONF_DIR" "$GEN_DIR" "$DATA_DIR/include_package"; then
                    "$BIN" run -C "$GEN_DIR" >> "$LOG_DIR/sing-box.log" 2>&1 &
                else
                    log WARN "whitelist generation failed, fallback to raw conf.d"
                    "$BIN" run -C "$CONF_DIR" >> "$LOG_DIR/sing-box.log" 2>&1 &
                fi
            else
                "$BIN" run -c "$CONFIG" >> "$LOG_DIR/sing-box.log" 2>&1 &
            fi
            PID=$!
            echo "$PID" > "$PIDFILE"
            log INFO "sing-box started (pid $PID)"
            update_desc
        fi
        # 监控: 每轮检查 sing-box 存活与模块开关状态
        while running && ! module_disabled && [ ! -f "$STOPFLAG" ]; do
            sleep "$MONITOR_INTERVAL"
        done
        [ -f "$STOPFLAG" ] && { rm -f "$STOPFLAG"; break; }
        if module_disabled; then
            continue
        fi
        # 到这里: sing-box 意外退出且模块仍启用 -> 崩溃重启
        log WARN "sing-box exited unexpectedly, restarting in ${RESTART_DELAY}s"
        sleep "$RESTART_DELAY"
    done
    rm -f "$PIDFILE" "$WPIDFILE"
    update_desc
}

start() {
    [ -x "$BIN" ] || { log ERROR "binary not found or not executable: $BIN"; exit 1; }
    if [ ! -f "$CONF_DIR/config.json" ] && [ ! -f "$CONFIG" ]; then
        log ERROR "config not found: $CONFIG"
        exit 1
    fi
    if watchdog_alive; then
        log INFO "watchdog already running, skip"
        update_desc
        return 0
    fi
    rm -f "$STOPFLAG"
    log INFO "starting watchdog"
    # setsid + 重定向 + </dev/null: 脱离调用方会话, 否则 su/action 会话结束时看门狗会被一起杀掉
    # 用 sh 调用自身, 不依赖可执行位 (安装后脚本可能没有 +x)
    setsid sh "$MODDIR/daemon.sh" watchdog_loop </dev/null >> "$LOG_DIR/watchdog.log" 2>&1 &
    # 等看门狗起来; 模块启用时再等 sing-box 真正拉起, 避免状态尚未生效就写描述 (竞态: 见 AGENTS.md)
    i=0
    while [ "$i" -lt 5 ] && ! watchdog_alive; do
        sleep 1
        i=$((i + 1))
    done
    i=0
    while [ "$i" -lt 5 ] && watchdog_alive && ! module_disabled && ! running; do
        sleep 1
        i=$((i + 1))
    done
    update_desc
}

status() {
    if running; then
        echo "sing-box 运行中 (pid $(cat "$PIDFILE"))"
    elif module_disabled; then
        echo "sing-box 未运行 (模块已禁用)"
    elif watchdog_alive; then
        echo "sing-box 未运行 (看门狗待命)"
    else
        echo "sing-box 未运行"
    fi
}

case "$1" in
    start) start ;;
    stop) stop ;;
    restart) stop; start ;;
    status) status ;;
    update_desc) update_desc ;;
    watchdog_loop) watchdog_loop ;;
    *)
        echo "usage: $0 {start|stop|restart|status|update_desc|watchdog_loop}" >&2
        exit 1
        ;;
esac
exit 0
