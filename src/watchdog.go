package main

import (
	"fmt"
	"os"
	"path/filepath"
	"runtime/debug"
	"strconv"
	"strings"
	"syscall"
	"time"
)

const (
	tickInterval        = 500 * time.Millisecond
	startConfirm        = 5 * time.Second
	stopGrace           = 10 * time.Second
	crashBackoff        = 3 * time.Second
	reloadDebounce      = 800 * time.Millisecond
	blockedRecheck      = 3 * time.Second
	crashResetAfter     = 60 * time.Second
	checkTimeout        = 10 * time.Second
	stateHeartbeat      = 5 * time.Second
	maxSelfHealsPerHour = 5
)

type st int

const (
	stDisabled st = iota
	stStarting
	stRunning
	stStopping
	stCrashBackoff
	stBlocked
	stExiting
)

func (s st) String() string {
	switch s {
	case stDisabled:
		return "disabled"
	case stStarting:
		return "starting"
	case stRunning:
		return "running"
	case stStopping:
		return "stopping"
	case stCrashBackoff:
		return "crash_backoff"
	case stBlocked:
		return "blocked"
	case stExiting:
		return "exiting"
	}
	return "unknown"
}

type ev int

const (
	evNone ev = iota
	evDisableOff
	evDisableOn
	evStopFlag
	evChildExited
	evStartConfirmed
	evTimeout
	evReload
	evUnblocked
)

// transition 是纯函数: 给定当前状态与事件返回下一个状态。
// 关键不变式: 只有真的观测到子进程消失 (evChildExited) 才会离开 Stopping,
// 绝不因为 "已发送 SIGTERM" 就宣布停止完成。
func transition(s st, e ev, restartAfterStop bool) (st, bool) {
	switch s {
	case stDisabled:
		switch e {
		case evDisableOff:
			return stStarting, true
		case evStopFlag:
			return stExiting, true
		}
	case stStarting:
		switch e {
		case evStartConfirmed:
			return stRunning, true
		case evChildExited, evTimeout:
			return stCrashBackoff, true
		case evDisableOn:
			return stStopping, true
		case evStopFlag:
			return stExiting, true
		}
	case stRunning:
		switch e {
		case evChildExited:
			return stCrashBackoff, true
		case evDisableOn, evReload:
			return stStopping, true
		case evStopFlag:
			return stExiting, true
		}
	case stStopping:
		switch e {
		case evChildExited:
			if restartAfterStop {
				return stStarting, true
			}
			return stDisabled, true
		case evStopFlag:
			return stExiting, true
		}
	case stCrashBackoff:
		switch e {
		case evTimeout:
			return stStarting, true
		case evDisableOn:
			return stDisabled, true
		case evStopFlag:
			return stExiting, true
		}
	case stBlocked:
		switch e {
		case evUnblocked:
			return stStarting, true
		case evDisableOn:
			return stDisabled, true
		case evStopFlag:
			return stExiting, true
		}
	}
	return s, false
}

type world struct {
	stopFlag        bool
	moduleDisabled  bool
	childJustExited bool
	childPresent    bool
	childAlive      bool
	deadlinePassed  bool
	startConfirmed  bool
	unblocked       bool
	reloadDue       bool
}

func deriveEvent(s st, w world) (ev, bool) {
	if w.stopFlag {
		return evStopFlag, true
	}
	if w.moduleDisabled && s != stDisabled && s != stStopping {
		return evDisableOn, true
	}
	if s == stDisabled {
		if !w.moduleDisabled {
			return evDisableOff, true
		}
		return evNone, false
	}
	if s == stStopping {
		// 只有当 Wait 真的返回 (childJustExited) 或句柄已不存在时才判死。
		// 进程看着已死但尚未收割时仍然等待, 不靠 /proc 读数宣布停止完成。
		if w.childJustExited || !w.childPresent {
			return evChildExited, true
		}
		return evNone, false
	}
	if w.childJustExited {
		return evChildExited, true
	}
	switch s {
	case stStarting:
		if w.startConfirmed {
			return evStartConfirmed, true
		}
		if w.deadlinePassed {
			return evTimeout, true
		}
	case stRunning:
		if w.reloadDue {
			return evReload, true
		}
	case stCrashBackoff:
		if w.deadlinePassed {
			return evTimeout, true
		}
	case stBlocked:
		if w.unblocked {
			return evUnblocked, true
		}
	}
	return evNone, false
}

