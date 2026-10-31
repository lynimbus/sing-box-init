package main

import (
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
)

func testApp(t *testing.T) *app {
	t.Helper()
	dir := t.TempDir()
	a := &app{
		modDir:      filepath.Join(dir, "module"),
		dataDir:     filepath.Join(dir, "data"),
		bin:         filepath.Join(dir, "module", "bin", "sing-box"),
		confDir:     filepath.Join(dir, "data", "conf.d"),
		logDir:      filepath.Join(dir, "data", "logs"),
		watchdogLog: filepath.Join(dir, "data", "logs", "watchdog.log"),
		singboxLog:  filepath.Join(dir, "data", "logs", "sing-box.log"),
		pidFile:     filepath.Join(dir, "data", "sing-box.pid"),
		wpidFile:    filepath.Join(dir, "data", "sing-box-watchdog.pid"),
		stopFlag:    filepath.Join(dir, "data", ".stop"),
		lockFile:    filepath.Join(dir, "data", ".watchdog.lock"),
		stateFile:   filepath.Join(dir, "data", "logs", "watchdog.state"),
		moduleProp:  filepath.Join(dir, "module", "module.prop"),
		disableFlag: filepath.Join(dir, "module", "disable"),
		removeFlag:  filepath.Join(dir, "module", "remove"),
	}
	ensureDir(a.modDir)
	ensureDir(a.logDir)
	ensureDir(a.confDir)
	writeFile(a.moduleProp, "id=x\nname=x\nversion=1\nversionCode=1\ndescription=旧描述\n")
	return a
}

func TestTransitionNeverLeavesStoppingOnTermAlone(t *testing.T) {
	cases := []struct {
		name    string
		state   st
		event   ev
		restart bool
		want    st
		moved   bool
	}{
		{"stopping waits", stStopping, evNone, false, stStopping, false},
		{"stopping exit -> disabled", stStopping, evChildExited, false, stDisabled, true},
		{"stopping exit -> restart (reload)", stStopping, evChildExited, true, stStarting, true},
		{"stopping stopflag -> exiting", stStopping, evStopFlag, false, stExiting, true},
		{"running exit -> backoff", stRunning, evChildExited, false, stCrashBackoff, true},
		{"running reload -> stopping", stRunning, evReload, false, stStopping, true},
		{"running disable -> stopping", stRunning, evDisableOn, false, stStopping, true},
		{"disabled + enable -> starting", stDisabled, evDisableOff, false, stStarting, true},
		{"disabled ignores child exit", stDisabled, evChildExited, false, stDisabled, false},
		{"blocked + unblocked -> starting", stBlocked, evUnblocked, false, stStarting, true},
		{"blocked ignores reload", stBlocked, evReload, false, stBlocked, false},
		{"exiting is terminal", stExiting, evDisableOn, false, stExiting, false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got, ok := transition(c.state, c.event, c.restart)
			if got != c.want || ok != c.moved {
				t.Fatalf("transition(%v, %v, %v) = (%v, %v), 期望 (%v, %v)",
					c.state, c.event, c.restart, got, ok, c.want, c.moved)
			}
		})
	}
}

func TestDeriveEventDoesNotDeclareStoppedWhileChildAlive(t *testing.T) {
	alive := world{childPresent: true, childAlive: true, deadlinePassed: true}
	if e, ok := deriveEvent(stStopping, alive); ok {
		t.Fatalf("子进程仍存活却产生了事件 %v", e)
	}

	killed := world{childPresent: true, childAlive: false, deadlinePassed: true}
	if e, ok := deriveEvent(stStopping, killed); ok {
		t.Fatalf("Wait 未返回前不得判死, 得到 %v", e)
	}

	reaped := world{childJustExited: true, childPresent: true, childAlive: false}
	if e, ok := deriveEvent(stStopping, reaped); !ok || e != evChildExited {
		t.Fatalf("Wait 返回后应产生 evChildExited, 得到 (%v, %v)", e, ok)
	}

	gone := world{childPresent: false}
	if e, ok := deriveEvent(stStopping, gone); !ok || e != evChildExited {
		t.Fatalf("没有子进程句柄时不应卡在 Stopping, 得到 (%v, %v)", e, ok)
	}
}

