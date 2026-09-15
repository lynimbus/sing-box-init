package main

import (
	"os"
	"path/filepath"
	"strconv"
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

func TestConfFingerprintDetectsEveryKindOfChange(t *testing.T) {
	dir := t.TempDir()
	cfg := filepath.Join(dir, "config.json")
	writeFile(cfg, `{"a":1}`)
	base := confFingerprint(dir)

	writeFile(cfg, `{"a":2}`)
	st, _ := os.Stat(cfg)
	os.Chtimes(cfg, st.ModTime().Add(time.Second), st.ModTime().Add(time.Second))
	if confFingerprint(dir) == base {
		t.Fatal("内容与 mtime 变化后指纹应改变")
	}

	base = confFingerprint(dir)
	writeFile(filepath.Join(dir, "extra.json"), `{}`)
	if confFingerprint(dir) == base {
		t.Fatal("新增配置后指纹应改变")
	}

	base = confFingerprint(dir)
	removeFile(filepath.Join(dir, "extra.json"))
	if confFingerprint(dir) == base {
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