type stopAction int

const (
	stopActionNone stopAction = iota
	stopActionKill
	stopActionStuck
)

func stopEscalation(forceKilled bool, deadlinePassed bool, childPresent bool, childAlive bool) stopAction {
	if !childPresent || !childAlive || !deadlinePassed {
		return stopActionNone
	}
	if !forceKilled {
		return stopActionKill
	}
	return stopActionStuck
}

func reloadDue(s st, changeSeenAt time.Time, now time.Time) bool {
	return s == stRunning && !changeSeenAt.IsZero() && now.Sub(changeSeenAt) >= reloadDebounce
}

type watchdog struct {
	a *app

	state       st
	ch          *child
	crashes     int
	coreVersion string
	blockReason string
	lastDesc    string

	fingerprint      string
	spawnFingerprint string
	badFingerprint   string
	changeSeenAt     time.Time

	deadline         time.Time
	forceKilled      bool
	restartAfterStop bool
	coreStartedAt    time.Time
	nextPreflight    time.Time
	unblocked        bool
	testPanicAt      time.Time
	lockFd           int
	lastState        string
	lastStateWrite   time.Time
}

func newWatchdog(a *app) *watchdog {
	w := &watchdog{a: a}
	w.coreVersion = coreVersion(a.bin)
	w.fingerprint = confFingerprint(a.confDir)
	w.spawnFingerprint = w.fingerprint
	if v := os.Getenv("SING_BOX_INIT_TEST_PANIC"); v != "" {
		if secs, err := strconv.Atoi(v); err == nil && secs > 0 {
			w.testPanicAt = time.Now().Add(time.Duration(secs) * time.Second)
		}
	}
	return w
}

func runWatchdog(a *app) {
	lock, err := watchdogLock(a)
	if err != nil {
		a.log("WARN", "已有看门狗实例在运行, 本实例退出")
		return
	}
	_, _ = syscall.Setsid()
	w := newWatchdog(a)
	w.lockFd = int(lock.Fd())
	defer func() {
		if r := recover(); r != nil {
			a.log("ERROR", "看门狗 panic: %v\n%s", r, debug.Stack())
			w.selfHeal()
		}
	}()
	w.run()
}

const lockFdEnv = "SING_BOX_INIT_LOCK_FD"

// watchdogLock 返回持有排他锁的句柄。自愈 re-exec 时锁是随 fd 继承过来的,
// 此时不能再 open+flock: 同一个进程和它自己继承的锁也会相冲突。
// 所以先校验继承来的 fd 确实指向锁文件, 是则直接复用。
func watchdogLock(a *app) (*os.File, error) {
	if v := os.Getenv(lockFdEnv); v != "" {
		_ = os.Unsetenv(lockFdEnv)
		if fd, err := strconv.Atoi(v); err == nil && fd > 0 {
			if target, err := os.Readlink(fmt.Sprintf("/proc/self/fd/%d", fd)); err == nil && target == a.lockFile {
				return os.NewFile(uintptr(fd), a.lockFile), nil
			}
		}
	}
	return acquireLock(a.lockFile)
}

func acquireLock(path string) (*os.File, error) {
	f, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0o644)
	if err != nil {
		return nil, err
	}
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		_ = f.Close()
		return nil, err
	}
	return f, nil
}

func (w *watchdog) run() {
	writeFile(w.a.wpidFile, strconv.Itoa(os.Getpid())+"\n")
	w.a.log("INFO", "看门狗启动 (pid %d, core %s)", os.Getpid(), w.coreVersion)
	w.killOrphanCore()
	w.gotoState(w.initialState())

	ticker := time.NewTicker(tickInterval)
	defer ticker.Stop()
	for {
		exited := w.observeChild()
		w.tick(exited)
		if w.state == stExiting {
			w.cleanup()
			return
		}
		var exitCh <-chan struct{}
		if w.ch != nil {
			exitCh = w.ch.done
		}
		select {
		case <-ticker.C:
		case <-exitCh:
		}
	}
}