func TestDeriveEventPriority(t *testing.T) {
	both := world{stopFlag: true, moduleDisabled: true, childJustExited: true, childPresent: false}
	if e, _ := deriveEvent(stRunning, both); e != evStopFlag {
		t.Fatalf("stop 标记优先级最高, 得到 %v", e)
	}

	disabledWithExit := world{moduleDisabled: true, childJustExited: true}
	if e, _ := deriveEvent(stRunning, disabledWithExit); e != evDisableOn {
		t.Fatalf("同一 tick 内禁用优先于子进程退出, 得到 %v", e)
	}

	stopping := world{moduleDisabled: true, childPresent: true, childAlive: true}
	if e, ok := deriveEvent(stStopping, stopping); ok {
		t.Fatalf("Stopping 期间禁用不应打断停止流程, 得到 %v", e)
	}

	starting := world{childPresent: true, childAlive: true, startConfirmed: true, deadlinePassed: true}
	if e, _ := deriveEvent(stStarting, starting); e != evStartConfirmed {
		t.Fatalf("确认启动优先于超时, 得到 %v", e)
	}
}

func TestStopEscalation(t *testing.T) {
	cases := []struct {
		name           string
		forceKilled    bool
		deadlinePassed bool
		present        bool
		alive          bool
		want           stopAction
	}{
		{"正常等待", false, false, true, true, stopActionNone},
		{"超时升级为 SIGKILL", false, true, true, true, stopActionKill},
		{"已强杀仍不死则继续等", true, true, true, true, stopActionStuck},
		{"进程已死不再补刀", false, true, true, false, stopActionNone},
		{"无句柄不动作", false, true, false, false, stopActionNone},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := stopEscalation(c.forceKilled, c.deadlinePassed, c.present, c.alive); got != c.want {
				t.Fatalf("stopEscalation = %v, 期望 %v", got, c.want)
			}
		})
	}
}

func TestReloadDueNeedsDebounceAndRunning(t *testing.T) {
	now := time.Now()
	seen := now.Add(-500 * time.Millisecond)
	if reloadDue(stRunning, seen, now) {
		t.Fatal("去抖未到期不应触发重载")
	}
	if !reloadDue(stRunning, now.Add(-reloadDebounce-time.Millisecond), now) {
		t.Fatal("去抖到期应触发重载")
	}
	if reloadDue(stStopping, now.Add(-time.Hour), now) {
		t.Fatal("非 Running 状态不应触发重载")
	}
	if reloadDue(stRunning, time.Time{}, now) {
		t.Fatal("无变化时不应触发重载")
	}
}

func TestConfScannerDetectsEveryKindOfChange(t *testing.T) {
	dir := t.TempDir()
	cfg := filepath.Join(dir, "config.json")
	var scan confScanner
	fp := func() string { return scan.fingerprint(dir) }
	writeFile(cfg, `{"a":1}`)
	base := fp()

	writeFile(cfg, `{"a":2}`)
	st, _ := os.Stat(cfg)
	os.Chtimes(cfg, st.ModTime().Add(time.Second), st.ModTime().Add(time.Second))
	if fp() == base {
		t.Fatal("内容与 mtime 变化后指纹应改变")
	}

	base = fp()
	writeFile(filepath.Join(dir, "extra.json"), `{}`)
	if fp() == base {
		t.Fatal("新增配置后指纹应改变")
	}

	base = fp()
	removeFile(filepath.Join(dir, "extra.json"))
	if fp() == base {
		t.Fatal("删除配置后指纹应改变")
	}
}

func TestRewriteModulePropDescOnlyTouchesDescription(t *testing.T) {
	a := testApp(t)
	a.rewriteModulePropDesc("sing-box: 运行中 (pid 1)")
	got := readFile(a.moduleProp)
	want := "id=x\nname=x\nversion=1\nversionCode=1\ndescription=sing-box: 运行中 (pid 1)\n"
	if got != want {
		t.Fatalf("module.prop 改写结果不对:\n%q\n期望:\n%q", got, want)
	}

	removeFile(a.moduleProp)
	writeFile(a.moduleProp, "id=x\n")
	a.rewriteModulePropDesc("新描述")
	if got := readFile(a.moduleProp); got != "id=x\n" {
		t.Fatalf("没有 description 行时不应写坏文件: %q", got)
	}
}

