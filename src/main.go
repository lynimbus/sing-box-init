package main

import (
	"fmt"
	"os"
	"time"
)

func main() {
	a := newApp()
	cmd := ""
	if len(os.Args) > 1 {
		cmd = os.Args[1]
	}
	switch cmd {
	case "start":
		cmdStart(a)
	case "stop":
		cmdStop(a)
	case "restart":
		cmdStop(a)
		cmdStart(a)
	case "status":
		fmt.Println(a.describe())
	case "watchdog_loop":
		runWatchdog(a)
	default:
		fmt.Println("usage: sing-box-init {start|stop|restart|status|watchdog_loop}")
	}
}

func cmdStart(a *app) {
	if !fileExists(a.bin) {
		a.log("ERROR", "sing-box 二进制不存在: %s", a.bin)
		return
	}
	if len(configFiles(a.confDir)) == 0 {
		a.log("ERROR", "配置不存在: %s", a.confDir)
		return
	}
	cleanStalePidFiles(a)
	if a.watchdogPid() > 0 {
		a.log("INFO", "看门狗已在运行, 跳过")
		a.setDescription(a.describe())
		return
	}
	removeFile(a.stopFlag)
	a.log("INFO", "拉起看门狗")
	if _, err := spawnDetached(selfExe(), []string{"watchdog_loop"}, a.watchdogLog); err != nil {
		a.log("ERROR", "无法拉起看门狗进程: %v", err)
		return
	}
	waitUntil(5*time.Second, func() bool { return a.watchdogPid() > 0 })
	if !a.moduleDisabled() {
		waitUntil(5*time.Second, func() bool { return a.corePid() > 0 })
	}
	a.setDescription(a.describe())
}

func cmdStop(a *app) {
	writeFile(a.stopFlag, "")
	// 先停看门狗, 再停内核: 顺序反了的话, 看门狗会在两者之间又拉起一个新内核,
	// 那个内核再也没人管 (真机上表现为"关了开关内核还在跑")。
	if pid := a.watchdogPid(); pid > 0 {
		a.log("INFO", "停止看门狗 (pid %d)", pid)
		waitExit(pid, 2*time.Second)
		if processAlive(pid) {
			signalPID(pid, sigTERM)
			waitExit(pid, stopGrace+2*time.Second)
		}
		if processAlive(pid) {
			a.log("WARN", "看门狗未退出, 发送 SIGKILL (pid %d)", pid)
			signalPID(pid, sigKILL)
			waitExit(pid, 3*time.Second)
		}
	}
	if pid := a.corePid(); pid > 0 {
		a.log("INFO", "停止 sing-box (pid %d)", pid)
		signalPID(pid, sigTERM)
		waitExit(pid, stopGrace)
		if processAlive(pid) {
			a.log("WARN", "sing-box 未在 %s 内退出, 发送 SIGKILL (pid %d)", stopGrace, pid)
			signalPID(pid, sigKILL)
			waitExit(pid, 3*time.Second)
		}
		if processAlive(pid) {
			a.log("ERROR", "sing-box 仍未被杀死 (pid %d)", pid)
		}
	}
	removeFile(a.pidFile)
	removeFile(a.wpidFile)
	removeFile(a.stopFlag)
	a.writeState(stateInfo{state: "stopped"})
	a.setDescription(a.describe())
	a.log("INFO", "sing-box 与看门狗已停止")
}

func cleanStalePidFiles(a *app) {
	for _, f := range []struct {
		path string
		exe  string
	}{
		{a.pidFile, a.bin},
		{a.wpidFile, selfExe()},
	} {
		pid := readPidFile(f.path)
		if pid <= 0 {
			continue
		}
		if !processAlive(pid) {
			removeFile(f.path)
			continue
		}
		if !ownsProcess(pid, f.exe) {
			a.log("WARN", "清理陈旧的 %s (pid %d 不是本模块进程)", f.path, pid)
			removeFile(f.path)
		}
	}
}

func waitUntil(d time.Duration, pred func() bool) bool {
	deadline := time.Now().Add(d)
	for time.Now().Before(deadline) {
		if pred() {
			return true
		}
		time.Sleep(100 * time.Millisecond)
	}
	return pred()
}