func (w *watchdog) initialState() st {
	if w.a.moduleDisabled() {
		return stDisabled
	}
	return stStarting
}

func (w *watchdog) observeChild() bool {
	if w.ch == nil || !w.ch.exited() {
		return false
	}
	pid, err := w.ch.pid, w.ch.err
	w.ch = nil
	removeFile(w.a.pidFile)
	if w.state == stRunning || w.state == stStarting {
		w.crashes++
		w.a.log("WARN", "sing-box 意外退出 (pid %d, %v), 第 %d 次", pid, err, w.crashes)
	} else {
		w.a.log("INFO", "sing-box 已退出 (pid %d, %v)", pid, err)
	}
	return true
}

func (w *watchdog) childPid() int {
	if w.ch == nil {
		return -1
	}
	return w.ch.pid
}

func (w *watchdog) deadlinePassed() bool {
	return !w.deadline.IsZero() && time.Now().After(w.deadline)
}

func (w *watchdog) tick(exited bool) {
	if !w.testPanicAt.IsZero() && time.Now().After(w.testPanicAt) {
		panic("SING_BOX_INIT_TEST_PANIC")
	}
	truncateIfLarger(w.a.singboxLog, logMaxBytes)

	w.fingerprint = confFingerprint(w.a.confDir)
	if w.fingerprint == w.spawnFingerprint {
		w.changeSeenAt = time.Time{}
		if w.badFingerprint != "" {
			w.badFingerprint = ""
			w.a.log("INFO", "配置已恢复到当前运行版本")
		}
		if w.blockReason != "" && w.state == stRunning {
			w.blockReason = ""
		}
	} else if w.fingerprint == w.badFingerprint {
		w.changeSeenAt = time.Time{}
	} else if w.changeSeenAt.IsZero() {
		w.changeSeenAt = time.Now()
		w.a.log("INFO", "检测到配置变化, 稳定 %s 后重启 sing-box", reloadDebounce)
	}

	if w.ch != nil && w.state == stRunning && time.Since(w.coreStartedAt) >= crashResetAfter {
		w.crashes = 0
	}

	if w.state == stStopping {
		alive := w.ch != nil && w.ch.alive()
		switch stopEscalation(w.forceKilled, w.deadlinePassed(), w.ch != nil, alive) {
		case stopActionKill:
			w.a.log("WARN", "sing-box 未在 %s 内退出, 发送 SIGKILL (pid %d)", stopGrace, w.childPid())
			w.ch.kill()
			w.forceKilled = true
			w.deadline = time.Now().Add(stopGrace)
		case stopActionStuck:
			w.a.log("ERROR", "sing-box 无法杀死 (pid %d), 继续等待", w.childPid())
			w.deadline = time.Now().Add(stopGrace)
		}
	}
	if w.state == stStopping && w.a.moduleDisabled() {
		w.restartAfterStop = false
	}

	w.unblocked = false
	if w.state == stBlocked && time.Now().After(w.nextPreflight) {
		w.nextPreflight = time.Now().Add(blockedRecheck)
		if w.preflight() == "" {
			w.unblocked = true
		}
	}

	ev, _ := deriveEvent(w.state, world{
		stopFlag:        fileExists(w.a.stopFlag),
		moduleDisabled:  w.a.moduleDisabled(),
		childJustExited: exited,
		childPresent:    w.ch != nil,
		childAlive:      w.ch != nil && processAlive(w.ch.pid),
		deadlinePassed:  w.deadlinePassed(),
		startConfirmed:  w.ch != nil && w.ch.alive(),
		unblocked:       w.unblocked,
		reloadDue:       reloadDue(w.state, w.changeSeenAt, time.Now()),
	})

	if ev == evReload {
		if reason := w.preflight(); reason != "" {
			w.badFingerprint = w.fingerprint
			w.changeSeenAt = time.Time{}
			w.blockReason = "配置错误, 已保留旧配置运行"
			w.a.log("ERROR", "新配置校验失败, 保持当前内核运行: %s", reason)
			ev = evNone
		} else {
			w.restartAfterStop = true
		}
	}

	if next, ok := transition(w.state, ev, w.restartAfterStop); ok {
		w.gotoState(next)
		return
	}
	w.updateDesc()
}