func TestDescribeReflectsRealProcessState(t *testing.T) {
	a := testApp(t)
	writeFile(a.pidFile, strconv.Itoa(os.Getpid())+"\n")
	a.bin = selfExe()
	a.writeState(stateInfo{state: "running", core: "1.15.0-alpha.3", crashes: 2})

	desc := a.describe()
	if desc != "sing-box: 运行中 (pid "+strconv.Itoa(os.Getpid())+", core 1.15.0-alpha.3, 崩溃 2 次) [看门狗未运行]" {
		t.Fatalf("描述不符合预期: %q", desc)
	}

	writeFile(a.pidFile, "999999\n")
	if desc := a.describe(); desc != "sing-box: 未运行" {
		t.Fatalf("陈旧的 pid 不应被当成运行中: %q", desc)
	}

	writeFile(a.pidFile, "not-a-pid\n")
	if desc := a.describe(); desc != "sing-box: 未运行" {
		t.Fatalf("非法 pid 文件不应被当成运行中: %q", desc)
	}
}

func TestOwnsProcessRejectsLookalike(t *testing.T) {
	if ownsProcess(os.Getpid(), "/bin/definitely-not-this-binary") {
		t.Fatal("不同可执行文件的进程不应被判为本模块进程")
	}
	if !ownsProcess(os.Getpid(), selfExe()) {
		t.Fatal("自身进程应被判为本模块进程")
	}
}

func TestSelfHealRateLimit(t *testing.T) {
	a := testApp(t)
	for i := 0; i < maxSelfHealsPerHour; i++ {
		if !selfHealAllowed(a) {
			t.Fatalf("第 %d 次自愈不应被限流", i+1)
		}
	}
	if selfHealAllowed(a) {
		t.Fatal("超过每小时上限后应停止自愈")
	}
}

func TestReadPidFile(t *testing.T) {
	a := testApp(t)
	writeFile(a.pidFile, " 1234 \n")
	if got := readPidFile(a.pidFile); got != 1234 {
		t.Fatalf("readPidFile = %d, 期望 1234", got)
	}
	writeFile(a.pidFile, "0\n")
	if got := readPidFile(a.pidFile); got != -1 {
		t.Fatalf("pid 0 应视为无效, 得到 %d", got)
	}
	removeFile(a.pidFile)
	if got := readPidFile(a.pidFile); got != -1 {
		t.Fatalf("文件不存在应返回 -1, 得到 %d", got)
	}
}

func TestRotateLogKeepsOnlyLatestGenerations(t *testing.T) {
	dir := t.TempDir()
	log := filepath.Join(dir, "sing-box.log")

	rotateLog(log, coreLogKeep)
	if fileExists(log) {
		t.Fatal("没有当前日志时不应凭空造出归档")
	}

	for i := 1; i <= 5; i++ {
		rotateLog(log, coreLogKeep)
		writeFile(log, "第 "+strconv.Itoa(i)+" 次启动\n")
	}

	if got := readFile(log); got != "第 5 次启动\n" {
		t.Fatalf("当前日志应是最近一次启动: %q", got)
	}
	if got := readFile(rotatedLogPath(log, 1)); got != "第 4 次启动\n" {
		t.Fatalf(".1 应是上一次启动: %q", got)
	}
	if got := readFile(rotatedLogPath(log, 2)); got != "第 3 次启动\n" {
		t.Fatalf(".2 应是上上次启动: %q", got)
	}
	if fileExists(rotatedLogPath(log, 3)) {
		t.Fatal("只保留 3 次启动, 不应留下第 3 代归档")
	}
}

func TestTickIntervalFor(t *testing.T) {
	if tickIntervalFor(stRunning) != idleTick || tickIntervalFor(stDisabled) != idleTick || tickIntervalFor(stBlocked) != idleTick {
		t.Fatal("稳态状态应降频到 idleTick")
	}
	for _, s := range []st{stStarting, stStopping, stCrashBackoff, stExiting} {
		if tickIntervalFor(s) != tickInterval {
			t.Fatalf("瞬态状态 %v 应保持快 tick", s)
		}
	}
}