func (w *watchdog) gotoState(next st) {
	w.state = next
	w.forceKilled = false
	switch next {
	case stDisabled:
		w.deadline = time.Time{}
		w.restartAfterStop = false
		w.a.log("INFO", "sing-box 已停止 (模块已禁用)")
	case stStarting:
		w.deadline = time.Now().Add(startConfirm)
		if reason := w.preflight(); reason != "" {
			w.blockReason = reason
			w.a.log("ERROR", "启动受阻: %s", reason)
			w.state = stBlocked
			w.nextPreflight = time.Now().Add(blockedRecheck)
			break
		}
		c, err := startChild(w.a.bin, []string{"run", "-C", w.a.confDir}, w.a.dataDir, w.a.singboxLog)
		if err != nil {
			w.blockReason = "启动失败: " + err.Error()
			w.a.log("ERROR", "启动 sing-box 失败: %v", err)
			w.state = stBlocked
			break
		}
		w.ch = c
		w.coreStartedAt = time.Now()
		w.spawnFingerprint = w.fingerprint
		w.badFingerprint = ""
		w.changeSeenAt = time.Time{}
		w.blockReason = ""
		writeFile(w.a.pidFile, strconv.Itoa(c.pid)+"\n")
		w.a.log("INFO", "sing-box 启动 (pid %d)", c.pid)
	case stRunning:
		w.deadline = time.Time{}
	case stStopping:
		w.deadline = time.Now().Add(stopGrace)
		if w.ch != nil && w.ch.alive() {
			w.a.log("INFO", "正在停止 sing-box (pid %d, 重启=%v)", w.ch.pid, w.restartAfterStop)
			w.ch.term()
		}
	case stCrashBackoff:
		w.deadline = time.Now().Add(crashBackoff)
		w.a.log("WARN", "%s 后重启 sing-box", crashBackoff)
	case stExiting:
		w.deadline = time.Time{}
	}
	w.updateDesc()
}

func (w *watchdog) updateDesc() {
	// 状态文件兼做心跳: 内容没变且距上次写入不到 stateHeartbeat 时不重复写盘。
	snapshot := fmt.Sprintf("%s|%s|%d|%s", w.state, w.coreVersion, w.crashes, w.blockReason)
	if snapshot != w.lastState || time.Since(w.lastStateWrite) >= stateHeartbeat {
		w.lastState = snapshot
		w.lastStateWrite = time.Now()
		w.a.writeState(stateInfo{
			state:   w.state.String(),
			core:    w.coreVersion,
			crashes: w.crashes,
			reason:  w.blockReason,
		})
	}
	desc := w.a.describe()
	if desc == w.lastDesc {
		return
	}
	w.lastDesc = desc
	w.a.setDescription(desc)
}

func (w *watchdog) preflight() string {
	if !fileExists(w.a.bin) {
		return "sing-box 内核不存在: " + w.a.bin
	}
	if len(configFiles(w.a.confDir)) == 0 {
		return "配置不存在: " + w.a.confDir
	}
	// 工作目录与真实运行一致 (dataDir): 配置里的相对路径按同一套规则解析。
	// check 只跑 box.New 不启动服务, 不会打开/锁定 cache.db (真机验证过源码路径)。
	out, err := runWithTimeout(checkTimeout, w.a.dataDir, w.a.bin, "check", "-C", w.a.confDir)
	if err != nil {
		msg := strings.TrimSpace(string(out))
		if msg == "" {
			msg = err.Error()
		}
		return "配置校验失败: " + truncate(msg, 200)
	}
	return ""
}