func TestConfScannerReuseAndNoAliasing(t *testing.T) {
	dir := t.TempDir()
	writeFile(filepath.Join(dir, "b.json"), `{}`)
	writeFile(filepath.Join(dir, "a.json"), `{}`)

	var cs confScanner
	f1 := cs.fingerprint(dir)
	// 未变化的复扫: 结果应等于旧串且不换新串 (无别名)
	f2 := cs.fingerprint(dir)
	if f1 != f2 {
		t.Fatalf("未变化的目录指纹不应漂移: %q vs %q", f1, f2)
	}
	if &f1 == &f2 {
		t.Fatal("不可言: 两次调用的返回值地址")
	}

	// 变化后必须产生新串
	writeFile(filepath.Join(dir, "a.json"), `{"x":1}`)
	f3 := cs.fingerprint(dir)
	if f3 == f2 {
		t.Fatal("内容变化必须改变指纹")
	}
	if !strings.Contains(f3, "a.json") || strings.HasPrefix(f3, "b.json") {
		t.Fatalf("指纹应按文件名排序: %q", f3)
	}
	// 无别名: 指纹含 mtime, 同内容重写也算变化; 先前返回值的底层字节
	// 不得被内部缓冲的后续复用所覆写
	snap := []byte(f2)
	writeFile(filepath.Join(dir, "a.json"), `{"y":2}`)
	cs.fingerprint(dir)
	cs.fingerprint(filepath.Join(dir, "nope")) // unreadable 分支也不能破坏状态
	if string(snap) != f2 {
		t.Fatalf("先前返回的指纹被覆写: %q -> %q", string(snap), f2)
	}
}

func TestDescFromMemory(t *testing.T) {
	a := testApp(t)
	// 用脚本内核当真子进程: pid 文件指向它, ownsProcess 经 argv[1] 精确命中,
	// 磁盘版 describe() 因此能给出 "运行中" —— 与看门狗视角一致
	ensureDir(filepath.Dir(a.bin))
	writeFile(a.bin, "#!/bin/sh\nsleep 30\n")
	_ = os.Chmod(a.bin, 0o755)
	c, err := startChild(a.bin, nil, a.dataDir, filepath.Join(a.logDir, "core.log"))
	if err != nil {
		t.Fatalf("stub 内核启动失败: %v", err)
	}
	defer func() {
		c.kill()
		<-c.done
	}()
	writeFile(a.pidFile, strconv.Itoa(c.pid)+"\n")
	writeFile(a.wpidFile, strconv.Itoa(os.Getpid())+"\n")
	w := &watchdog{a: a, coreVersion: "stub-1.0", crashes: 2, ch: c}
	w.state = stRunning
	w.blockReason = "配置错误, 已保留旧配置运行"
	a.writeState(stateInfo{state: w.state.String(), core: w.coreVersion, crashes: w.crashes, reason: w.blockReason})
	if got, want := w.descFromMemory(), a.describe(); got != want {
		t.Fatalf("运行中: 内存版 %q != 磁盘版 %q", got, want)
	}

	// 崩溃计数变化 (心跳周期内): 内存版必须立即反映, 磁盘版读的是旧 state 文件
	w.crashes = 3
	if got := w.descFromMemory(); !strings.Contains(got, "崩溃 3 次") {
		t.Fatalf("内存版应立即反映最新崩溃计数: %q", got)
	}
	w.crashes = 2

	w.ch = nil
	removeFile(a.pidFile)
	for _, s := range []st{stStarting, stStopping, stCrashBackoff, stBlocked, stDisabled, stRunning} {
		w.state = s
		w.blockReason = ""
		if s == stBlocked {
			w.blockReason = "配置校验失败: boom"
		}
		if s == stDisabled {
			writeFile(a.disableFlag, "")
		} else {
			removeFile(a.disableFlag)
		}
		a.writeState(stateInfo{state: s.String(), core: w.coreVersion, crashes: w.crashes, reason: w.blockReason})
		if got, want := w.descFromMemory(), a.describe(); got != want {
			t.Fatalf("%v: 内存版 %q != 磁盘版 %q", s, got, want)
		}
	}
}

func TestConfScannerUnreadableDir(t *testing.T) {
	var cs confScanner
	if f := cs.fingerprint(filepath.Join(t.TempDir(), "nope")); f != "unreadable" {
		t.Fatalf("不存在的目录应返回 unreadable: %q", f)
	}
}

func TestRotateLogIgnoresEmptyCurrentLog(t *testing.T) {
	dir := t.TempDir()
	log := filepath.Join(dir, "sing-box.log")
	writeFile(log, "")
	writeFile(rotatedLogPath(log, 1), "旧启动\n")

	rotateLog(log, coreLogKeep)

	if got := readFile(rotatedLogPath(log, 1)); got != "旧启动\n" {
		t.Fatalf("空日志不应挤掉已有归档: %q", got)
	}
	if fileExists(log) {
		t.Fatal("空日志应被删除")
	}
}