func (w *watchdog) cleanup() {
	if w.ch != nil {
		if w.ch.alive() {
			w.a.log("INFO", "停止 sing-box (pid %d)", w.ch.pid)
			w.ch.term()
			waitExit(w.ch.pid, stopGrace)
			if processAlive(w.ch.pid) {
				w.a.log("WARN", "sing-box 未在 %s 内退出, 发送 SIGKILL (pid %d)", stopGrace, w.ch.pid)
				w.ch.kill()
				waitExit(w.ch.pid, 3*time.Second)
			}
		}
		w.ch = nil
	}
	removeFile(w.a.pidFile)
	removeFile(w.a.wpidFile)
	removeFile(w.a.stopFlag)
	w.a.writeState(stateInfo{state: "stopped", core: w.coreVersion})
	w.a.setDescription(w.a.describe())
	w.a.log("INFO", "看门狗退出")
}

// killOrphanCore 处理 "看门狗死了但内核还在" 的残留: 它不再受管, 必须清掉再重来。
func (w *watchdog) killOrphanCore() {
	pid := readPidFile(w.a.pidFile)
	if pid > 0 && ownsProcess(pid, w.a.bin) {
		w.a.log("WARN", "发现无人看管的内核进程 (pid %d), 先停止它", pid)
		signalPID(pid, syscall.SIGTERM)
		waitExit(pid, 5*time.Second)
		if processAlive(pid) {
			signalPID(pid, syscall.SIGKILL)
			waitExit(pid, 3*time.Second)
		}
	}
	removeFile(w.a.pidFile)
}

func (w *watchdog) selfHeal() {
	w.killOrphanCore()
	if !selfHealAllowed(w.a) {
		w.a.log("ERROR", "自愈次数过多 (1 小时内超过 %d 次), 停止自愈", maxSelfHealsPerHour)
		w.a.writeState(stateInfo{state: "failed", core: w.coreVersion, reason: "看门狗反复崩溃"})
		w.a.setDescription(w.a.describe())
		os.Exit(1)
	}
	clearCloexec(w.lockFd)
	_ = os.Setenv(lockFdEnv, strconv.Itoa(w.lockFd))
	exe := selfExe()
	w.a.log("WARN", "看门狗自愈: 重新 exec %s", exe)
	if err := syscall.Exec(exe, []string{exe, "watchdog_loop"}, os.Environ()); err != nil {
		w.a.log("ERROR", "自愈失败 (exec 失败): %v", err)
		os.Exit(1)
	}
}

func clearCloexec(fd int) {
	if fd <= 0 {
		return
	}
	_, _, _ = syscall.Syscall(syscall.SYS_FCNTL, uintptr(fd), syscall.F_SETFD, 0)
}

func selfHealAllowed(a *app) bool {
	path := filepath.Join(a.dataDir, ".watchdog-selfheal")
	now := time.Now().Unix()
	var kept []string
	for _, line := range strings.Split(readFile(path), "\n") {
		if v, err := strconv.ParseInt(strings.TrimSpace(line), 10, 64); err == nil && v >= now-3600 {
			kept = append(kept, strconv.FormatInt(v, 10))
		}
	}
	if len(kept) >= maxSelfHealsPerHour {
		writeFile(path, strings.Join(kept, "\n")+"\n")
		return false
	}
	kept = append(kept, strconv.FormatInt(now, 10))
	writeFile(path, strings.Join(kept, "\n")+"\n")
	return true
}

// coreVersion 取核心版本号用于模块描述。优先用 `version -n` (只输出版本号),
// 拿不到再回退解析 `version` 首行, 失败返回空串 (描述里就不显示)。
func coreVersion(bin string) string {
	if !fileExists(bin) {
		return ""
	}
	if out, err := runWithTimeout(5*time.Second, "", bin, "version", "-n"); err == nil {
		if v := strings.TrimSpace(string(out)); v != "" && !strings.ContainsAny(v, " \n") {
			return v
		}
	}
	out, err := runWithTimeout(5*time.Second, "", bin, "version")
	if err != nil {
		return ""
	}
	line := strings.TrimSpace(string(out))
	if i := strings.IndexByte(line, '\n'); i >= 0 {
		line = line[:i]
	}
	fields := strings.Fields(line)
	if len(fields) >= 3 && fields[0] == "sing-box" {
		return fields[2]
	}
	if len(fields) >= 1 {
		return fields[len(fields)-1]
	}
	return ""
}
